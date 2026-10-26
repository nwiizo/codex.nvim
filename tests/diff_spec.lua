local h = require("tests.harness")
local codex = require("codex")
local ui = require("codex.app_server.ui")

local function with_repository(callback)
  local root = vim.fn.tempname() .. " repo with spaces"
  vim.fn.mkdir(root, "p")
  local original_terminal = package.loaded["codex.terminal"]
  local original_notify = vim.notify
  local messages = {}
  local function git(args)
    local argv = { "git", "-C", root }
    vim.list_extend(argv, args)
    local result = vim
      .system(argv, {
        text = true,
        env = { GIT_CONFIG_NOSYSTEM = "1", GIT_CONFIG_GLOBAL = "/dev/null" },
      })
      :wait()
    h.eq(0, result.code, result.stderr)
    return result.stdout
  end
  rawset(vim, "notify", function(message)
    table.insert(messages, message)
  end)
  package.loaded["codex.terminal"] = {
    status = function()
      return { running = true, cwd = root }
    end,
  }
  require("codex.config").setup({ backend = "terminal" })
  local ok, err = pcall(callback, root, git, messages)
  ui.reset()
  package.loaded["codex.terminal"] = original_terminal
  rawset(vim, "notify", original_notify)
  vim.fn.delete(root, "rf")
  if not ok then
    error(err, 0)
  end
end

h.test("terminal diff shows staged and unstaged changes without modifying files or index", function()
  with_repository(function(root, git)
    git({ "init", "-q" })
    git({ "config", "diff.external", "false" })
    vim.fn.writefile({ "staged text" }, root .. "/sample.txt")
    git({ "add", "sample.txt" })
    vim.fn.writefile({ "working text" }, root .. "/sample.txt")
    vim.fn.writefile({ "untracked text" }, root .. "/untracked.txt")
    local before = git({ "status", "--porcelain" })
    h.truthy(codex.show_diff())
    h.truthy(vim.wait(3000, function()
      return vim.api.nvim_buf_get_name(0) == "codex://git-diff"
    end, 10))
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    h.contains(text, "Unstaged changes")
    h.contains(text, "+working text")
    h.contains(text, "Staged changes")
    h.contains(text, "+staged text")
    h.eq(nil, text:find("untracked text", 1, true))
    h.eq("nofile", vim.bo.buftype)
    h.eq(false, vim.bo.modifiable)
    h.eq("diff", vim.bo.filetype)
    h.eq(before, git({ "status", "--porcelain" }))
    h.eq("staged text\n", git({ "show", ":sample.txt" }))
    h.eq({ "working text" }, vim.fn.readfile(root .. "/sample.txt"))
  end)
end)

h.test("terminal diff works without starting a session and reports an empty repository", function()
  with_repository(function(root, git, messages)
    git({ "init", "-q" })
    package.loaded["codex.terminal"].status = function()
      return { running = false }
    end
    require("codex.config").setup({ cwd = root })
    local before = vim.api.nvim_get_current_buf()
    h.truthy(codex.show_diff())
    h.truthy(vim.wait(3000, function()
      return #messages > 0
    end, 10))
    h.contains(messages[#messages], "no tracked Git changes")
    h.eq(before, vim.api.nvim_get_current_buf())
  end)
end)

h.test("terminal diff reports Git failures without opening a buffer", function()
  with_repository(function(_, _, messages)
    local before = vim.api.nvim_get_current_buf()
    h.truthy(codex.show_diff())
    h.truthy(vim.wait(3000, function()
      return #messages > 0
    end, 10))
    h.contains(messages[#messages], "could not read Git diff")
    h.eq(before, vim.api.nvim_get_current_buf())
  end)
end)
