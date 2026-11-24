local limits = require("ai-proofread.limits")

local function response_schema(type_values, category_values, min_items, max_items)
  local finding = {
    type = "object",
    properties = {
      type = {
        type = "string",
        enum = type_values,
      },
      category = {
        type = "string",
        enum = category_values,
      },
      original = {
        type = "string",
        minLength = 1,
        maxLength = limits.max_original_bytes,
      },
      suggestion = {
        type = "string",
        minLength = 1,
        maxLength = limits.max_suggestion_bytes,
      },
      message = {
        type = "string",
        minLength = 1,
        maxLength = limits.max_message_bytes,
      },
    },
    required = {
      "type",
      "category",
      "original",
      "suggestion",
      "message",
    },
    additionalProperties = false,
  }

  return {
    type = "object",
    properties = {
      findings = {
        type = "array",
        items = finding,
        minItems = min_items,
        maxItems = max_items,
      },
    },
    required = { "findings" },
    additionalProperties = false,
  }
end

local M = response_schema(
  { "correction", "rewrite" },
  { "spelling", "grammar", "punctuation", "long_sentence" },
  0,
  limits.max_findings
)

function M.rewrite()
  return response_schema({ "rewrite" }, { "long_sentence" }, 1, 1)
end

return M
