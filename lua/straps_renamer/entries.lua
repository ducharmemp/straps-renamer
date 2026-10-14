-- Registry entries: the three judgement steps of a rename are late-bound fns
-- so a user can redefine any of them (:StrapsEdit fn.renamer_prompt) without
-- touching this plugin's code. define_default never clobbers a redefinition.

local M = {}

function M.register()
  local registry = require("straps.registry")
  local define = registry.define_default or registry.define

  define({
    name = "fn.renamer_excerpt",
    kind = "fn",
    doc = "Transcript excerpt the naming model reads. (bufnr, { max_bytes, tool_input_bytes }) -> string.",
    source = [[return function(bufnr, opts)
  return require("straps_renamer.excerpt").build(bufnr, opts)
end]],
  })
  define({
    name = "fn.renamer_prompt",
    kind = "fn",
    doc = "Prompt for the naming model. (excerpt) -> { system = string, user = string }.",
    source = [[return function(excerpt)
  return require("straps_renamer.title").prompt(excerpt)
end]],
  })
  define({
    name = "fn.renamer_clean",
    kind = "fn",
    doc = "Turn the model's raw reply into a one-line title, or nil. (raw, max_chars) -> string|nil.",
    source = [[return function(raw, max_chars)
  return require("straps_renamer.title").clean(raw, max_chars)
end]],
  })
end

return M
