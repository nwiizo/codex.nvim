local M = {}

local function notify(message, level)
  vim.notify("codex.nvim: " .. message, level or vim.log.levels.ERROR)
end

---@param cwd string
---@return boolean
function M.open_git(cwd)
  local sections = {}
  local function read(staged)
    local argv = { "git", "--no-pager", "diff", "--no-ext-diff", "--no-textconv", "--color=never" }
    if staged then
      table.insert(argv, "--cached")
    end
    table.insert(argv, "--")
    local ok, err = pcall(vim.system, argv, { cwd = cwd, text = true, timeout = 10000 }, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          notify("could not read Git diff: " .. vim.trim(result.stderr or "") .. " (exit " .. result.code .. ")")
          return
        end
        if result.stdout and result.stdout ~= "" then
          table.insert(sections, (staged and "Staged changes\n\n" or "Unstaged changes\n\n") .. result.stdout)
        end
        if not staged then
          read(true)
          return
        end
        if #sections == 0 then
          notify("no tracked Git changes; untracked files and unsaved buffers are not included", vim.log.levels.INFO)
          return
        end
        local header = "Git changes in "
          .. cwd
          .. "\n"
          .. "Includes all authors' changes. Untracked files and unsaved buffers are not included.\n\n"
        require("codex.app_server.ui").show_diff(header .. table.concat(sections, "\n"), "codex://git-diff")
      end)
    end)
    if not ok then
      notify("could not read Git diff: " .. tostring(err))
    end
    return ok
  end
  return read(false)
end

return M
