local h = require("tests.harness")
local config = require("codex.config")
local terminal = require("codex.terminal")

-- A deterministic command loop accepting the same paste framing as the TUI.
local command_loop = [[
paste_start=$(printf '\033[200~'); paste_end=$(printf '\033[201~')
while IFS= read -r line; do
  line=${line#"$paste_start"}; line=${line%"$paste_end"}
  eval "$line"
done
]]
local ready_shell = { "sh", "-c", "printf '\\033[0 q\\033[?25h'; " .. command_loop }

local function with_failed_split(callback)
  local original_cmd = vim.cmd
  local original_notify = vim.notify
  rawset(vim, "cmd", function(command)
    if type(command) == "string" and command:find("vsplit", 1, true) then
      error("simulated split failure")
    end
    return original_cmd(command)
  end)
  rawset(vim, "notify", function() end)

  local ok, result = pcall(callback)

  rawset(vim, "notify", original_notify)
  rawset(vim, "cmd", original_cmd)
  if not ok then
    error(result, 0)
  end
  return result
end

local function with_failed_float(callback)
  local original_open_win = vim.api.nvim_open_win
  local original_notify = vim.notify
  rawset(vim.api, "nvim_open_win", function()
    error("simulated float failure")
  end)
  rawset(vim, "notify", function() end)

  local ok, result = pcall(callback)

  rawset(vim, "notify", original_notify)
  rawset(vim.api, "nvim_open_win", original_open_win)
  if not ok then
    error(result, 0)
  end
  return result
end

local function with_failed_buffer_attach(callback)
  local original_set_buf = vim.api.nvim_win_set_buf
  local original_notify = vim.notify
  rawset(vim.api, "nvim_win_set_buf", function()
    error("simulated buffer attach failure")
  end)
  rawset(vim, "notify", function() end)

  local ok, result = pcall(callback)

  rawset(vim, "notify", original_notify)
  rawset(vim.api, "nvim_win_set_buf", original_set_buf)
  if not ok then
    error(result, 0)
  end
  return result
end

local function with_failed_winnew(callback)
  local original_notify = vim.notify
  local group = vim.api.nvim_create_augroup("codex_nvim_test_failed_winnew", { clear = true })
  vim.api.nvim_create_autocmd("WinNew", {
    group = group,
    once = true,
    callback = function()
      error("simulated WinNew failure")
    end,
  })
  rawset(vim, "notify", function() end)

  local ok, result = pcall(callback)

  rawset(vim, "notify", original_notify)
  pcall(vim.api.nvim_del_augroup_by_id, group)
  if not ok then
    error(result, 0)
  end
  return result
end

h.test("terminal builds argv without shell interpolation", function()
  config.setup({ cmd = { "codex", "--profile", "work" } })
  h.eq({ "codex", "--profile", "work", "resume", "--last" }, terminal._build_argv("resume", { "--last" }))
end)

h.test("terminal wraps multiline input as bracketed paste", function()
  h.eq("hello", terminal._encode("hello"))
  h.eq("\27[200~hello\27[201~", terminal._encode("hello", true))
  h.eq("\27[200~one\ntwo\27[201~", terminal._encode("one\ntwo"))
end)

h.test("terminal guidance survives custom winbars and follows terminal input mode", function()
  terminal._reset()
  config.setup({ cmd = ready_shell, terminal = { auto_insert = false } })
  local editor = vim.api.nvim_get_current_win()
  local original_mode = vim.fn.mode
  local group = vim.api.nvim_create_augroup("codex_test_custom_winbar", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "CodexStarted", "CodexOpened" },
    callback = function(event)
      vim.wo[event.data.winid].winbar = "My actions"
    end,
  })
  local ok, err = xpcall(function()
    h.truthy(terminal.open())
    vim.wait(50)
    local function hint()
      local winid = terminal.status().winid
      local winbar = vim.wo[winid].winbar
      return vim.api.nvim_eval_statusline(winbar, { winid = winid, use_winbar = true, maxwidth = 200 }).str
    end
    h.contains(hint(), "Press i")
    h.contains(hint(), "My actions")
    -- Terminal input mode needs an attached UI; cover its renderer here, while
    -- keeping the actual PTY, windows, lifecycle callbacks and winbar evaluation.
    rawset(vim.fn, "mode", function()
      return "t"
    end)
    local input_hint = hint()
    rawset(vim.fn, "mode", original_mode)
    h.contains(input_hint, "Enter to send")
    h.contains(hint(), "Press i")
    h.truthy(terminal.hide())
    h.eq(editor, vim.api.nvim_get_current_win())
    h.truthy(terminal.show())
    vim.wait(50)
    h.contains(hint(), "Press i")
    local _, copies = hint():gsub("My actions", "")
    h.eq(1, copies)
    vim.wo.winbar = "%!'Dynamic actions'"
    vim.api.nvim_exec_autocmds("WinEnter", { buffer = terminal.status().bufnr })
    vim.wait(50)
    h.eq("Dynamic actions", hint())
    vim.wo.winbar = "My actions"
    vim.api.nvim_exec_autocmds("WinEnter", { buffer = terminal.status().bufnr })
    vim.wait(50)
    vim.api.nvim_set_current_win(editor)
    h.contains(hint(), "Focus")
  end, debug.traceback)
  rawset(vim.fn, "mode", original_mode)
  vim.api.nvim_del_augroup_by_id(group)
  terminal._reset()
  if not ok then
    error(err, 0)
  end
end)

h.test("failed terminal start cleans up its split and state", function()
  terminal._reset()
  config.setup({
    cmd = { "/definitely/not/a/codex/binary" },
    terminal = { auto_insert = false },
  })
  local windows_before = #vim.api.nvim_list_wins()
  local original_notify = vim.notify
  rawset(vim, "notify", function() end)
  local ok, result = pcall(terminal.open, { focus = false })
  rawset(vim, "notify", original_notify)
  h.eq(true, ok)
  h.eq(false, result)
  h.eq(windows_before, #vim.api.nvim_list_wins())
  h.eq(false, terminal.status().running)
  h.eq(false, terminal.status().visible)
end)

h.test("failed initial split does not leak buffer state", function()
  terminal._reset()
  config.setup({
    cmd = ready_shell,
    terminal = { auto_insert = false },
  })

  h.eq(
    false,
    with_failed_split(function()
      return terminal.open({ focus = false })
    end)
  )
  h.eq(nil, terminal.status().bufnr)
  h.eq(false, terminal.is_running())
end)

h.test("failed send auto-start does not leak buffer state", function()
  terminal._reset()
  config.setup({
    cmd = ready_shell,
    terminal = { auto_insert = false },
  })
  local completed

  h.eq(
    false,
    with_failed_split(function()
      return terminal.send("draft", {
        submit = false,
        on_complete = function(ok)
          completed = ok
        end,
      })
    end)
  )
  h.eq(false, completed)
  h.eq(nil, terminal.status().bufnr)
  h.eq(false, terminal.is_running())
end)

h.test("failed initial float does not leak buffer state", function()
  terminal._reset()
  config.setup({
    cmd = ready_shell,
    terminal = { layout = "float", auto_insert = false },
  })

  h.eq(
    false,
    with_failed_float(function()
      return terminal.open({ focus = false })
    end)
  )
  h.eq(nil, terminal.status().bufnr)
  h.eq(false, terminal.is_running())
end)

h.test("partially created split is rolled back", function()
  terminal._reset()
  config.setup({
    cmd = ready_shell,
    terminal = { auto_insert = false },
  })
  local original_win = vim.api.nvim_get_current_win()
  local windows_before = #vim.api.nvim_list_wins()

  h.eq(
    false,
    with_failed_buffer_attach(function()
      return terminal.open({ focus = false })
    end)
  )
  h.eq(windows_before, #vim.api.nvim_list_wins())
  h.eq(original_win, vim.api.nvim_get_current_win())
  h.eq(nil, terminal.status().bufnr)
  h.eq(false, terminal.is_running())
end)

h.test("split created before a WinNew error is rolled back", function()
  terminal._reset()
  config.setup({
    cmd = ready_shell,
    terminal = { auto_insert = false },
  })
  local original_win = vim.api.nvim_get_current_win()
  local windows_before = #vim.api.nvim_list_wins()

  h.eq(
    false,
    with_failed_winnew(function()
      return terminal.open({ focus = false })
    end)
  )
  h.eq(windows_before, #vim.api.nvim_list_wins())
  h.eq(original_win, vim.api.nvim_get_current_win())
  h.eq(nil, terminal.status().bufnr)
  h.eq(false, terminal.is_running())
end)

h.test("failed split restore preserves a hidden session", function()
  terminal._reset()
  config.setup({
    cmd = ready_shell,
    terminal = { auto_insert = false, auto_close = true },
  })
  h.truthy(terminal.open({ focus = false }))
  local bufnr = terminal.status().bufnr
  h.truthy(terminal.hide())

  h.eq(
    false,
    with_failed_split(function()
      return terminal.show({ focus = false })
    end)
  )
  h.eq(bufnr, terminal.status().bufnr)
  h.truthy(terminal.is_running())
  h.eq(false, terminal.is_visible())

  h.truthy(terminal.show({ focus = false }))
  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)

h.test("native terminal survives hiding and can be shown again", function()
  terminal._reset()
  config.setup({
    cmd = ready_shell,
    terminal = { auto_insert = false, auto_close = true },
  })
  h.truthy(terminal.open({ focus = false }))
  h.truthy(terminal.is_running())
  h.truthy(terminal.is_visible())
  h.truthy(terminal.hide())
  h.eq(false, terminal.is_visible())
  h.truthy(terminal.show({ focus = false }))
  h.truthy(terminal.is_visible())
  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)

h.test("floating terminal is centered and survives hiding", function()
  terminal._reset()
  config.setup({
    cmd = ready_shell,
    terminal = {
      layout = "float",
      auto_insert = false,
      auto_close = true,
      float = {
        width_percentage = 0.6,
        height_percentage = 0.5,
        border = "rounded",
      },
    },
  })
  local editor_win = vim.api.nvim_get_current_win()
  h.truthy(terminal.open({ focus = false }))
  local status = terminal.status()
  local win_config = vim.api.nvim_win_get_config(status.winid)
  local available_height = math.max(1, vim.o.lines - vim.o.cmdheight)
  h.eq("editor", win_config.relative)
  h.eq(math.min(vim.o.columns - 2, math.floor(vim.o.columns * 0.6)), win_config.width)
  h.eq(math.min(available_height - 2, math.floor(available_height * 0.5)), win_config.height)
  h.eq(editor_win, vim.api.nvim_get_current_win())

  h.truthy(terminal.show({ focus = true }))
  h.eq(status.winid, vim.api.nvim_get_current_win())
  h.truthy(terminal.hide())
  h.eq(editor_win, vim.api.nvim_get_current_win())
  h.eq(false, terminal.is_visible())
  h.truthy(terminal.show({ focus = false }))
  h.eq("editor", vim.api.nvim_win_get_config(terminal.status().winid).relative)
  vim.api.nvim_exec_autocmds("VimResized", {})

  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)

h.test("focus is a smart focus and hide toggle", function()
  terminal._reset()
  config.setup({
    cmd = ready_shell,
    terminal = { auto_insert = false, auto_close = true },
  })
  local editor_win = vim.api.nvim_get_current_win()
  h.truthy(terminal.open({ focus = false }))
  local terminal_win = terminal.status().winid
  h.eq(editor_win, vim.api.nvim_get_current_win())

  h.truthy(terminal.focus())
  h.eq(terminal_win, vim.api.nvim_get_current_win())
  h.truthy(terminal.focus())
  h.eq(false, terminal.is_visible())
  h.eq(editor_win, vim.api.nvim_get_current_win())
  h.truthy(terminal.focus())
  h.truthy(terminal.is_visible())

  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)

h.test("hiding the terminal restores the most recent editor window", function()
  terminal._reset()
  config.setup({
    cmd = ready_shell,
    terminal = { auto_insert = false, auto_close = true },
  })
  local original_win = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local recent_editor_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(original_win)

  h.truthy(terminal.open({ focus = false }))
  vim.api.nvim_set_current_win(recent_editor_win)
  h.truthy(terminal.show({ focus = true }))
  h.truthy(terminal.hide())
  h.eq(recent_editor_win, vim.api.nvim_get_current_win())

  h.truthy(terminal.show({ focus = false }))
  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
  if vim.api.nvim_win_is_valid(recent_editor_win) then
    vim.api.nvim_win_close(recent_editor_win, true)
  end
end)

h.test("terminal exit restores an editor window from another tab", function()
  terminal._reset()
  config.setup({
    cmd = ready_shell,
    terminal = { auto_insert = false, auto_close = true },
  })
  local original_tab = vim.api.nvim_get_current_tabpage()
  h.truthy(terminal.open({ focus = false }))
  vim.cmd("tabnew")
  local editor_tab = vim.api.nvim_get_current_tabpage()
  local editor_win = vim.api.nvim_get_current_win()

  h.truthy(terminal.show({ focus = true }))
  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
      and vim.api.nvim_get_current_tabpage() == editor_tab
      and vim.api.nvim_get_current_win() == editor_win
  end, 10))
  h.eq(editor_tab, vim.api.nvim_get_current_tabpage())
  h.eq(editor_win, vim.api.nvim_get_current_win())

  vim.cmd("tabclose")
  h.eq(original_tab, vim.api.nvim_get_current_tabpage())
  terminal._reset()
end)

h.test("focus starts a session when none is running", function()
  terminal._reset()
  config.setup({
    cmd = ready_shell,
    terminal = { auto_insert = false, auto_close = true },
  })

  h.truthy(terminal.focus())
  h.truthy(terminal.is_running())
  h.truthy(terminal.is_visible())
  h.eq(terminal.status().winid, vim.api.nvim_get_current_win())

  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)

h.test("send waits for the composer after starting a session", function()
  terminal._reset()
  config.setup({
    cmd = {
      "sh",
      "-c",
      "printf 'startup screen\\n'; sleep 0.1; printf '\\033[0 '; sleep 0.05; printf 'q\\033[?25h'; exec sh",
    },
    focus_after_send = false,
    terminal = { auto_insert = false, auto_close = true },
  })
  local editor_win = vim.api.nvim_get_current_win()
  local completed = {}

  h.truthy(terminal.send("draft", {
    submit = false,
    on_complete = function(ok)
      table.insert(completed, ok)
    end,
  }))
  h.truthy(terminal.send("-queued", {
    submit = false,
    on_complete = function(ok)
      table.insert(completed, ok)
    end,
  }))
  local status = terminal.status()
  h.truthy(status.running)
  h.truthy(status.visible)
  h.eq(editor_win, vim.api.nvim_get_current_win())
  h.eq({}, completed)
  vim.api.nvim_set_current_win(status.winid)
  h.contains(terminal._input_hint():lower(), "queued")
  h.contains(terminal._input_hint(), "setup")
  vim.api.nvim_set_current_win(editor_win)
  h.eq(nil, table.concat(vim.api.nvim_buf_get_lines(status.bufnr, 0, -1, false), "\n"):find("draft", 1, true))
  h.truthy(vim.wait(1000, function()
    local lines = vim.api.nvim_buf_get_lines(status.bufnr, 0, -1, false)
    return table.concat(lines, "\n"):find("draft-queued", 1, true) ~= nil
  end, 10))
  h.eq({ true, true }, completed)
  vim.api.nvim_set_current_win(status.winid)
  h.eq(nil, terminal._input_hint():lower():find("queued", 1, true))

  terminal._reset()
end)

h.test("draft sends retain their cwd and reject a different running session", function()
  terminal._reset()
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  directory = assert(vim.uv.fs_realpath(directory))
  config.setup({ cmd = ready_shell, cwd = "nvim", terminal = { auto_insert = false } })
  local original_notify = vim.notify
  rawset(vim, "notify", function() end)
  local ok, err = xpcall(function()
    local delivered
    h.truthy(terminal.send("draft", {
      cwd = directory,
      submit = false,
      on_complete = function(result)
        delivered = result
      end,
    }))
    h.eq(directory, terminal.status().cwd)
    h.truthy(vim.wait(1000, function()
      return delivered ~= nil
    end, 10))
    h.eq(true, delivered)
    h.eq(false, terminal.send("wrong project", { cwd = vim.uv.cwd(), submit = false }))
    h.eq(directory, terminal.status().cwd)
  end, debug.traceback)
  terminal._reset()
  rawset(vim, "notify", original_notify)
  vim.fn.delete(directory, "rf")
  if not ok then
    error(err, 0)
  end
end)

h.test("send waits for the composer when the session was opened first", function()
  terminal._reset()
  config.setup({
    cmd = {
      "sh",
      "-c",
      "printf 'startup screen\\n'; sleep 0.1; printf '\\033[0 '; sleep 0.05; printf 'q\\033[?25h'; exec sh",
    },
    focus_after_send = false,
    terminal = { auto_insert = false, auto_close = true },
  })
  local completed = {}

  h.truthy(terminal.open({ focus = false }))
  h.truthy(terminal.send("draft", {
    submit = false,
    on_complete = function(ok)
      table.insert(completed, ok)
    end,
  }))
  h.eq({}, completed)
  local status = terminal.status()
  h.eq(nil, table.concat(vim.api.nvim_buf_get_lines(status.bufnr, 0, -1, false), "\n"):find("draft", 1, true))
  h.truthy(vim.wait(1000, function()
    local lines = vim.api.nvim_buf_get_lines(status.bufnr, 0, -1, false)
    return table.concat(lines, "\n"):find("draft", 1, true) ~= nil
  end, 10))
  h.eq({ true }, completed)

  terminal._reset()
end)

h.test("send recognizes cursor restoration between its style and visibility sequences", function()
  terminal._reset()
  config.setup({
    cmd = {
      "sh",
      "-c",
      "stty -echo; printf '\\033[0 q\\033[1;1H \\033[0m'; sleep 0.05; printf '\\033[2;3H\\033[?25h'; " .. command_loop,
    },
    terminal = { auto_insert = false },
  })
  local delivered
  h.truthy(terminal.send("printf 'INTERLEAVED_OK\\n'", {
    on_complete = function(ok)
      delivered = ok
    end,
  }))
  local status = terminal.status()
  local submitted = vim.wait(1000, function()
    return table.concat(vim.api.nvim_buf_get_lines(status.bufnr, 0, -1, false), "\n"):find("INTERLEAVED_OK", 1, true)
      ~= nil
  end, 10)
  terminal._reset()
  h.eq(true, delivered)
  h.truthy(submitted)
end)

h.test("submitted sends wait past a loading startup draft that ignores Enter", function()
  terminal._reset()
  config.setup({
    cmd = {
      "bash",
      "-c",
      "stty -echo; printf 'model: loading\\n\\342\\200\\272 Ask Codex to do anything\\n\\033[0 q\\033[?25h'; "
        .. "IFS= read -r -t 0.2 startup_draft; "
        .. "printf '\\033[2J\\033[Hmodel: gpt-6-astra\\n\\033[0 q\\033[1;1H\\033[?25h'; "
        .. command_loop,
    },
    terminal = { auto_insert = false },
  })
  local delivered
  h.truthy(terminal.send("printf 'AFTER_STARTUP_OK\\n'", {
    on_complete = function(ok)
      delivered = ok
    end,
  }))
  local status = terminal.status()
  local submitted = vim.wait(1000, function()
    return table.concat(vim.api.nvim_buf_get_lines(status.bufnr, 0, -1, false), "\n"):find("AFTER_STARTUP_OK", 1, true)
      ~= nil
  end, 10)
  terminal._reset()
  h.eq(true, delivered)
  h.truthy(submitted, "startup must not consume Enter without submitting")
end)

h.test("queued send fails if the terminal exits before showing a composer", function()
  terminal._reset()
  config.setup({
    cmd = { "sh", "-c", "sleep 0.05; exit 7" },
    focus_after_send = false,
    terminal = { auto_insert = false, auto_close = true },
  })
  local completed
  local notifications = {}
  local original_notify = vim.notify
  rawset(vim, "notify", function(message)
    table.insert(notifications, message)
  end)

  local sent = terminal.send("draft", {
    submit = false,
    on_complete = function(ok)
      completed = ok
    end,
  })
  local waited = vim.wait(1000, function()
    return completed ~= nil
  end, 10)
  rawset(vim, "notify", original_notify)

  h.truthy(sent)
  h.truthy(waited)
  h.eq(false, completed)
  h.eq(false, terminal.is_running())
  h.contains(table.concat(notifications, "\n"), "was not delivered")

  terminal._reset()
end)

h.test("queued send warns when composer detection is still pending", function()
  terminal._reset()
  config.setup({
    cmd = { "sh" },
    focus_after_send = false,
    terminal = { auto_insert = false, auto_close = true },
  })
  local deferred_callback
  local notifications = {}
  local original_defer_fn = vim.defer_fn
  local original_notify = vim.notify
  rawset(vim, "defer_fn", function(callback)
    deferred_callback = callback
  end)
  rawset(vim, "notify", function(message)
    table.insert(notifications, message)
  end)

  local sent = terminal.send("draft", { submit = false })
  if deferred_callback then
    deferred_callback()
  end
  rawset(vim, "notify", original_notify)
  rawset(vim, "defer_fn", original_defer_fn)
  terminal._reset()

  h.truthy(sent)
  h.truthy(deferred_callback)
  h.contains(table.concat(notifications, "\n"), "still queued")
end)

h.test("terminal installs configurable buffer-local navigation and action keys", function()
  terminal._reset()
  config.setup({
    cmd = ready_shell,
    terminal = {
      auto_insert = false,
      auto_close = true,
      hide_keys = { "<F7>", "<F8>" },
      normal_mode_keys = { "<F5>" },
      window_navigation = { left = "<F6>" },
    },
  })
  h.truthy(terminal.open({ focus = false }))
  local bufnr = terminal.status().bufnr
  local mappings = vim.api.nvim_buf_get_keymap(bufnr, "t")
  local found_navigation = false
  local normal_mode_rhs
  local hide_keys = {}
  for _, mapping in ipairs(mappings) do
    if mapping.lhs == "<F6>" and mapping.desc == "Move to left window" then
      found_navigation = true
    elseif mapping.lhs == "<F5>" and mapping.desc == "Enter terminal Normal mode" then
      normal_mode_rhs = mapping.rhs
    elseif mapping.desc == "Hide Codex terminal" then
      hide_keys[mapping.lhs] = true
    end
  end
  h.truthy(found_navigation)
  h.eq("<C-\\><C-N>", normal_mode_rhs)
  h.truthy(hide_keys["<F7>"])
  h.truthy(hide_keys["<F8>"])

  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)

h.test("terminal hide mapping restores editor focus", function()
  terminal._reset()
  config.setup({
    cmd = ready_shell,
    terminal = {
      layout = "float",
      auto_insert = false,
      auto_close = true,
      hide_keys = { "<F9>" },
    },
  })
  local editor_win = vim.api.nvim_get_current_win()
  h.truthy(terminal.open())
  h.eq(terminal.status().winid, vim.api.nvim_get_current_win())

  local rhs
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(terminal.status().bufnr, "t")) do
    if mapping.lhs == "<F9>" then
      rhs = mapping.rhs
      break
    end
  end
  h.truthy(rhs)
  vim.api.nvim_feedkeys(vim.keycode(rhs), "x", false)
  h.truthy(vim.wait(1000, function()
    return not terminal.is_visible() and vim.api.nvim_get_current_win() == editor_win
  end, 10))

  h.truthy(terminal.show({ focus = false }))
  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)

h.test("terminal lifecycle events distinguish focus from reopening", function()
  terminal._reset()
  config.setup({ cmd = ready_shell, terminal = { auto_insert = false, auto_close = true } })
  local opened = 0
  local closed = 0
  local group = vim.api.nvim_create_augroup("codex_nvim_test_lifecycle", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodexOpened",
    callback = function()
      opened = opened + 1
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodexClosed",
    callback = function()
      closed = closed + 1
    end,
  })

  h.truthy(terminal.open({ focus = false }))
  h.truthy(terminal.show({ focus = true }))
  h.eq(0, opened)
  h.truthy(terminal.hide())
  h.eq(1, closed)
  h.truthy(terminal.show({ focus = false }))
  h.eq(1, opened)

  vim.api.nvim_del_augroup_by_id(group)
  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)

h.test("terminal hides every view and survives as the last window", function()
  terminal._reset()
  config.setup({
    cmd = ready_shell,
    terminal = { auto_insert = false, auto_close = true },
  })
  local editor_win = vim.api.nvim_get_current_win()
  h.truthy(terminal.open({ focus = false }))
  local status = terminal.status()

  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, status.bufnr)
  h.eq(2, #vim.fn.win_findbuf(status.bufnr))
  h.truthy(terminal.hide())
  h.eq(0, #vim.fn.win_findbuf(status.bufnr))
  h.truthy(terminal.is_running())

  h.truthy(terminal.show({ focus = false }))
  vim.api.nvim_win_close(editor_win, true)
  h.eq(1, #vim.api.nvim_list_wins())
  h.truthy(terminal.hide())
  h.eq(1, #vim.api.nvim_list_wins())
  h.eq(0, #vim.fn.win_findbuf(status.bufnr))
  h.truthy(terminal.is_running())

  h.truthy(terminal.show({ focus = false }))
  h.truthy(terminal.send("exit"))
  h.truthy(vim.wait(1000, function()
    return not terminal.is_running()
  end, 10))
  terminal._reset()
end)
