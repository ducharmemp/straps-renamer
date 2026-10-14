-- plugin/straps_renamer.lua: replace straps' :StrapsRename and install the
-- automatic-rename autocmds. Plugin files load in runtimepath order, so when
-- straps' plugin/straps.lua runs after this one it would win; the VimEnter
-- pass redefines the command after every startup plugin file has run, and
-- the SourcePost watch redefines it again when straps' plugin file is
-- sourced later (lazy loading). setup() also redefines it.

if vim.g.loaded_straps_renamer then
  return
end
vim.g.loaded_straps_renamer = true

local function define()
  require("straps_renamer").define_command()
end

define()
require("straps_renamer").enable_auto()
local group = vim.api.nvim_create_augroup("straps_renamer", { clear = true })
vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = define })
vim.api.nvim_create_autocmd("SourcePost", {
  group = group,
  pattern = "*/plugin/straps.lua",
  callback = define,
})
