local h = require("tests.harness")
local context = require("codex.context")

local limits = { max_lines = 10, max_bytes = 1000 }
local buffer_number = 0

local function buffer(lines)
  buffer_number = buffer_number + 1
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local filename = string.format("codex-nvim-context-%d.rs", buffer_number)
  vim.api.nvim_buf_set_name(bufnr, "/tmp/" .. filename)
  vim.bo[bufnr].filetype = "rust"
  return bufnr, filename
end

h.test("range context includes path, line numbers, and filetype", function()
  local bufnr, filename = buffer({ "fn main() {", '  println!("hi");', "}" })
  local prompt, metadata = context.range(bufnr, 1, 2, "/tmp", limits)
  h.contains(prompt, "@" .. filename .. " (lines 1-2)")
  h.contains(prompt, "```rust")
  h.contains(prompt, "println!")
  h.eq(filename, metadata.file_path)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("characterwise selection keeps exact edge columns", function()
  local bufnr = buffer({ "abcdef", "ghijkl" })
  local lines = context._selection_text(bufnr, { 1, 2 }, { 2, 3 }, "v")
  h.eq({ "cdef", "ghij" }, lines)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("linewise visual selection keeps complete lines", function()
  local original_bufnr = vim.api.nvim_get_current_buf()
  local bufnr, filename = buffer({ "use alpha;", "use beta;", "fn main() {}" })
  local ok, err = xpcall(function()
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd([[execute "normal! ggV2j\<Esc>"]])

    local end_pos = vim.api.nvim_buf_get_mark(bufnr, ">")
    h.eq(vim.v.maxcol, end_pos[2])

    local prompt, metadata = context.visual(bufnr, "/tmp", limits)
    h.contains(prompt, "@" .. filename .. " (lines 1-3)")
    h.contains(prompt, "```rust\nuse alpha;\nuse beta;\nfn main() {}\n```")
    h.eq(1, metadata.start_line)
    h.eq(3, metadata.end_line)
  end, debug.traceback)

  vim.api.nvim_set_current_buf(original_bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  if not ok then
    error(err, 0)
  end
end)

h.test("blockwise selection slices every line", function()
  local bufnr = buffer({ "abcdef", "ghijkl" })
  local lines = context._selection_text(bufnr, { 1, 1 }, { 2, 3 }, "\22")
  h.eq({ "bcd", "hij" }, lines)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("selection includes complete multibyte characters", function()
  local bufnr = buffer({ "日本🙂語" })
  local lines = context._selection_text(bufnr, { 1, 0 }, { 1, 6 }, "v")
  h.eq({ "日本🙂" }, lines)
  h.truthy(pcall(vim.str_utfindex, lines[1]))
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("blockwise selection respects tabs, wide characters, and short lines", function()
  local bufnr = buffer({ "abcdefghij", "\t日本", "x", "ab🙂cdefgh" })
  local lines = context._selection_text(bufnr, { 1, 1 }, { 4, 9 }, "\22")
  h.eq({ "bcdefgh", "       ", "", "b🙂cdef" }, lines)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("exclusive characterwise selection omits the final character", function()
  local bufnr = buffer({ "日本語" })
  local lines = context._selection_text(bufnr, { 1, 0 }, { 1, 3 }, "v", true)
  h.eq({ "日" }, lines)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("selection limits fail visibly", function()
  local bufnr = buffer({ "one", "two" })
  local prompt, err = context.range(bufnr, 1, 2, "/tmp", { max_lines = 1, max_bytes = 100 })
  h.eq(nil, prompt)
  h.contains(err, "2 lines")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("file context rejects missing paths", function()
  local path, err = context.file("/tmp/codex-nvim-file-that-does-not-exist", 0, "/tmp")
  h.eq(nil, path)
  h.contains(err, "path does not exist")
end)
