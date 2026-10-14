-- Shared test bootstrap: puts this plugin and a straps checkout on the
-- runtimepath. STRAPS_ROOT names the checkout; ../straps is the default.
-- Returns { root, straps_root, write_exec }. busted's describe/setup are
-- injected into each spec chunk's environment, not into chunks loaded with
-- dofile, so the step() sequencer is defined in the spec file.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
local straps_root = vim.env.STRAPS_ROOT
if not straps_root or straps_root == "" then
  straps_root = vim.fn.fnamemodify(root .. "/../straps", ":p"):gsub("/$", "")
end
assert(vim.fn.isdirectory(straps_root .. "/lua/straps") == 1,
  "no straps checkout at " .. straps_root .. " (set STRAPS_ROOT)")

vim.opt.rtp:prepend(straps_root)
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;"
  .. straps_root .. "/lua/?.lua;" .. straps_root .. "/lua/?/init.lua;" .. package.path

local function write_exec(path, text)
  text = text:gsub("^#!/usr/bin/env bash", "#!" .. vim.fn.exepath("bash"), 1)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
  vim.fn.setfperm(path, "rwxr-xr-x")
end

return { root = root, straps_root = straps_root, write_exec = write_exec }
