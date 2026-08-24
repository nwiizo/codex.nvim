local h = require("tests.harness")

h.test("plugin registers commands without loading the core module", function()
  package.loaded.codex = nil
  vim.g.loaded_codex_nvim = nil
  vim.cmd("runtime plugin/codex.lua")
  h.eq(nil, package.loaded.codex)
  h.eq(nil, package.loaded["codex.config"])
  h.eq(nil, package.loaded["codex.terminal"])

  for _, name in ipairs({
    "Codex",
    "CodexOpen",
    "CodexClose",
    "CodexFocus",
    "CodexStop",
    "CodexResume",
    "CodexContinue",
    "CodexFork",
    "CodexReview",
    "CodexImage",
    "CodexPrompt",
    "CodexDiff",
    "CodexInterrupt",
    "CodexSend",
    "CodexSendVisual",
    "CodexAddVisual",
    "CodexAdd",
    "CodexTreeAdd",
    "CodexSendText",
    "CodexStatus",
    "CodexHealth",
  }) do
    h.eq(2, vim.fn.exists(":" .. name), name .. " should exist")
  end

  local notified
  local original_notify = vim.notify
  rawset(vim, "notify", function(message)
    notified = message
  end)
  vim.cmd("CodexStatus")
  rawset(vim, "notify", original_notify)
  h.truthy(package.loaded.codex)
  h.contains(notified, "terminal stopped")
  h.contains(notified, "next cwd")
end)
