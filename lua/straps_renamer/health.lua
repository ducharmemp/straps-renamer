local M = {}

function M.check()
  vim.health.start("straps_renamer")
  local ok, registry = pcall(require, "straps.registry")
  if not ok then
    vim.health.error("Straps is missing from runtimepath")
    return
  end
  if registry.get("fn.renamer_excerpt") then vim.health.ok("renamer request registered")
  else vim.health.warn("renamer request is not registered; run setup()") end
  local status = require("straps_renamer").status()
  vim.health.info("automatic renaming enabled: " .. tostring(status.config.auto.enabled))
  vim.health.info("requests in progress: " .. #status.inflight)
  if vim.fn.executable("curl") == 1 then vim.health.ok("curl available")
  else vim.health.error("curl is required for title requests") end
end

return M
