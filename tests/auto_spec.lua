-- Automatic renames: driven by straps' StrapsRunStart / StrapsRunEnd User
-- autocmds. The events are fired by hand here (the loop fires the same
-- payloads, see straps doc/straps.txt *StrapsRunEnd*), and the model is a
-- fake `curl` whose reply counts how many times it was asked.
-- Run: busted tests/auto_spec.lua

local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua")

local function step(fn)
  local info = debug.getinfo(fn, "S")
  describe("step@" .. info.short_src .. ":" .. info.linedefined, function() setup(fn) end)
end

vim.env.ANTHROPIC_API_KEY = "test-anthropic-key"
local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
straps.config.provider = "anthropic"
straps.config.base_url = "http://renamer-fake.invalid"
local state = require("straps.state")

vim.g.loaded_straps = nil
vim.cmd("source " .. vim.fn.fnameescape(H.straps_root .. "/plugin/straps.lua"))
vim.g.loaded_straps_renamer = nil
vim.cmd("source " .. vim.fn.fnameescape(H.root .. "/plugin/straps_renamer.lua"))
local renamer = require("straps_renamer")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/ok", "p")
vim.fn.mkdir(tmp .. "/slow", "p")
local real_path = vim.env.PATH
H.write_exec(tmp .. "/ok/curl", ([[#!/usr/bin/env bash
D=%q
N=$(cat "$D/n" 2>/dev/null || echo 0); N=$((N+1)); echo $N > "$D/n"
cat > "$D/body.$N"
echo "STRAPS_HTTP_STATUS:200" >&2
printf '%%s' "{\"content\":[{\"type\":\"text\",\"text\":\"generated title $N\"}]}"
]]):format(tmp))
H.write_exec(tmp .. "/slow/curl", ([[#!/usr/bin/env bash
D=%q
N=$(cat "$D/n" 2>/dev/null || echo 0); N=$((N+1)); echo $N > "$D/n"
cat > /dev/null
sleep 1
echo "STRAPS_HTTP_STATUS:200" >&2
printf '%%s' "{\"content\":[{\"type\":\"text\",\"text\":\"generated title $N\"}]}"
]]):format(tmp))
vim.env.PATH = tmp .. "/ok:" .. real_path

local function calls()
  if vim.fn.filereadable(tmp .. "/n") == 0 then
    return 0
  end
  return tonumber(vim.fn.readfile(tmp .. "/n")[1]) or 0
end

local function fire(pattern, data)
  vim.api.nvim_exec_autocmds("User", { pattern = pattern, data = data })
end

local function wait_calls(n)
  vim.wait(10000, function() return calls() >= n end, 20)
  assert.equals(n, calls())
  vim.wait(10000, function() return #renamer.status().inflight == 0 end, 20)
  assert.equals(0, #renamer.status().inflight)
end

local function settle()
  assert.equals(0, #renamer.status().inflight, "a request is in flight: " .. vim.inspect(renamer.status().inflight))
  vim.wait(300, function() return false end, 20)
end

local function new_session(prompt)
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, prompt)
  state.append(bufnr, "assistant", nil, "Working on it.")
  return bufnr, vim.api.nvim_buf_get_name(bufnr)
end

local notices = {}
local real_notify = vim.notify
vim.notify = function(msg, level)
  notices[#notices + 1] = { msg = msg, level = level }
end

describe("plugin file", function()
  it("installs the autocmds without setup()", function()
    local cmds = vim.api.nvim_get_autocmds({ group = "straps_renamer_auto", event = "User" })
    local patterns = {}
    for _, a in ipairs(cmds) do patterns[a.pattern] = true end
    assert.is_true(patterns.StrapsRunStart)
    assert.is_true(patterns.StrapsRunEnd)
  end)
end)

describe("on_start", function()
  it("renames on the first StrapsRunStart only", function()
    local bufnr, path = new_session("fix the lexer")
    local before = calls()
    fire("StrapsRunStart", { bufnr = bufnr })
    wait_calls(before + 1)
    vim.wait(5000, function() return state.session_title(path) ~= nil end, 20)
    assert.equals("generated title " .. (before + 1), state.session_title(path))
    fire("StrapsRunEnd", { bufnr = bufnr, reason = "ok", turns = 2 })
    fire("StrapsRunStart", { bufnr = bufnr })
    settle()
    assert.equals(before + 1, calls())
  end)

  it("skips an empty transcript silently", function()
    local bufnr = state.new_session()
    local before, n = calls(), #notices
    fire("StrapsRunStart", { bufnr = bufnr })
    settle()
    assert.equals(before, calls())
    assert.equals(n, #notices)
  end)

  it("skips subagents by default and includes them with auto.subagents", function()
    local bufnr = new_session("child work")
    vim.b[bufnr].straps_parent = 1
    local before = calls()
    fire("StrapsRunStart", { bufnr = bufnr })
    settle()
    assert.equals(before, calls())
    renamer.config.auto.subagents = true
    local child2 = new_session("child work two")
    vim.b[child2].straps_parent = 1
    fire("StrapsRunStart", { bufnr = child2 })
    wait_calls(before + 1)
    renamer.config.auto.subagents = false
  end)
end)

describe("every_runs", function()
  it("renames on every Nth StrapsRunEnd", function()
    renamer.config.auto.on_start = false
    renamer.config.auto.every_runs = 2
    local bufnr = new_session("multi run")
    local before = calls()
    fire("StrapsRunEnd", { bufnr = bufnr, reason = "ok", turns = 1 })
    settle()
    assert.equals(before, calls())
    fire("StrapsRunEnd", { bufnr = bufnr, reason = "ok", turns = 1 })
    wait_calls(before + 1)
    fire("StrapsRunEnd", { bufnr = bufnr, reason = "ok", turns = 1 })
    settle()
    assert.equals(before + 1, calls())
    fire("StrapsRunEnd", { bufnr = bufnr, reason = "ok", turns = 1 })
    wait_calls(before + 2)
    assert.equals(4, vim.b[bufnr].straps_renamer_runs)
  end)

  it("counts but does not rename on a blank or crashed run; a cancelled run does rename", function()
    renamer.config.auto.every_runs = 1
    local bufnr = new_session("errors")
    local before = calls()
    fire("StrapsRunEnd", { bufnr = bufnr, reason = "blank", turns = 0 })
    fire("StrapsRunEnd", { bufnr = bufnr, reason = "error", turns = 1 })
    settle()
    assert.equals(before, calls())
    assert.equals(2, vim.b[bufnr].straps_renamer_runs)
    fire("StrapsRunEnd", { bufnr = bufnr, reason = "cancelled", turns = 1 })
    wait_calls(before + 1)
  end)

  it("every_runs = 0 disables the per-run rename", function()
    renamer.config.auto.every_runs = 0
    local bufnr = new_session("never")
    local before = calls()
    fire("StrapsRunEnd", { bufnr = bufnr, reason = "ok", turns = 1 })
    settle()
    assert.equals(before, calls())
  end)

  it("a fractional every_runs is floored", function()
    renamer.config.auto.every_runs = 2.5
    local bufnr = new_session("fraction")
    local before = calls()
    fire("StrapsRunEnd", { bufnr = bufnr, reason = "ok", turns = 1 })
    settle()
    assert.equals(before, calls())
    fire("StrapsRunEnd", { bufnr = bufnr, reason = "ok", turns = 1 })
    wait_calls(before + 1)
  end)

  it("an empty first prompt does not consume the on_start rename", function()
    renamer.config.auto.on_start = true
    local bufnr, path = state.new_session(), nil
    path = vim.api.nvim_buf_get_name(bufnr)
    local before = calls()
    fire("StrapsRunStart", { bufnr = bufnr })
    settle()
    assert.equals(before, calls())
    state.append(bufnr, "user", nil, "second attempt has text")
    fire("StrapsRunStart", { bufnr = bufnr })
    wait_calls(before + 1)
    vim.wait(5000, function() return state.session_title(path) ~= nil end, 20)
    assert.equals("generated title " .. (before + 1), state.session_title(path))
    renamer.config.auto.on_start = false
  end)

  step(function()
    renamer.config.auto.on_start = true
    renamer.config.auto.every_runs = 3
  end)
end)

describe("keep_manual", function()
  it("does not overwrite a title the user set by hand", function()
    local bufnr, path = new_session("manual wins")
    state.set_session_title(path, "my own title")
    local before = calls()
    fire("StrapsRunStart", { bufnr = bufnr })
    settle()
    assert.equals(before, calls())
    assert.equals("my own title", state.session_title(path))
    local ok, why = renamer.auto_wanted(bufnr)
    assert.is_false(ok)
    assert.equals("title was set by hand", why)
  end)

  it("marks generated titles in the .meta file so they survive a restart", function()
    local bufnr, path = new_session("durable mark")
    local before = calls()
    fire("StrapsRunStart", { bufnr = bufnr })
    wait_calls(before + 1)
    vim.wait(5000, function() return state.session_title(path) ~= nil end, 20)
    local meta = vim.json.decode(table.concat(vim.fn.readfile(path .. ".meta"), "\n"))
    assert.equals("generated title " .. (before + 1), meta.title)
    assert.equals("straps_renamer", meta.generated_by)
    local title, generated = renamer.title_of(path)
    assert.equals(meta.title, title)
    assert.is_true(generated)
    state.set_session_title(path, "typed by hand")
    local _, generated2 = renamer.title_of(path)
    assert.is_false(generated2)
    assert.equals("typed by hand", state.session_title(path))
  end)

  it("keeps a title set by hand while the model was replying", function()
    vim.env.PATH = tmp .. "/slow:" .. real_path
    local bufnr, path = new_session("race")
    local before = calls()
    local done, err
    renamer.rename(bufnr, function(_, e) done, err = true, e end)
    vim.wait(10000, function() return calls() >= before + 1 end, 20)
    state.set_session_title(path, "typed during request")
    vim.wait(10000, function() return done end, 20)
    vim.env.PATH = tmp .. "/ok:" .. real_path
    assert.equals("typed during request", state.session_title(path))
    assert.is_not_nil(err:find("title changed while the model was replying", 1, true), err)
  end)

  it("does overwrite a title it generated itself", function()
    renamer.config.auto.every_runs = 1
    local bufnr, path = new_session("regenerate")
    local before = calls()
    fire("StrapsRunStart", { bufnr = bufnr })
    wait_calls(before + 1)
    vim.wait(5000, function() return state.session_title(path) ~= nil end, 20)
    assert.equals("generated title " .. (before + 1), state.session_title(path))
    fire("StrapsRunEnd", { bufnr = bufnr, reason = "ok", turns = 1 })
    wait_calls(before + 2)
    vim.wait(5000, function() return state.session_title(path) == "generated title " .. (before + 2) end, 20)
    assert.equals("generated title " .. (before + 2), state.session_title(path))
    renamer.config.auto.every_runs = 3
  end)

  it("keep_manual = false overwrites a hand-set title", function()
    renamer.config.auto.keep_manual = false
    local bufnr, path = new_session("overwrite me")
    state.set_session_title(path, "hand title")
    local before = calls()
    fire("StrapsRunStart", { bufnr = bufnr })
    wait_calls(before + 1)
    vim.wait(5000, function() return state.session_title(path) ~= "hand title" end, 20)
    assert.equals("generated title " .. (before + 1), state.session_title(path))
    renamer.config.auto.keep_manual = true
  end)
end)

describe("enabled and notify", function()
  it("auto.enabled = false stops every automatic rename", function()
    renamer.config.auto.enabled = false
    local bufnr = new_session("off")
    local before = calls()
    fire("StrapsRunStart", { bufnr = bufnr })
    fire("StrapsRunEnd", { bufnr = bufnr, reason = "ok", turns = 1 })
    fire("StrapsRunEnd", { bufnr = bufnr, reason = "ok", turns = 1 })
    fire("StrapsRunEnd", { bufnr = bufnr, reason = "ok", turns = 1 })
    settle()
    assert.equals(before, calls())
    renamer.config.auto.enabled = true
  end)

  it("notifies at INFO by default and not at all with auto.notify = false", function()
    local bufnr, path = new_session("notify")
    local before = calls()
    fire("StrapsRunStart", { bufnr = bufnr })
    wait_calls(before + 1)
    vim.wait(5000, function() return state.session_title(path) ~= nil end, 20)
    local last = notices[#notices]
    assert.is_not_nil(last.msg:find("session titled generated title " .. (before + 1), 1, true))
    assert.equals(vim.log.levels.INFO, last.level)

    renamer.config.auto.notify = false
    local bufnr2, path2 = new_session("quiet")
    local n = #notices
    fire("StrapsRunStart", { bufnr = bufnr2 })
    wait_calls(before + 2)
    vim.wait(5000, function() return state.session_title(path2) ~= nil end, 20)
    assert.equals(n, #notices)
    renamer.config.auto.notify = true
  end)

  it("a failed automatic rename warns instead of erroring", function()
    vim.env.PATH = tmp .. "/missing"
    local bufnr = new_session("no curl")
    local n = #notices
    fire("StrapsRunStart", { bufnr = bufnr })
    vim.wait(5000, function() return #notices > n end, 20)
    vim.env.PATH = tmp .. "/ok:" .. real_path
    assert.equals(n + 1, #notices)
    assert.equals(vim.log.levels.WARN, notices[#notices].level)
    assert.is_not_nil(notices[#notices].msg:find("curl", 1, true), notices[#notices].msg)
  end)

  it("an error raised inside the handler is reported, not swallowed", function()
    local registry = require("straps.registry")
    local saved = registry.get("fn.renamer_excerpt")
    registry.define({ name = "fn.renamer_excerpt", kind = "fn", doc = "test: raise",
      source = [[return function() error("excerpt exploded") end]] })
    local bufnr = new_session("boom")
    local n = #notices
    fire("StrapsRunStart", { bufnr = bufnr })
    registry.define({ name = "fn.renamer_excerpt", kind = "fn", doc = saved.doc, source = saved.source })
    assert.equals(n + 1, #notices)
    assert.equals(vim.log.levels.WARN, notices[#notices].level)
    assert.is_not_nil(notices[#notices].msg:find("excerpt exploded", 1, true), notices[#notices].msg)
  end)
end)

step(function()
  vim.notify = real_notify
  vim.env.PATH = real_path
end)
