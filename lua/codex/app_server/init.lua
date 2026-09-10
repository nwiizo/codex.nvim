local M = {}

local client = require("codex.app_server.client")
local ui = require("codex.app_server.ui")

local state = {
  thread_id = nil,
  turn_id = nil,
  active = false,
  cwd = nil,
  cwd_locked = false,
  draft = "",
  last_diff = nil,
  file_changes = {},
  delta_items = {},
  thread_starting = false,
  thread_waiters = {},
  thread_switching = false,
  turn_starting = false,
  review_turn = false,
  pending_inputs = {},
  submitting = false,
  submission_callback = nil,
  submission_token = 0,
}

local function notify(message, level)
  vim.notify("codex.nvim: " .. message, level or vim.log.levels.INFO)
end

local function emit(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = pattern,
    modeline = false,
    data = data or {},
  })
end

local function current_cwd()
  local config = require("codex.config").get()
  return require("codex.cwd").resolve(0, config.cwd, config.root_markers)
end

---@param ok boolean
---@param token? integer
local function finish_submission(ok, token)
  if not state.submitting or (token and token ~= state.submission_token) then
    return
  end
  local callback = state.submission_callback
  state.submission_callback = nil
  state.submitting = false
  if ok then
    state.draft = ""
  end
  if callback then
    callback(ok)
  end
end

---@param callback fun()
---@param captured_cwd? string
---@return boolean
local function ensure_client(callback, captured_cwd)
  local config = require("codex.config").get()
  if not state.cwd_locked then
    local cwd, err = captured_cwd, nil
    if not cwd then
      cwd, err = current_cwd()
    end
    if not cwd then
      notify(tostring(err), vim.log.levels.ERROR)
      return false
    end
    state.cwd = cwd
    state.cwd_locked = true
  end
  client.set_notification_handler(M._handle_notification)
  client.set_server_request_handler(M._handle_server_request)
  local started = client.start({
    cmd = config.app_server.cmd,
    cwd = state.cwd,
    env = config.env,
    on_ready = callback,
    on_exit = M._handle_client_exit,
  })
  if not started and not client.is_running() then
    state.cwd = nil
    state.cwd_locked = false
  end
  return started
end

---@param callback fun(boolean)
local function ensure_thread(callback)
  if state.thread_id then
    callback(true)
    return
  end
  table.insert(state.thread_waiters, callback)
  if state.thread_starting then
    return
  end
  state.thread_starting = true
  local requested = client.request("thread/start", {
    cwd = state.cwd,
    serviceName = "codex.nvim",
  }, function(result, err)
    state.thread_starting = false
    local waiters = state.thread_waiters
    state.thread_waiters = {}
    if err or not result or not result.thread then
      notify(
        "could not start app-server thread: " .. tostring(err and err.message or "invalid response"),
        vim.log.levels.ERROR
      )
      for _, waiter in ipairs(waiters) do
        waiter(false)
      end
      return
    end
    state.thread_id = result.thread.id
    state.cwd = result.cwd or state.cwd
    ui.append("Thread: `" .. state.thread_id .. "`\n\n")
    emit("CodexThreadStarted", { thread_id = state.thread_id, cwd = state.cwd })
    for _, waiter in ipairs(waiters) do
      waiter(true)
    end
  end)
  if not requested then
    state.thread_starting = false
    local waiters = state.thread_waiters
    state.thread_waiters = {}
    for _, waiter in ipairs(waiters) do
      waiter(false)
    end
  end
end

---@param input table[]
---@param callback? fun(ok: boolean)
---@return boolean
local function steer_turn(input, callback)
  local requested = client.request("turn/steer", {
    threadId = state.thread_id,
    expectedTurnId = state.turn_id,
    input = input,
  }, function(_, err)
    if err then
      local message = "could not steer turn: " .. tostring(err.message or err.code)
      notify(message, vim.log.levels.ERROR)
      ui.append("\n\n> Error: " .. message .. "\n")
    end
    if callback then
      callback(err == nil)
    end
  end)
  if not requested then
    notify("could not send turn/steer", vim.log.levels.ERROR)
    if callback then
      callback(false)
    end
  end
  return requested
end

local function reject_pending_inputs()
  local pending = state.pending_inputs
  state.pending_inputs = {}
  for _, item in ipairs(pending) do
    if item.callback then
      item.callback(false)
    end
  end
end

local function steer_pending_inputs()
  local pending = state.pending_inputs
  state.pending_inputs = {}
  for _, item in ipairs(pending) do
    steer_turn(item.input, item.callback)
  end
end

---@param input table[]
---@param display string
---@param callback? fun(ok: boolean)
---@return boolean
local function start_turn(input, display, callback)
  if not ui.open(require("codex.config").get().focus_after_send) then
    notify("could not open the app-server panel; turn was not sent", vim.log.levels.ERROR)
    if callback then
      callback(false)
    end
    return false
  end
  ui.append("\n## You\n\n" .. display .. "\n\n## Codex\n\n")
  if state.turn_starting then
    table.insert(state.pending_inputs, { input = input, callback = callback })
    return true
  end
  if state.active and state.turn_id then
    return steer_turn(input, callback)
  end
  state.turn_starting = true
  state.review_turn = false
  state.turn_id = nil
  state.last_diff = nil
  state.file_changes = {}
  local requested = client.request("turn/start", {
    threadId = state.thread_id,
    cwd = state.cwd,
    input = input,
  }, function(result, err)
    state.turn_starting = false
    if err or not result or not result.turn then
      reject_pending_inputs()
      notify("could not start turn: " .. tostring(err and err.message or "invalid response"), vim.log.levels.ERROR)
      if callback then
        callback(false)
      end
      return
    end
    state.turn_id = result.turn.id
    state.active = true
    emit("CodexTurnStarted", { thread_id = state.thread_id, turn_id = state.turn_id })
    if callback then
      callback(true)
    end
    steer_pending_inputs()
  end)
  if not requested then
    state.turn_starting = false
    reject_pending_inputs()
    notify("could not send turn/start", vim.log.levels.ERROR)
    if callback then
      callback(false)
    end
  end
  return requested
end

---@param params table
---@return string?
local function event_turn_id(params)
  return params.turnId or (params.turn and params.turn.id) or nil
end

---@param method string
---@param params table
---@return boolean
local function is_current_notification(method, params)
  if params.threadId and state.thread_id and params.threadId ~= state.thread_id then
    return false
  end
  local turn_id = event_turn_id(params)
  if state.turn_starting and not state.turn_id then
    return method == "turn/started" or method == "warning" or method == "configWarning" or method == "error"
  end
  if turn_id and state.turn_id and turn_id ~= state.turn_id then
    return false
  end
  if turn_id and not state.turn_id and not state.turn_starting and method ~= "turn/started" then
    return false
  end
  return true
end

---@param thread_id string?
---@param turn_id string?
---@param item_id string?
---@return string?
local function item_key(thread_id, turn_id, item_id)
  if not thread_id or not turn_id or not item_id then
    return nil
  end
  return table.concat({ thread_id, turn_id, item_id }, "\0")
end

---@param method string
---@param params table
function M._handle_notification(method, params)
  if not is_current_notification(method, params) then
    return
  end
  if method == "turn/started" and params.turn then
    state.turn_id = params.turn.id
    state.active = true
  elseif method == "item/started" and params.item and params.item.type == "fileChange" then
    local key = item_key(params.threadId, params.turnId, params.item.id)
    if key then
      state.file_changes[key] = params.item.changes
    end
  elseif method == "item/agentMessage/delta" then
    state.delta_items[params.itemId or "__stream"] = true
    ui.append(params.delta or "")
  elseif method == "item/completed" and params.item then
    local item = params.item
    if item.type == "agentMessage" and not state.delta_items[item.id] then
      ui.append(item.text or "")
    elseif item.type == "commandExecution" then
      local output = item.aggregatedOutput or ""
      ui.append(string.format("\n\n```console\n$ %s\n%s\n```\n", item.command or "", output))
    end
  elseif method == "turn/diff/updated" then
    state.last_diff = {
      text = params.diff,
      thread_id = params.threadId,
      turn_id = params.turnId,
    }
    emit("CodexDiffUpdated", { thread_id = params.threadId, turn_id = params.turnId, diff = params.diff })
  elseif method == "turn/plan/updated" then
    local lines = { "\n\n### Plan" }
    for _, item in ipairs(params.plan or {}) do
      table.insert(lines, string.format("- [%s] %s", item.status == "completed" and "x" or " ", item.step))
    end
    ui.append(table.concat(lines, "\n") .. "\n")
  elseif method == "turn/completed" then
    state.turn_starting = false
    reject_pending_inputs()
    state.active = false
    state.review_turn = false
    state.turn_id = params.turn and params.turn.id or state.turn_id
    local status = params.turn and params.turn.status or "completed"
    ui.append("\n\n---\nTurn " .. status .. ".\n")
    emit("CodexTurnCompleted", { thread_id = state.thread_id, turn_id = state.turn_id, status = status })
  elseif method == "warning" or method == "configWarning" then
    ui.append("\n\n> Warning: " .. tostring(params.message or params.summary) .. "\n")
  elseif method == "error" then
    local err = params.error or params
    ui.append("\n\n> Error: " .. tostring(err.message or err) .. "\n")
  end
end

local decision_labels = {
  accept = "Accept",
  acceptForSession = "Accept for session",
  decline = "Decline",
  cancel = "Cancel turn",
}

---@param decision unknown
---@return string?
local function decision_label(decision)
  if type(decision) == "string" then
    return decision_labels[decision] or decision
  end
  if type(decision) ~= "table" then
    return nil
  end
  if decision.acceptWithExecpolicyAmendment then
    return "Accept and remember command policy: " .. vim.inspect(decision.acceptWithExecpolicyAmendment)
  end
  if decision.applyNetworkPolicyAmendment then
    return "Apply network policy: " .. vim.inspect(decision.applyNetworkPolicyAmendment)
  end
  return nil
end

---@param decisions unknown
---@param fallback boolean
---@return table[]
local function approval_choices(decisions, fallback)
  if decisions == nil and fallback then
    decisions = { "accept", "acceptForSession", "decline", "cancel" }
  end
  if type(decisions) ~= "table" or not vim.islist(decisions) then
    return {}
  end
  local choices = {}
  for _, decision in ipairs(decisions) do
    local label = decision_label(decision)
    if label then
      table.insert(choices, { label = label, decision = decision })
    end
  end
  return choices
end

---@param choices table[]
---@return string?
local function dismissal_decision(choices)
  for _, wanted in ipairs({ "cancel", "decline" }) do
    for _, choice in ipairs(choices) do
      if choice.decision == wanted then
        return wanted
      end
    end
  end
end

---@param method string
---@param params table
---@param id integer|string
local function handle_approval(method, params, id)
  local is_file = method == "item/fileChange/requestApproval"
  local changes
  if is_file then
    changes = state.file_changes[item_key(params.threadId, params.turnId, params.itemId)]
    if changes then
      local diffs = {}
      for _, change in ipairs(changes) do
        if type(change.diff) == "string" and change.diff ~= "" then
          table.insert(diffs, change.diff)
        end
      end
      if #diffs > 0 then
        ui.show_diff(table.concat(diffs, "\n"))
      end
    end
  end

  local details = {
    "\n\n### Approval requested",
    "- Type: " .. (is_file and "file change" or "command execution"),
  }
  local fields = {
    "itemId",
    "command",
    "cwd",
    "reason",
    "commandActions",
    "additionalPermissions",
    "networkApprovalContext",
    "proposedExecpolicyAmendment",
    "proposedNetworkPolicyAmendments",
    "grantRoot",
    "environmentId",
  }
  for _, field in ipairs(fields) do
    if params[field] ~= nil then
      table.insert(details, string.format("- %s: `%s`", field, vim.inspect(params[field])))
    end
  end
  if is_file then
    if changes then
      table.insert(details, "- changes: `" .. vim.inspect(changes) .. "`")
    end
  end
  ui.append(table.concat(details, "\n") .. "\n")

  local choices = approval_choices(params.availableDecisions, not is_file)
  if is_file then
    choices = approval_choices(nil, true)
  end
  if #choices == 0 then
    notify("app-server supplied no supported approval decisions", vim.log.levels.ERROR)
    client.respond(id, nil, { code = -32000, message = "No supported approval decisions" })
    return
  end
  local subject = params.command or params.reason or (is_file and "Apply file changes?") or "Run command?"
  if params.cwd then
    subject = subject .. " — " .. params.cwd
  end
  vim.ui.select(choices, {
    prompt = tostring(subject),
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      client.respond(id, { decision = choice.decision })
      return
    end
    local decision = dismissal_decision(choices)
    if decision then
      client.respond(id, { decision = decision })
    else
      client.respond(id, nil, { code = -32000, message = "Approval prompt dismissed" })
    end
  end)
end

---@param questions table[]
---@param index integer
---@param answers table
---@param done fun(answers: table)
local function ask_question(questions, index, answers, done)
  local question = questions[index]
  if not question then
    done(answers)
    return
  end
  local function save(value)
    answers[question.id] = { answers = value and value ~= "" and { value } or {} }
    ask_question(questions, index + 1, answers, done)
  end
  local function input_answer()
    local prompt = question.question .. " "
    if question.isSecret then
      local ok, value = pcall(vim.fn.inputsecret, prompt)
      save(ok and value or nil)
    else
      vim.ui.input({ prompt = prompt }, save)
    end
  end
  if type(question.options) == "table" and #question.options > 0 then
    local choices = vim.deepcopy(question.options)
    if question.isOther then
      table.insert(choices, { label = "Other…", description = "Enter a custom answer", custom = true })
    end
    vim.ui.select(choices, {
      prompt = question.question,
      format_item = function(item)
        return item.description ~= "" and (item.label .. " — " .. item.description) or item.label
      end,
    }, function(choice)
      if choice and choice.custom then
        input_answer()
      else
        save(choice and choice.label or nil)
      end
    end)
  else
    input_answer()
  end
end

---@param params table
---@param id integer|string
local function handle_permissions(params, id)
  ui.append("\n\n### Permission request\n\n```lua\n" .. vim.inspect(params) .. "\n```\n")
  local choices = {
    { label = "Grant for this turn", scope = "turn" },
    { label = "Grant for this session", scope = "session" },
    { label = "Decline", scope = nil },
  }
  vim.ui.select(choices, {
    prompt = params.reason or "Grant the requested permissions?",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    client.respond(id, {
      permissions = choice and choice.scope and params.permissions or {},
      scope = (choice and choice.scope) or "turn",
    })
  end)
end

---@param method string
---@param params table
---@param id integer|string
function M._handle_server_request(method, params, id)
  if params.threadId and params.threadId ~= state.thread_id then
    client.respond(id, nil, { code = -32000, message = "Request belongs to an inactive thread" })
    return
  end
  if params.turnId and params.turnId ~= state.turn_id then
    client.respond(id, nil, { code = -32000, message = "Request belongs to an inactive turn" })
    return
  end
  if method == "item/commandExecution/requestApproval" or method == "item/fileChange/requestApproval" then
    handle_approval(method, params, id)
  elseif method == "item/tool/requestUserInput" then
    local resolved = false
    local timer
    local function respond(answers)
      if resolved then
        return
      end
      resolved = true
      if timer then
        pcall(timer.stop, timer)
        if not timer:is_closing() then
          timer:close()
        end
      end
      client.respond(id, { answers = answers })
    end
    if type(params.autoResolutionMs) == "number" then
      timer = vim.defer_fn(function()
        respond({})
      end, params.autoResolutionMs)
    end
    ask_question(params.questions or {}, 1, {}, respond)
  elseif method == "item/permissions/requestApproval" then
    handle_permissions(params, id)
  elseif method == "mcpServer/elicitation/request" then
    vim.ui.select({ "decline", "cancel" }, { prompt = params.message or "MCP server requests input" }, function(choice)
      client.respond(id, { action = choice or "cancel" })
    end)
  else
    client.respond(id, nil, { code = -32601, message = "Unsupported client request: " .. method })
  end
end

---@param opts? table
---@return boolean
function M.open(opts)
  opts = opts or {}
  local captured_cwd
  if not state.cwd_locked then
    local err
    captured_cwd, err = current_cwd()
    if not captured_cwd then
      notify(tostring(err), vim.log.levels.ERROR)
      return false
    end
  end
  if not ui.open(opts.focus ~= false) then
    return false
  end
  return ensure_client(function()
    ensure_thread(function() end)
  end, captured_cwd)
end

function M.hide()
  return ui.hide()
end

function M.toggle()
  if ui.status().visible then
    return ui.hide()
  end
  return M.open()
end

function M.focus()
  if not client.is_running() then
    return M.open()
  end
  return ui.focus()
end

---@param text string
---@param opts? CodexNvimSendOptions
---@return boolean
function M.send(text, opts)
  opts = opts or {}
  local captured_cwd
  if opts.cwd then
    local err
    captured_cwd, err = require("codex.cwd").resolve(0, opts.cwd, require("codex.config").get().root_markers)
    if not captured_cwd then
      notify(tostring(err), vim.log.levels.ERROR)
      return false
    end
    if state.cwd_locked and captured_cwd ~= state.cwd then
      notify("request cwd differs from the running session; stop it before sending this request", vim.log.levels.WARN)
      return false
    end
  end
  if state.thread_switching then
    notify("wait for the thread switch to complete", vim.log.levels.WARN)
    return false
  end
  if type(text) ~= "string" or text == "" then
    notify("cannot send empty text", vim.log.levels.WARN)
    return false
  end
  if state.review_turn then
    notify("wait for the active review to complete before sending another prompt", vim.log.levels.WARN)
    return false
  end
  if state.submitting then
    notify("wait for the pending prompt to be accepted", vim.log.levels.WARN)
    return false
  end
  if opts.submit == false then
    if not state.cwd_locked then
      local cwd, err = captured_cwd, nil
      if not cwd then
        cwd, err = current_cwd()
      end
      if not cwd then
        notify(tostring(err), vim.log.levels.ERROR)
        return false
      end
      state.cwd = cwd
      state.cwd_locked = true
    end
    if require("codex.config").get().focus_after_send and not ui.open(true) then
      notify("could not open the app-server panel; draft was not inserted", vim.log.levels.ERROR)
      return false
    end
    state.draft = state.draft .. text
    ui.append("\n\n> Draft: " .. text .. "\n")
    if opts.on_complete then
      opts.on_complete(true)
    end
    return true
  end
  local prompt = state.draft .. text
  state.submitting = true
  state.submission_token = state.submission_token + 1
  local submission_token = state.submission_token
  state.submission_callback = opts.on_complete
  local delivery_result
  local function complete(ok)
    if not state.submitting or state.submission_token ~= submission_token then
      return
    end
    delivery_result = ok
    finish_submission(ok, submission_token)
  end
  local started = ensure_client(function()
    ensure_thread(function(ok)
      if not ok then
        complete(false)
        return
      end
      start_turn({ { type = "text", text = prompt } }, prompt, complete)
    end)
  end, captured_cwd)
  if not started then
    complete(false)
  end
  return started and delivery_result ~= false
end

---@param paths string[]
---@return boolean
function M.send_images(paths)
  if state.thread_switching then
    notify("wait for the thread switch to complete", vim.log.levels.WARN)
    return false
  end
  if state.submitting then
    notify("wait for the pending prompt to be accepted", vim.log.levels.WARN)
    return false
  end
  if state.review_turn then
    notify("wait for the active review to complete before sending images", vim.log.levels.WARN)
    return false
  end
  local input = { { type = "text", text = "Use these images as context." } }
  local display = { "Attached images:" }
  for _, path in ipairs(paths) do
    local absolute = require("codex.cwd").absolute(path)
    local stat = vim.uv.fs_stat(absolute)
    if not stat or stat.type ~= "file" then
      notify("image does not exist: " .. absolute, vim.log.levels.ERROR)
      return false
    end
    absolute = vim.uv.fs_realpath(absolute) or absolute
    table.insert(input, { type = "localImage", path = absolute })
    table.insert(display, "- `" .. absolute .. "`")
  end
  return ensure_client(function()
    ensure_thread(function(ok)
      if ok then
        start_turn(input, table.concat(display, "\n"))
      end
    end)
  end)
end

---@param callback fun(threads: table[]?, error: table?)
---@param all? boolean
---@return boolean
function M.list_threads(callback, all)
  return ensure_client(function()
    local params = { limit = 50, sortKey = "recency_at", sortDirection = "desc" }
    if not all then
      params.cwd = state.cwd
    end
    client.request("thread/list", params, function(result, err)
      callback(result and result.data or nil, err)
    end)
  end)
end

---@param action "resume"|"fork"
---@param thread_id string
---@param callback? fun(boolean)
---@return boolean
local function switch_thread(action, thread_id, callback)
  if state.active or state.turn_starting or state.thread_starting or state.thread_switching or state.submitting then
    notify("interrupt or wait for current app-server work before switching threads", vim.log.levels.WARN)
    if callback then
      callback(false)
    end
    return false
  end
  state.thread_switching = true
  local started = ensure_client(function()
    local requested = client.request("thread/" .. action, { threadId = thread_id }, function(result, err)
      state.thread_switching = false
      if err or not result or not result.thread then
        notify(
          string.format("could not %s thread: %s", action, tostring(err and err.message or "invalid response")),
          vim.log.levels.ERROR
        )
        if callback then
          callback(false)
        end
        return
      end
      state.thread_id = result.thread.id
      state.cwd = result.cwd or state.cwd
      state.turn_id = nil
      state.active = false
      state.draft = ""
      state.last_diff = nil
      state.file_changes = {}
      state.delta_items = {}
      state.review_turn = false
      ui.open(true)
      ui.append(string.format("\n%s thread `%s`.\n", action == "resume" and "Resumed" or "Forked as", state.thread_id))
      if callback then
        callback(true)
      end
    end)
    if not requested then
      state.thread_switching = false
      if callback then
        callback(false)
      end
    end
  end)
  if not started then
    state.thread_switching = false
  end
  return started
end

---@param thread_id string
---@param callback? fun(boolean)
---@return boolean
function M.resume_thread(thread_id, callback)
  return switch_thread("resume", thread_id, callback)
end

---@param thread_id string
---@param callback? fun(boolean)
---@return boolean
function M.fork_thread(thread_id, callback)
  return switch_thread("fork", thread_id, callback)
end

---@param target table
---@return boolean
function M.review(target)
  if state.active or state.turn_starting or state.thread_starting or state.thread_switching or state.submitting then
    notify("wait for current app-server work before starting a review", vim.log.levels.WARN)
    return false
  end
  local captured_cwd
  if not state.cwd_locked then
    local err
    captured_cwd, err = current_cwd()
    if not captured_cwd then
      notify(tostring(err), vim.log.levels.ERROR)
      return false
    end
  end
  if not ui.open(require("codex.config").get().focus_after_send) then
    return false
  end
  state.turn_starting = true
  state.review_turn = true
  state.turn_id = nil
  state.last_diff = nil
  state.file_changes = {}
  local started = ensure_client(function()
    ensure_thread(function(ok)
      if not ok then
        state.turn_starting = false
        state.review_turn = false
        reject_pending_inputs()
        return
      end
      local requested = client.request("review/start", {
        threadId = state.thread_id,
        delivery = "inline",
        target = target,
      }, function(result, err)
        state.turn_starting = false
        if err or not result or not result.turn then
          reject_pending_inputs()
          state.review_turn = false
          notify(
            "could not start review: " .. tostring(err and err.message or "invalid response"),
            vim.log.levels.ERROR
          )
          return
        end
        state.turn_id = result.turn.id
        state.active = true
        steer_pending_inputs()
      end)
      if not requested then
        state.turn_starting = false
        state.review_turn = false
        notify("could not send review/start", vim.log.levels.ERROR)
      end
    end)
  end, captured_cwd)
  if not started then
    state.turn_starting = false
    state.review_turn = false
    reject_pending_inputs()
  end
  return started
end

function M.show_diff()
  if not state.last_diff then
    notify("no app-server diff is available", vim.log.levels.WARN)
    return false
  end
  return ui.show_diff(state.last_diff.text)
end

function M.interrupt()
  if not state.active or not state.thread_id or not state.turn_id then
    notify("no active app-server turn", vim.log.levels.WARN)
    return false
  end
  return client.request("turn/interrupt", { threadId = state.thread_id, turnId = state.turn_id })
end

---@param exit_code integer
function M._handle_client_exit(exit_code)
  ui.append(string.format("\n\n> App-server exited unexpectedly (code %d).\n", exit_code))
  state.thread_id = nil
  state.turn_id = nil
  state.active = false
  state.cwd = nil
  state.cwd_locked = false
  finish_submission(false)
  state.last_diff = nil
  state.file_changes = {}
  state.delta_items = {}
  state.thread_starting = false
  state.thread_waiters = {}
  state.thread_switching = false
  state.turn_starting = false
  state.review_turn = false
  reject_pending_inputs()
end

function M.stop()
  local stopped = client.stop()
  finish_submission(false)
  reject_pending_inputs()
  ui.reset()
  state.thread_id = nil
  state.turn_id = nil
  state.active = false
  state.cwd = nil
  state.cwd_locked = false
  state.draft = ""
  state.last_diff = nil
  state.file_changes = {}
  state.delta_items = {}
  state.thread_starting = false
  state.thread_waiters = {}
  state.thread_switching = false
  state.turn_starting = false
  state.review_turn = false
  state.pending_inputs = {}
  state.submitting = false
  state.submission_callback = nil
  return stopped
end

function M.status()
  local client_status = client.status()
  local ui_status = ui.status()
  return {
    backend = "app_server",
    running = client_status.running,
    visible = ui_status.visible,
    initialized = client_status.initialized,
    bufnr = ui_status.bufnr,
    winid = ui_status.winid,
    jobid = client_status.jobid,
    cwd = state.cwd,
    thread_id = state.thread_id,
    turn_id = state.turn_id,
    active = state.active or state.turn_starting,
  }
end

function M._reset()
  M.stop()
  if client._reset then
    client._reset()
  end
end

return M
