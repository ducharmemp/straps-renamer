-- The part of a transcript the naming model sees: user and assistant text
-- plus tool names and their inputs, bounded in bytes. System prompts, tool
-- results and harness notices carry no title-worthy detail and are skipped.

local M = {}

local function compact_json(value, limit)
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok or type(encoded) ~= "string" then
    return ""
  end
  if #encoded > limit then
    return require("straps.state").utf8_cut(encoded, limit) .. "..."
  end
  return encoded
end

local function text_of(block)
  if type(block) == "string" then
    return block
  end
  if type(block) == "table" and type(block.text) == "string" then
    return block.text
  end
  return nil
end

function M.lines(bufnr, opts)
  local state = require("straps.state")
  local input_limit = (opts and opts.tool_input_bytes) or 160
  local parsed = state.parse(bufnr)
  local out = {}
  for _, message in ipairs(parsed.messages or {}) do
    for _, block in ipairs(type(message.content) == "table" and message.content or { message.content }) do
      local kind = type(block) == "table" and block.type or "text"
      if kind == "text" then
        local text = text_of(block)
        if text and text:match("%S") then
          local notice = state.notice_of(text)
          if not (notice and notice.from == "harness") then
            out[#out + 1] = message.role .. ": " .. vim.trim(text)
          end
        end
      elseif kind == "tool_use" then
        out[#out + 1] = "tool " .. tostring(block.name) .. " " .. compact_json(block.input, input_limit)
      end
    end
  end
  return out
end

function M.build(bufnr, opts)
  local max_bytes = math.max(64, (opts and opts.max_bytes) or 12000)
  local text = table.concat(M.lines(bufnr, opts), "\n")
  if #text <= max_bytes then
    return text
  end
  local utf8_cut = require("straps.state").utf8_cut
  local head_bytes = math.floor(max_bytes * 2 / 3)
  local tail_bytes = max_bytes - head_bytes
  local head = utf8_cut(text, head_bytes)
  local tail_start = #text - tail_bytes + 1
  tail_start = tail_start + vim.str_utf_start(text, tail_start)
  local tail = text:sub(tail_start)
  return head .. "\n[...]\n" .. tail
end

return M
