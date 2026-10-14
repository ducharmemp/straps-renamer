-- straps-renamer: :StrapsRename with no argument asks a cheap model for a
-- grep-friendly title and stores it as the session's durable title (the
-- same .meta file straps' own :StrapsRename {title} writes). The same
-- rename runs automatically on a session's first run and every few runs.

local M = {}

M.config = {
  anthropic_model = "claude-haiku-4-5-20251001",
  anthropic_max_tokens = 200,
  openai_model = "gpt-4.1-mini",
  openai_max_output_tokens = 200,
  max_excerpt_bytes = 12000,
  tool_input_bytes = 160,
  max_title_chars = 80,
  timeout_ms = 30000,
  auto = {
    enabled = true,
    on_start = true,
    every_runs = 3,
    subagents = false,
    keep_manual = true,
    notify = true,
  },
}

local registered = false
local inflight = {}

local GENERATED_BY = "straps_renamer"

local function ensure_entries()
  if registered then
    return
  end
  require("straps_renamer.entries").register()
  registered = true
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  ensure_entries()
  M.define_command()
  M.enable_auto()
  return M
end

local function session_path(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if vim.bo[bufnr].buftype ~= "" or not path:match("%.straps$") or vim.fn.filereadable(path) == 0 then
    return nil
  end
  return path
end

local function refresh_views()
  pcall(function()
    require("straps.agents").refresh()
  end)
end

--- The session's durable title and whether this plugin wrote it. Reads the
--- companion .meta file straps keeps; straps' own writers store { title }
--- only, so a title without the generated_by field was set by hand.
function M.title_of(path)
  local meta = path .. ".meta"
  if vim.fn.filereadable(meta) == 0 then
    return nil, false
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(meta), "\n"))
  if not ok or type(decoded) ~= "table" or type(decoded.title) ~= "string" or decoded.title == "" then
    return nil, false
  end
  return decoded.title, decoded.generated_by == GENERATED_BY
end

local function write_generated_title(path, title)
  local ok = pcall(vim.fn.writefile,
    { vim.json.encode({ title = title, generated_by = GENERATED_BY }) }, path .. ".meta")
  return ok and require("straps.state").session_title(path) == title
end

--- Generate and store a title for the session in bufnr. cb(title, err) is
--- optional; the result is also reported through vim.notify. Returns true
--- when a request was sent, false when the rename was refused before
--- sending. opts.quiet (automatic renames) lowers the notices: success to
--- INFO or nothing when opts.quiet == "silent", failures to WARN, an empty
--- transcript to nothing.
function M.rename(bufnr, cb, opts)
  ensure_entries()
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  cb = cb or function() end
  opts = opts or {}
  local function fail(msg, level)
    if level ~= "silent" then
      vim.notify("straps_renamer: " .. msg, level or vim.log.levels.ERROR)
    end
    cb(nil, msg)
    return false
  end
  local failure_level = opts.quiet and vim.log.levels.WARN or nil
  local path = session_path(bufnr)
  if not path then
    return fail("buffer " .. tostring(bufnr) .. " is not a saved session; nothing to rename", failure_level)
  end
  if inflight[bufnr] then
    return fail("a rename is already in progress for this session", failure_level)
  end
  local registry = require("straps.registry")
  local cfg = M.config
  local excerpt = registry.call("fn.renamer_excerpt", bufnr,
    { max_bytes = cfg.max_excerpt_bytes, tool_input_bytes = cfg.tool_input_bytes })
  if not excerpt or not excerpt:match("%S") then
    return fail("the transcript has no user or assistant text yet", opts.quiet and "silent" or nil)
  end
  local prompt = registry.call("fn.renamer_prompt", excerpt)
  local request = require("straps_renamer.request")
  local provider = request.provider_for(bufnr)
  local title_at_send = M.title_of(path)
  inflight[bufnr] = true
  local ok_send, send_err = pcall(request.send, provider, cfg, prompt, function(raw, err)
    inflight[bufnr] = nil
    if not raw then
      return fail(provider .. ": " .. tostring(err), failure_level)
    end
    local title = registry.call("fn.renamer_clean", raw, cfg.max_title_chars)
    if not title then
      return fail(provider .. " returned no usable title: " .. vim.inspect(raw), failure_level)
    end
    if M.title_of(path) ~= title_at_send then
      return fail("the title changed while the model was replying; keeping " .. vim.inspect(M.title_of(path)),
        failure_level)
    end
    if not write_generated_title(path, title) then
      return fail("could not write the session title for " .. path, failure_level)
    end
    refresh_views()
    if opts.quiet ~= "silent" then
      vim.notify("straps_renamer: session titled " .. title, opts.quiet and vim.log.levels.INFO or nil)
    end
    cb(title)
  end)
  if not ok_send then
    inflight[bufnr] = nil
    return fail("could not start the request: " .. tostring(send_err), failure_level)
  end
  return true
end

--- Whether an automatic rename should run for bufnr right now. Returns
--- true, or false and the reason it was skipped.
function M.auto_wanted(bufnr)
  local auto = M.config.auto or {}
  if not auto.enabled then
    return false, "disabled"
  end
  if not session_path(bufnr) then
    return false, "not a saved session"
  end
  if not auto.subagents and vim.b[bufnr].straps_parent ~= nil then
    return false, "subagent"
  end
  if auto.keep_manual then
    local current, generated = M.title_of(session_path(bufnr))
    if current ~= nil and not generated then
      return false, "title was set by hand"
    end
  end
  return true
end

local function auto_rename(bufnr, why)
  local ok, reason = M.auto_wanted(bufnr)
  if not ok then
    return false, reason
  end
  if not M.rename(bufnr, nil, { quiet = M.config.auto.notify and true or "silent" }) then
    return false, "rename refused"
  end
  return true, why
end

local function on_run_start(bufnr)
  if vim.b[bufnr].straps_renamer_started or not M.config.auto.on_start then
    return false, "not the first run"
  end
  local ok, why = auto_rename(bufnr, "first run started")
  if ok then
    vim.b[bufnr].straps_renamer_started = true
  end
  return ok, why
end

local function on_run_end(bufnr, reason)
  local runs = (tonumber(vim.b[bufnr].straps_renamer_runs) or 0) + 1
  vim.b[bufnr].straps_renamer_runs = runs
  if reason == "blank" or reason == "error" then
    return false, "run ended with " .. reason
  end
  local every = math.floor(tonumber(M.config.auto.every_runs) or 0)
  if every ~= every or every <= 0 or runs % every ~= 0 then
    return false, ("run %d is not a multiple of every_runs=%s"):format(runs, tostring(every))
  end
  return auto_rename(bufnr, ("run %d ended"):format(runs))
end

local function guarded(handler)
  return function(args)
    local bufnr = type(args.data) == "table" and args.data.bufnr
    if not bufnr then
      return
    end
    local ok, err = pcall(handler, bufnr, args.data.reason)
    if not ok then
      vim.notify("straps_renamer: automatic rename failed: " .. tostring(err), vim.log.levels.WARN)
    end
  end
end

--- Install the StrapsRunStart / StrapsRunEnd autocmds that drive automatic
--- renames. Idempotent; config.auto is read at event time, so a later
--- setup() changes behaviour without reinstalling.
function M.enable_auto()
  local group = vim.api.nvim_create_augroup("straps_renamer_auto", { clear = true })
  vim.api.nvim_create_autocmd("User", { group = group, pattern = "StrapsRunStart", callback = guarded(on_run_start) })
  vim.api.nvim_create_autocmd("User", { group = group, pattern = "StrapsRunEnd", callback = guarded(on_run_end) })
end

M._on_run_start = on_run_start
M._on_run_end = on_run_end

--- :StrapsRename            generate a title with the cheap model
--- :StrapsRename {title}    set the title directly (straps' own behaviour)
--- :StrapsRename!           open straps' manual prompt, pre-filled
function M.define_command()
  vim.api.nvim_create_user_command("StrapsRename", function(opts)
    local ui = require("straps.ui")
    local target = ui.resolve_session(vim.api.nvim_get_current_buf())
    if not target then
      vim.notify("straps: run :StrapsRename on a session buffer", vim.log.levels.ERROR)
      return
    end
    if opts.args ~= "" then
      return ui.rename_session(target, opts.args)
    end
    if opts.bang then
      return ui.rename_session(target, nil)
    end
    M.rename(target)
  end, {
    nargs = "?",
    bang = true,
    desc = "straps: title this session (no arg = ask a cheap model; ! = manual prompt; arg = set directly)",
  })
end

function M.status()
  return { entries = registered, inflight = vim.tbl_keys(inflight), config = M.config }
end

return M
