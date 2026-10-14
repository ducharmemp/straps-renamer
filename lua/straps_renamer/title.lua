-- Prompt text sent to the naming model and the cleanup applied to its reply.

local M = {}

M.SYSTEM = table.concat({
  "You name transcripts of a coding agent so that a person can find them later with grep.",
  "Reply with one line only: a title of 4 to 12 words.",
  "Name the concrete subject: file names, function names, commands, error strings, the part of the repository touched.",
  "Keep identifiers exactly as written. Use lowercase for ordinary words.",
  "No quotes, no trailing period, no preamble, no explanation.",
}, " ")

function M.prompt(excerpt)
  return {
    system = M.SYSTEM,
    user = "Transcript excerpt:\n\n" .. excerpt .. "\n\nTitle:",
  }
end

function M.clean(raw, max_chars)
  if type(raw) ~= "string" then
    return nil
  end
  local line
  for _, candidate in ipairs(vim.split(raw, "\n", { plain = true })) do
    if candidate:match("%S") then
      line = candidate
      break
    end
  end
  if not line then
    return nil
  end
  line = vim.trim(line)
  line = line:gsub("^[Tt]itle:%s*", "")
  line = line:gsub("%.$", "")
  line = line:gsub("^[\"'`]+", ""):gsub("[\"'`]+$", "")
  line = line:gsub("%.$", "")
  line = line:gsub("%s+", " ")
  line = vim.trim(line)
  if line == "" then
    return nil
  end
  local limit = max_chars or 80
  if limit <= 0 then
    return nil
  end
  if vim.fn.strchars(line) > limit then
    line = vim.trim(vim.fn.strcharpart(line, 0, limit))
  end
  return line
end

return M
