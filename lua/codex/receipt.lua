local M = {}

---@type { receipt: CodexNvimContextReceipt, backend: CodexNvimBackend, jobid: integer?, thread_id: string? }?
local last_context

---@param receipt CodexNvimContextReceipt
---@param status CodexNvimStatus
function M.remember(receipt, status)
  last_context = {
    receipt = vim.deepcopy(receipt),
    backend = status.backend,
    jobid = status.jobid,
    thread_id = status.thread_id,
  }
end

function M.clear()
  last_context = nil
end

---@param status CodexNvimStatus
---@return CodexNvimContextReceipt?
function M.active(status)
  if not last_context or last_context.backend ~= status.backend then
    return nil
  end
  if not status.running and (last_context.jobid or last_context.thread_id) then
    return nil
  end
  if last_context.jobid and status.jobid and last_context.jobid ~= status.jobid then
    return nil
  end
  if last_context.thread_id and status.thread_id and last_context.thread_id ~= status.thread_id then
    return nil
  end
  return vim.deepcopy(last_context.receipt)
end

---@param receipt CodexNvimContextReceipt
---@return string
function M.format_context(receipt)
  local targets
  if receipt.kind == "files" then
    targets = receipt.paths
  else
    targets = { receipt.file_path }
  end
  local labels = {}
  for index, path in ipairs(targets) do
    if index > 3 then
      break
    end
    table.insert(labels, "@" .. path)
  end
  if #targets > #labels then
    table.insert(labels, string.format("+%d more", #targets - #labels))
  end
  local target = table.concat(labels, ", ")
  if receipt.kind ~= "files" and not receipt.file_path then
    target = "[No Name]"
  end
  if receipt.start_line and receipt.end_line then
    target = string.format("%s:%d-%d", target, receipt.start_line, receipt.end_line)
  end
  return string.format(
    "%s %s, %s (cwd %s)",
    receipt.kind,
    target,
    receipt.submitted and "submitted" or "inserted",
    receipt.cwd
  )
end

---@param status CodexNvimStatus
---@return string
function M.format_status(status)
  local cwd = status.cwd or status.resolved_cwd
  local message
  if status.running then
    local details = { status.visible and "visible" or "hidden" }
    if status.jobid then
      table.insert(details, "job " .. tostring(status.jobid))
    end
    if cwd then
      table.insert(details, "cwd " .. cwd)
    end
    if status.thread_id then
      table.insert(details, "thread " .. status.thread_id)
    end
    message = string.format("%s running (%s)", status.backend, table.concat(details, ", "))
  else
    message = status.backend .. " stopped"
    if cwd then
      message = message .. " (next cwd " .. cwd .. ")"
    end
  end
  if status.last_context then
    message = message .. "\nlast context: " .. M.format_context(status.last_context)
  end
  return message
end

return M
