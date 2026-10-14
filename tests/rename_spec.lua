-- Rename round-trip against fake `curl` binaries: the request shape sent to
-- each backend, the title written to the session's .meta file, the error
-- paths, and the :StrapsRename command's three modes.
-- Run: busted tests/rename_spec.lua

local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua")

-- Runs `fn` at test time, in document order with the surrounding `it`s.
local function step(fn)
  local info = debug.getinfo(fn, "S")
  describe("step@" .. info.short_src .. ":" .. info.linedefined, function() setup(fn) end)
end

vim.env.ANTHROPIC_API_KEY = "test-anthropic-key"
vim.env.OPENAI_API_KEY = "test-openai-key"
local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
straps.config.provider = "anthropic"
straps.config.base_url = "http://renamer-fake.invalid"
straps.config.openai_base_url = "http://renamer-fake-oai.invalid"
local state = require("straps.state")
local registry = require("straps.registry")

vim.g.loaded_straps = nil
vim.cmd("source " .. vim.fn.fnameescape(H.straps_root .. "/plugin/straps.lua"))
local renamer = require("straps_renamer").setup({ timeout_ms = 5000 })

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/ok", "p")
vim.fn.mkdir(tmp .. "/http500", "p")
vim.fn.mkdir(tmp .. "/refused", "p")
vim.fn.mkdir(tmp .. "/garbage", "p")
vim.fn.mkdir(tmp .. "/slow", "p")
local real_path = vim.env.PATH

H.write_exec(tmp .. "/ok/curl", ([[#!/usr/bin/env bash
D=%q
N=$(cat "$D/n" 2>/dev/null || echo 0); N=$((N+1)); echo $N > "$D/n"
printf '%%s\n' "$*" > "$D/argv.$N"
cat > "$D/body.$N"
echo "STRAPS_HTTP_STATUS:200" >&2
if grep -q 'trigger-incomplete' "$D/body.$N"; then
  printf '%%s' '{"id":"resp_2","object":"response","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"reasoning","id":"rs_2","summary":[]}]}'
elif grep -q '"input"' "$D/body.$N"; then
  printf '%%s' '{"id":"resp_1","object":"response","output":[{"type":"reasoning","id":"rs_1","summary":[]},{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"  \"openai title for lexer.lua rename.\"\n"}]}]}'
else
  printf '%%s' '{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Title: anthropic title for lexer.lua rename"}],"stop_reason":"end_turn"}'
fi
]]):format(tmp))

H.write_exec(tmp .. "/http500/curl", [[#!/usr/bin/env bash
cat > /dev/null
echo "STRAPS_HTTP_STATUS:500" >&2
printf '%s' '{"error":{"type":"api_error","message":"fake upstream failure"}}'
]])

H.write_exec(tmp .. "/refused/curl", [[#!/usr/bin/env bash
cat > /dev/null
echo "curl: (7) Failed to connect to renamer-fake.invalid port 80" >&2
echo "STRAPS_HTTP_STATUS:000" >&2
exit 7
]])

H.write_exec(tmp .. "/garbage/curl", [[#!/usr/bin/env bash
cat > /dev/null
echo "STRAPS_HTTP_STATUS:200" >&2
printf '%s' 'this is not json'
]])

H.write_exec(tmp .. "/slow/curl", [[#!/usr/bin/env bash
cat > /dev/null
sleep 2
echo "STRAPS_HTTP_STATUS:200" >&2
printf '%s' '{"content":[{"type":"text","text":"slow title"}]}'
]])

local function new_session(prompt)
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, prompt)
  state.append(bufnr, "assistant", nil, "Working on it.")
  return bufnr, vim.api.nvim_buf_get_name(bufnr)
end

local function rename_sync(bufnr)
  local done, title, err = false, nil, nil
  renamer.rename(bufnr, function(t, e)
    done, title, err = true, t, e
  end)
  vim.wait(10000, function() return done end, 20)
  assert(done, "rename callback never fired")
  return title, err
end

local function read_body(n)
  return vim.json.decode(table.concat(vim.fn.readfile(tmp .. "/body." .. n), "\n"))
end

local function read_argv(n)
  return vim.fn.readfile(tmp .. "/argv." .. n)[1]
end

local notices = {}
local real_notify = vim.notify
vim.notify = function(msg, level)
  notices[#notices + 1] = { msg = msg, level = level }
end

describe("renamer.rename over Anthropic", function()
  local bufnr, path
  step(function()
    vim.env.PATH = tmp .. "/ok:" .. real_path
    bufnr, path = new_session("rename the tokenizer in lexer.lua to scan")
  end)

  it("writes the cleaned title to the session .meta file", function()
    local title, err = rename_sync(bufnr)
    assert.is_nil(err)
    assert.equals("anthropic title for lexer.lua rename", title)
    assert.equals("anthropic title for lexer.lua rename", state.session_title(path))
    assert.equals("anthropic title for lexer.lua rename", state.session_summary(path))
  end)

  it("posts a non-streaming Messages request with the cheap model and the excerpt", function()
    local argv = read_argv(1)
    assert.is_not_nil(argv:find("http://renamer-fake.invalid/v1/messages", 1, true))
    assert.is_not_nil(argv:find("x-api-key: test-anthropic-key", 1, true))
    assert.is_not_nil(argv:find("anthropic-version: 2023-06-01", 1, true))
    local body = read_body(1)
    assert.equals("claude-haiku-4-5-20251001", body.model)
    assert.equals(200, body.max_tokens)
    assert.is_nil(body.stream)
    assert.is_nil(body.thinking)
    assert.is_nil(body.output_config)
    assert.equals(require("straps_renamer.title").SYSTEM, body.system)
    assert.equals(1, #body.messages)
    assert.equals("user", body.messages[1].role)
    assert.is_not_nil(body.messages[1].content:find("rename the tokenizer in lexer.lua to scan", 1, true))
    assert.is_not_nil(body.messages[1].content:find("assistant: Working on it.", 1, true))
    assert.is_nil(body.messages[1].content:find("You are Cinch", 1, true))
  end)

  it("notifies the new title", function()
    local found
    for _, n in ipairs(notices) do
      if n.msg:find("session titled anthropic title for lexer.lua rename", 1, true) then found = true end
    end
    assert.is_true(found == true)
  end)
end)

describe("renamer.rename over OpenAI", function()
  local bufnr, path
  step(function()
    vim.env.PATH = tmp .. "/ok:" .. real_path
    bufnr, path = new_session("port the build script to just")
    vim.b[bufnr].straps_provider = "openai"
  end)

  it("picks the per-buffer provider, posts to /v1/responses and stores the title", function()
    local title, err = rename_sync(bufnr)
    assert.is_nil(err)
    assert.equals("openai title for lexer.lua rename", title)
    assert.equals("openai title for lexer.lua rename", state.session_title(path))
    local argv = read_argv(2)
    assert.is_not_nil(argv:find("http://renamer-fake-oai.invalid/v1/responses", 1, true))
    assert.is_not_nil(argv:find("Authorization: Bearer test-openai-key", 1, true))
    local body = read_body(2)
    assert.equals("gpt-4.1-mini", body.model)
    assert.equals(200, body.max_output_tokens)
    assert.is_nil(body.reasoning)
    assert.equals(false, body.store)
    assert.is_nil(body.stream)
    assert.equals(require("straps_renamer.title").SYSTEM, body.instructions)
    assert.is_not_nil(body.input:find("port the build script to just", 1, true))
  end)

  step(function()
    vim.b[bufnr].straps_provider = nil
  end)
end)

describe("renamer.rename failure paths", function()
  it("reports an HTTP error with the server's message and leaves the title alone", function()
    vim.env.PATH = tmp .. "/http500:" .. real_path
    local bufnr, path = new_session("anything")
    local title, err = rename_sync(bufnr)
    assert.is_nil(title)
    assert.is_not_nil(err:find("HTTP 500", 1, true), err)
    assert.is_not_nil(err:find("fake upstream failure", 1, true), err)
    assert.is_nil(state.session_title(path))
  end)

  it("reports a curl failure with curl's own message", function()
    vim.env.PATH = tmp .. "/refused:" .. real_path
    local bufnr, path = new_session("anything")
    local title, err = rename_sync(bufnr)
    assert.is_nil(title)
    assert.is_not_nil(err:find("curl exited with code 7", 1, true), err)
    assert.is_not_nil(err:find("Failed to connect", 1, true), err)
    assert.is_nil(err:find("STRAPS_HTTP_STATUS", 1, true), err)
    assert.is_nil(state.session_title(path))
  end)

  it("reports a non-JSON body", function()
    vim.env.PATH = tmp .. "/garbage:" .. real_path
    local bufnr, path = new_session("anything")
    local title, err = rename_sync(bufnr)
    assert.is_nil(title)
    assert.is_not_nil(err:find("not JSON", 1, true), err)
    assert.is_nil(state.session_title(path))
  end)

  it("refuses an unsaved (ephemeral) buffer", function()
    local scratch = vim.api.nvim_create_buf(true, false)
    vim.b[scratch].straps_session = true
    local title, err = rename_sync(scratch)
    assert.is_nil(title)
    assert.is_not_nil(err:find("not a saved session", 1, true), err)
  end)

  it("refuses a transcript with no user or assistant text", function()
    vim.env.PATH = tmp .. "/ok:" .. real_path
    local bufnr = state.new_session()
    local title, err = rename_sync(bufnr)
    assert.is_nil(title)
    assert.is_not_nil(err:find("no user or assistant text", 1, true), err)
  end)

  it("refuses a second rename while one is in flight", function()
    vim.env.PATH = tmp .. "/slow:" .. real_path
    local bufnr, path = new_session("slow one")
    local first_done, first_title
    renamer.rename(bufnr, function(t) first_done, first_title = true, t end)
    local second_title, second_err = rename_sync(bufnr)
    assert.is_nil(second_title)
    assert.is_not_nil(second_err:find("already in progress", 1, true), second_err)
    vim.wait(10000, function() return first_done end, 20)
    assert.equals("slow title", first_title)
    assert.equals("slow title", state.session_title(path))
  end)

  it("reports an unknown provider", function()
    vim.env.PATH = tmp .. "/ok:" .. real_path
    local bufnr = new_session("whatever")
    vim.b[bufnr].straps_provider = "bogus"
    local title, err = rename_sync(bufnr)
    assert.is_nil(title)
    assert.is_not_nil(err:find("unknown provider bogus", 1, true), err)
  end)
end)

describe("provider_for", function()
  local request = require("straps_renamer.request")
  it("prefers vim.b, then config.provider, then fn.provider_pref, then anthropic", function()
    local bufnr = new_session("p")
    local saved_pref = registry.get("fn.provider_pref")
    local function pref(value)
      registry.define({ name = "fn.provider_pref", kind = "fn", doc = "test",
        source = ("return function() return %s end"):format(value and ("%q"):format(value) or "nil") })
    end
    pref("openai")
    straps.config.provider = "anthropic"
    vim.b[bufnr].straps_provider = "openai"
    assert.equals("openai", request.provider_for(bufnr))
    vim.b[bufnr].straps_provider = nil
    assert.equals("anthropic", request.provider_for(bufnr))
    straps.config.provider = nil
    assert.equals("openai", request.provider_for(bufnr))
    pref(nil)
    assert.equals("anthropic", request.provider_for(bufnr))
    registry.define({ name = "fn.provider_pref", kind = "fn", doc = saved_pref.doc, source = saved_pref.source })
    straps.config.provider = "anthropic"
  end)
end)

describe("OpenAI incomplete response", function()
  it("names the truncation reason instead of a missing text item", function()
    vim.env.PATH = tmp .. "/ok:" .. real_path
    local bufnr = new_session("trigger-incomplete")
    vim.b[bufnr].straps_provider = "openai"
    local title, err = rename_sync(bufnr)
    assert.is_nil(title)
    assert.is_not_nil(err:find("response incomplete (max_output_tokens)", 1, true), err)
    assert.is_not_nil(err:find("openai_max_output_tokens", 1, true), err)
  end)
end)

describe("timeout_ms", function()
  it("falls back to 30 seconds for a non-numeric value and still fires the callback", function()
    vim.env.PATH = tmp .. "/ok:" .. real_path
    local saved = renamer.config.timeout_ms
    renamer.config.timeout_ms = false
    local bufnr = new_session("bad timeout")
    local title, err = rename_sync(bufnr)
    renamer.config.timeout_ms = saved
    assert.is_nil(err)
    assert.equals("anthropic title for lexer.lua rename", title)
    local n = vim.fn.readfile(tmp .. "/n")[1]
    assert.is_not_nil(read_argv(tonumber(n)):find("--max-time 30 ", 1, true))
    assert.equals(0, #renamer.status().inflight)
  end)
end)

describe(":StrapsRename", function()
  step(function()
    vim.env.PATH = tmp .. "/ok:" .. real_path
  end)

  it("is the renamer's command, with bang support", function()
    local cmd = vim.api.nvim_get_commands({})["StrapsRename"]
    assert.is_not_nil(cmd)
    assert.is_true(cmd.bang)
    assert.is_not_nil(cmd.definition:find("cheap model", 1, true))
  end)

  it("with an argument sets the title directly without calling the model", function()
    local bufnr, path = new_session("manual")
    local before = vim.fn.readfile(tmp .. "/n")[1]
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("StrapsRename hand written title")
    assert.equals("hand written title", state.session_title(path))
    assert.equals(before, vim.fn.readfile(tmp .. "/n")[1])
  end)

  it("with a bang opens the manual prompt pre-filled with the current title", function()
    local bufnr, path = new_session("manual")
    state.set_session_title(path, "old title")
    local seen_default
    local real_input = vim.ui.input
    vim.ui.input = function(opts, cb)
      seen_default = opts.default
      cb("from prompt")
    end
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("StrapsRename!")
    vim.ui.input = real_input
    assert.equals("old title", seen_default)
    assert.equals("from prompt", state.session_title(path))
  end)

  it("with no argument asks the model and stores the title", function()
    local bufnr, path = new_session("auto")
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("StrapsRename")
    vim.wait(10000, function() return state.session_title(path) ~= nil end, 20)
    assert.equals("anthropic title for lexer.lua rename", state.session_title(path))
  end)

  it("errors on a non-session buffer", function()
    local plain = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(plain)
    local n = #notices
    vim.cmd("StrapsRename")
    assert.equals(n + 1, #notices)
    assert.is_not_nil(notices[#notices].msg:find("run :StrapsRename on a session buffer", 1, true))
    assert.equals(vim.log.levels.ERROR, notices[#notices].level)
  end)
end)

step(function()
  vim.notify = real_notify
  vim.env.PATH = real_path
end)
