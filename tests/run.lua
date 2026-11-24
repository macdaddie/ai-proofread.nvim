local failures = 0

local function test(name, body)
  local ok, err = pcall(body)
  if ok then
    io.stdout:write("ok - " .. name .. "\n")
    return
  end

  failures = failures + 1
  io.stderr:write("not ok - " .. name .. "\n" .. tostring(err) .. "\n")
end

local function equal(actual, expected)
  if not vim.deep_equal(actual, expected) then
    error(string.format(
      "expected %s, got %s",
      vim.inspect(expected),
      vim.inspect(actual)
    ))
  end
end

test("public API loads and merges setup options", function()
  local review = require("ai-proofread")
  equal(require("foundation-review"), review)
  equal(type(review.setup), "function")
  equal(type(review.review), "function")
  equal(type(review.review_selection), "function")
  equal(type(review.cancel), "function")
  equal(type(review.apply), "function")
  equal(type(review.apply_all), "function")
  equal(type(review.ignore), "function")
  equal(type(review.status), "function")

  review.setup({
    ollama = { model = "test-model" },
    quickfix = { auto_open = false },
  })

  local config = review.get_config()
  equal(config.ollama.model, "test-model")
  equal(config.ollama.url, "http://127.0.0.1:11434")
  equal(config.quickfix.auto_open, false)
  equal(config.quickfix.height_ratio, 1 / 3)
  equal(config.quickfix.keep_focus_on_select, true)
  equal(config.checks.long_sentence, true)
  equal(config.long_sentence.max_words, 30)
end)

test("plugin registers public commands", function()
  vim.cmd.runtime("plugin/ai-proofread.lua")
  equal(vim.fn.exists(":AIProofread"), 2)
  equal(vim.fn.exists(":AIProofreadSelection"), 2)
  equal(vim.fn.exists(":AIProofreadCancel"), 2)
  equal(vim.fn.exists(":AIProofreadHealth"), 2)
  equal(vim.fn.exists(":AIProofreadApply"), 2)
  equal(vim.fn.exists(":AIProofreadApplyAll"), 2)
  equal(vim.fn.exists(":AIProofreadIgnore"), 2)
  equal(vim.fn.exists(":FoundationReview"), 2)
  equal(vim.fn.exists(":FoundationReviewApply"), 2)
end)

test("setup can preload the configured model asynchronously", function()
  local review = require("ai-proofread")
  local called = false
  review.setup({
    ollama = {
      model = "preload-model",
      preload = true,
      keep_alive = "1h",
    },
    keymaps = {
      review = false,
      review_selection = false,
      apply = false,
      apply_all = false,
      ignore = false,
    },
    _preload_transport = function(config, callback)
      called = true
      equal(config.model, "preload-model")
      equal(config.keep_alive, "1h")
      callback(nil)
      return { kill = function() end }
    end,
  })
  equal(called, true)
end)

test("configuration rejects removed proofreading checks", function()
  local config = require("ai-proofread.config")
  local valid, err = config.validate({
    checks = { sentence_readability = true },
  })
  equal(valid, nil)
  equal(err, "unsupported check: sentence_readability")
end)

test("configuration validates the inference backend", function()
  local config = require("ai-proofread.config")
  local valid, err = config.validate({ backend = "cloud" })
  equal(valid, nil)
  equal(err, "backend must be 'ollama' or 'fm'")
end)

test("configuration validates the fm chunk budget", function()
  local config = require("ai-proofread.config")
  local valid, err = config.validate({ fm = { chunk_size = 0 } })
  equal(valid, nil)
  equal(err, "fm.chunk_size must be a positive integer")

  valid, err = config.validate({ fm = { chunk_size = 1.5 } })
  equal(valid, nil)
  equal(err, "fm.chunk_size must be a positive integer")

  valid, err = config.validate({
    fm = { chunk_size = 100 },
    review = { hard_limit = 50 },
  })
  equal(valid, nil)
  equal(err, "fm.chunk_size must not exceed review.hard_limit")

  valid, err = config.validate({ fm = { chunk_size = 800 } })
  assert(valid)
  equal(err, nil)
  equal(valid.fm.chunk_size, 800)
end)

test("configuration validates long-sentence and quickfix options", function()
  local config = require("ai-proofread.config")

  local valid, err = config.validate({
    long_sentence = { max_words = 0 },
  })
  equal(valid, nil)
  equal(err, "long_sentence.max_words must be a positive integer")

  valid, err = config.validate({
    quickfix = { height_ratio = 2 },
  })
  equal(valid, nil)
  equal(err, "quickfix.height_ratio must be between 0 and 1")

  valid, err = config.validate({
    quickfix = { keep_focus_on_select = "yes" },
  })
  equal(valid, nil)
  equal(err, "quickfix.keep_focus_on_select must be a boolean")

  valid, err = config.validate({ long_sentence = false })
  equal(valid, nil)
  equal(err, "long_sentence must be a table")

  valid, err = config.validate({
    ollama = { url = "https://example.com" },
  })
  equal(valid, nil)
  equal(err, "ollama.url must use a loopback host")

  valid, err = config.validate({
    ollama = { url = "http://[::1]:11434" },
  })
  assert(valid)

  valid, err = config.validate({
    ollama = { url = "http://localhost:" },
  })
  equal(valid, nil)
  equal(err, "ollama.url must use a loopback host")
end)

test("validator maps a UTF-8 finding to a line-local byte column", function()
  local validator = require("ai-proofread.validate")
  local text = "One café has teh colour."
  local map = {}
  for byte = 1, #text do
    map[byte] = byte
  end

  local finding, reason = validator.validate_finding({
    type = "correction",
    category = "spelling",
    original = "teh",
    suggestion = "the",
    message = "Incorrect spelling.",
  }, {
    review_text = text,
    document_text = text,
    offset_map = map,
    protected_spans = {},
  })

  equal(reason, nil)
  equal(finding.line, 1)
  equal(finding.column, 15)
  equal(finding.source_start_byte, 15)
  equal(finding.source_end_byte, 17)
end)

test("validator rejects an ambiguous exact quotation", function()
  local validator = require("ai-proofread.validate")
  local text = "teh first and teh second"
  local map = {}
  for byte = 1, #text do
    map[byte] = byte
  end

  local finding, reason = validator.validate_finding({
    type = "correction",
    category = "spelling",
    original = "teh",
    suggestion = "the",
    message = "Incorrect spelling.",
  }, {
    review_text = text,
    document_text = text,
    offset_map = map,
  })

  equal(finding, nil)
  equal(reason, "not_unique")
end)

test("validator retains source text for a whitespace-collapsed match", function()
  local validator = require("ai-proofread.validate")
  local text = "This sentence is hard\nwrapped here."
  local map = {}
  for byte = 1, #text do
    map[byte] = byte
  end

  local finding, reason = validator.validate_finding({
    type = "correction",
    category = "grammar",
    original = "is hard wrapped",
    suggestion = "is hard-wrapped",
    message = "Use a compound modifier.",
  }, {
    review_text = text,
    document_text = text,
    offset_map = map,
  })

  equal(reason, nil)
  equal(finding.source_text, "is hard\nwrapped")
end)

test("validator rejects a finding that intersects protected content", function()
  local validator = require("ai-proofread.validate")
  local text = "Use `teh_code` here."
  local map = {}
  for byte = 1, #text do
    map[byte] = byte
  end

  local finding, reason = validator.validate_finding({
    type = "correction",
    category = "spelling",
    original = "teh_code",
    suggestion = "the_code",
    message = "Use the intended identifier.",
  }, {
    review_text = text,
    document_text = text,
    offset_map = map,
    protected_spans = {
      { start_byte = 5, end_byte = 14 },
    },
  })

  equal(finding, nil)
  equal(reason, "protected")
end)

test("plain-text chunks preserve exact source bytes", function()
  local adapters = require("ai-proofread.adapters")
  local text = "First paragraph.\n\nSecond paragraph."
  local chunks = adapters.prepare("text", text, 20)

  equal(#chunks, 2)
  equal(chunks[1].review_text, "First paragraph.")
  equal(chunks[1].offset_map[1], 1)
  equal(chunks[2].review_text, "Second paragraph.")
  equal(chunks[2].offset_map[1], 19)
  equal(chunks[2].document_text, text)
end)

test("AsciiDoc adapter masks source blocks without moving prose", function()
  local adapters = require("ai-proofread.adapters")
  local text = table.concat({
    "Intro teh.",
    "",
    "[source,lua]",
    "----",
    "local teh = 1",
    "----",
    "",
    "Outro teh.",
  }, "\n")

  local chunks = adapters.prepare("asciidoc", text, 1000)
  equal(#chunks, 1)
  equal(chunks[1].review_text:find("local", 1, true), nil)

  local intro = assert(chunks[1].review_text:find("Intro teh.", 1, true))
  local outro = assert(chunks[1].review_text:find("Outro teh.", 1, true))
  equal(chunks[1].offset_map[intro], 1)
  equal(chunks[1].offset_map[outro], text:find("Outro", 1, true))
end)

test("Markdown adapter masks frontmatter and fenced code", function()
  local adapters = require("ai-proofread.adapters")
  local text = table.concat({
    "---",
    "title: Teh title",
    "---",
    "",
    "Review teh prose.",
    "",
    "```lua",
    "local teh = true",
    "```",
  }, "\n")

  local chunks = adapters.prepare("markdown", text, 1000)
  equal(#chunks, 1)
  equal(chunks[1].review_text:find("Teh title", 1, true), nil)
  equal(chunks[1].review_text:find("local teh", 1, true), nil)
  assert(chunks[1].review_text:find("Review teh prose.", 1, true))
end)

test("Ollama request enforces deterministic structured output", function()
  local ollama = require("ai-proofread.ollama")
  local request = ollama.build_request(
    "test-model",
    "Review this text.",
    "Proofread British English prose.",
    "1h"
  )

  equal(request.model, "test-model")
  equal(request.stream, false)
  equal(request.think, false)
  equal(request.options.temperature, 0)
  equal(request.keep_alive, "1h")
  equal(request.format.type, "object")
  equal(
    request.format.properties.findings.items.properties.type.enum,
    { "correction", "rewrite" }
  )
  equal(
    request.format.properties.findings.items.properties.category.enum,
    {
      "spelling",
      "grammar",
      "punctuation",
      "long_sentence",
    }
  )
end)

test("rewrite schema narrows the retry response contract", function()
  local schema = require("ai-proofread.schema")
  local general = schema.properties.findings.items.properties
  local rewrite = schema.rewrite().properties.findings.items.properties

  equal(general.type.enum, { "correction", "rewrite" })
  equal(general.category.enum, {
    "spelling",
    "grammar",
    "punctuation",
    "long_sentence",
  })
  equal(schema.properties.findings.minItems, 0)
  equal(rewrite.type.enum, { "rewrite" })
  equal(rewrite.category.enum, { "long_sentence" })
  equal(schema.rewrite().properties.findings.minItems, 1)
  equal(schema.rewrite().properties.findings.maxItems, 1)
end)

test("Ollama preload request loads without generating text", function()
  local ollama = require("ai-proofread.ollama")
  equal(
    ollama.build_preload_request("test-model", "1h"),
    {
      model = "test-model",
      stream = false,
      keep_alive = "1h",
    }
  )
end)

test("Ollama preload timeout is configurable", function()
  local config = require("ai-proofread.config")
  equal(config.merge({}).ollama.preload_timeout_ms, 120000)

  local valid, err = config.validate({
    ollama = { preload_timeout_ms = 500 },
  })
  equal(valid, nil)
  equal(err, "ollama.preload_timeout_ms must be at least 1000ms")
end)

test("Ollama failures are classified for the user", function()
  local ollama = require("ai-proofread.ollama")

  local timeout_code, timeout_detail = ollama.classify_failure({ code = 28 })
  equal(timeout_code, "timeout")
  equal(type(timeout_detail), "string")

  local refused = ollama.classify_failure({ code = 7 })
  equal(refused, "connection_failed")

  local failed, detail = ollama.classify_failure({
    code = 22,
    stderr = "curl: (22) The requested URL returned error: 500\n",
  })
  equal(failed, "transport_error")
  equal(detail, "curl: (22) The requested URL returned error: 500")
end)

test("Ollama loaded models are decoded from /api/ps", function()
  local ollama = require("ai-proofread.ollama")

  equal(
    ollama.parse_loaded_models(vim.json.encode({
      models = {
        { name = "first:latest" },
        { model = "second:latest" },
      },
    })),
    { "first:latest", "second:latest" }
  )

  local invalid = ollama.parse_loaded_models("not json")
  equal(invalid, nil)
end)

test("fm adapter builds and decodes a structured request", function()
  local fm = require("ai-proofread.fm")
  equal(
    fm.build_request("Review this.", "Proofread British English."),
    {
      prompt = "Review this.",
      system = "Proofread British English.",
    }
  )
  local document, err = fm.decode_response(
    vim.json.encode({ findings = {} })
  )
  equal(err, nil)
  equal(document, { findings = {} })

  local rewrite_schema = fm.rewrite_schema_path()
  assert(rewrite_schema:find("fm_rewrite_response_schema.json", 1, true))
  equal(
    fm.build_request("Rewrite this.", "Proofread British English.", rewrite_schema),
    {
      prompt = "Rewrite this.",
      system = "Proofread British English.",
      schema_path = rewrite_schema,
    }
  )
end)

test("review can use the native fm backend", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "teh text" })

  local received_config
  local received_payload
  review.setup({
    backend = "fm",
    keymaps = {
      review = false,
      review_selection = false,
      apply = false,
      apply_all = false,
      ignore = false,
    },
    quickfix = { auto_open = false },
    _transport = function(config, payload, callback)
      received_config = config
      received_payload = payload
      callback(nil, { findings = {} })
      return { kill = function() end }
    end,
  })

  review.review()
  equal(received_config.command, "fm")
  equal(received_config.chunk_size, 800)
  assert(received_payload.prompt:find("teh text", 1, true))
  equal(received_payload.system, require("ai-proofread.prompt").system)
end)

test("fm chunk budget overrides the general review chunk size", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  local paragraph = string.rep("a", 600)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    paragraph, "", paragraph, "", paragraph,
  })

  local calls = 0
  review.setup({
    backend = "fm",
    keymaps = { review = false },
    review = { chunk_size = 2500 },
    quickfix = { auto_open = false },
    _transport = function(_, _, callback)
      calls = calls + 1
      callback(nil, { findings = {} })
      return { kill = function() end }
    end,
  })
  review.review()
  equal(calls, 3)
end)

test("progress reports an active review in place", function()
  local progress = require("ai-proofread.progress")
  local buffer = vim.api.nvim_create_buf(false, true)
  local captured = {}
  local original_echo = vim.api.nvim_echo

  vim.api.nvim_echo = function(chunks, history, options)
    captured[#captured + 1] = {
      chunks = chunks,
      history = history,
      options = options,
    }
  end

  local ok, err = pcall(function()
    local fake = {
      id = 9999,
      buffer = buffer,
      index = 0,
      config = { backend = "fm" },
      chunks = { {}, {}, {} },
    }
    progress.start(fake)
    equal(#captured, 1)
    equal(captured[1].options.kind, "progress")
    equal(captured[1].options.status, "running")
    equal(captured[1].options.percent, 0)
    equal(captured[1].options.title, "AI Proofread")
    equal(captured[1].options.source, "fm")

    fake.index = 1
    progress.update(fake, "requesting chunk 1/3")
    equal(captured[#captured].options.percent, 33)
    assert(captured[#captured].chunks[1][1]:find("chunk 1/3", 1, true))

    local status = progress.status(buffer)
    equal(status.backend, "fm")
    equal(status.done, 1)
    equal(status.total, 3)
    equal(status.running, true)
    assert(progress.format(buffer):find("fm 1/3", 1, true))

    progress.stop(buffer, "success", "complete")
    equal(captured[#captured].options.status, "success")
    equal(captured[#captured].options.percent, 33)
    equal(progress.status(buffer), nil)
  end)

  progress.stop(buffer, "success", "cleanup")
  vim.api.nvim_echo = original_echo
  assert(ok, err)
end)

test("Ollama response decoder returns the findings envelope", function()
  local ollama = require("ai-proofread.ollama")
  local model_document = vim.json.encode({
    findings = {
      {
        type = "correction",
        category = "grammar",
        original = "they is",
        suggestion = "they are",
        message = "Use plural agreement.",
      },
    },
  })
  local body = vim.json.encode({ response = model_document })

  local document, err = ollama.decode_response(body)
  equal(err, nil)
  equal(document.findings[1].suggestion, "they are")
end)

test("Ollama response decoder rejects empty and malformed output", function()
  local ollama = require("ai-proofread.ollama")

  local document, malformed = ollama.decode_response("not json")
  equal(document, nil)
  assert(malformed:match("^invalid_transport_json"))

  local empty_document, empty = ollama.decode_response(
    vim.json.encode({ response = "" })
  )
  equal(empty_document, nil)
  equal(empty, "empty_response")
end)

test("public review publishes validated findings to quickfix", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "This has teh mistake.",
  })

  local requested
  review.setup({
    keymaps = { review = false },
    quickfix = { auto_open = false },
    _transport = function(_, payload, callback)
      requested = payload
      callback(nil, {
        findings = {
          {
            type = "correction",
            category = "spelling",
            original = "teh",
            suggestion = "the",
            message = "Incorrect spelling.",
          },
        },
      })
      return { kill = function() end }
    end,
  })

  review.review()

  local quickfix = vim.fn.getqflist({ items = 1, title = 1 })
  equal(quickfix.title, "AI Proofread")
  equal(#quickfix.items, 1)
  equal(quickfix.items[1].bufnr, buffer)
  equal(quickfix.items[1].lnum, 1)
  equal(quickfix.items[1].col, 10)
  equal(quickfix.items[1].end_lnum, 1)
  equal(quickfix.items[1].end_col, 12)
  assert(quickfix.items[1].user_data.ai_proofread_id)
  assert(quickfix.items[1].text:find("the", 1, true))
  equal(requested.think, false)
end)

test("visual review submits and locates only selected text", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "Ignore this.",
    "Review teh only.",
    "Ignore sentance.",
  })

  local requested
  review.setup({
    keymaps = {
      review = false,
      review_selection = false,
      apply = false,
      apply_all = false,
      ignore = false,
    },
    quickfix = { auto_open = false },
    _transport = function(_, payload, callback)
      requested = payload
      callback(nil, {
        findings = {
          {
            type = "correction",
            category = "spelling",
            original = "teh",
            suggestion = "the",
            message = "Incorrect spelling.",
          },
        },
      })
      return { kill = function() end }
    end,
  })

  vim.api.nvim_win_set_cursor(0, { 2, 7 })
  vim.cmd([[execute "normal! v2l\<Esc>"]])
  review.review_selection()

  assert(requested.prompt:find("\nteh", 1, true))
  equal(requested.prompt:find("Ignore this.", 1, true), nil)
  equal(requested.prompt:find("Ignore sentance.", 1, true), nil)
  local quickfix = vim.fn.getqflist({ items = 1 })
  equal(#quickfix.items, 1)
  equal(quickfix.items[1].lnum, 2)
  equal(quickfix.items[1].col, 8)
end)

test("review discards findings when the buffer becomes stale", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "teh text" })
  vim.fn.setqflist({}, "r")

  local complete
  review.setup({
    keymaps = { review = false },
    quickfix = { auto_open = false },
    _transport = function(_, _, callback)
      complete = callback
      return { kill = function() end }
    end,
  })

  review.review()
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "changed text" })
  complete(nil, {
    findings = {
      {
        type = "correction",
        category = "spelling",
        original = "teh",
        suggestion = "the",
        message = "Incorrect spelling.",
      },
    },
  })

  equal(#vim.fn.getqflist(), 0)
end)

test("cancel terminates the active transport and ignores its callback", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "teh text" })
  vim.fn.setqflist({}, "r")

  local complete
  local killed = false
  review.setup({
    keymaps = { review = false },
    quickfix = { auto_open = false },
    _transport = function(_, _, callback)
      complete = callback
      return {
        kill = function()
          killed = true
        end,
      }
    end,
  })

  review.review()
  equal(review.cancel(), true)
  equal(killed, true)
  complete(nil, { findings = {} })
  equal(#vim.fn.getqflist(), 0)
end)

test("partial failure still publishes findings from successful chunks", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "teh first.",
    "",
    "Second paragraph fails.",
  })

  local call = 0
  review.setup({
    keymaps = { review = false },
    review = { chunk_size = 15 },
    quickfix = { auto_open = false },
    _transport = function(_, _, callback)
      call = call + 1
      if call == 1 then
        callback(nil, {
          findings = {
            {
              type = "correction",
              category = "spelling",
              original = "teh",
              suggestion = "the",
              message = "Incorrect spelling.",
            },
          },
        })
      else
        callback("transport_error")
      end
      return { kill = function() end }
    end,
  })

  review.review()
  local quickfix = vim.fn.getqflist({ items = 1, context = 1 })
  equal(#quickfix.items, 1)
  equal(quickfix.context.complete, false)
  equal(quickfix.context.failed_chunks, 1)
end)

test("long paragraphs split at sentence boundaries", function()
  local adapters = require("ai-proofread.adapters")
  local text = "First sentence. Second sentence."
  local chunks = adapters.prepare("text", text, 17)

  equal(#chunks, 2)
  equal(chunks[1].source_text, "First sentence.")
  equal(chunks[2].source_text, "Second sentence.")
  equal(chunks[2].offset_map[1], 17)
end)

test("prompt requires minimal spans for corrections", function()
  local prompt = require("ai-proofread.prompt")
  local content = prompt.build("This has teh error.", {
    spelling = true,
  })

  assert(content:find("smallest exact offending substring", 1, true))
  assert(content:find("never quote the complete sentence", 1, true))
  assert(content:find('"teh"', 1, true))
  assert(content:find('"the"', 1, true))
  assert(content:find("readability, style, structure", 1, true))
end)

test("prompt requests constrained long-sentence rewrites", function()
  local prompt = require("ai-proofread.prompt")
  local content = prompt.build("Long text.", {
    spelling = true,
    long_sentence = true,
  }, {
    max_words = 30,
  })

  assert(content:find("more than 30 words", 1, true))
  assert(content:find("type rewrite", 1, true))
  assert(content:find("preserving every meaning", 1, true))
  assert(content:find("at most 30 words", 1, true))
  assert(content:find("Do not remove content", 1, true))
  equal(content:find("code-detected candidates", 1, true), nil)

  local focused = prompt.build_rewrite(
    "The exact code-detected candidate.",
    30
  )
  assert(focused:find("exactly one source sentence", 1, true))
  assert(focused:find("one rewrite finding", 1, true))
  assert(focused:find("copy that sentence verbatim", 1, true))
  assert(focused:find("two or more complete sentences", 1, true))
  assert(focused:find("at most 30 words", 1, true))
  assert(focused:find("The exact code-detected candidate.", 1, true))
end)

test("sentence detection supplies only deterministic long candidates", function()
  local sentence = require("ai-proofread.sentence")
  local first = "Dr. Smith wrote a short sentence."
  local words = {}
  for index = 1, 31 do
    words[index] = "word" .. index
  end
  local long = table.concat(words, " ") .. "."
  local text = first .. " " .. long
  local map = {}
  for byte = 1, #text do
    map[byte] = byte
  end
  local candidates = sentence.long_candidates({
    review_text = text,
    document_text = text,
    offset_map = map,
    protected_spans = {},
  }, 30)

  equal(#sentence.find(text), 2)
  equal(#candidates, 1)
  equal(candidates[1].text, long)
end)

test("validator rejects removed proofreading categories", function()
  local validator = require("ai-proofread.validate")
  local finding, reason = validator.validate_finding({
    type = "correction",
    category = "word_choice",
    original = "affect",
    suggestion = "effect",
    message = "Use the intended noun.",
  }, {
    review_text = "affect",
    document_text = "affect",
    offset_map = { 1, 2, 3, 4, 5, 6 },
  })

  equal(finding, nil)
  equal(reason, "unsupported_category")
end)

test("validator rejects a correction that changes nothing", function()
  local validator = require("ai-proofread.validate")
  local finding, reason = validator.validate_finding({
    type = "correction",
    category = "spelling",
    original = "wrong",
    suggestion = "wrong",
    message = "No change.",
  }, {
    review_text = "wrong",
    document_text = "wrong",
    offset_map = { 1, 2, 3, 4, 5 },
  })
  equal(finding, nil)
  equal(reason, "no_change")
end)

test("validator enforces the configured long-sentence limit", function()
  local validator = require("ai-proofread.validate")
  local words = {}
  for index = 1, 31 do
    words[index] = "word" .. index
  end
  local text = table.concat(words, " ") .. "."
  local offset_map = {}
  for byte = 1, #text do
    offset_map[byte] = byte
  end
  local chunk = {
    review_text = text,
    document_text = text,
    offset_map = offset_map,
  }
  local finding = {
    type = "rewrite",
    category = "long_sentence",
    original = text,
    suggestion = "First shorter sentence. Second shorter sentence.",
    message = "Split this long sentence.",
  }

  local accepted = validator.validate_finding(finding, chunk, {
    checks = { long_sentence = true },
    long_sentence = { max_words = 30 },
  })
  assert(accepted)

  local rejected, reason = validator.validate_finding(finding, chunk, {
    checks = { long_sentence = true },
    long_sentence = { max_words = 31 },
  })
  equal(rejected, nil)
  equal(reason, "below_long_sentence_limit")

  rejected, reason = validator.validate_finding(finding, chunk, {
    checks = { long_sentence = false },
    long_sentence = { max_words = 30 },
  })
  equal(rejected, nil)
  equal(reason, "disabled_category")
end)

test("long-sentence rewrites supersede contained corrections", function()
  local validator = require("ai-proofread.validate")
  local words = { "teh" }
  for index = 2, 31 do
    words[index] = "word" .. index
  end
  local text = table.concat(words, " ") .. "."
  local offset_map = {}
  for byte = 1, #text do
    offset_map[byte] = byte
  end

  local result = validator.validate_findings({
    {
      type = "correction",
      category = "spelling",
      original = "teh",
      suggestion = "the",
      message = "Correct the spelling.",
    },
    {
      type = "rewrite",
      category = "long_sentence",
      original = text,
      suggestion = "First shorter sentence. Second shorter sentence.",
      message = "Split this long sentence.",
    },
  }, {
    review_text = text,
    document_text = text,
    offset_map = offset_map,
  }, {
    checks = {
      spelling = true,
      long_sentence = true,
    },
    long_sentence = { max_words = 30 },
  })

  equal(#result.valid, 1)
  equal(result.valid[1].category, "long_sentence")
  equal(#result.rejected, 1)
  equal(result.rejected[1].reason, "superseded_by_long_sentence")
end)

test("validator rejects hostile or structurally invalid rewrites", function()
  local validator = require("ai-proofread.validate")
  local words = {}
  for index = 1, 31 do
    words[index] = "word" .. index
  end
  local text = table.concat(words, " ") .. "."
  local map = {}
  for byte = 1, #text do
    map[byte] = byte
  end
  local chunk = {
    review_text = text,
    document_text = text,
    offset_map = map,
    protected_spans = {},
  }
  local options = {
    checks = { long_sentence = true },
    long_sentence = { max_words = 30 },
  }

  local finding = {
    type = "rewrite",
    category = "long_sentence",
    original = text,
    suggestion = "This remains one sentence.",
    message = "Split it.",
  }
  local valid, reason = validator.validate_finding(finding, chunk, options)
  equal(valid, nil)
  equal(reason, "invalid_long_sentence_rewrite")

  finding.suggestion = "First sentence.\0Hidden content. Second sentence."
  valid, reason = validator.validate_finding(finding, chunk, options)
  equal(valid, nil)
  equal(reason, "schema_invalid")

  local half = {}
  for index = 1, 16 do
    half[index] = "alpha" .. index
  end
  local first = table.concat(half, " ") .. "."
  for index = 1, 16 do
    half[index] = "beta" .. index
  end
  local combined = first .. " " .. table.concat(half, " ") .. "."
  map = {}
  for byte = 1, #combined do
    map[byte] = byte
  end
  finding.original = combined
  finding.suggestion = "First shorter sentence. Second shorter sentence."
  valid, reason = validator.validate_finding(finding, {
    review_text = combined,
    document_text = combined,
    offset_map = map,
    protected_spans = {},
  }, options)
  equal(valid, nil)
  equal(reason, "not_long_sentence_candidate")
end)

test("validator selects bounded deterministic rewrite retries", function()
  local sentence = require("ai-proofread.sentence")
  local limits = require("ai-proofread.limits")
  local validator = require("ai-proofread.validate")
  local expected = {}
  local rejected_findings = {}

  for index = 1, limits.max_rewrite_retries_per_chunk + 1 do
    local words = { "prefix" .. index }
    for word = 2, 31 do
      words[word] = "word" .. word
    end
    local text = table.concat(words, " ") .. "."
    expected[index] = text
    rejected_findings[index] = {
      finding = {
        type = "rewrite",
        category = "long_sentence",
        original = text,
        suggestion = text,
        message = "Split this long sentence.",
      },
      reason = validator.RejectionReason.NO_CHANGE,
    }
  end

  local text = table.concat(expected, " ")
  local map = {}
  for byte = 1, #text do
    map[byte] = byte
  end
  local chunk = {
    review_text = text,
    document_text = text,
    offset_map = map,
    protected_spans = {},
  }
  chunk.long_sentence_candidates = sentence.long_candidates(chunk, 30)
  equal(#chunk.long_sentence_candidates, #expected)

  local candidates, retryable = validator.retry_candidates(
    rejected_findings,
    chunk
  )
  equal(#candidates, limits.max_rewrite_retries_per_chunk)
  equal(retryable[1], true)
  equal(retryable[limits.max_rewrite_retries_per_chunk], true)
  equal(retryable[limits.max_rewrite_retries_per_chunk + 1], nil)
end)

test("model response limits reject oversized output", function()
  local limits = require("ai-proofread.limits")
  local validator = require("ai-proofread.validate")
  local findings = {}
  for index = 1, limits.max_findings + 1 do
    findings[index] = {}
  end
  local document, reason = validator.validate_document({
    findings = findings,
  })
  equal(document, nil)
  equal(reason, "schema_invalid")

  local oversized = string.rep("x", limits.max_response_bytes + 1)
  local decoded, err = require("ai-proofread.ollama").decode_response(
    oversized
  )
  equal(decoded, nil)
  equal(err, "response_too_large")
  decoded, err = require("ai-proofread.fm").decode_response(oversized)
  equal(decoded, nil)
  equal(err, "response_too_large")
end)

test("applies the current quickfix correction", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "This has teh mistake.",
  })

  review.setup({
    keymaps = { review = false, apply = false, apply_all = false },
    quickfix = { auto_open = false },
    _transport = function(_, _, callback)
      callback(nil, {
        findings = {
          {
            type = "correction",
            category = "spelling",
            original = "teh",
            suggestion = "the",
            message = "Incorrect spelling.",
          },
        },
      })
      return { kill = function() end }
    end,
  })

  review.review()
  equal(review.apply(), true)
  equal(
    vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
    { "This has the mistake." }
  )
  equal(#vim.fn.getqflist(), 0)
end)

test("applies a validated long-sentence rewrite", function()
  local review = require("ai-proofread")
  local words = {}
  for index = 1, 31 do
    words[index] = "word" .. index
  end
  local sentence = table.concat(words, " ") .. "."
  local replacement = "First shorter sentence. Second shorter sentence."
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { sentence })

  review.setup({
    keymaps = { review = false, apply = false },
    quickfix = { auto_open = false },
    _transport = function(_, _, callback)
      callback(nil, {
        findings = {
          {
            type = "rewrite",
            category = "long_sentence",
            original = sentence,
            suggestion = replacement,
            message = "Split this long sentence.",
          },
        },
      })
      return { kill = function() end }
    end,
  })

  review.review()
  equal(review.apply(), true)
  equal(
    vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
    { replacement }
  )
end)

test("bulk application is one undoable change", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "Teh cats is ready.",
  })
  local undo_levels = vim.bo[buffer].undolevels
  vim.bo[buffer].undolevels = -1
  vim.bo[buffer].undolevels = undo_levels

  review.setup({
    keymaps = { review = false, apply = false, apply_all = false },
    quickfix = { auto_open = false },
    _transport = function(_, _, callback)
      callback(nil, {
        findings = {
          {
            type = "correction",
            category = "spelling",
            original = "Teh",
            suggestion = "The",
            message = "Incorrect spelling.",
          },
          {
            type = "correction",
            category = "grammar",
            original = "cats is",
            suggestion = "cats are",
            message = "Use plural agreement.",
          },
        },
      })
      return { kill = function() end }
    end,
  })

  review.review()
  equal(review.apply_all(), true)
  equal(
    vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
    { "The cats are ready." }
  )
  equal(#vim.fn.getqflist(), 0)
  vim.cmd("undo")
  equal(
    vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
    { "Teh cats is ready." }
  )
end)

test("remaining corrections follow an individually applied edit", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "Teeh cats is ready.",
  })

  review.setup({
    keymaps = { review = false, apply = false, apply_all = false },
    quickfix = { auto_open = false },
    _transport = function(_, _, callback)
      callback(nil, {
        findings = {
          {
            type = "correction",
            category = "spelling",
            original = "Teeh",
            suggestion = "The",
            message = "Incorrect spelling.",
          },
          {
            type = "correction",
            category = "grammar",
            original = "cats is",
            suggestion = "cats are",
            message = "Use plural agreement.",
          },
        },
      })
      return { kill = function() end }
    end,
  })

  review.review()
  equal(review.apply(), true)
  local remaining = vim.fn.getqflist({ idx = 0, items = 1 })
  equal(#remaining.items, 1)
  equal(remaining.idx, 1)
  assert(remaining.items[1].text:find("plural", 1, true))
  equal(review.apply_all(), true)
  equal(
    vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
    { "The cats are ready." }
  )
  equal(#vim.fn.getqflist(), 0)
end)

test("ignored corrections are removed and excluded from apply all", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "Teeh cats is ready.",
  })

  review.setup({
    keymaps = {
      review = false,
      apply = false,
      apply_all = false,
      ignore = false,
    },
    quickfix = { auto_open = false },
    _transport = function(_, _, callback)
      callback(nil, {
        findings = {
          {
            type = "correction",
            category = "spelling",
            original = "Teeh",
            suggestion = "The",
            message = "Incorrect spelling.",
          },
          {
            type = "correction",
            category = "grammar",
            original = "cats is",
            suggestion = "cats are",
            message = "Use plural agreement.",
          },
        },
      })
      return { kill = function() end }
    end,
  })

  review.review()
  equal(review.ignore(), true)
  equal(
    vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
    { "Teeh cats is ready." }
  )
  local remaining = vim.fn.getqflist({ idx = 0, items = 1 })
  equal(#remaining.items, 1)
  equal(remaining.idx, 1)
  assert(remaining.items[1].text:find("plural", 1, true))

  equal(review.apply_all(), true)
  equal(
    vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
    { "Teeh cats are ready." }
  )
  equal(#vim.fn.getqflist(), 0)
end)

test("bulk application aborts when any source text changed", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "Teh cats is ready.",
  })

  review.setup({
    keymaps = { review = false, apply = false, apply_all = false },
    quickfix = { auto_open = false },
    _transport = function(_, _, callback)
      callback(nil, {
        findings = {
          {
            type = "correction",
            category = "spelling",
            original = "Teh",
            suggestion = "The",
            message = "Incorrect spelling.",
          },
          {
            type = "correction",
            category = "grammar",
            original = "cats is",
            suggestion = "cats are",
            message = "Use plural agreement.",
          },
        },
      })
      return { kill = function() end }
    end,
  })

  review.review()
  vim.api.nvim_buf_set_text(buffer, 0, 4, 0, 8, { "dogs" })
  local applied = review.apply_all()
  equal(applied, nil)
  equal(
    vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
    { "Teh dogs is ready." }
  )
  equal(#vim.fn.getqflist(), 2)
end)

test("bulk application rejects overlapping corrections", function()
  local apply = require("ai-proofread.apply")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "abcdef" })

  apply.register(buffer, 999, {
    {
      line = 1,
      column = 1,
      end_line = 1,
      end_column = 3,
      source_text = "abc",
      suggestion = "x",
    },
    {
      line = 1,
      column = 2,
      end_line = 1,
      end_column = 4,
      source_text = "bcd",
      suggestion = "y",
    },
  })

  local applied = apply.all()
  equal(applied, nil)
  equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { "abcdef" })
end)

test("sentences beyond the hard limit are reported without inference", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "This single sentence has no early boundary and exceeds the hard limit.",
  })

  local requests = 0
  review.setup({
    keymaps = { review = false },
    review = { chunk_size = 20, hard_limit = 40 },
    quickfix = { auto_open = false },
    _transport = function()
      requests = requests + 1
    end,
  })

  review.review()
  local quickfix = vim.fn.getqflist({ context = 1, title = 1 })
  equal(requests, 0)
  equal(quickfix.title, "AI Proofread")
  equal(quickfix.context.complete, false)
  equal(quickfix.context.unreviewable_sections, 1)
end)

test("validator rejects a non-array findings envelope", function()
  local validator = require("ai-proofread.validate")
  local findings, reason = validator.validate_document({
    findings = { unexpected = "object" },
  })
  equal(findings, nil)
  equal(reason, "schema_invalid")
end)

test("quickfix receives findings before the final chunk completes", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "teh first.",
    "",
    "And teh second.",
  })

  local callbacks = {}
  review.setup({
    keymaps = { review = false },
    review = { chunk_size = 15 },
    quickfix = { auto_open = false },
    _transport = function(_, _, callback)
      callbacks[#callbacks + 1] = callback
      return { kill = function() end }
    end,
  })

  review.review()
  equal(#callbacks, 1)

  callbacks[1](nil, {
    findings = {
      {
        type = "correction",
        category = "spelling",
        original = "teh",
        suggestion = "the",
        message = "Incorrect spelling.",
      },
    },
  })

  local quickfix = vim.fn.getqflist({ items = 1, context = 1 })
  equal(#quickfix.items, 1)
  equal(quickfix.context.complete, false)
  equal(quickfix.context.chunks_done, 1)
  equal(quickfix.context.chunks_total, 2)
  local first_id = quickfix.items[1].user_data.ai_proofread_id
  assert(first_id)

  callbacks[2](nil, {
    findings = {
      {
        type = "correction",
        category = "spelling",
        original = "teh",
        suggestion = "the",
        message = "Incorrect spelling.",
      },
    },
  })

  quickfix = vim.fn.getqflist({ items = 1, context = 1 })
  equal(#quickfix.items, 2)
  equal(quickfix.context.complete, true)
  equal(quickfix.context.chunks_done, 2)
  equal(quickfix.items[1].user_data.ai_proofread_id, first_id)
  assert(quickfix.items[2].user_data.ai_proofread_id ~= first_id)
end)

test("rewrite retry publishes before later chunks and keeps streaming", function()
  local review = require("ai-proofread")
  local words = { "prefix" }
  for word = 2, 31 do
    words[word] = "word" .. word
  end
  local long_sentence = table.concat(words, " ") .. "."
  local replacement = "First shorter sentence. Second shorter sentence."
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    long_sentence,
    "",
    "teh second.",
  })

  local callbacks = {}
  local payloads = {}
  review.setup({
    keymaps = { review = false },
    review = { chunk_size = 120, hard_limit = 12000 },
    quickfix = { auto_open = false },
    _transport = function(_, payload, callback)
      payloads[#payloads + 1] = payload
      callbacks[#callbacks + 1] = callback
      return { kill = function() end }
    end,
  })

  review.review()
  equal(#callbacks, 1)

  callbacks[1](nil, {
    findings = {
      {
        type = "rewrite",
        category = "long_sentence",
        original = long_sentence,
        suggestion = long_sentence,
        message = "Split this long sentence.",
      },
    },
  })
  equal(#callbacks, 2)
  assert(payloads[2].prompt:find("<<<SENTENCE>>>", 1, true))
  equal(
    payloads[2].format.properties.findings.items.properties.type.enum,
    { "rewrite" }
  )
  equal(
    payloads[2].format.properties.findings.items.properties.category.enum,
    { "long_sentence" }
  )

  callbacks[2](nil, {
    findings = {
      {
        type = "rewrite",
        category = "long_sentence",
        original = long_sentence,
        suggestion = replacement,
        message = "Split this long sentence.",
      },
    },
  })
  equal(#callbacks, 3)
  local mid_review = vim.fn.getqflist({ items = 1, context = 1 })
  equal(#mid_review.items, 1)
  equal(mid_review.context.complete, false)
  equal(mid_review.context.chunks_done, 1)

  callbacks[3](nil, {
    findings = {
      {
        type = "correction",
        category = "spelling",
        original = "teh",
        suggestion = "the",
        message = "Incorrect spelling.",
      },
    },
  })
  local final_review = vim.fn.getqflist({ items = 1, context = 1 })
  equal(#final_review.items, 2)
  equal(final_review.context.complete, true)
  equal(final_review.context.chunks_done, 2)
end)

test("apply during review rebases later findings and keeps review running", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "Cats is here.",
    "",
    "Teh there.",
  })

  local callbacks = {}
  review.setup({
    keymaps = { review = false, apply = false, apply_all = false },
    review = { chunk_size = 20 },
    quickfix = { auto_open = false },
    _transport = function(_, _, callback)
      callbacks[#callbacks + 1] = callback
      return { kill = function() end }
    end,
  })

  review.review()
  equal(#callbacks, 1)

  callbacks[1](nil, {
    findings = {
      {
        type = "correction",
        category = "grammar",
        original = "Cats is",
        suggestion = "Cats are\n",
        message = "Use plural agreement.",
      },
    },
  })
  equal(#vim.fn.getqflist(), 1)
  equal(review.apply(), true)
  equal(#vim.fn.getqflist(), 0)

  callbacks[2](nil, {
    findings = {
      {
        type = "correction",
        category = "spelling",
        original = "Teh",
        suggestion = "The",
        message = "Incorrect spelling.",
      },
    },
  })

  local quickfix = vim.fn.getqflist({ items = 1, context = 1 })
  equal(#quickfix.items, 1)
  equal(quickfix.items[1].lnum, 4)
  equal(quickfix.items[1].col, 1)
  equal(quickfix.context.complete, true)
end)

test("ignore during review allows later findings to append", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "teh first.",
    "",
    "And teh second.",
  })

  local callbacks = {}
  review.setup({
    keymaps = {
      review = false,
      apply = false,
      apply_all = false,
      ignore = false,
    },
    review = { chunk_size = 15 },
    quickfix = { auto_open = false },
    _transport = function(_, _, callback)
      callbacks[#callbacks + 1] = callback
      return { kill = function() end }
    end,
  })

  review.review()
  equal(#callbacks, 1)

  callbacks[1](nil, {
    findings = {
      {
        type = "correction",
        category = "spelling",
        original = "teh",
        suggestion = "the",
        message = "Incorrect spelling.",
      },
    },
  })
  equal(review.ignore(), true)
  equal(#vim.fn.getqflist(), 0)

  callbacks[2](nil, {
    findings = {
      {
        type = "correction",
        category = "spelling",
        original = "teh",
        suggestion = "the",
        message = "Incorrect spelling.",
      },
    },
  })

  local quickfix = vim.fn.getqflist({ items = 1, context = 1 })
  equal(#quickfix.items, 1)
  equal(quickfix.items[1].lnum, 3)
  equal(quickfix.context.complete, true)
end)

test("external edit during streaming discards published findings", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "teh first.",
    "",
    "And teh second.",
  })

  local callbacks = {}
  review.setup({
    keymaps = { review = false },
    review = { chunk_size = 15 },
    quickfix = { auto_open = false },
    _transport = function(_, _, callback)
      callbacks[#callbacks + 1] = callback
      return { kill = function() end }
    end,
  })

  review.review()
  equal(#callbacks, 1)

  callbacks[1](nil, {
    findings = {
      {
        type = "correction",
        category = "spelling",
        original = "teh",
        suggestion = "the",
        message = "Incorrect spelling.",
      },
    },
  })
  equal(#vim.fn.getqflist(), 1)

  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "changed", "", "text" })
  callbacks[2](nil, { findings = {} })
  equal(#vim.fn.getqflist(), 0)
end)

test("cancel removes findings published by an active review", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "teh first.",
    "",
    "And teh second.",
  })

  local callbacks = {}
  review.setup({
    keymaps = { review = false },
    review = { chunk_size = 15 },
    quickfix = { auto_open = false },
    _transport = function(_, _, callback)
      callbacks[#callbacks + 1] = callback
      return { kill = function() end }
    end,
  })

  review.review()
  equal(#callbacks, 1)

  callbacks[1](nil, {
    findings = {
      {
        type = "correction",
        category = "spelling",
        original = "teh",
        suggestion = "the",
        message = "Incorrect spelling.",
      },
    },
  })
  equal(#vim.fn.getqflist(), 1)

  equal(review.cancel(), true)
  equal(#vim.fn.getqflist(), 0)

  callbacks[2](nil, { findings = {} })
  equal(#vim.fn.getqflist(), 0)
end)

test("quickfix opens on the first finding without stealing focus", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "teh text" })

  local source_window = vim.api.nvim_get_current_win()
  review.setup({
    keymaps = { review = false },
    quickfix = { auto_open = true },
    _transport = function(_, _, callback)
      callback(nil, {
        findings = {
          {
            type = "correction",
            category = "spelling",
            original = "teh",
            suggestion = "the",
            message = "Incorrect spelling.",
          },
        },
      })
      return { kill = function() end }
    end,
  })

  review.review()
  equal(vim.api.nvim_get_current_win(), source_window)
  local quickfix = vim.fn.getqflist({ id = 0, title = 1, items = 1 })
  equal(quickfix.title, "AI Proofread")
  equal(#quickfix.items, 1)

  local quickfix_window
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local info = vim.fn.getwininfo(window)[1]
    if info and info.quickfix == 1 then
      quickfix_window = window
      break
    end
  end
  assert(quickfix_window)
  assert(
    vim.api.nvim_win_get_height(quickfix_window)
      >= math.ceil(vim.o.lines / 3)
  )
  vim.cmd("cclose")
end)

test("quickfix Enter previews the finding and retains list focus", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "First line.",
    "This has teh mistake.",
  })

  local source_window = vim.api.nvim_get_current_win()
  review.setup({
    keymaps = { review = false },
    quickfix = {
      auto_open = true,
      keep_focus_on_select = true,
    },
    _transport = function(_, _, callback)
      callback(nil, {
        findings = {
          {
            type = "correction",
            category = "spelling",
            original = "teh",
            suggestion = "the",
            message = "Incorrect spelling.",
          },
        },
      })
      return { kill = function() end }
    end,
  })

  review.review()
  local quickfix_window
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local info = vim.fn.getwininfo(window)[1]
    if info and info.quickfix == 1 then
      quickfix_window = window
      break
    end
  end
  assert(quickfix_window)

  vim.api.nvim_set_current_win(quickfix_window)
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  equal(vim.api.nvim_get_current_win(), quickfix_window)
  equal(vim.api.nvim_win_get_cursor(source_window)[1], 2)
  vim.cmd("cclose")
end)

test("quickfix selection previews and applies the highlighted finding", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "Teh first line.",
    "A second line with teh error.",
  })
  local source_window = vim.api.nvim_get_current_win()

  review.setup({
    keymaps = { review = false, apply = false, apply_all = false },
    quickfix = { auto_open = true, keep_focus_on_select = true },
    _transport = function(_, _, callback)
      callback(nil, {
        findings = {
          {
            type = "correction",
            category = "spelling",
            original = "Teh",
            suggestion = "The",
            message = "First spelling.",
          },
          {
            type = "correction",
            category = "spelling",
            original = "teh",
            suggestion = "the",
            message = "Second spelling.",
          },
        },
      })
      return { kill = function() end }
    end,
  })

  review.review()
  local quickfix_window
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local info = vim.fn.getwininfo(window)[1]
    if info and info.quickfix == 1 and info.loclist == 0 then
      quickfix_window = window
      break
    end
  end
  assert(quickfix_window)
  equal(#vim.fn.getqflist(), 2)
  vim.api.nvim_set_current_win(quickfix_window)
  vim.api.nvim_win_set_cursor(quickfix_window, { 2, 0 })
  vim.api.nvim_set_current_win(source_window)
  equal(vim.fn.getqflist({ idx = 0 }).idx, 2)
  vim.api.nvim_set_current_win(quickfix_window)
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  equal(vim.api.nvim_get_current_win(), quickfix_window)
  equal(vim.api.nvim_win_get_cursor(source_window)[1], 2)
  equal(vim.fn.getqflist({ idx = 0 }).idx, 2)

  vim.api.nvim_set_current_win(source_window)
  equal(review.apply(), true)
  equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), {
    "Teh first line.",
    "A second line with the error.",
  })
  local remaining = vim.fn.getqflist({ items = 1, idx = 0 })
  equal(#remaining.items, 1)
  assert(remaining.items[1].text:find("First spelling.", 1, true))
  vim.cmd("cclose")
end)

test("apply from quickfix uses the highlighted row without Enter", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "Teh first line.",
    "A second line with teh error.",
  })
  review.setup({
    keymaps = { review = false, apply = false, apply_all = false },
    quickfix = { auto_open = true },
    _transport = function(_, _, callback)
      callback(nil, {
        findings = {
          {
            type = "correction",
            category = "spelling",
            original = "Teh",
            suggestion = "The",
            message = "First spelling.",
          },
          {
            type = "correction",
            category = "spelling",
            original = "teh",
            suggestion = "the",
            message = "Second spelling.",
          },
        },
      })
      return { kill = function() end }
    end,
  })
  review.review()
  vim.cmd("copen")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  equal(review.apply(), true)
  equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), {
    "Teh first line.",
    "A second line with the error.",
  })
  vim.cmd("cclose")
end)

test("quickfix setup does not configure an open location list", function()
  local review = require("ai-proofread")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "teh text" })
  local source_window = vim.api.nvim_get_current_win()
  vim.fn.setloclist(source_window, {
    { bufnr = buffer, lnum = 1, col = 1, text = "location" },
  }, "r")
  vim.cmd("lopen 3")
  vim.api.nvim_set_current_win(source_window)

  review.setup({
    keymaps = { review = false },
    quickfix = { auto_open = true },
    _transport = function(_, _, callback)
      callback(nil, {
        findings = {{
          type = "correction",
          category = "spelling",
          original = "teh",
          suggestion = "the",
          message = "Incorrect spelling.",
        }},
      })
      return { kill = function() end }
    end,
  })
  review.review()

  local quickfix_mapped = false
  local location_mapped = false
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local info = vim.fn.getwininfo(window)[1]
    if info and info.quickfix == 1 then
      local mapped = false
      for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(
        vim.api.nvim_win_get_buf(window),
        "n"
      )) do
        if mapping.desc == "Preview AI Proofread finding" then
          mapped = true
        end
      end
      if info.loclist == 1 then
        location_mapped = mapped
      else
        quickfix_mapped = mapped
      end
    end
  end
  equal(location_mapped, false)
  equal(quickfix_mapped, true)
  vim.cmd("cclose")
  vim.cmd("lclose")
end)

if failures > 0 then
  vim.cmd("cquit " .. failures)
end

vim.cmd("qa!")
