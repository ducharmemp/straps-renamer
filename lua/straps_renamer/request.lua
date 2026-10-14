-- One non-streaming POST to the active backend. Mirrors fn.provider's
-- backend selection (vim.b straps_provider, then config.provider, then the
-- persisted fn.provider_pref choice, then Anthropic) and reuses the straps
-- key fns, so the renamer needs no credentials of its own. Neither body
-- carries a thinking or reasoning field: the title is a one-shot reply.

local M = {}

function M.provider_for(bufnr)
  local registry = require("straps.registry")
  local ok_straps, straps = pcall(require, "straps")
  local config = (ok_straps and type(straps) == "table" and rawget(straps, "config")) or {}
  local provider
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local b = vim.b[bufnr].straps_provider
    if b and b ~= "" then
      provider = b
    end
  end
  if not provider and config.provider and config.provider ~= "" then
    provider = config.provider
  end
  if not provider then
    local ok, pref = pcall(registry.try_call, "fn.provider_pref")
    if ok and pref and pref ~= "" then
      provider = pref
    end
  end
  return provider or "anthropic"
end

local function straps_config()
  local ok_straps, straps = pcall(require, "straps")
  return (ok_straps and type(straps) == "table" and rawget(straps, "config")) or {}
end

local function anthropic(cfg, prompt)
  local config = straps_config()
  local body = {
    model = cfg.anthropic_model,
    max_tokens = cfg.anthropic_max_tokens,
    system = prompt.system,
    messages = { { role = "user", content = prompt.user } },
  }
  return {
    url = (config.base_url or "https://api.anthropic.com") .. "/v1/messages",
    headers = {
      "x-api-key: " .. require("straps.registry").call("fn.api_key"),
      "anthropic-version: 2023-06-01",
    },
    body = body,
    extract = function(decoded)
      for _, block in ipairs(type(decoded.content) == "table" and decoded.content or {}) do
        if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
          return block.text
        end
      end
      return nil, "no text block in the Anthropic response"
    end,
  }
end

local function openai(cfg, prompt)
  local config = straps_config()
  local registry = require("straps.registry")
  if not registry.get("fn.openai_api_key") then
    error("straps_renamer: the openai layer is disabled (setup{ layers = { openai = false } })")
  end
  local body = {
    model = cfg.openai_model,
    max_output_tokens = cfg.openai_max_output_tokens,
    instructions = prompt.system,
    input = prompt.user,
    store = false,
  }
  return {
    url = (config.openai_base_url or "https://api.openai.com") .. "/v1/responses",
    headers = { "Authorization: Bearer " .. registry.call("fn.openai_api_key") },
    body = body,
    extract = function(decoded)
      for _, item in ipairs(type(decoded.output) == "table" and decoded.output or {}) do
        if type(item) == "table" and item.type == "message" then
          for _, part in ipairs(type(item.content) == "table" and item.content or {}) do
            if type(part) == "table" and part.type == "output_text" and type(part.text) == "string" then
              return part.text
            end
          end
        end
      end
      if decoded.status == "incomplete" then
        local details = type(decoded.incomplete_details) == "table" and decoded.incomplete_details or {}
        return nil, "response incomplete (" .. tostring(details.reason or "no reason given")
          .. "); raise openai_max_output_tokens, or pick a non-reasoning openai_model"
      end
      return nil, "no output_text item in the OpenAI response"
    end,
  }
end

local function error_detail(body)
  local ok, decoded = pcall(vim.json.decode, body or "")
  if ok and type(decoded) == "table" and type(decoded.error) == "table" then
    return decoded.error.message or vim.json.encode(decoded.error)
  end
  if body and body ~= "" then
    return require("straps.state").utf8_cut(body, 400)
  end
  return "no response body"
end

--- Ask the backend for a title. cb(text, err) runs on the main loop with the
--- model's raw reply, or nil and an error string.
function M.send(provider, cfg, prompt, cb)
  if provider ~= "openai" and provider ~= "anthropic" then
    return cb(nil, "unknown provider " .. tostring(provider) .. " (expected anthropic or openai)")
  end
  local ok_spec, spec = pcall(provider == "openai" and openai or anthropic, cfg, prompt)
  if not ok_spec then
    return cb(nil, tostring(spec))
  end
  local payload = require("straps.state").utf8_scrub(vim.json.encode(spec.body))
  local argv = {
    "curl", "-sS", "--max-time", tostring(math.ceil((tonumber(cfg.timeout_ms) or 30000) / 1000)),
    "-X", "POST", spec.url,
    "-H", "content-type: application/json",
  }
  for _, h in ipairs(spec.headers) do
    vim.list_extend(argv, { "-H", h })
  end
  vim.list_extend(argv, { "-w", "%{stderr}\nSTRAPS_HTTP_STATUS:%{http_code}\n", "--data-binary", "@-" })
  local ok_spawn, err = pcall(vim.system, argv, { stdin = payload, text = true }, function(res)
    vim.schedule(function()
      local stderr = res.stderr or ""
      local status = tonumber(stderr:match("STRAPS_HTTP_STATUS:(%d+)"))
      if status == 0 then
        status = nil
      end
      local stdout = res.stdout or ""
      if status and (status < 200 or status >= 300) then
        return cb(nil, ("HTTP %d: %s"):format(status, error_detail(stdout)))
      end
      if res.code ~= 0 then
        return cb(nil, ("curl exited with code %d: %s"):format(res.code,
          vim.trim((stderr:gsub("%s*STRAPS_HTTP_STATUS:%d+%s*$", "")))))
      end
      if not status then
        return cb(nil, "no HTTP status from curl")
      end
      local ok_decode, decoded = pcall(vim.json.decode, stdout)
      if not ok_decode or type(decoded) ~= "table" then
        return cb(nil, "response is not JSON: " .. require("straps.state").utf8_cut(stdout, 200))
      end
      local text, extract_err = spec.extract(decoded)
      if not text then
        return cb(nil, extract_err)
      end
      return cb(text)
    end)
  end)
  if not ok_spawn then
    cb(nil, "curl could not be spawned: " .. tostring(err))
  end
end

return M
