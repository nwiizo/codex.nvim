if vim.g.loaded_codex_nvim then
  return
end
vim.g.loaded_codex_nvim = 1

if vim.fn.has("nvim-0.12") ~= 1 then
  vim.api.nvim_err_writeln("codex.nvim requires Neovim >= 0.12")
  return
end

local function codex()
  return require("codex")
end

vim.api.nvim_create_user_command("Codex", function(opts)
  codex().toggle(opts.fargs)
end, { nargs = "*", desc = "Toggle the Codex panel" })

vim.api.nvim_create_user_command("CodexOpen", function(opts)
  codex().open(opts.fargs)
end, { nargs = "*", desc = "Open the Codex panel" })

vim.api.nvim_create_user_command("CodexClose", function()
  codex().close()
end, { desc = "Hide the Codex panel" })

vim.api.nvim_create_user_command("CodexFocus", function()
  codex().focus()
end, { desc = "Focus the Codex panel" })

vim.api.nvim_create_user_command("CodexStop", function()
  codex().stop()
end, { desc = "Stop the Codex process" })

vim.api.nvim_create_user_command("CodexResume", function(opts)
  codex().resume(opts.fargs)
end, { nargs = "*", desc = "Resume a Codex session" })

vim.api.nvim_create_user_command("CodexContinue", function()
  codex().continue()
end, { desc = "Resume the latest Codex session" })

vim.api.nvim_create_user_command("CodexFork", function(opts)
  codex().fork(opts.fargs)
end, { nargs = "*", desc = "Fork a Codex session" })

vim.api.nvim_create_user_command("CodexReview", function(opts)
  codex().review(opts.fargs)
end, { nargs = "*", desc = "Review changes with Codex" })

vim.api.nvim_create_user_command("CodexImage", function(opts)
  codex().image(opts.fargs)
end, { nargs = "+", complete = "file", desc = "Start a Codex turn with images" })

vim.api.nvim_create_user_command("CodexPrompt", function(opts)
  codex().prompt(opts.args ~= "" and opts.args or nil)
end, { nargs = "*", desc = "Prompt the active Codex backend" })

vim.api.nvim_create_user_command("CodexDiff", function()
  codex().show_diff()
end, { desc = "Show the latest app-server diff" })

vim.api.nvim_create_user_command("CodexInterrupt", function()
  codex().interrupt()
end, { desc = "Interrupt the active app-server turn" })

vim.api.nvim_create_user_command("CodexSend", function(opts)
  codex().send_range(opts.line1, opts.line2)
end, { range = true, desc = "Send a line range to Codex" })

vim.api.nvim_create_user_command("CodexSendVisual", function()
  codex().send_visual()
end, { range = true, desc = "Send the exact visual selection to Codex" })

vim.api.nvim_create_user_command("CodexAddVisual", function()
  codex().add_visual()
end, { range = true, desc = "Insert the exact visual selection without submitting" })

vim.api.nvim_create_user_command("CodexAdd", function(opts)
  codex().add(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", complete = "file", desc = "Insert a file reference into the Codex composer" })

vim.api.nvim_create_user_command("CodexTreeAdd", function(opts)
  codex().add_from_explorer(opts.range > 0 and opts.line1 or nil, opts.range > 0 and opts.line2 or nil)
end, { range = true, desc = "Insert selected explorer paths into the Codex composer" })

vim.api.nvim_create_user_command("CodexSendText", function(opts)
  codex().send(opts.args, { submit = not opts.bang })
end, { nargs = "+", bang = true, desc = "Send text to Codex; bang inserts without submitting" })

vim.api.nvim_create_user_command("CodexStatus", function()
  vim.notify("codex.nvim: " .. codex().status_message(), vim.log.levels.INFO)
end, { desc = "Show Codex backend status" })

vim.api.nvim_create_user_command("CodexHealth", function()
  vim.cmd("checkhealth codex")
end, { desc = "Run codex.nvim health checks" })
