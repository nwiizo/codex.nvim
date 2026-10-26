local client = require("codex.app_server.client")

local done = false
local failure
local count
local sandbox = vim.fn.tempname()
vim.fn.mkdir(sandbox .. "/codex", "p")

local started = client.start({
  cmd = { "codex", "-c", 'cli_auth_credentials_store="file"', "app-server" },
  cwd = sandbox,
  env = {
    HOME = sandbox,
    CODEX_HOME = sandbox .. "/codex",
    XDG_CONFIG_HOME = sandbox .. "/config",
    XDG_DATA_HOME = sandbox .. "/data",
    XDG_CACHE_HOME = sandbox .. "/cache",
    OPENAI_API_KEY = "",
    CODEX_API_KEY = "",
    CODEX_ACCESS_TOKEN = "",
  },
  on_ready = function()
    client.request("thread/list", {
      limit = 1,
      sortKey = "recency_at",
      sortDirection = "desc",
      sourceKinds = { "cli", "vscode", "appServer" },
    }, function(result, err)
      if err then
        failure = err.message or vim.inspect(err)
      else
        count = #(result.data or {})
      end
      done = true
    end)
  end,
})

if not started or not vim.wait(10000, function()
  return done
end, 10) then
  failure = failure or "timed out waiting for app-server"
end

local jobid = client.status().jobid
client.stop()
if jobid then
  vim.fn.jobwait({ jobid }, 3000)
end
vim.fn.delete(sandbox, "rf")
if failure then
  io.stderr:write("app-server integration failed: " .. failure .. "\n")
  vim.cmd("cquit 1")
else
  io.stdout:write(string.format("app-server integration ok: thread/list returned %d item(s)\n", count))
  vim.cmd("qa!")
end
