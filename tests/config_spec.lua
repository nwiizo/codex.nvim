local h = require("tests.harness")
local config = require("codex.config")

h.test("config returns independent defaults", function()
  config._reset()
  local first = config.defaults()
  first.cmd[1] = "changed"
  h.eq("codex", config.defaults().cmd[1])
end)

h.test("config replaces argv lists and merges nested options", function()
  config._reset()
  local value = config.setup({
    cmd = { "my-codex", "--profile", "work" },
    terminal = { auto_insert = false },
  })
  h.eq({ "my-codex", "--profile", "work" }, value.cmd)
  h.eq(false, value.terminal.auto_insert)
  h.eq("split", value.terminal.layout)
  h.eq("right", value.terminal.split_side)
  h.eq({}, value.terminal.hide_keys)
  h.eq({}, value.terminal.normal_mode_keys)
  h.eq("root", value.cwd)
  h.eq("terminal", value.backend)
end)

h.test("config accepts a floating terminal and buffer-local terminal keys", function()
  config._reset()
  local value = config.setup({
    terminal = {
      layout = "float",
      float = {
        width_percentage = 0.8,
        height_percentage = 0.7,
        border = "single",
      },
      hide_keys = { "<C-/>", "<C-_>" },
      normal_mode_keys = { "<M-n>" },
    },
  })
  h.eq("float", value.terminal.layout)
  h.eq(0.8, value.terminal.float.width_percentage)
  h.eq(0.7, value.terminal.float.height_percentage)
  h.eq("single", value.terminal.float.border)
  h.eq({ "<C-/>", "<C-_>" }, value.terminal.hide_keys)
  h.eq({ "<M-n>" }, value.terminal.normal_mode_keys)
end)

h.test("config accepts cwd policies and app-server backend", function()
  config._reset()
  local provider = function(ctx)
    return ctx.file_dir
  end
  h.eq("file", config.setup({ cwd = "file" }).cwd)
  h.eq("/tmp/project", config.setup({ cwd = "/tmp/project" }).cwd)
  h.eq(provider, config.setup({ cwd = provider }).cwd)
  h.eq("app_server", config.setup({ backend = "app_server" }).backend)
end)

h.test("config validates cwd and terminal navigation", function()
  config._reset()
  h.raises("cwd", function()
    local invalid = { cwd = 42 }
    ---@cast invalid any
    config.setup(invalid)
  end)
  h.raises("backend", function()
    local invalid = { backend = "unknown" }
    ---@cast invalid any
    config.setup(invalid)
  end)
  h.raises("terminal.window_navigation.left", function()
    config.setup({ terminal = { window_navigation = { left = "" } } })
  end)
  h.raises("terminal.hide_keys[1]", function()
    config.setup({ terminal = { hide_keys = { "" } } })
  end)
  h.raises("terminal.normal_mode_keys[1]", function()
    config.setup({ terminal = { normal_mode_keys = { "" } } })
  end)
end)

h.test("config treats empty nested tables as maps", function()
  config._reset()
  local value = config.setup({ terminal = {}, context = {} })
  h.eq("right", value.terminal.split_side)
  h.eq(500, value.context.max_lines)
end)

h.test("config validates precise option paths", function()
  config._reset()
  h.raises("terminal.split_side", function()
    ---@diagnostic disable-next-line: assign-type-mismatch
    config.setup({ terminal = { split_side = "top" } })
  end)
  h.raises("terminal.layout", function()
    ---@diagnostic disable-next-line: assign-type-mismatch
    config.setup({ terminal = { layout = "popup" } })
  end)
  h.raises("terminal.float.width_percentage", function()
    config.setup({ terminal = { float = { width_percentage = 2 } } })
  end)
  h.raises("terminal.float.border", function()
    ---@diagnostic disable-next-line: assign-type-mismatch
    config.setup({ terminal = { float = { border = "invalid" } } })
  end)
  h.raises("context.max_lines", function()
    config.setup({ context = { max_lines = 0 } })
  end)
  h.raises("terminal.typo", function()
    config.setup({ terminal = { typo = true } })
  end)
end)

h.test("config lazily applies global options without eager module loading", function()
  config._reset()
  vim.g.codex_nvim_opts = { focus_after_send = true }
  h.eq(true, config.get().focus_after_send)
  vim.g.codex_nvim_opts = nil
  config._reset()
end)
