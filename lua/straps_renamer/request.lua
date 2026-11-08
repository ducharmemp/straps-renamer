local M = {}

local function straps_config()
  return require("straps").config or {}
end

function M.provider_for(bufnr)
  local provider, _, err = require("straps.provider").resolve_provider(bufnr, straps_config())
  return provider, err
end

local function response_text(decoded)
  if decoded.status == "incomplete" then
    local details = type(decoded.incomplete_details) == "table" and decoded.incomplete_details or {}
    return nil, "response incomplete (" .. tostring(details.reason or "no reason given")
      .. "); raise openai_max_output_tokens, or pick a non-reasoning openai_model"
  end
  if decoded.status == "failed" then
    return nil, "response failed: " .. tostring(type(decoded.error) == "table" and decoded.error.message or "no reason given")
  end
  local texts = {}
  for _, item in ipairs(type(decoded.output) == "table" and decoded.output or {}) do
    if type(item) == "table" and item.type == "message" then
      for _, part in ipairs(type(item.content) == "table" and item.content or {}) do
        if type(part) == "table" and part.type == "output_text" and type(part.text) == "string" then
          texts[#texts + 1] = part.text
        end
      end
    end
  end
  if #texts > 0 then return table.concat(texts) end
  return nil, "no output_text item in the OpenAI response"
end

local function stream_text(raw)
  local deltas = {}
  for frame in (raw:gsub("\r\n", "\n") .. "\n\n"):gmatch("(.-)\n\n") do
    local data = {}
    for line in frame:gmatch("[^\n]+") do
      local value = line:match("^data:%s?(.*)$")
      if value then data[#data + 1] = value end
    end
    if #data > 0 then
      local ok, event = pcall(vim.json.decode, table.concat(data, "\n"))
      if not ok or type(event) ~= "table" then return nil, "malformed Codex event" end
      if event.type == "response.output_text.delta" then
        if type(event.delta) ~= "string" then return nil, "malformed Codex text delta" end
        deltas[#deltas + 1] = event.delta
      elseif event.type == "response.completed" or event.type == "response.done" then
        if type(event.response) ~= "table" then return nil, "malformed Codex terminal response" end
        local text, err = response_text(event.response)
        if event.response.status == "incomplete" or event.response.status == "failed" then return nil, err end
        if text then return text end
        if #deltas > 0 then return table.concat(deltas) end
        return nil, err
      elseif event.type == "response.incomplete" then
        local response = type(event.response) == "table" and event.response or {}
        response.status = "incomplete"
        return response_text(response)
      elseif event.type == "error" or event.type == "response.failed" then
        return nil, "Codex response failed"
      end
    end
  end
  return nil, "Codex stream ended without a terminal response"
end

local function specification(provider, cfg, prompt, ctx, key, source, account, base)
  local providers = require("straps.provider")
  local registry = require("straps.registry")
  local config = straps_config()
  local headers = providers.auth_headers(provider, key)
  if provider == "openai" then
    local body = { model = cfg.openai_model, max_output_tokens = cfg.openai_max_output_tokens,
      instructions = prompt.system, input = prompt.user, store = false }
    local url = base .. "/v1/responses"
    if source == "codex" then
      local model, model_err = cfg.codex_model, nil
      if model == nil then model, model_err = providers.resolve_model("openai", ctx.bufnr, config) end
      if model_err then error(model_err, 0) end
      if type(model) ~= "string" or model == "" then error("no model configured for codex", 0) end
      body.model = model
      body.input = { { role = "user", content = prompt.user } }
      ctx.codex_entry = providers.model_entry("openai", body.model, config)
      local extra
      url, extra = registry.call("fn.openai_codex_request", body, ctx, account)
      vim.list_extend(headers, extra)
    end
    return { url = url, headers = headers, body = body, stream = source == "codex", extract = response_text }
  end
  local model, model_err = cfg.anthropic_model, nil
  if provider == "llamacpp" then model, model_err = providers.resolve_model(provider, ctx.bufnr, config) end
  if model_err then error(model_err, 0) end
  if type(model) ~= "string" or model == "" then error("no model configured for " .. provider, 0) end
  vim.list_extend(headers, { "-H", "anthropic-version: 2023-06-01" })
  return {
    url = base .. "/v1/messages", headers = headers,
    body = { model = model, max_tokens = cfg.anthropic_max_tokens, system = prompt.system,
      messages = { { role = "user", content = prompt.user } } },
    extract = function(decoded)
      for _, block in ipairs(type(decoded.content) == "table" and decoded.content or {}) do
        if type(block) == "table" and block.type == "text" and type(block.text) == "string" then return block.text end
      end
      return nil, "no text block in the Anthropic response"
    end,
  }
end

local function error_detail(body)
  local ok, decoded = pcall(vim.json.decode, body or "")
  if ok and type(decoded) == "table" and type(decoded.error) == "table" then
    return decoded.error.message or vim.json.encode(decoded.error)
  end
  if body and body ~= "" then return require("straps.state").utf8_cut(body, 400) end
  return "no response body"
end

function M.send(provider, cfg, prompt, cb, bufnr)
  local providers = require("straps.provider")
  if not providers.is_provider(provider) then return cb(nil, providers.unknown_provider_error(provider)) end
  local timeout = tonumber(cfg.timeout_ms) or 30000
  if timeout <= 0 or timeout ~= timeout or timeout == math.huge then timeout = 30000 end
  local thread, finished
  local function finish(text, err)
    if finished then return end
    finished = true
    cb(text, err)
  end
  local function resume(...)
    if finished then return end
    local ok, err = coroutine.resume(thread, ...)
    if not ok then finish(nil, tostring(err)) end
  end
  local ctx = { bufnr = bufnr, cancelled = function() return false end }
  ctx.await = function(start)
    local settled, timer = false, vim.uv.new_timer()
    local function resolve(...)
      if settled then return end
      settled = true
      timer:stop()
      timer:close()
      local args = { n = select("#", ...), ... }
      vim.schedule(function() resume(unpack(args, 1, args.n)) end)
    end
    timer:start(timeout, 0, function() resolve(nil, "request timed out") end)
    local ok, err = pcall(start, resolve)
    if not ok then resolve(nil, tostring(err)) end
    return coroutine.yield()
  end
  thread = coroutine.create(function()
    local registry = require("straps.registry")
    local slot = providers.provider_slot(provider)
    if not registry.get(slot.key_fn) then error("the " .. provider .. " layer is disabled", 0) end
    local base, base_err = providers.base_url(provider, straps_config())
    if not base then error(base_err, 0) end
    local key, source, account = registry.call(slot.key_fn, { ctx = ctx, base_url = base })
    for attempt = 1, 2 do
      local spec = specification(provider, cfg, prompt, ctx, key, source, account, base)
      local argv = { "curl", "-sS", "--max-time", tostring(math.ceil(timeout / 1000)),
        "-X", "POST", spec.url, "-H", "content-type: application/json" }
      vim.list_extend(argv, spec.headers)
      vim.list_extend(argv, { "-w", "%{stderr}\nSTRAPS_HTTP_STATUS:%{http_code}\n", "--data-binary", "@-" })
      local res, request_err = ctx.await(function(resolve)
        vim.system(argv, { stdin = require("straps.state").utf8_scrub(vim.json.encode(spec.body)), text = true },
          function(result) resolve(result) end)
      end)
      if not res then return finish(nil, request_err) end
      local stderr, stdout = res.stderr or "", res.stdout or ""
      local status = tonumber(stderr:match("STRAPS_HTTP_STATUS:(%d+)"))
      if status == 401 and attempt == 1 and provider == "openai" and (source == "oauth" or source == "codex") then
        local cred, refresh_err = ctx.await(function(resolve)
          registry.call(source == "codex" and "fn.openai_codex_refresh" or "fn.openai_oauth_refresh",
            { rejected_access = key }, resolve)
        end)
        if not cred then return finish(nil, refresh_err or "token refresh failed") end
        key, account = cred.access, cred.account_id
      else
        if status and status ~= 0 and (status < 200 or status >= 300) then
          return finish(nil, ("HTTP %d: %s"):format(status, error_detail(stdout)))
        end
        if res.code ~= 0 then
          return finish(nil, ("curl exited with code %d: %s"):format(res.code,
            vim.trim((stderr:gsub("%s*STRAPS_HTTP_STATUS:%d+%s*$", "")))))
        end
        if not status or status == 0 then return finish(nil, "no HTTP status from curl") end
        if spec.stream then return finish(stream_text(stdout)) end
        local ok, decoded = pcall(vim.json.decode, stdout)
        if not ok or type(decoded) ~= "table" then
          return finish(nil, "response is not JSON: " .. require("straps.state").utf8_cut(stdout, 200))
        end
        return finish(spec.extract(decoded))
      end
    end
  end)
  resume()
end

return M
