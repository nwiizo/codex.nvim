local M = {}

local health = vim.health

---@param argv string[]
---@return string? version
---@return string? error
local function version(argv)
  local command = vim.deepcopy(argv)
  table.insert(command, "--version")
  local ok, process = pcall(vim.system, command, { text = true })
  if not ok then
    return nil, tostring(process)
  end
  local result = process:wait(3000)
  if result.code ~= 0 then
    return nil, ((result.stderr or ""):gsub("%s+$", ""))
  end
  return ((result.stdout or ""):gsub("%s+$", ""))
end

function M.check()
  health.start("codex.nvim")

  if vim.fn.has("nvim-0.12") == 1 then
    health.ok("Neovim 0.12 or newer")
  else
    health.error("Neovim 0.12 or newer is required")
  end

  local config = require("codex.config").get()
  health.info("Backend: " .. config.backend)
  local command = config.backend == "app_server" and config.app_server.cmd or config.cmd
  local executable = vim.fn.exepath(command[1])
  if executable == "" then
    health.error("Codex CLI is not executable: " .. command[1], {
      "Install Codex CLI from https://developers.openai.com/codex/cli/",
    })
  else
    health.ok("Codex CLI: " .. executable)
    local output, err = version({ command[1] })
    if output then
      health.ok(output)
    else
      health.error("failed to run Codex CLI: " .. err)
    end
  end

  local resolved_cwd, cwd_error = require("codex.cwd").resolve(0, config.cwd, config.root_markers)
  if resolved_cwd then
    health.ok("Working directory: " .. resolved_cwd)
  else
    health.error("Working directory cannot be resolved: " .. tostring(cwd_error))
  end

  health.info("Terminal layout: " .. config.terminal.layout)
  if #config.terminal.hide_keys == 0 then
    health.info("Terminal hide keys are disabled")
  else
    health.ok("Terminal hide keys: " .. table.concat(config.terminal.hide_keys, "/"))
  end

  if #config.terminal.normal_mode_keys == 0 then
    health.info("Terminal Normal-mode keys are disabled")
  else
    health.ok("Terminal Normal-mode keys: " .. table.concat(config.terminal.normal_mode_keys, "/"))
  end

  local navigation = config.terminal.window_navigation
  if navigation == false then
    health.info("Terminal window navigation is disabled")
  else
    health.ok(
      string.format(
        "Terminal navigation: %s/%s/%s/%s",
        navigation.left,
        navigation.down,
        navigation.up,
        navigation.right
      )
    )
  end

  local status = require("codex").status()
  if status.running then
    health.ok("Codex session is running in " .. tostring(status.cwd))
    if status.backend == "app_server" then
      health.info("App-server thread: " .. tostring(status.thread_id or "not started"))
    end
  else
    health.info("No Codex session is running")
  end
end

return M
