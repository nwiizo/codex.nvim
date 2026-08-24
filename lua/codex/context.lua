local M = {}

local cwd = require("codex.cwd")

---@param bufnr integer
---@param working_directory string
---@return string? path
---@return string? error
local function source_path(bufnr, working_directory)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil, "current buffer has no file path"
  end
  return cwd.relative(path, working_directory)
end

local function fence_for(text)
  local fence = "```"
  while text:find(fence, 1, true) do
    fence = fence .. "`"
  end
  return fence
end

---@param lines string[]
---@param text string
---@param limits CodexNvimContextConfig
---@return boolean? valid
---@return string? error
local function check_limits(lines, text, limits)
  if #lines > limits.max_lines then
    return nil, string.format("selection has %d lines; limit is %d", #lines, limits.max_lines)
  end
  if #text > limits.max_bytes then
    return nil, string.format("selection has %d bytes; limit is %d", #text, limits.max_bytes)
  end
  return true
end

---@param bufnr integer
---@param working_directory string
---@param start_line integer
---@param end_line integer
---@param lines string[]
---@param limits CodexNvimContextConfig
---@return string? prompt
---@return CodexNvimContextMetadata|string metadata_or_error
local function format_selection(bufnr, working_directory, start_line, end_line, lines, limits)
  local path, path_error = source_path(bufnr, working_directory)
  if not path then
    return nil, assert(path_error)
  end

  local text = table.concat(lines, "\n")
  local valid, limit_error = check_limits(lines, text, limits)
  if not valid then
    return nil, assert(limit_error)
  end

  local filetype = vim.bo[bufnr].filetype
  local fence = fence_for(text)
  local prompt = string.format(
    "Use this Neovim selection from @%s (lines %d-%d):\n%s%s\n%s",
    path,
    start_line,
    end_line,
    fence,
    filetype,
    text .. "\n" .. fence
  )
  return prompt, {
    file_path = path,
    start_line = start_line,
    end_line = end_line,
  }
end

---@param bufnr integer?
---@param start_line integer
---@param end_line integer
---@param working_directory string
---@param limits CodexNvimContextConfig
---@return string? prompt
---@return CodexNvimContextMetadata|string metadata_or_error
function M.range(bufnr, start_line, end_line, working_directory, limits)
  bufnr = bufnr or 0
  if start_line < 1 or end_line < start_line then
    return nil, "invalid line range"
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if end_line > line_count then
    return nil, "line range exceeds the buffer"
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  return format_selection(bufnr, working_directory, start_line, end_line, lines, limits)
end

---@param column integer
---@return integer
local function getregion_column(column)
  -- Buffer marks use zero-based columns, while getregion() uses one-based columns.
  -- v:maxcol is an end-of-line sentinel rather than a byte index, so preserve it.
  if column == vim.v.maxcol then
    return column
  end
  return column + 1
end

---@param bufnr integer
---@param start_pos integer[]
---@param end_pos integer[]
---@param mode string
---@param exclusive? boolean
---@return string[] lines
---@return integer first_line
---@return integer last_line
function M._selection_text(bufnr, start_pos, end_pos, mode, exclusive)
  local first_line = math.min(start_pos[1], end_pos[1])
  local last_line = math.max(start_pos[1], end_pos[1])
  local positions = {
    { bufnr, start_pos[1], getregion_column(start_pos[2]), 0 },
    { bufnr, end_pos[1], getregion_column(end_pos[2]), 0 },
  }
  local lines = vim.fn.getregion(positions[1], positions[2], {
    type = mode,
    exclusive = exclusive == true,
  })
  return lines, first_line, last_line
end

---@param bufnr integer?
---@param working_directory string
---@param limits CodexNvimContextConfig
---@param mode? string
---@return string? prompt
---@return CodexNvimContextMetadata|string metadata_or_error
function M.visual(bufnr, working_directory, limits, mode)
  bufnr = bufnr or 0
  local start_pos = vim.api.nvim_buf_get_mark(bufnr, "<")
  local end_pos = vim.api.nvim_buf_get_mark(bufnr, ">")
  if start_pos[1] == 0 or end_pos[1] == 0 then
    return nil, "no visual selection is available"
  end
  local lines, start_line, end_line =
    M._selection_text(bufnr, start_pos, end_pos, mode or vim.fn.visualmode(), vim.o.selection == "exclusive")
  return format_selection(bufnr, working_directory, start_line, end_line, lines, limits)
end

---@param path? string
---@param bufnr? integer
---@param working_directory string
---@return string? relative_path
---@return string path_or_error
function M.file(path, bufnr, working_directory)
  if not path or path == "" then
    path = vim.api.nvim_buf_get_name(bufnr or 0)
    if path == "" then
      return nil, "current buffer has no file path"
    end
  end

  local absolute_path = cwd.absolute(path)
  if not vim.uv.fs_stat(absolute_path) then
    return nil, "path does not exist: " .. absolute_path
  end
  return cwd.relative(absolute_path, working_directory), absolute_path
end

return M
