local M = {}

local window = require("codex.window")

local state = {
  bufnr = nil,
  winid = nil,
  diff_bufnr = nil,
  return_winid = nil,
}

local function notify(message)
  vim.notify("codex.nvim: " .. message, vim.log.levels.ERROR)
end

local function valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function find_window(bufnr)
  if not valid_buffer(bufnr) then
    return nil
  end
  local windows = vim.fn.win_findbuf(bufnr)
  return windows[1]
end

local function create_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.api.nvim_buf_set_name(bufnr, "codex://app-server")
  vim.keymap.set("n", "q", function()
    M.hide()
  end, { buf = bufnr, desc = "Hide Codex" })
  return bufnr
end

---@param command string
---@param bufnr integer
---@param wrap boolean
---@return integer? winid
---@return unknown? error
local function try_open_split(command, bufnr, wrap)
  local original_win = vim.api.nvim_get_current_win()
  local original_wins = {}
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    original_wins[winid] = true
  end
  local ok, winid_or_error = pcall(function()
    vim.cmd(command)
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.wo[winid].number = false
    vim.wo[winid].relativenumber = false
    vim.wo[winid].signcolumn = "no"
    vim.wo[winid].wrap = wrap
    return winid
  end)
  if not ok then
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if not original_wins[winid] then
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end
    if vim.api.nvim_win_is_valid(original_win) then
      pcall(vim.api.nvim_set_current_win, original_win)
    end
    return nil, winid_or_error
  end
  return winid_or_error
end

local function open_buffer(bufnr)
  local panel_config = require("codex.config").get().terminal
  local width = math.max(1, math.floor(vim.o.columns * panel_config.split_width_percentage))
  local modifier = panel_config.split_side == "left" and "topleft" or "botright"
  return try_open_split(string.format("%s %dvsplit", modifier, width), bufnr, true)
end

---@param focus? boolean
---@return boolean
function M.open(focus)
  state.return_winid = window.remember(state.return_winid, state.bufnr, state.diff_bufnr)
  local created = false
  if not valid_buffer(state.bufnr) then
    state.bufnr = create_buffer()
    created = true
    M.append("# Codex\n\n")
  end
  state.winid = find_window(state.bufnr)
  local original_win = vim.api.nvim_get_current_win()
  if not state.winid then
    local err
    state.winid, err = open_buffer(state.bufnr)
    if not state.winid then
      if created and valid_buffer(state.bufnr) then
        pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
        state.bufnr = nil
      end
      notify("could not open app-server split: " .. tostring(err))
      return false
    end
  end
  if focus == false and vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
  else
    vim.api.nvim_set_current_win(state.winid)
  end
  return true
end

---@return boolean
function M.hide()
  state.winid = find_window(state.bufnr)
  if not state.winid then
    return true
  end
  local restore_focus = vim.api.nvim_win_get_buf(0) == state.bufnr
  local ok, err = window.hide_buffer_windows(state.bufnr)
  if not ok then
    notify("could not hide app-server panel: " .. tostring(err))
    return false
  end
  state.winid = nil
  if restore_focus then
    window.restore(state.return_winid, state.bufnr, state.diff_bufnr)
  end
  return true
end

---@return boolean
function M.focus()
  state.winid = find_window(state.bufnr)
  if state.winid and vim.api.nvim_get_current_win() == state.winid then
    return M.hide()
  end
  return M.open(true)
end

---@return boolean
function M.toggle()
  state.winid = find_window(state.bufnr)
  if state.winid then
    return M.hide()
  end
  return M.open(true)
end

---@param text string
function M.append(text)
  if not valid_buffer(state.bufnr) or text == "" then
    return
  end
  local lines = vim.split(text, "\n", { plain = true })
  vim.bo[state.bufnr].modifiable = true
  local line_count = vim.api.nvim_buf_line_count(state.bufnr)
  local last = vim.api.nvim_buf_get_lines(state.bufnr, line_count - 1, line_count, false)[1] or ""
  lines[1] = last .. lines[1]
  vim.api.nvim_buf_set_lines(state.bufnr, line_count - 1, line_count, false, lines)
  vim.bo[state.bufnr].modifiable = false
  state.winid = find_window(state.bufnr)
  if state.winid then
    vim.api.nvim_win_set_cursor(state.winid, { vim.api.nvim_buf_line_count(state.bufnr), 0 })
  end
end

---@param diff string
---@param name? string
function M.show_diff(diff, name)
  state.return_winid = window.remember(state.return_winid, state.bufnr, state.diff_bufnr)
  if valid_buffer(state.diff_bufnr) then
    pcall(vim.api.nvim_buf_delete, state.diff_bufnr, { force = true })
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  state.diff_bufnr = bufnr
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "diff"
  vim.api.nvim_buf_set_name(bufnr, name or "codex://turn-diff")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(diff, "\n", { plain = true }))
  vim.bo[bufnr].modifiable = false
  local winid, err = try_open_split("botright vsplit", bufnr, false)
  if not winid then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    state.diff_bufnr = nil
    notify("could not open diff split: " .. tostring(err))
    return false
  end
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buf = bufnr, desc = "Close Codex diff" })
  return true
end

function M.status()
  state.winid = find_window(state.bufnr)
  return {
    visible = state.winid ~= nil,
    bufnr = state.bufnr,
    winid = state.winid,
  }
end

function M.reset()
  if valid_buffer(state.diff_bufnr) then
    pcall(vim.api.nvim_buf_delete, state.diff_bufnr, { force = true })
  end
  if valid_buffer(state.bufnr) then
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
  end
  state.bufnr = nil
  state.winid = nil
  state.diff_bufnr = nil
  state.return_winid = nil
end

return M
