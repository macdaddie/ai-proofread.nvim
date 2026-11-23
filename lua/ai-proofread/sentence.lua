local M = {}

local abbreviations = {
  ["dr."] = true,
  ["e.g."] = true,
  ["etc."] = true,
  ["fig."] = true,
  ["i.e."] = true,
  ["mr."] = true,
  ["mrs."] = true,
  ["ms."] = true,
  ["no."] = true,
  ["prof."] = true,
  ["vs."] = true,
}

local function trim_span(text, first, last)
  while first <= last and text:sub(first, first):match("%s") do
    first = first + 1
  end
  while last >= first and text:sub(last, last):match("%s") do
    last = last - 1
  end
  return first, last
end

function M.word_count(text)
  local count = 0
  for token in text:gmatch("%S+") do
    token = token:gsub("^[%p]+", ""):gsub("[%p]+$", "")
    if token ~= ""
      and not token:match("^[—–…]+$")
    then
      count = count + 1
    end
  end
  return count
end

function M.find(text)
  local sentences = {}
  local start_byte = 1
  local byte = 1

  local function add(end_byte)
    local first, last = trim_span(text, start_byte, end_byte)
    if first <= last then
      local value = text:sub(first, last)
      sentences[#sentences + 1] = {
        start_byte = first,
        end_byte = last,
        text = value,
        word_count = M.word_count(value),
      }
    end
    start_byte = end_byte + 1
  end

  while byte <= #text do
    local character = text:sub(byte, byte)
    if character == "." or character == "!" or character == "?" then
      local end_byte = byte
      while text:sub(end_byte + 1, end_byte + 1):match("[\"')%]]") do
        end_byte = end_byte + 1
      end
      local following = text:sub(end_byte + 1, end_byte + 1)
      local prefix = text:sub(start_byte, byte)
      local token = prefix:match("(%S+)$")
      local abbreviation = token and abbreviations[token:lower()]
      if not abbreviation and (following == "" or following:match("%s")) then
        add(end_byte)
        byte = end_byte
      end
    end
    byte = byte + 1
  end

  if start_byte <= #text then
    add(#text)
  end
  return sentences
end

local function overlaps(left_start, left_end, right)
  return left_start <= right.end_byte and left_end >= right.start_byte
end

function M.long_candidates(chunk, max_words)
  local candidates = {}
  for _, found in ipairs(M.find(chunk.review_text)) do
    if found.word_count > max_words then
      local source_start = chunk.offset_map[found.start_byte]
      local source_end = chunk.offset_map[found.end_byte]
      local protected = false
      for _, span in ipairs(chunk.protected_spans or {}) do
        if overlaps(source_start, source_end, span) then
          protected = true
          break
        end
      end
      if not protected then
        found.source_start_byte = source_start
        found.source_end_byte = source_end
        candidates[#candidates + 1] = found
      end
    end
  end
  return candidates
end

function M.valid_split(text, max_words)
  local sentences = M.find(text)
  if #sentences < 2 then
    return false
  end
  for _, found in ipairs(sentences) do
    if found.word_count == 0 or found.word_count > max_words then
      return false
    end
  end
  return true
end

function M.has_disallowed_control(text)
  for byte = 1, #text do
    local value = text:byte(byte)
    if (value < 32 and value ~= 9 and value ~= 10 and value ~= 13)
      or value == 127
    then
      return true
    end
  end
  return false
end

return M
