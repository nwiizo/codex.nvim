local M = {}

local namespace = vim.api.nvim_create_namespace("codex_nvim_selection")
local marked_buf
local owned = {}
local actions = {
  { name = "ask", label = "Ask", rhs = ":<C-U>CodexAskVisual<CR>" },
  { name = "edit", label = "Edit", rhs = ":<C-U>CodexEdit<CR>" },
}

local function clear()
  if marked_buf and vim.api.nvim_buf_is_valid(marked_buf) then
    vim.api.nvim_buf_clear_namespace(marked_buf, namespace, 0, -1)
  end
  marked_buf = nil
end

-- Store expanded keys so changing mapleader does not leave old mappings behind.
local function expand(key)
  return (
    key
      :gsub("<[Ll][Ee][Aa][Dd][Ee][Rr]>", function()
        return vim.g.mapleader or "\\"
      end)
      :gsub("<[Ll][Oo][Cc][Aa][Ll][Ll][Ee][Aa][Dd][Ee][Rr]>", function()
        return vim.g.maplocalleader or "\\"
      end)
  )
end

function M.update()
  clear()
  local config = require("codex.config").get().selection
  local mode = vim.fn.mode()
  if not config.enabled or not config.hint or (mode ~= "v" and mode ~= "V" and mode ~= "\22") then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].buftype ~= "" then
    return
  end
  local labels = {}
  for _, action in ipairs(actions) do
    local key = config.keymaps[action.name]
    if key and vim.fn.maparg(key, "x") == action.rhs then
      table.insert(labels, key .. ": " .. action.label)
    end
  end
  if #labels == 0 then
    return
  end
  local row = math.max(vim.fn.line("v"), vim.api.nvim_win_get_cursor(0)[1]) - 1
  vim.api.nvim_buf_set_extmark(bufnr, namespace, row, 0, {
    virt_lines = { { { " [Codex " .. table.concat(labels, ", ") .. "] ", "CodexSelectionHint" } } },
  })
  marked_buf = bufnr
end

function M.setup()
  clear()
  -- Check global mappings directly: a buffer-local override must not hide an
  -- owned global mapping during cleanup, or be removed itself.
  for _, mapping in ipairs(vim.api.nvim_get_keymap("x")) do
    for _, previous in ipairs(owned) do
      if vim.keycode(mapping.lhs) == vim.keycode(previous.key) and mapping.rhs == previous.rhs then
        vim.keymap.del("x", previous.key)
      end
    end
  end
  owned = {}
  local group = vim.api.nvim_create_augroup("CodexSelection", { clear = true })
  local config = require("codex.config").get().selection
  if not config.enabled then
    return
  end
  for _, action in ipairs(actions) do
    local key = config.keymaps[action.name]
    if key and vim.fn.maparg(key, "x") == "" then
      key = expand(key)
      vim.keymap.set("x", key, action.rhs, { silent = true, desc = "Codex: " .. action.label .. " selection" })
      table.insert(owned, { key = key, rhs = action.rhs })
    end
  end
  vim.api.nvim_set_hl(0, "CodexSelectionHint", { default = true, link = "Comment" })
  vim.api.nvim_create_autocmd({ "ModeChanged", "CursorMoved", "BufEnter", "WinEnter" }, {
    group = group,
    callback = M.update,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, { group = group, callback = clear })
  M.update()
end

return M
