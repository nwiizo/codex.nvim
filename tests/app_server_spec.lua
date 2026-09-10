local h = require("tests.harness")

h.test("app-server backend starts a thread, sends a turn, and streams UI updates", function()
  local requests = {}
  local notification_handler
  local server_request_handler
  local client_exit_handler
  local turn_callback
  local review_callback
  local appended = {}
  local diff
  local cwd_calls = 0
  local ui_open_ok = true
  local client_start_ok = true
  local client_running = false
  local thread_start_error = false
  local ui_open_focuses = {}
  local sequence = {}
  local responses = {}
  local fake_client = {
    start = function(opts)
      if not client_start_ok then
        return false
      end
      client_running = true
      client_exit_handler = opts.on_exit
      opts.on_ready()
      return true
    end,
    request = function(method, params, callback)
      table.insert(requests, { method = method, params = params })
      if method == "thread/start" then
        if thread_start_error then
          callback(nil, { message = "thread rejected" })
        else
          callback({ thread = { id = "thread-1" }, cwd = params.cwd })
        end
      elseif method == "turn/start" then
        turn_callback = callback
      elseif method == "turn/steer" then
        if callback then
          callback({}, nil)
        end
      elseif method == "review/start" then
        review_callback = callback
      end
      return true
    end,
    set_notification_handler = function(handler)
      notification_handler = handler
    end,
    set_server_request_handler = function(handler)
      server_request_handler = handler
    end,
    is_running = function()
      return client_running
    end,
    status = function()
      return { running = true, initialized = true, jobid = 71 }
    end,
    stop = function()
      client_running = false
      return true
    end,
    respond = function(id, result, err)
      table.insert(responses, { id = id, result = result, error = err })
    end,
  }
  local fake_ui = {
    open = function(focus)
      table.insert(sequence, "ui")
      table.insert(ui_open_focuses, focus)
      return ui_open_ok
    end,
    hide = function() end,
    focus = function() end,
    toggle = function() end,
    append = function(text)
      table.insert(appended, text)
    end,
    show_diff = function(value)
      diff = value
      return true
    end,
    status = function()
      return { visible = true, bufnr = 8, winid = 9 }
    end,
    reset = function() end,
  }
  local original_client = package.loaded["codex.app_server.client"]
  local original_ui = package.loaded["codex.app_server.ui"]
  package.loaded["codex.app_server.client"] = fake_client
  package.loaded["codex.app_server.ui"] = fake_ui
  package.loaded["codex.app_server"] = nil

  require("codex.config").setup({
    backend = "app_server",
    focus_after_send = true,
    cwd = function()
      cwd_calls = cwd_calls + 1
      table.insert(sequence, "cwd")
      return vim.uv.cwd()
    end,
  })
  local app = require("codex.app_server")
  h.truthy(app.open())
  h.eq({ "cwd", "ui" }, sequence)
  h.eq("thread/start", requests[1].method)
  h.truthy(app.send("@lua/codex/init.lua ", { submit = false }))
  h.eq(true, ui_open_focuses[#ui_open_focuses])
  h.contains(appended[#appended], "> Draft: @lua/codex/init.lua ")
  h.truthy(app.send("hello"))
  h.eq("turn/start", requests[2].method)
  h.eq("@lua/codex/init.lua hello", requests[2].params.input[1].text)
  local original_notify = vim.notify
  rawset(vim, "notify", function() end)
  h.eq(false, app.send("too early"))
  rawset(vim, "notify", original_notify)
  h.eq(2, #requests)
  turn_callback({ turn = { id = "turn-1" } })
  h.truthy(app.send("follow up"))
  h.eq("turn/steer", requests[3].method)
  h.eq("follow up", requests[3].params.input[1].text)
  h.eq(1, cwd_calls)
  h.eq(vim.uv.cwd(), requests[2].params.cwd)

  notification_handler("item/agentMessage/delta", { delta = "answer" })
  notification_handler("turn/diff/updated", { diff = "diff --git a/a b/a" })
  h.eq("answer", appended[#appended])
  h.truthy(app.show_diff())
  h.contains(diff, "diff --git")
  h.truthy(server_request_handler)

  local original_select = vim.ui.select
  rawset(vim.ui, "select", function(items, _, callback)
    callback(items[1])
  end)
  diff = nil
  notification_handler("item/started", {
    threadId = "thread-1",
    turnId = "turn-1",
    item = {
      id = "file-item",
      type = "fileChange",
      changes = { { path = "a.lua", kind = "update", diff = "diff --git a/a.lua b/a.lua\n+new" } },
    },
  })
  server_request_handler("item/fileChange/requestApproval", {
    threadId = "thread-1",
    turnId = "turn-1",
    itemId = "file-item",
  }, 90)
  h.truthy(type(diff) == "string")
  ---@cast diff string
  h.contains(diff, "diff --git a/a.lua")
  h.eq(nil, diff:find("diff --git a/a b/a", 1, true))

  server_request_handler("item/commandExecution/requestApproval", {
    threadId = "thread-1",
    turnId = "turn-1",
    itemId = "item-1",
    command = "make test",
    cwd = vim.uv.cwd(),
    availableDecisions = {
      { acceptWithExecpolicyAmendment = { execpolicy_amendment = { "make", "test" } } },
      "decline",
    },
  }, 91)
  rawset(vim.ui, "select", original_select)
  h.eq(91, responses[#responses].id)
  h.eq({ "make", "test" }, responses[#responses].result.decision.acceptWithExecpolicyAmendment.execpolicy_amendment)

  local appended_before = #appended
  notification_handler("item/agentMessage/delta", {
    threadId = "another-thread",
    turnId = "another-turn",
    delta = "stale",
  })
  h.eq(appended_before, #appended)
  original_notify = vim.notify
  rawset(vim, "notify", function() end)
  h.eq(false, app.resume_thread("another-thread"))
  rawset(vim, "notify", original_notify)

  notification_handler("turn/completed", {
    threadId = "thread-1",
    turn = { id = "turn-1", status = "completed" },
  })
  h.truthy(app.review({ type = "uncommittedChanges" }))
  local review_requests = #requests
  original_notify = vim.notify
  rawset(vim, "notify", function() end)
  h.eq(false, app.send("review focus"))
  rawset(vim, "notify", original_notify)
  h.eq(review_requests, #requests)
  h.truthy(review_callback)
  review_callback({ turn = { id = "review-turn" } })
  original_notify = vim.notify
  rawset(vim, "notify", function() end)
  h.eq(false, app.send("still reviewing"))
  rawset(vim, "notify", original_notify)
  h.eq(review_requests, #requests)

  notification_handler("turn/completed", {
    threadId = "thread-1",
    turn = { id = "review-turn", status = "completed" },
  })
  ui_open_ok = true
  h.truthy(app.send("@retry ", { submit = false }))
  ui_open_ok = false
  local requests_before = #requests
  local failed_completion
  original_notify = vim.notify
  rawset(vim, "notify", function() end)
  h.eq(
    false,
    app.send("first", {
      on_complete = function(ok)
        failed_completion = ok
      end,
    })
  )
  rawset(vim, "notify", original_notify)
  h.eq(requests_before, #requests)
  h.eq(false, failed_completion)

  ui_open_ok = true
  local successful_completion
  h.truthy(app.send("second", {
    on_complete = function(ok)
      successful_completion = ok
    end,
  }))
  h.eq("turn/start", requests[#requests].method)
  h.eq("@retry second", requests[#requests].params.input[1].text)
  turn_callback({ turn = { id = "turn-2" } })
  h.eq(true, successful_completion)

  notification_handler("turn/completed", {
    threadId = "thread-1",
    turn = { id = "turn-2", status = "completed" },
  })
  h.truthy(app.send("@turn-failure ", { submit = false }))
  local rejected_completion
  h.truthy(app.send("first", {
    on_complete = function(ok)
      rejected_completion = ok
    end,
  }))
  original_notify = vim.notify
  rawset(vim, "notify", function() end)
  turn_callback(nil, { message = "turn rejected" })
  rawset(vim, "notify", original_notify)
  h.eq(false, rejected_completion)
  h.truthy(app.send("second"))
  h.eq("@turn-failure second", requests[#requests].params.input[1].text)
  turn_callback({ turn = { id = "turn-3" } })
  notification_handler("turn/completed", {
    threadId = "thread-1",
    turn = { id = "turn-3", status = "completed" },
  })

  client_running = false
  client_exit_handler(1)
  h.truthy(app.send("@client-failure ", { submit = false }))
  client_start_ok = false
  local client_completion
  original_notify = vim.notify
  rawset(vim, "notify", function() end)
  h.eq(
    false,
    app.send("first", {
      on_complete = function(ok)
        client_completion = ok
      end,
    })
  )
  rawset(vim, "notify", original_notify)
  h.eq(false, client_completion)
  client_start_ok = true
  h.truthy(app.send("second"))
  h.eq("@client-failure second", requests[#requests].params.input[1].text)
  turn_callback({ turn = { id = "turn-4" } })
  notification_handler("turn/completed", {
    threadId = "thread-1",
    turn = { id = "turn-4", status = "completed" },
  })

  client_running = false
  client_exit_handler(1)
  h.truthy(app.send("@thread-failure ", { submit = false }))
  thread_start_error = true
  local thread_completion
  original_notify = vim.notify
  rawset(vim, "notify", function() end)
  h.eq(
    false,
    app.send("first", {
      on_complete = function(ok)
        thread_completion = ok
      end,
    })
  )
  rawset(vim, "notify", original_notify)
  h.eq(false, thread_completion)
  thread_start_error = false
  h.truthy(app.send("second"))
  h.eq("@thread-failure second", requests[#requests].params.input[1].text)
  turn_callback({ turn = { id = "turn-5" } })

  client_running = false
  client_exit_handler(1)
  h.eq(false, app.status().active)
  h.eq(nil, app.status().thread_id)
  h.eq(nil, app.status().cwd)

  -- A request created before focus moved to another project keeps its cwd.
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  directory = assert(vim.uv.fs_realpath(directory))
  h.truthy(app.send("request from the original editor", { cwd = directory }))
  h.eq(directory, app.status().cwd)
  h.eq(directory, requests[#requests].params.cwd)
  turn_callback({ turn = { id = "captured-cwd-turn" } })
  local request_count = #requests
  original_notify = vim.notify
  rawset(vim, "notify", function() end)
  h.eq(false, app.send("wrong project", { cwd = vim.uv.cwd() }))
  rawset(vim, "notify", original_notify)
  h.eq(request_count, #requests)

  app._reset()
  vim.fn.delete(directory, "rf")
  package.loaded["codex.app_server"] = nil
  package.loaded["codex.app_server.client"] = original_client
  package.loaded["codex.app_server.ui"] = original_ui
end)
