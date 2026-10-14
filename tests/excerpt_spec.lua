-- Excerpt tests: which transcript blocks reach the naming model and how the
-- excerpt is bounded. Hermetic: the session dir is a temp dir.
-- Run: busted tests/excerpt_spec.lua

dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua")

local straps = require("straps")
straps.config.session_dir = vim.fn.tempname()
local state = require("straps.state")
local excerpt = require("straps_renamer.excerpt")

local function session_with(blocks)
  local bufnr = state.new_session()
  for _, b in ipairs(blocks) do
    state.append(bufnr, b[1], b[2], b[3])
  end
  return bufnr
end

describe("excerpt.lines", function()
  it("keeps user and assistant text, tool names and inputs; drops system, results and notices", function()
    local bufnr = session_with({
      { "user", nil, "rename the parser in lexer.lua" },
      { "assistant", nil, "Reading lexer.lua first." },
      { "tool_use", { id = "t1", name = "read_file" }, vim.json.encode({ path = "lexer.lua" }) },
      { "tool_result", { id = "t1" }, "SECRET-RESULT-BODY" },
      { "user", nil, "[straps] a subagent finished (buffer 9)" },
      { "user", nil, "[straps] from agent child (buffer 9): peer says hi" },
      { "assistant", nil, "Done." },
    })
    local lines = excerpt.lines(bufnr)
    local joined = table.concat(lines, "\n")
    assert.equals("user: rename the parser in lexer.lua", lines[1])
    assert.equals("assistant: Reading lexer.lua first.", lines[2])
    assert.equals('tool read_file {"path":"lexer.lua"}', lines[3])
    assert.is_nil(joined:find("SECRET-RESULT-BODY", 1, true))
    assert.is_nil(joined:find("You are Cinch", 1, true))
    assert.is_nil(joined:find("subagent finished", 1, true))
    assert.is_not_nil(joined:find("peer says hi", 1, true))
    assert.equals("assistant: Done.", lines[#lines])
  end)

  it("truncates a long tool input to tool_input_bytes", function()
    local bufnr = session_with({
      { "user", nil, "go" },
      { "tool_use", { id = "t1", name = "write_file" }, vim.json.encode({ content = ("x"):rep(500) }) },
    })
    local lines = excerpt.lines(bufnr, { tool_input_bytes = 40 })
    assert.equals("tool write_file " .. ('{"content":"' .. ("x"):rep(500)):sub(1, 40) .. "...", lines[2])
  end)
end)

describe("excerpt.build", function()
  it("returns the whole text when it fits", function()
    local bufnr = session_with({ { "user", nil, "short prompt" } })
    assert.equals("user: short prompt", excerpt.build(bufnr, { max_bytes = 1000 }))
  end)

  it("keeps the head and the tail around a [...] marker when it does not fit", function()
    local bufnr = session_with({
      { "user", nil, "HEAD-MARKER " .. ("a"):rep(600) },
      { "assistant", nil, ("b"):rep(600) .. " TAIL-MARKER" },
    })
    local text = excerpt.build(bufnr, { max_bytes = 300 })
    assert.is_not_nil(text:find("^user: HEAD%-MARKER"))
    assert.is_not_nil(text:find("TAIL%-MARKER$"))
    assert.is_not_nil(text:find("\n[...]\n", 1, true))
    assert.is_true(#text <= 300 + #"\n[...]\n")
  end)

  it("clamps max_bytes to a usable minimum", function()
    local bufnr = session_with({ { "user", nil, ("x"):rep(500) } })
    for _, max_bytes in ipairs({ 0, -5, 1 }) do
      local text = excerpt.build(bufnr, { max_bytes = max_bytes })
      assert.is_not_nil(text:find("^user: x"))
      assert.is_not_nil(text:find("\n[...]\n", 1, true))
      assert.is_true(#text <= 64 + #"\n[...]\n")
    end
  end)

  it("cuts on UTF-8 boundaries", function()
    local bufnr = session_with({
      { "user", nil, ("é"):rep(200) },
      { "assistant", nil, ("ü"):rep(200) },
    })
    local function valid_utf8(s)
      local i = 1
      while i <= #s do
        local c = s:byte(i)
        local len = c < 0x80 and 1 or (c >= 0xC2 and c <= 0xDF) and 2 or (c >= 0xE0 and c <= 0xEF) and 3
          or (c >= 0xF0 and c <= 0xF4) and 4 or nil
        if not len then return false, i end
        for j = i + 1, i + len - 1 do
          local b = s:byte(j)
          if not b or b < 0x80 or b > 0xBF then return false, j end
        end
        i = i + len
      end
      return true
    end
    for _, max_bytes in ipairs({ 100, 101, 102, 103 }) do
      local text = excerpt.build(bufnr, { max_bytes = max_bytes })
      local ok, at = valid_utf8(text)
      assert.is_true(ok, ("max_bytes=%d: invalid UTF-8 at byte %s"):format(max_bytes, tostring(at)))
      assert.is_not_nil(text:find("\n[...]\n", 1, true))
      assert.is_true(#text <= max_bytes + #"\n[...]\n" + 3, ("max_bytes=%d: %d bytes"):format(max_bytes, #text))
    end
  end)
end)
