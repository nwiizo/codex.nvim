local M = {}

local window = require("codex.window")
local context = require("codex.context")

---@class CodexNvimAskDraft
---@field bufnr integer
---@field source_bufnr integer
---@field source_path string
---@field source_tick integer
---@field cwd string
---@field backend CodexNvimBackend
---@field return_winid integer
---@field winid? integer
---@field start_line? integer
---@field end_line? integer
---@field pending boolean
---@field follow_up? { jobid?: integer, thread_id?: string }

---@type CodexNvimAskDraft?
local draft

---@type fun(current: CodexNvimAskDraft): boolean
local show

local actions = {
  { label = "Explain", text = "Explain this code and any important edge cases. Do not change files." },
  { label = "Fix", text = "Find and fix the problem in this code, then verify the fix." },
  { label = "Add tests", text = "Add tests for this code, including important edge cases, and run them." },
  { label = "Refactor", text = "Refactor this code for readability while preserving its behavior. Verify the result." },
}

local function notify(message)
  vim.notify("codex.nvim: " .. message, vim.log.levels.WARN)
end

---@param current CodexNvimAskDraft
---@param mode? string
---@return string
local function footer(current, mode)
  if current.pending then
    return " Request queued. Check Codex for any setup prompts. "
  end
  mode = mode or vim.fn.mode()
  if mode:match("^[iR]") then
    return " Type your request. Ctrl-S to send. Enter for a new line. "
  end
  if mode:match("^[vVsS\22\19]") then
    return " Press Esc, then i to type. Ctrl-S to send. "
  end
  return " Press i to start typing. Ctrl-S to send. "
end

---@param current CodexNvimAskDraft
---@param mode? string
local function update_guidance(current, mode)
  local winid = current.winid
  if not winid or not vim.api.nvim_win_is_valid(winid) or vim.api.nvim_win_get_buf(winid) ~= current.bufnr then
    return
  end
  if vim.api.nvim_win_get_config(winid).relative == "" then
    return
  end
  vim.api.nvim_win_set_config(winid, { footer = footer(current, mode) })
  vim.wo[winid].winbar = current.pending and ""
    or (
      "Ctrl-S Send%< | Ctrl-P Actions"
      .. (current.follow_up and "" or " | Ctrl-D Diagnostics")
      .. " | Ctrl-F File | Esc q Hide"
    )
end

local function current_draft()
  if draft and vim.api.nvim_buf_is_valid(draft.bufnr) then
    if vim.api.nvim_buf_is_loaded(draft.bufnr) then
      return draft
    end
    -- :bdelete unloads the text but keeps the buffer name allocated.
    pcall(vim.api.nvim_buf_delete, draft.bufnr, { force = true })
  end
  draft = nil
end

---@param text string
---@return boolean
local function within_limits(text)
  local limits = require("codex.config").get().context
  local lines = #vim.split(text, "\n", { plain = true })
  if lines > limits.max_lines or #text > limits.max_bytes then
    notify(
      string.format(
        "request has %d lines and %d bytes; limits are %d lines and %d bytes; remove context or select a smaller range",
        lines,
        #text,
        limits.max_lines,
        limits.max_bytes
      )
    )
    return false
  end
  return true
end

---@param current CodexNvimAskDraft
---@return string
local function contents(current)
  return table.concat(vim.api.nvim_buf_get_lines(current.bufnr, 0, -1, false), "\n")
end

---@param text string
---@param prepend? boolean
---@return boolean
local function add_text(text, prepend)
  local current = current_draft()
  if not current or current.pending then
    notify("open an editable request with :CodexAsk first")
    return false
  end
  local existing = contents(current)
  local combined = prepend and (text .. "\n\n" .. existing) or (existing .. "\n\n" .. text)
  if not within_limits(combined) then
    return false
  end
  vim.api.nvim_buf_set_lines(current.bufnr, 0, -1, false, vim.split(combined, "\n", { plain = true }))
  return true
end

---@return boolean
function M.hide()
  local current = current_draft()
  if not current then
    return true
  end
  local restore = vim.api.nvim_get_current_buf() == current.bufnr
  local ok, err = window.hide_buffer_windows(current.bufnr)
  if not ok then
    notify("could not hide request: " .. tostring(err))
    return false
  end
  current.winid = nil
  if restore then
    vim.cmd("stopinsert")
    window.restore(current.return_winid, current.bufnr)
  end
  return true
end

function M.reset()
  local current = current_draft()
  draft = nil
  if current then
    pcall(vim.api.nvim_buf_delete, current.bufnr, { force = true })
  end
end

---@return boolean
function M.submit()
  local current = current_draft()
  if not current or current.pending then
    notify("no editable request is ready to send")
    return false
  end
  if require("codex.config").get().backend ~= current.backend then
    notify("the backend changed; restore it or discard this request with :bdelete!")
    return false
  end
  if current.follow_up then
    local status = require("codex").status()
    if
      not status.running
      or status.jobid ~= current.follow_up.jobid
      or status.thread_id ~= current.follow_up.thread_id
      or status.cwd ~= current.cwd
    then
      notify("the conversation stopped or changed; the follow-up draft is kept but was not sent")
      return false
    end
  end
  local text = contents(current)
  if vim.trim(text) == "" then
    notify("write a request before sending")
    return false
  end
  if not within_limits(text) then
    return false
  end
  -- Start/focus the backend from the originating window so hiding its panel
  -- returns there, and the request float does not cover the Codex startup UI.
  if not M.hide() then
    return false
  end

  current.pending = true
  vim.bo[current.bufnr].modifiable = false
  local tick = vim.api.nvim_buf_get_changedtick(current.bufnr)
  local completed = false
  local function complete(ok)
    if completed or current_draft() ~= current then
      return
    end
    completed = true
    current.pending = false
    vim.bo[current.bufnr].modifiable = true
    if current.winid and vim.api.nvim_win_is_valid(current.winid) then
      vim.api.nvim_win_set_config(current.winid, {
        title = ok and " Codex request " or " Codex — delivery failed ",
      })
      update_guidance(current)
    end
    if not ok then
      show(current)
      notify("request was not delivered; the draft is kept for editing or retry")
    elseif vim.api.nvim_buf_get_changedtick(current.bufnr) ~= tick then
      notify("request delivered; newer draft edits have been kept")
    elseif M.hide() then
      M.reset()
    end
  end
  local ok, sent = pcall(require("codex").send, text, {
    submit = true,
    cwd = current.cwd,
    on_complete = complete,
  })
  if not ok or not sent then
    complete(false)
    if not ok then
      notify(tostring(sent))
    end
    return false
  end
  if not completed then
    notify("request queued; the draft is locked until delivery completes")
  end
  return true
end

function M.choose_action()
  local current = current_draft()
  if not current or current.pending then
    return
  end
  vim.ui.select(actions, {
    prompt = "Add an instruction (edit it before sending):",
    format_item = function(action)
      return action.label
    end,
  }, function(action)
    if action and current_draft() == current then
      add_text(action.text, true)
    end
  end)
end

---@param path? string
---@return boolean
function M.add_file(path)
  local current = current_draft()
  if not current or current.pending then
    return false
  end
  if not path then
    vim.ui.input({ prompt = "Attach file or directory: ", completion = "file" }, function(input)
      if input and input ~= "" and current_draft() == current then
        M.add_file(input)
      end
    end)
    return true
  end
  if not vim.startswith(path, "/") and not vim.startswith(path, "~") then
    path = vim.fs.joinpath(current.cwd, path)
  end
  local relative, absolute = context.file(path, current.source_bufnr, current.cwd)
  if not relative then
    notify(absolute)
    return false
  end
  return add_text("File or directory on disk: @" .. absolute)
end

---@return boolean
function M.add_diagnostics()
  local current = current_draft()
  if not current or current.pending then
    return false
  end
  if current.follow_up then
    notify("use :CodexAsk from a source file to attach its diagnostics")
    return false
  end
  if not vim.api.nvim_buf_is_valid(current.source_bufnr) then
    notify("the source buffer is no longer available")
    return false
  end
  if
    vim.api.nvim_buf_get_changedtick(current.source_bufnr) ~= current.source_tick
    or vim.api.nvim_buf_get_name(current.source_bufnr) ~= current.source_path
  then
    notify("the source changed; create a new request before attaching its diagnostics")
    return false
  end
  local diagnostics = vim.diagnostic.get(current.source_bufnr)
  table.sort(diagnostics, function(a, b)
    return a.lnum == b.lnum and a.col < b.col or a.lnum < b.lnum
  end)
  local lines = {}
  for _, diagnostic in ipairs(diagnostics) do
    if
      not current.start_line
      or ((diagnostic.end_lnum or diagnostic.lnum) >= current.start_line - 1 and diagnostic.lnum < current.end_line)
    then
      table.insert(
        lines,
        string.format(
          "%d:%d %s: %s",
          diagnostic.lnum + 1,
          diagnostic.col + 1,
          vim.diagnostic.severity[diagnostic.severity] or "Diagnostic",
          diagnostic.message
        )
      )
    end
  end
  if #lines == 0 then
    notify("no diagnostics in the source range")
    return false
  end
  return add_text("Diagnostics from @" .. current.source_path .. ":\n" .. table.concat(lines, "\n"))
end

---@param current CodexNvimAskDraft
---@return boolean
show = function(current)
  local windows = vim.fn.win_findbuf(current.bufnr)
  if #windows > 0 then
    current.winid = windows[1]
    vim.api.nvim_set_current_win(current.winid)
    update_guidance(current)
    if not current.pending then
      vim.cmd("startinsert")
    end
    return true
  end
  local width = math.max(1, math.min(vim.o.columns - 4, math.floor(vim.o.columns * 0.85)))
  local height = math.max(1, math.min(vim.o.lines - 4, math.floor(vim.o.lines * 0.6)))
  local ok, result = pcall(vim.api.nvim_open_win, current.bufnr, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = current.pending and " Codex — waiting to send "
      or (current.follow_up and " Codex — follow up in this conversation " or " Codex — write your request "),
    footer = footer(current),
  })
  if not ok then
    notify("could not open request: " .. tostring(result))
    return false
  end
  current.winid = result
  vim.wo[result].wrap = true
  update_guidance(current)
  if not current.pending then
    vim.cmd("startinsert")
  end
  return true
end

---@param opts? { text?: string, visual?: boolean, start_line?: integer, end_line?: integer, follow_up?: boolean }
---@return boolean
function M.open(opts)
  opts = opts or {}
  local existing = current_draft()
  if existing then
    if opts.text or opts.visual or opts.start_line then
      notify("an unfinished request is open; edit it or discard it with :bdelete! before starting another")
      show(existing)
      return false
    end
    return show(existing)
  end

  local config = require("codex.config").get()
  local bufnr = vim.api.nvim_get_current_buf()
  if not opts.follow_up and vim.bo[bufnr].buftype ~= "" then
    notify("open a source file before creating a request")
    return false
  end
  local status = require("codex").status()
  if opts.follow_up and (not status.running or (config.backend == "app_server" and not status.thread_id)) then
    notify("start or resume a Codex conversation before composing a follow-up")
    return false
  end
  local cwd = status.cwd or status.resolved_cwd
  if not cwd then
    notify("could not resolve the request working directory")
    return false
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  local source_text, metadata
  -- A follow-up can start from a terminal or diff preview; attach no buffer text.
  if not opts.follow_up then
    if opts.visual then
      source_text, metadata = context.visual(bufnr, cwd, config.context, nil, true)
    elseif opts.start_line or (path ~= "" and vim.bo[bufnr].modified) then
      source_text, metadata = context.range(
        bufnr,
        opts.start_line or 1,
        opts.end_line or vim.api.nvim_buf_line_count(bufnr),
        cwd,
        config.context,
        true
      )
    elseif path ~= "" then
      local relative, absolute = context.file(path, bufnr, cwd)
      if relative then
        source_text = "Current file on disk: @" .. absolute
      else
        metadata = absolute
      end
    end
  end
  if metadata and type(metadata) == "string" then
    notify(metadata)
    return false
  end
  local text = opts.text or ""
  if source_text then
    text = text .. "\n\n" .. source_text
  end
  if not within_limits(text) then
    return false
  end

  local request_bufnr = vim.api.nvim_create_buf(false, true)
  local current = {
    bufnr = request_bufnr,
    source_bufnr = bufnr,
    source_path = path,
    source_tick = vim.api.nvim_buf_get_changedtick(bufnr),
    cwd = cwd,
    backend = config.backend,
    return_winid = vim.api.nvim_get_current_win(),
    start_line = type(metadata) == "table" and metadata.start_line or nil,
    end_line = type(metadata) == "table" and metadata.end_line or nil,
    pending = false,
    follow_up = opts.follow_up and { jobid = status.jobid, thread_id = status.thread_id } or nil,
  }
  draft = current
  vim.bo[request_bufnr].buftype = "acwrite"
  vim.bo[request_bufnr].bufhidden = "hide"
  vim.bo[request_bufnr].swapfile = false
  vim.bo[request_bufnr].undofile = false
  vim.bo[request_bufnr].modeline = false
  vim.bo[request_bufnr].filetype = "markdown"
  vim.api.nvim_buf_set_name(request_bufnr, "codex://ask")
  vim.api.nvim_buf_set_lines(request_bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.keymap.set({ "n", "i" }, "<C-s>", M.submit, { buf = request_bufnr, desc = "Send Codex request" })
  vim.keymap.set({ "n", "i" }, "<C-p>", M.choose_action, { buf = request_bufnr, desc = "Choose Codex instruction" })
  vim.keymap.set({ "n", "i" }, "<C-d>", M.add_diagnostics, { buf = request_bufnr, desc = "Attach source diagnostics" })
  vim.keymap.set({ "n", "i" }, "<C-f>", function()
    M.add_file()
  end, { buf = request_bufnr, desc = "Attach file to Codex request" })
  vim.keymap.set("n", "q", M.hide, { buf = request_bufnr, desc = "Hide Codex request" })
  vim.keymap.set({ "n", "i" }, "<C-c>", M.hide, { buf = request_bufnr, desc = "Hide Codex request" })
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = request_bufnr, callback = M.submit })
  vim.api.nvim_create_autocmd({ "ModeChanged", "WinEnter" }, {
    buffer = request_bufnr,
    callback = function(event)
      update_guidance(current, event.event == "ModeChanged" and vim.v.event.new_mode or nil)
    end,
  })
  if not show(current) then
    M.reset()
    return false
  end
  local instruction_lines = vim.split(opts.text or "", "\n", { plain = true })
  vim.api.nvim_win_set_cursor(current.winid, { #instruction_lines, #instruction_lines[#instruction_lines] })
  return true
end

return M
