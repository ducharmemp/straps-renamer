dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua")

local straps = require("straps").setup({ layers = { editor = false } })
local registry = require("straps.registry")
local request = require("straps_renamer.request")
local oauth = require("straps.oauth")
local state = require("straps.state")
local checked, counterfactuals = 0, 0
local mutate = vim.env.STRAPS_AUTH_COUNTERFACTUAL == "1"

local function equal(expected, actual)
  assert.are.same(expected, actual)
  checked = checked + 1
  if mutate then
    local ok = pcall(assert.are.same, { synthetic_counterfactual_operand = checked }, actual)
    assert.is_false(ok, "counterfactual operand survived assertion " .. checked)
    counterfactuals = counterfactuals + 1
  end
end

local function contains(fragment, text)
  equal(true, type(text) == "string" and text:find(fragment, 1, true) ~= nil)
end

local function response(text)
  return { output = { { type = "message", content = { { type = "output_text", text = text } } } } }
end

local function event(kind, value)
  value = value or {}
  value.type = kind
  return "data: " .. vim.json.encode(value) .. "\n\n"
end

local function terminal(text, kind)
  return event(kind or "response.completed", { response = response(text) })
end

local function credential(kind, expires)
  local value = { access = "synthetic-" .. kind, refresh = "synthetic-refresh", expires = expires or oauth.now_ms() + 3600000,
    client_id = "synthetic-client", account_id = "synthetic-account" }
  registry.call("fn.openai_" .. kind .. "_credential", value)
  return value
end

local function jwt(account)
  return "e30." .. vim.base64.encode(vim.json.encode({ [oauth.JWT_AUTH_CLAIM] = { chatgpt_account_id = account } }))
    :gsub("=+$", ""):gsub("+", "-"):gsub("/", "_") .. ".synthetic"
end

local real_system, real_notify = vim.system, vim.notify
local calls, replies, held, buffers, before_reply
local cfg
local function result(body, status)
  return { code = 0, stdout = type(body) == "table" and vim.json.encode(body) or body,
    stderr = "STRAPS_HTTP_STATUS:" .. (status or 200) }
end

local function header(call, name)
  for i, arg in ipairs(call.argv) do
    if arg == "-H" and call.argv[i + 1]:lower():sub(1, #name + 2) == name:lower() .. ": " then
      return call.argv[i + 1]:sub(#name + 3)
    end
  end
end

local function session()
  local buf = vim.api.nvim_create_buf(true, false)
  buffers[#buffers + 1] = buf
  return buf
end

local function send(provider, buf)
  local out = { count = 0 }
  request.send(provider or "openai", cfg, { system = "synthetic instructions", user = "synthetic prompt" }, function(text, err)
    out.count, out.text, out.err = out.count + 1, text, err
  end, buf)
  equal(true, vim.wait(2000, function() return out.count > 0 end, 5))
  return out
end

describe("renamer synthetic authentication", function()
  before_each(function()
    vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
    vim.fn.mkdir(vim.env.XDG_CONFIG_HOME, "p")
    vim.env.ANTHROPIC_API_KEY = "synthetic-anthropic-env"
    vim.env.OPENAI_API_KEY = "synthetic-openai-env"
    vim.env.LLAMACPP_API_KEY, vim.env.LLAMA_API_KEY = nil, nil
    straps.config.base_url, straps.config.openai_base_url, straps.config.llamacpp_base_url = nil, nil, nil
    straps.config.provider, straps.config.openai_model, straps.config.llamacpp_model = nil, nil, nil
    cfg = { anthropic_model = "synthetic-haiku", anthropic_max_tokens = 200, openai_model = "synthetic-mini",
      openai_max_output_tokens = 201, timeout_ms = 1000 }
    calls, replies, held, buffers, before_reply = {}, {}, {}, {}, nil
    vim.notify = function() end
    vim.system = function(argv, opts, cb)
      calls[#calls + 1] = { argv = argv, stdin = opts.stdin }
      local reply = table.remove(replies, 1)
      if before_reply then before_reply(#calls) end
      if reply == false then
        held[#held + 1] = cb
      else
        cb(reply or result(response("synthetic title")))
      end
      return { kill = function() end }
    end
  end)

  after_each(function()
    vim.system, vim.notify = real_system, real_notify
    for _, buf in ipairs(buffers) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    vim.fn.delete(vim.env.XDG_CONFIG_HOME, "rf")
  end)

  teardown(function()
    print(("auth assertions checked=%d counterfactuals rejected=%d enabled=%s"):format(checked, counterfactuals, tostring(mutate)))
  end)

  it("uses the Anthropic slot without the removed alias and prefers a stored key", function()
    equal(nil, registry.get("fn.api_key"))
    registry.call("fn.api_key_store", "anthropic", "synthetic-anthropic-stored")
    replies[1] = result({ content = { { type = "text", text = "anthropic title" } } })
    local out = send("anthropic")
    equal("anthropic title", out.text)
    equal("synthetic-anthropic-stored", header(calls[1], "x-api-key"))
    equal("https://api.anthropic.com/v1/messages", calls[1].argv[7])
    local body = vim.json.decode(calls[1].stdin)
    equal("synthetic-haiku", body.model)
    equal(200, body.max_tokens)
    equal("2023-06-01", header(calls[1], "anthropic-version"))
    registry.call("fn.api_key_store", "anthropic", false)
    replies[1] = result({ content = { { type = "text", text = "env title" } } })
    send("anthropic")
    equal("synthetic-anthropic-env", header(calls[2], "x-api-key"))
  end)

  it("trims environment keys and prefers stored OpenAI keys", function()
    vim.env.OPENAI_API_KEY = "  synthetic-env-trimmed  \n"
    send()
    equal("Bearer synthetic-env-trimmed", header(calls[1], "authorization"))
    registry.call("fn.api_key_store", "openai", "synthetic-stored")
    send()
    equal("Bearer synthetic-stored", header(calls[2], "authorization"))
    local body = vim.json.decode(calls[2].stdin)
    equal("synthetic-mini", body.model)
    equal(201, body.max_output_tokens)
    equal(false, body.store)
    equal("synthetic prompt", body.input)
  end)

  it("uses OAuth ahead of Codex, stored keys and environment on the Responses route", function()
    registry.call("fn.api_key_store", "openai", "synthetic-stored")
    credential("codex")
    credential("oauth")
    local out = send()
    equal("synthetic title", out.text)
    equal("https://api.openai.com/v1/responses", calls[1].argv[7])
    equal("Bearer synthetic-oauth", header(calls[1], "authorization"))
    equal(nil, header(calls[1], "chatgpt-account-id"))
    local body = vim.json.decode(calls[1].stdin)
    equal("synthetic-mini", body.model)
    equal("synthetic instructions", body.instructions)
    equal(201, body.max_output_tokens)
  end)

  it("uses the Codex transformer, inherited or overridden model and buffer identity", function()
    credential("codex")
    local buf, other = session(), session()
    vim.b[buf].straps_openai_model = "synthetic-session-model"
    vim.api.nvim_set_current_buf(other)
    replies[1] = result(terminal("codex title"))
    local out = send("openai", buf)
    equal("codex title", out.text)
    equal("https://chatgpt.com/backend-api/codex/responses", calls[1].argv[7])
    equal("Bearer synthetic-codex", header(calls[1], "authorization"))
    equal("synthetic-account", header(calls[1], "chatgpt-account-id"))
    equal("text/event-stream", header(calls[1], "accept"))
    local body = vim.json.decode(calls[1].stdin)
    equal("synthetic-session-model", body.model)
    equal(nil, body.max_output_tokens)
    equal(true, body.stream)
    equal(false, body.store)
    equal({ { role = "user", content = "synthetic prompt" } }, body.input)
    equal({ verbosity = "low" }, body.text)
    equal({ "reasoning.encrypted_content" }, body.include)
    equal("auto", body.tool_choice)
    equal(true, body.parallel_tool_calls)
    equal(state.codex_session_id(buf), body.prompt_cache_key)
    equal(body.prompt_cache_key, header(calls[1], "session-id"))
    equal(body.prompt_cache_key, header(calls[1], "x-client-request-id"))
    equal(false, body.prompt_cache_key == state.codex_session_id(other))
    cfg.codex_model = "synthetic-override"
    replies[1] = result(terminal("override"))
    send("openai", buf)
    equal("synthetic-override", vim.json.decode(calls[2].stdin).model)
  end)

  for _, kind in ipairs({ "oauth", "codex" }) do
    it("protects custom origins for " .. kind .. " without spawning", function()
      credential(kind)
      straps.config.openai_base_url = "https://synthetic.invalid/v1"
      local out = send()
      equal(nil, out.text)
      contains("only", out.err)
      equal(0, #calls)
    end)

    it("refreshes " .. kind .. " before sending an expired token", function()
      credential(kind, 0)
      local token = { access_token = kind == "codex" and jwt("fresh-account") or "synthetic-fresh-oauth",
        refresh_token = "synthetic-fresh-refresh", expires_in = 3600, scope = oauth.DIRECT_TOKEN_SCOPE }
      replies[1] = { code = 0, stdout = vim.json.encode(token) .. "\nSTRAPS_HTTP_STATUS:200\n", stderr = "" }
      replies[2] = result(kind == "codex" and terminal("fresh title") or response("fresh title"))
      local out = send()
      equal("fresh title", out.text)
      equal(2, #calls)
      contains("grant_type=refresh_token", calls[1].stdin)
      equal("Bearer " .. token.access_token, header(calls[2], "authorization"))
      if kind == "codex" then equal("fresh-account", header(calls[2], "chatgpt-account-id")) end
    end)

    it("retries " .. kind .. " 401 once with refreshed credentials", function()
      credential(kind)
      local token = { access_token = kind == "codex" and jwt("retry-account") or "synthetic-retry-oauth",
        refresh_token = "synthetic-fresh-refresh", expires_in = 3600, scope = oauth.DIRECT_TOKEN_SCOPE }
      replies[1] = result({ error = { message = "expired" } }, 401)
      replies[2] = { code = 0, stdout = vim.json.encode(token) .. "\nSTRAPS_HTTP_STATUS:200\n", stderr = "" }
      replies[3] = result({ error = { message = "still rejected" } }, 401)
      local out = send()
      equal(nil, out.text)
      contains("HTTP 401: still rejected", out.err)
      equal(3, #calls)
      equal("Bearer " .. token.access_token, header(calls[3], "authorization"))
      if kind == "codex" then equal("retry-account", header(calls[3], "chatgpt-account-id")) end
      equal(1, out.count)
    end)

    it("reports " .. kind .. " refresh failure without retrying the request", function()
      credential(kind)
      replies[1] = result({}, 401)
      replies[2] = { code = 0, stdout = '{"error":"synthetic refresh failure"}\nSTRAPS_HTTP_STATUS:400\n', stderr = "" }
      local out = send()
      equal(nil, out.text)
      contains("refresh failed", out.err)
      equal(2, #calls)
      equal(1, out.count)
    end)
  end

  for _, key in ipairs({ "bad key", "bad\nkey", "badékey", "   " }) do
    it("refuses invalid key " .. vim.inspect(key) .. " before spawning", function()
      vim.env.OPENAI_API_KEY = key
      local out = send()
      equal(nil, out.text)
      contains("key", out.err)
      equal(0, #calls)
    end)
  end

  for _, kind in ipairs({ "oauth", "codex" }) do
    it("pins the validated origin while refreshing " .. kind, function()
      credential(kind, 0)
      local token = { access_token = kind == "codex" and jwt("pinned-account") or "synthetic-pinned-oauth",
        refresh_token = "synthetic-refresh", expires_in = 3600, scope = oauth.DIRECT_TOKEN_SCOPE }
      replies[1] = { code = 0, stdout = vim.json.encode(token) .. "\nSTRAPS_HTTP_STATUS:200\n", stderr = "" }
      replies[2] = result(kind == "codex" and terminal("pinned") or response("pinned"))
      before_reply = function(n)
        if n == 1 then straps.config.openai_base_url = "https://synthetic-attacker.invalid" end
      end
      local out = send()
      equal("pinned", out.text)
      equal(kind == "codex" and "https://chatgpt.com/backend-api/codex/responses" or "https://api.openai.com/v1/responses",
        calls[2].argv[7])
      equal(2, #calls)
    end)
  end

  it("permits an explicit API key on a custom origin", function()
    straps.config.openai_base_url = "https://synthetic.invalid/v1/"
    send()
    equal("https://synthetic.invalid/v1/responses", calls[1].argv[7])
    equal("Bearer synthetic-openai-env", header(calls[1], "authorization"))
  end)

  it("reports invalid providers and invalid URLs through the callback", function()
    local out = send("synthetic-unknown")
    contains("unknown provider", out.err)
    equal(1, out.count)
    straps.config.openai_base_url = "not-a-url"
    out = send()
    contains("must start with", out.err)
    equal(0, #calls)
  end)

  it("returns provider preference errors instead of falling back", function()
    local original = registry.try_call
    registry.try_call = function(name, ...)
      if name == "fn.provider_pref" then return nil, "synthetic preference read failure" end
      return original(name, ...)
    end
    local ok, provider, err = pcall(request.provider_for, session())
    registry.try_call = original
    equal(true, ok)
    equal(nil, provider)
    equal("synthetic preference read failure", err)
  end)

  it("supports llama without a key and uses the resolved server model", function()
    local buf = session()
    vim.b[buf].straps_llamacpp_model = "synthetic-server-model"
    replies[1] = result({ content = { { type = "text", text = "local title" } } })
    local out = send("llamacpp", buf)
    equal("local title", out.text)
    equal(nil, header(calls[1], "authorization"))
    equal("http://127.0.0.1:8080/v1/messages", calls[1].argv[7])
    equal("synthetic-server-model", vim.json.decode(calls[1].stdin).model)
    vim.env.LLAMA_API_KEY = "synthetic-llama-key"
    replies[1] = result({ content = { { type = "text", text = "keyed" } } })
    send("llamacpp", buf)
    equal("Bearer synthetic-llama-key", header(calls[2], "authorization"))
  end)

  it("refuses llama without a resolved model before spawning", function()
    local out = send("llamacpp", session())
    equal(nil, out.text)
    contains("no model configured", out.err)
    equal(0, #calls)
  end)

  local streams = {
    { "completed terminal output", terminal("terminal"), "terminal" },
    { "done terminal output", terminal("done", "response.done"), "done" },
    { "terminal overrides delta", event("response.output_text.delta", { delta = "old" }) .. terminal("final"), "final" },
    { "delta fallback", event("response.output_text.delta", { delta = "delta " })
      .. event("response.output_text.delta", { delta = "title" }) .. event("response.done", { response = {} }), "delta title" },
    { "ignores trailing events", terminal("finished") .. "data: broken\n\n" .. event("error"), "finished" },
    { "error", event("error"), nil, "Codex response failed" },
    { "failed", event("response.failed"), nil, "Codex response failed" },
    { "incomplete", event("response.done", { response = { status = "incomplete" } }), nil, "response incomplete" },
    { "incomplete event", event("response.incomplete", { response = { status = "incomplete" } }), nil, "response incomplete" },
    { "failed terminal", event("response.done", { response = { status = "failed", error = { message = "denied" } } }),
      nil, "response failed: denied" },
    { "malformed JSON", "data: {broken\n\n", nil, "malformed Codex event" },
    { "malformed delta", event("response.output_text.delta", { delta = 42 }), nil, "malformed Codex text delta" },
    { "malformed terminal", event("response.done"), nil, "malformed Codex terminal response" },
    { "missing terminal", event("response.output_text.delta", { delta = "unfinished" }), nil, "without a terminal" },
    { "terminal missing text", event("response.done", { response = {} }), nil, "no output_text" },
  }
  for _, case in ipairs(streams) do
    it("parses Codex " .. case[1], function()
      credential("codex")
      replies[1] = result(case[2])
      local out = send()
      equal(case[3], out.text)
      if case[4] then contains(case[4], out.err) else equal(nil, out.err) end
      equal(1, out.count)
    end)
  end

  for _, provider in ipairs({ "openai", "llamacpp" }) do
    it("reports model preference errors for " .. provider .. " before spawning", function()
      if provider == "openai" then credential("codex") end
      local dir = oauth.config_dir()
      vim.fn.mkdir(dir, "p")
      vim.fn.writefile({ "malformed synthetic model preference" }, dir .. "/model_" .. provider)
      local out = send(provider, session())
      equal(nil, out.text)
      contains("not a JSON object", out.err)
      equal(0, #calls)
    end)
  end

  it("reports provider resolver errors through rename's callback", function()
    local renamer = require("straps_renamer").setup({ auto = { enabled = false } })
    straps.config.session_dir = vim.fn.tempname()
    local buf = state.new_session()
    buffers[#buffers + 1] = buf
    state.append(buf, "user", nil, "synthetic rename prompt")
    local original = registry.try_call
    registry.try_call = function(name, ...)
      if name == "fn.provider_pref" then return nil, "synthetic callback preference error" end
      return original(name, ...)
    end
    local count, text, err = 0
    local ok, sent = pcall(renamer.rename, buf, function(t, e) count, text, err = count + 1, t, e end,
      { quiet = "silent" })
    registry.try_call = original
    equal(true, ok)
    equal(false, sent)
    equal(1, count)
    equal(nil, text)
    contains("synthetic callback preference error", err)
    equal(0, #calls)
    vim.fn.delete(straps.config.session_dir, "rf")
  end)

  it("reports a disabled OpenAI layer without spawning", function()
    local original = registry.get
    registry.get = function(name, ...)
      if name == "fn.openai_api_key" then return nil end
      return original(name, ...)
    end
    local ok, out = pcall(send)
    registry.get = original
    equal(true, ok)
    contains("layer is disabled", out.err)
    equal(0, #calls)
  end)

  it("times out and ignores a late transport callback", function()
    cfg.timeout_ms = 15
    replies[1] = false
    local out = send()
    equal(nil, out.text)
    equal("request timed out", out.err)
    equal(1, #held)
    held[1](result(response("late title")))
    vim.wait(30, function() return false end, 5)
    equal(1, out.count)
    equal(nil, out.text)
  end)
end)
