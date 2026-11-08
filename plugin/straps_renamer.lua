-- plugin/straps_renamer.lua: define :StrapsRenameAuto and install the
-- automatic-rename autocmds. straps' own :StrapsRename is left untouched.

if vim.g.loaded_straps_renamer then
  return
end
vim.g.loaded_straps_renamer = true

require("straps_renamer").define_command()
require("straps_renamer").enable_auto()
