local M = {}

---@type CodexNvimConfig
local defaults = {
  backend = "terminal",
  cmd = { "codex" },
  env = {},
  cwd = "root",
  root_markers = { ".git" },
  focus_after_send = false,
  terminal = {
    layout = "split",
    split_side = "right",
    split_width_percentage = 0.35,
    float = {
      width_percentage = 0.85,
      height_percentage = 0.85,
      border = "rounded",
    },
    auto_insert = true,
    auto_close = true,
    hide_keys = {},
    normal_mode_keys = {},
    window_navigation = {
      left = "<M-h>",
      down = "<M-j>",
      up = "<M-k>",
      right = "<M-l>",
    },
  },
  context = {
    max_lines = 500,
    max_bytes = 65536,
  },
  app_server = {
    cmd = { "codex", "app-server" },
  },
}

---@type CodexNvimConfig?
local values

local function fail(path, expected)
  error(string.format("codex.nvim: %s must be %s", path, expected), 3)
end

local function is_list(value)
  return type(value) == "table" and vim.islist(value)
end

local function validate_string(value, path)
  if type(value) ~= "string" or value == "" then
    fail(path, "a non-empty string")
  end
end

local function validate_positive_integer(value, path)
  if type(value) ~= "number" or value <= 0 or value % 1 ~= 0 then
    fail(path, "a positive integer")
  end
end

local function validate_string_list(value, path)
  if not is_list(value) or #value == 0 then
    fail(path, "a non-empty list of strings")
  end
  for index, item in ipairs(value) do
    validate_string(item, string.format("%s[%d]", path, index))
  end
end

---@param path string
---@param key unknown
---@return string
local function option_path(path, key)
  local name = tostring(key)
  return path == "" and name or path .. "." .. name
end

---@param override table
---@param schema table
---@param path? string
local function validate_known_options(override, schema, path)
  path = path or ""
  for key, value in pairs(override) do
    local schema_value = schema[key]
    if schema_value == nil then
      fail(option_path(path, key), "a recognized option")
    end
    if type(value) == "table" and type(schema_value) == "table" and not is_list(schema_value) then
      validate_known_options(value, schema_value, option_path(path, key))
    end
  end
end

---@param base table
---@param override table
---@return table
local function merge(base, override)
  local result = vim.deepcopy(base)
  for key, value in pairs(override) do
    if type(value) == "table" and type(result[key]) == "table" and not is_list(result[key]) then
      result[key] = merge(result[key], value)
    else
      result[key] = vim.deepcopy(value)
    end
  end
  return result
end

---@param config CodexNvimConfig
local function validate(config)
  if type(config) ~= "table" then
    fail("setup options", "a table")
  end

  validate_string_list(config.cmd, "cmd")
  validate_string_list(config.root_markers, "root_markers")
  if config.backend ~= "terminal" and config.backend ~= "app_server" then
    fail("backend", '"terminal" or "app_server"')
  end
  if type(config.cwd) ~= "string" and type(config.cwd) ~= "function" then
    fail("cwd", '"root", "file", "nvim", a path, or a function')
  end
  if type(config.cwd) == "string" and config.cwd == "" then
    fail("cwd", "a non-empty string or a function")
  end

  if type(config.env) ~= "table" or (next(config.env) ~= nil and is_list(config.env)) then
    fail("env", "a string-to-string table")
  end
  for key, value in pairs(config.env) do
    validate_string(key, "env key")
    if type(value) ~= "string" then
      fail("env." .. key, "a string")
    end
  end

  if type(config.focus_after_send) ~= "boolean" then
    fail("focus_after_send", "a boolean")
  end

  if type(config.terminal) ~= "table" then
    fail("terminal", "a table")
  end
  if config.terminal.layout ~= "split" and config.terminal.layout ~= "float" then
    fail("terminal.layout", '"split" or "float"')
  end
  if config.terminal.split_side ~= "left" and config.terminal.split_side ~= "right" then
    fail("terminal.split_side", '"left" or "right"')
  end
  if
    type(config.terminal.split_width_percentage) ~= "number"
    or config.terminal.split_width_percentage <= 0
    or config.terminal.split_width_percentage > 1
  then
    fail("terminal.split_width_percentage", "a number greater than 0 and at most 1")
  end
  if type(config.terminal.float) ~= "table" then
    fail("terminal.float", "a table")
  end
  for _, key in ipairs({ "width_percentage", "height_percentage" }) do
    local value = config.terminal.float[key]
    if type(value) ~= "number" or value <= 0 or value > 1 then
      fail("terminal.float." .. key, "a number greater than 0 and at most 1")
    end
  end
  local border = config.terminal.float.border
  if
    border ~= "none"
    and border ~= "single"
    and border ~= "double"
    and border ~= "rounded"
    and border ~= "solid"
    and border ~= "shadow"
  then
    fail("terminal.float.border", '"none", "single", "double", "rounded", "solid", or "shadow"')
  end
  for _, key in ipairs({ "auto_insert", "auto_close" }) do
    if type(config.terminal[key]) ~= "boolean" then
      fail("terminal." .. key, "a boolean")
    end
  end
  for _, option in ipairs({ "hide_keys", "normal_mode_keys" }) do
    local keys = config.terminal[option]
    if not is_list(keys) then
      fail("terminal." .. option, "a list of strings")
    end
    for index, key in ipairs(keys) do
      validate_string(key, string.format("terminal.%s[%d]", option, index))
    end
  end
  local navigation = config.terminal.window_navigation
  if navigation ~= false then
    if type(navigation) ~= "table" then
      fail("terminal.window_navigation", "false or a table")
    end
    for _, direction in ipairs({ "left", "down", "up", "right" }) do
      validate_string(navigation[direction], "terminal.window_navigation." .. direction)
    end
  end

  if type(config.context) ~= "table" then
    fail("context", "a table")
  end
  validate_positive_integer(config.context.max_lines, "context.max_lines")
  validate_positive_integer(config.context.max_bytes, "context.max_bytes")

  if type(config.app_server) ~= "table" then
    fail("app_server", "a table")
  end
  validate_string_list(config.app_server.cmd, "app_server.cmd")
end

---@param opts? CodexNvimSetupOptions
---@return CodexNvimConfig
function M.setup(opts)
  if opts ~= nil and type(opts) ~= "table" then
    fail("setup options", "a table or nil")
  end
  validate_known_options(opts or {}, defaults)
  local candidate = merge(defaults, opts or {})
  validate(candidate)
  values = candidate
  return vim.deepcopy(values)
end

function M.get()
  if not values then
    M.setup(vim.g.codex_nvim_opts)
  end
  return values
end

---@return CodexNvimConfig
function M.defaults()
  return vim.deepcopy(defaults)
end

function M._reset()
  values = nil
end

return M
