local limits = require("ai-proofread.limits")

local finding = {
  type = "object",
  properties = {
    type = {
      type = "string",
      enum = { "correction", "rewrite" },
    },
    category = {
      type = "string",
      enum = {
        "spelling",
        "grammar",
        "punctuation",
        "long_sentence",
      },
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
      minItems = 0,
      maxItems = limits.max_findings,
    },
  },
  required = { "findings" },
  additionalProperties = false,
}
