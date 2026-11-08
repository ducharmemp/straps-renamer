package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local plugin = require('straps_renamer')

it('validates setup before registration or config changes', function()
  local before = vim.deepcopy(plugin.config)
  for _, opts in ipairs({ false, { typo = true }, { timeout_ms = 0 }, { auto = { enabled = 1 } }, { codex_model = '' } }) do
    assert.is_false(pcall(plugin.setup, opts))
    assert.same(before, plugin.config)
  end
end)

it('reports registered entries without requesting a title', function()
  local saved, health = package.loaded['straps.registry'], vim.health
  local reports = {}
  vim.health = setmetatable({}, { __index = function(_, key) return function(msg) reports[#reports + 1] = key .. ':' .. msg end end })
  package.loaded['straps.registry'] = { get = function(name) return name == 'fn.renamer_excerpt' and {} or nil end }
  require('straps_renamer.health').check()
  assert.is_truthy(table.concat(reports):find('ok:renamer request registered', 1, true))
  assert.same({}, plugin.status().inflight)
  package.loaded['straps.registry'], vim.health = saved, health
end)
