local h = require("tests.harness")

local function with_app(callback)
  local modules = { "codex.app_server", "codex.app_server.init", "codex.app_server.client", "codex.app_server.ui" }
  local originals = {}
  for _, name in ipairs(modules) do
    originals[name] = package.loaded[name]
    package.loaded[name] = nil
  end
  local original_select, original_input = vim.ui.select, vim.ui.input
  local responses, prompts, requests = {}, {}, {}
  local fake_client = {
    start = function(opts)
      opts.on_ready()
      return true
    end,
    request = function(method, params, done)
      table.insert(requests, { method = method, params = params })
      if method == "thread/start" then
        done({ thread = { id = "thread" } })
      elseif method == "thread/list" then
        done({ data = { { id = "native" } }, nextCursor = "next" })
      end
      return true
    end,
    set_notification_handler = function() end,
    set_server_request_handler = function() end,
    stop = function()
      return true
    end,
    respond = function(id, result, err)
      table.insert(responses, { id = id, result = result, error = err })
    end,
  }
  package.loaded["codex.app_server.client"] = fake_client
  package.loaded["codex.app_server.ui"] = {
    open = function()
      return true
    end,
    append = function() end,
    reset = function() end,
  }
  rawset(vim.ui, "select", function(items, _, done)
    table.insert(prompts, function()
      done(items[1])
    end)
  end)
  rawset(vim.ui, "input", function(_, done)
    table.insert(prompts, function()
      done("answer")
    end)
  end)
  require("codex.config").setup({ cwd = "nvim" })
  local app = require("codex.app_server")
  local ok, err = pcall(function()
    h.truthy(app.open())
    app._handle_notification("turn/started", { threadId = "thread", turn = { id = "turn" } })
    callback(app, responses, prompts, requests, fake_client)
  end)
  app.stop()
  rawset(vim.ui, "select", original_select)
  rawset(vim.ui, "input", original_input)
  for _, name in ipairs(modules) do
    package.loaded[name] = originals[name]
  end
  require("codex.config").setup({})
  if not ok then
    error(err, 0)
  end
end

h.test("thread listing includes native sessions and returns a page cursor", function()
  with_app(function(app, _, _, requests, fake_client)
    local threads, cursor, failure
    h.truthy(app.list_threads(function(data, err, next_cursor)
      threads, failure, cursor = data, err, next_cursor
    end, false, "previous"))
    local params = requests[#requests].params
    h.eq({ "cli", "vscode", "appServer" }, params.sourceKinds)
    h.eq("previous", params.cursor)
    h.eq(vim.uv.cwd(), params.cwd)
    h.eq("native", threads[1].id)
    h.eq("next", cursor)
    h.eq(nil, failure)
    app.list_threads(function() end, true)
    h.eq(nil, requests[#requests].params.cwd)
    fake_client.request = function()
      return false
    end
    app.list_threads(function(_, err)
      failure = err
    end)
    h.truthy(failure)
  end)
end)

for _, method in ipairs({
  "item/commandExecution/requestApproval",
  "item/fileChange/requestApproval",
  "item/permissions/requestApproval",
  "mcpServer/elicitation/request",
  "item/tool/requestUserInput",
}) do
  h.test(method .. " ignores answers after server resolution", function()
    with_app(function(app, responses, prompts)
      app._handle_server_request(method, {
        threadId = "thread",
        turnId = "turn",
        permissions = {},
        questions = { { id = "q1", question = "First?" }, { id = "q2", question = "Second?" } },
      }, "request")
      h.eq(1, #prompts)
      app._handle_notification("serverRequest/resolved", { threadId = "thread", requestId = "request" })
      prompts[1]()
      h.eq(0, #responses)
      h.eq(1, #prompts)
    end)
  end)
end

h.test("request callbacks cannot approve a replacement process with the same request ID", function()
  with_app(function(app, responses, prompts)
    local params = { threadId = "thread", turnId = "turn" }
    app._handle_server_request("item/commandExecution/requestApproval", params, 1)
    app.stop()
    app.open()
    app._handle_notification("turn/started", { threadId = "thread", turn = { id = "turn" } })
    app._handle_server_request("item/commandExecution/requestApproval", params, 1)
    prompts[1]()
    h.eq(0, #responses)
    prompts[2]()
    h.eq(1, #responses)
    h.eq("accept", responses[1].result.decision)
    prompts[2]()
    h.eq(1, #responses)
  end)
end)

h.test("isBlocking supersedes the deprecated user input timeout", function()
  with_app(function(app, responses, prompts)
    app._handle_server_request("item/tool/requestUserInput", {
      threadId = "thread",
      turnId = "turn",
      isBlocking = false,
      autoResolutionMs = 1,
      questions = { { id = "q", question = "Continue?" } },
    }, 1)
    vim.wait(30, function()
      return #responses > 0
    end, 5)
    h.eq(0, #responses)
    prompts[1]()
    h.eq({ "answer" }, responses[1].result.answers.q.answers)
  end)
end)

h.test("legacy input timeout stops the remaining questions", function()
  with_app(function(app, responses, prompts)
    app._handle_server_request("item/tool/requestUserInput", {
      threadId = "thread",
      turnId = "turn",
      autoResolutionMs = 1,
      questions = { { id = "q1", question = "First?" }, { id = "q2", question = "Second?" } },
    }, 1)
    h.truthy(vim.wait(1000, function()
      return #responses == 1
    end, 5))
    prompts[1]()
    h.eq(1, #prompts)
    h.eq(1, #responses)
  end)
end)

for _, ending in ipairs({ "completed", "exit" }) do
  h.test("pending approvals are invalidated on " .. ending, function()
    with_app(function(app, responses, prompts)
      app._handle_server_request("item/commandExecution/requestApproval", {
        threadId = "thread",
        turnId = "turn",
      }, 1)
      if ending == "exit" then
        app._handle_client_exit(1)
      else
        app._handle_notification("turn/completed", {
          threadId = "thread",
          turn = { id = "turn", status = "completed" },
        })
      end
      prompts[1]()
      h.eq(0, #responses)
    end)
  end)
end

h.test("resolution notifications are scoped by thread and cancel legacy timers", function()
  with_app(function(app, responses, prompts)
    app._handle_server_request("item/tool/requestUserInput", {
      threadId = "thread",
      turnId = "turn",
      autoResolutionMs = 10,
      questions = { { id = "q", question = "Continue?" } },
    }, 1)
    app._handle_notification("serverRequest/resolved", { threadId = "another", requestId = 1 })
    prompts[1]()
    h.eq(1, #responses)
    app._handle_server_request("item/tool/requestUserInput", {
      threadId = "thread",
      turnId = "turn",
      autoResolutionMs = 10,
      questions = { { id = "q", question = "Continue?" } },
    }, 2)
    app._handle_notification("serverRequest/resolved", { threadId = "thread", requestId = 2 })
    vim.wait(30, function()
      return #responses > 1
    end, 5)
    h.eq(1, #responses)
    prompts[2]()
    h.eq(1, #responses)
  end)
end)
