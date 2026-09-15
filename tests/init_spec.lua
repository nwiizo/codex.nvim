local h = require("tests.harness")
local codex = require("codex")
local config = require("codex.config")

h.test("reports the release version", function()
  h.eq("0.0.4", codex.version)
end)

h.test("add_paths sends one composer update and emits normalized context", function()
  codex._reset()
  local sent
  local project_dir = vim.fn.tempname()
  vim.fn.mkdir(project_dir, "p")
  local original_terminal = package.loaded["codex.terminal"]
  package.loaded["codex.terminal"] = {
    status = function()
      return { backend = "terminal", cwd = project_dir, running = true, visible = false, jobid = 42 }
    end,
    send = function(text, opts)
      sent = { text = text, opts = opts }
      if opts.on_complete then
        opts.on_complete(true)
      end
      return true
    end,
  }
  config.setup({ cwd = "nvim" })

  local first = project_dir .. "/first.lua"
  local second = project_dir .. "/second.lua"
  vim.fn.writefile({}, first)
  vim.fn.writefile({}, second)
  local expected_first = "first.lua"
  local expected_second = "second.lua"
  local ok = codex.add_paths({ first, second }, "test")
  local status = codex.status()

  package.loaded["codex.terminal"] = original_terminal
  vim.fn.delete(project_dir, "rf")
  h.truthy(ok)
  h.contains(sent.text, "@" .. first)
  h.contains(sent.text, "@" .. second)
  h.eq(false, sent.opts.submit)
  local receipt = status.last_context
  h.truthy(receipt)
  h.eq("files", receipt.kind)
  h.eq({ expected_first, expected_second }, receipt.paths)
  h.eq(project_dir, receipt.cwd)
  h.eq("test", receipt.source)
  h.eq(false, receipt.submitted)
  h.contains(codex.status_message(status), "last context: files")
  h.contains(codex.status_message(status), "inserted (cwd " .. project_dir .. ")")
  codex._reset()
end)

h.test("status resolves the next cwd while Codex is stopped", function()
  codex._reset()
  local original_terminal = package.loaded["codex.terminal"]
  package.loaded["codex.terminal"] = {
    status = function()
      return { backend = "terminal", running = false, visible = false }
    end,
  }
  config.setup({ cwd = "nvim" })

  local status = codex.status()

  package.loaded["codex.terminal"] = original_terminal
  h.eq(vim.uv.cwd(), status.resolved_cwd)
  h.contains(codex.status_message(status), "terminal stopped (next cwd ")
end)

h.test("context status distinguishes submitted selections from inserted files", function()
  local message = require("codex.receipt").format_context({
    kind = "visual",
    file_path = "lua/codex/init.lua",
    start_line = 10,
    end_line = 12,
    cwd = "/tmp/codex.nvim",
    source = "visual",
    submitted = true,
  })
  h.eq("visual @lua/codex/init.lua:10-12, submitted (cwd /tmp/codex.nvim)", message)
end)

h.test("range sends record a submitted context receipt", function()
  codex._reset()
  local sent
  local sent_opts
  local original_terminal = package.loaded["codex.terminal"]
  package.loaded["codex.terminal"] = {
    status = function()
      return { backend = "terminal", cwd = "/tmp", running = true, visible = true, jobid = 43 }
    end,
    send = function(text, opts)
      sent = text
      sent_opts = opts
      if opts.on_complete then
        opts.on_complete(true)
      end
      return true
    end,
  }
  config.setup({ cwd = "nvim" })
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, "/tmp/context-receipt.lua")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local one = 1", "local two = 2" })
  local absolute_path = vim.api.nvim_buf_get_name(bufnr)

  h.truthy(codex.send_range(1, 2, bufnr))
  local status = codex.status()

  package.loaded["codex.terminal"] = original_terminal
  vim.api.nvim_buf_delete(bufnr, { force = true })
  h.contains(sent, "@" .. absolute_path .. " (lines 1-2)")
  h.eq(true, sent_opts.submit)
  local receipt = status.last_context
  h.truthy(receipt)
  ---@cast receipt CodexNvimContextReceipt
  h.eq("range", receipt.kind)
  h.eq("context-receipt.lua", receipt.file_path)
  h.eq(true, receipt.submitted)
  codex._reset()
end)

h.test("add_visual inserts exact selection without submitting", function()
  codex._reset()
  local sent
  local original_buf = vim.api.nvim_get_current_buf()
  local original_terminal = package.loaded["codex.terminal"]
  local bufnr = vim.api.nvim_create_buf(true, false)
  local ok, err = xpcall(function()
    vim.api.nvim_buf_set_name(bufnr, "/tmp/visual-draft.lua")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local one = 1", "local two = 2" })
    local absolute_path = vim.api.nvim_buf_get_name(bufnr)
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("normal! gg06lvj2l")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)

    package.loaded["codex.terminal"] = {
      status = function()
        return { backend = "terminal", cwd = "/tmp", running = true, visible = true, jobid = 45 }
      end,
      send = function(text, opts)
        sent = { text = text, opts = opts }
        if opts.on_complete then
          opts.on_complete(true)
        end
        return true
      end,
    }
    config.setup({ cwd = "nvim" })

    h.truthy(codex.add_visual(bufnr))
    local status = codex.status()

    h.contains(sent.text, "one = 1")
    h.contains(sent.text, "local two")
    h.contains(sent.text, "@" .. absolute_path)
    h.eq("\n\n", sent.text:sub(-2))
    h.eq(false, sent.opts.submit)
    local receipt = status.last_context
    h.truthy(receipt)
    ---@cast receipt CodexNvimContextReceipt
    h.eq("visual", receipt.kind)
    h.eq("visual-draft.lua", receipt.file_path)
    h.eq(false, receipt.submitted)
    h.contains(codex.status_message(status), "inserted")
  end, debug.traceback)

  if vim.api.nvim_buf_is_valid(original_buf) then
    vim.api.nvim_set_current_buf(original_buf)
  end
  package.loaded["codex.terminal"] = original_terminal
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
  codex._reset()
  if not ok then
    error(err, 0)
  end
end)

h.test("add_visual inserts unnamed readonly buffer text without submitting", function()
  codex._reset()
  local sent
  local original_buf = vim.api.nvim_get_current_buf()
  local original_terminal = package.loaded["codex.terminal"]
  local bufnr = vim.api.nvim_create_buf(false, true)
  local ok, err = xpcall(function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "mail body", "unselected text" })
    vim.bo[bufnr].filetype = "mail"
    vim.bo[bufnr].readonly = true
    vim.bo[bufnr].modifiable = false
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("normal! gg0v3l")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)

    package.loaded["codex.terminal"] = {
      status = function()
        return { backend = "terminal", cwd = "/tmp", running = true, visible = true, jobid = 46 }
      end,
      send = function(text, opts)
        sent = { text = text, opts = opts }
        opts.on_complete(true)
        return true
      end,
    }
    config.setup({ cwd = "nvim" })

    h.truthy(codex.add_visual(bufnr))
    h.eq("Use this Neovim selection from an unnamed buffer (lines 1-1):\n```mail\nmail\n```\n\n", sent.text)
    h.eq(false, sent.opts.submit)
    local status = codex.status()
    h.eq(nil, status.last_context.file_path)
    h.eq(false, status.last_context.submitted)
    h.contains(codex.status_message(status), "visual [No Name]:1-1, inserted (cwd /tmp)")
    h.eq("", vim.api.nvim_buf_get_name(bufnr))
    h.eq(false, vim.bo[bufnr].modifiable)
  end, debug.traceback)

  vim.api.nvim_set_current_buf(original_buf)
  package.loaded["codex.terminal"] = original_terminal
  vim.api.nvim_buf_delete(bufnr, { force = true })
  codex._reset()
  if not ok then
    error(err, 0)
  end
end)

h.test("failed context delivery does not record a receipt", function()
  codex._reset()
  local completion
  local original_terminal = package.loaded["codex.terminal"]
  package.loaded["codex.terminal"] = {
    status = function()
      return { backend = "terminal", cwd = "/tmp", running = true, visible = true, jobid = 44 }
    end,
    send = function(_, opts)
      completion = opts.on_complete
      return true
    end,
  }
  config.setup({ cwd = "nvim" })
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, "/tmp/failed-context-receipt.lua")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "return false" })

  h.truthy(codex.send_range(1, 1, bufnr))
  h.eq(nil, codex.status().last_context)
  h.truthy(completion)
  ---@cast completion fun(ok: boolean)
  completion(false)
  h.eq(nil, codex.status().last_context)

  package.loaded["codex.terminal"] = original_terminal
  vim.api.nvim_buf_delete(bufnr, { force = true })
  codex._reset()
end)

h.test("review arguments map to app-server review targets", function()
  h.eq({ type = "uncommittedChanges" }, codex._review_target({}))
  h.eq({ type = "baseBranch", branch = "main" }, codex._review_target({ "--base", "main" }))
  h.eq({ type = "commit", sha = "abc123" }, codex._review_target({ "--commit", "abc123" }))
  h.eq({ type = "custom", instructions = "focus on safety" }, codex._review_target({ "focus", "on", "safety" }))
end)

h.test("terminal review preserves options and combines a multiword prompt", function()
  h.eq({}, codex._terminal_review_args({}))
  h.eq({ "--base", "main" }, codex._terminal_review_args({ "--base", "main" }))
  h.eq({ "focus on safety" }, codex._terminal_review_args({ "focus", "on", "safety" }))
end)
