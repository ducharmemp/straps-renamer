-- Title prompt and reply cleanup.
-- Run: busted tests/title_spec.lua

dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua")

local title = require("straps_renamer.title")

describe("title.prompt", function()
  it("embeds the excerpt in the user turn and keeps the system text", function()
    local p = title.prompt("user: fix lexer.lua")
    assert.equals(title.SYSTEM, p.system)
    assert.is_not_nil(p.user:find("user: fix lexer.lua", 1, true))
    assert.is_not_nil(p.system:find("grep", 1, true))
  end)
end)

describe("title.clean", function()
  it("returns the first non-blank line, trimmed", function()
    assert.equals("fix lexer.lua tokenizer", title.clean("\n  fix lexer.lua tokenizer  \nsecond line"))
  end)

  it("strips a Title: prefix, surrounding quotes and a trailing period", function()
    assert.equals("rename parse_expr in parser.lua",
      title.clean('Title: "rename parse_expr in parser.lua."'))
    assert.equals("rename parse_expr", title.clean("`rename parse_expr`"))
    assert.equals("rename parse_expr", title.clean('"rename parse_expr".'))
    assert.equals("ends with v1.2", title.clean("ends with v1.2.."))
  end)

  it("collapses internal whitespace", function()
    assert.equals("a b c", title.clean("a   b\t c"))
  end)

  it("caps the length in characters, not bytes", function()
    local long = ("é"):rep(100)
    local out = title.clean(long, 10)
    assert.equals(10, vim.fn.strchars(out))
    assert.equals(("é"):rep(10), out)
  end)

  it("returns nil for empty, blank or non-string input, or a zero limit", function()
    assert.is_nil(title.clean(""))
    assert.is_nil(title.clean("   \n  "))
    assert.is_nil(title.clean('""'))
    assert.is_nil(title.clean(nil))
    assert.is_nil(title.clean(42))
    assert.is_nil(title.clean("fine title", 0))
  end)
end)
