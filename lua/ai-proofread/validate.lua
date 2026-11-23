local locator = require("ai-proofread.locator")
local limits = require("ai-proofread.limits")
local sentence = require("ai-proofread.sentence")

local M = {}

M.RejectionReason = {
  SCHEMA_INVALID = "schema_invalid",
  NOT_EXACT = "not_exact",
  NOT_UNIQUE = "not_unique",
  PROTECTED = "protected",
  UNSUPPORTED_CATEGORY = "unsupported_category",
  TYPE_MISMATCH = "type_mismatch",
  NO_CHANGE = "no_change",
  STALE = "stale",
  BELOW_LONG_SENTENCE_LIMIT = "below_long_sentence_limit",
  DISABLED_CATEGORY = "disabled_category",
  SUPERSEDED_BY_LONG_SENTENCE = "superseded_by_long_sentence",
  NOT_LONG_SENTENCE_CANDIDATE = "not_long_sentence_candidate",
  INVALID_LONG_SENTENCE_REWRITE = "invalid_long_sentence_rewrite",
}

local categories = {
  spelling = "correction",
  grammar = "correction",
  punctuation = "correction",
  long_sentence = "rewrite",
}

local required_fields = {
  type = true,
  category = true,
  original = true,
  suggestion = true,
  message = true,
}

local function line_and_column(text, absolute_byte)
  local line = 1
  local line_start = 1

  for byte = 1, absolute_byte - 1 do
    if text:sub(byte, byte) == "\n" then
      line = line + 1
      line_start = byte + 1
    end
  end

  return line, absolute_byte - line_start + 1
end

local function overlaps(span_start, span_end, protected)
  return span_start <= protected.end_byte
    and span_end >= protected.start_byte
end

function M.validate_schema(finding)
  if type(finding) ~= "table" then
    return false
  end

  for field in pairs(required_fields) do
    if type(finding[field]) ~= "string" or finding[field] == "" then
      return false
    end
  end

  for field in pairs(finding) do
    if not required_fields[field] then
      return false
    end
  end

  if finding.type ~= "correction" and finding.type ~= "rewrite" then
    return false
  end
  if #finding.original > limits.max_original_bytes
    or #finding.suggestion > limits.max_suggestion_bytes
    or #finding.message > limits.max_message_bytes
    or sentence.has_disallowed_control(finding.original)
    or sentence.has_disallowed_control(finding.suggestion)
    or sentence.has_disallowed_control(finding.message)
  then
    return false
  end

  return true
end

function M.validate_finding(finding, chunk, options)
  if not M.validate_schema(finding) then
    return nil, M.RejectionReason.SCHEMA_INVALID
  end

  local expected_type = categories[finding.category]
  if not expected_type then
    return nil, M.RejectionReason.UNSUPPORTED_CATEGORY
  end
  if finding.type ~= expected_type then
    return nil, M.RejectionReason.TYPE_MISMATCH
  end
  if options
    and options.checks
    and options.checks[finding.category] == false
  then
    return nil, M.RejectionReason.DISABLED_CATEGORY
  end

  local match = locator.find(chunk.review_text, finding.original)
  if match.status ~= "exact" then
    return nil, match.status
  end

  if chunk.target_start_byte
    and (match.start_byte < chunk.target_start_byte
      or match.end_byte > chunk.target_end_byte)
  then
    return nil, M.RejectionReason.NOT_EXACT
  end

  local source_start = chunk.offset_map[match.start_byte]
  local source_end = chunk.offset_map[match.end_byte]
  if not source_start or not source_end then
    return nil, M.RejectionReason.NOT_EXACT
  end

  for _, protected in ipairs(chunk.protected_spans or {}) do
    if overlaps(source_start, source_end, protected) then
      return nil, M.RejectionReason.PROTECTED
    end
  end

  local line, column = line_and_column(
    chunk.document_text,
    source_start
  )
  local end_line, end_column = line_and_column(
    chunk.document_text,
    source_end
  )
  local source_text = chunk.document_text:sub(source_start, source_end)
  if finding.suggestion == finding.original
    or finding.suggestion == source_text
  then
    return nil, M.RejectionReason.NO_CHANGE
  end
  if finding.category == "long_sentence" then
    local configured = options
      and options.long_sentence
      and options.long_sentence.max_words
    local max_words = configured or 30
    if sentence.word_count(source_text) <= max_words then
      return nil, M.RejectionReason.BELOW_LONG_SENTENCE_LIMIT
    end
    local candidates = chunk.long_sentence_candidates
      or sentence.long_candidates(chunk, max_words)
    local candidate_match = false
    for _, candidate in ipairs(candidates) do
      if candidate.source_start_byte == source_start
        and candidate.source_end_byte == source_end
      then
        candidate_match = true
        break
      end
    end
    if not candidate_match then
      return nil, M.RejectionReason.NOT_LONG_SENTENCE_CANDIDATE
    end
    if not sentence.valid_split(finding.suggestion, max_words)
      or #finding.suggestion > math.max(#source_text * 2, 1024)
    then
      return nil, M.RejectionReason.INVALID_LONG_SENTENCE_REWRITE
    end
  end

  return {
    line = line,
    column = column,
    end_line = end_line,
    end_column = end_column,
    source_start_byte = source_start,
    source_end_byte = source_end,
    source_text = source_text,
    severity = "warning",
    type = finding.type,
    category = finding.category,
    original = finding.original,
    suggestion = finding.suggestion,
    message = finding.message,
  }
end

function M.validate_findings(findings, chunk, options)
  local result = { valid = {}, rejected = {} }
  for _, finding in ipairs(findings) do
    local valid, reason = M.validate_finding(finding, chunk, options)
    if valid then
      result.valid[#result.valid + 1] = valid
    else
      result.rejected[#result.rejected + 1] = {
        finding = finding,
        reason = reason,
      }
    end
  end

  local rewrites = {}
  for _, finding in ipairs(result.valid) do
    if finding.category == "long_sentence" then
      rewrites[#rewrites + 1] = finding
    end
  end

  if #rewrites > 0 then
    local retained = {}
    for _, finding in ipairs(result.valid) do
      local superseded = false
      if finding.category ~= "long_sentence" then
        for _, rewrite in ipairs(rewrites) do
          if finding.source_start_byte >= rewrite.source_start_byte
            and finding.source_end_byte <= rewrite.source_end_byte
          then
            superseded = true
            break
          end
        end
      end

      if superseded then
        result.rejected[#result.rejected + 1] = {
          finding = finding,
          reason = M.RejectionReason.SUPERSEDED_BY_LONG_SENTENCE,
        }
      else
        retained[#retained + 1] = finding
      end
    end
    result.valid = retained
  end

  return result
end

function M.validate_document(document)
  if type(document) ~= "table"
    or type(document.findings) ~= "table"
    or not vim.islist(document.findings)
  then
    return nil, M.RejectionReason.SCHEMA_INVALID
  end
  if #document.findings > limits.max_findings then
    return nil, M.RejectionReason.SCHEMA_INVALID
  end

  for field in pairs(document) do
    if field ~= "findings" then
      return nil, M.RejectionReason.SCHEMA_INVALID
    end
  end

  return document.findings
end

return M
