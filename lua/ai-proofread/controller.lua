local adapters = require("ai-proofread.adapters")
local apply = require("ai-proofread.apply")
local fm = require("ai-proofread.fm")
local ollama = require("ai-proofread.ollama")
local progress = require("ai-proofread.progress")
local prompt = require("ai-proofread.prompt")
local quickfix = require("ai-proofread.quickfix")
local schema = require("ai-proofread.schema")
local sentence = require("ai-proofread.sentence")
local validator = require("ai-proofread.validate")

-- Streaming review orchestration.
-- ADR-035 defines per-chunk publication and rebase after a plugin-originated
-- apply. ADR-011 still governs stale results from external edits.
-- See docs/arch/arch_design.adoc: Review Controller, Scheduling,
-- Quickfix Integration and Cancellation.

local M = {}

-- One review per buffer; starting another supersedes the active review.
local active = {}

-- Monotonic request identifier, used to build stable finding IDs.
local sequence = 0

local function notify(message, level)
  vim.notify("AI Proofread: " .. message, level or vim.log.levels.INFO)
end

local function is_current(review)
  return active[review.buffer] == review
end

local function snapshot_valid(review)
  return vim.api.nvim_buf_is_valid(review.buffer)
    and vim.api.nvim_buf_get_changedtick(review.buffer) == review.changedtick
end

-- The on-device fm context is smaller than the default review chunk. It needs
-- a tighter byte budget to keep structured responses inside that context.
local function chunk_budget(config)
  if config.backend == "fm" and config.fm.chunk_size then
    return config.fm.chunk_size
  end
  return config.review.chunk_size
end

-- Stop the request and remove every artefact published by this review.
-- Explicit cancellation and stale external edits share this cleanup path.
local function discard(review, message, level)
  if review.process and review.process.kill then
    pcall(review.process.kill, review.process, 15)
  end
  active[review.buffer] = nil
  apply.reset(review.buffer)
  quickfix.clear(review.quickfix_id)
  progress.stop(review.buffer, "cancel", "cancelled")
  if message then
    notify(message, level)
  end
end

-- Shift work that has not been validated yet by plugin-originated edits.
--
-- Only published findings can be applied, so every edit precedes the
-- in-flight chunk and all later chunks. Published positions are refreshed
-- from extmarks, which already followed the edit. Advancing changedtick
-- keeps the baseline in step with our own edit; any later change is
-- therefore an external edit.
local function rebase(review, edits)
  if not is_current(review) then
    return
  end

  local total = 0
  for _, edit in ipairs(edits) do
    total = total + edit.delta_bytes
  end

  if total ~= 0 then
    review.snapshot_text = table.concat(
      vim.api.nvim_buf_get_lines(review.buffer, 0, -1, true),
      "\n"
    )
    for index = review.index, #review.chunks do
      local chunk = review.chunks[index]
      chunk.source_start_byte = chunk.source_start_byte + total
      chunk.source_end_byte = chunk.source_end_byte + total
      for relative, absolute in pairs(chunk.offset_map) do
        chunk.offset_map[relative] = absolute + total
      end
      for _, protected in ipairs(chunk.protected_spans or {}) do
        protected.start_byte = protected.start_byte + total
        protected.end_byte = protected.end_byte + total
      end
      chunk.document_text = review.snapshot_text
    end
  end

  review.changedtick = vim.api.nvim_buf_get_changedtick(review.buffer)
  quickfix.refresh_positions(review.quickfix_id, apply.positions(review.buffer))
end

-- Finalise context after every chunk has returned or failed.
-- `finished` gates context.complete, while `result.complete` records
-- partial failure and stays false for an incomplete review.
local function finish(review)
  if not is_current(review) then
    return
  end

  if not snapshot_valid(review) then
    discard(review, "buffer changed; discarded stale results", vim.log.levels.WARN)
    return
  end

  active[review.buffer] = nil
  review.finished = true
  apply.set_listener(review.buffer, review.id, nil)
  quickfix.finish(review)

  local detail = string.format(
    "%d findings, %d rejected",
    #review.result.valid_findings,
    #review.result.rejected_findings
  )
  progress.stop(
    review.buffer,
    review.result.complete and "success" or "failed",
    (review.result.complete and "complete: " or "incomplete: ") .. detail
  )

  if not review.result.complete then
    notify("review incomplete; inspect quickfix context", vim.log.levels.WARN)
  end
end

local function publish(review, findings)
  if #findings == 0 then
    return
  end

  -- IDs come from the published count and never change once visible.
  local first_index = review.published + 1
  review.published = review.published + #findings
  apply.add(review.buffer, review.id, findings, first_index)
  vim.list_extend(review.result.valid_findings, findings)
  quickfix.append(review, findings)
end

local function record_rejections(review, rejected)
  vim.list_extend(review.result.rejected_findings, rejected)
end

local function request_for(review, review_prompt, rewrite)
  if review.config.backend == "fm" then
    local request_schema = rewrite and fm.rewrite_schema_path() or nil
    return fm,
      review.config.fm,
      fm.build_request(review_prompt, prompt.system, request_schema)
  end

  local format = rewrite and schema.rewrite() or nil
  return ollama,
    review.config.ollama,
    ollama.build_request(
      review.config.ollama.model,
      review_prompt,
      prompt.system,
      review.config.ollama.keep_alive,
      format
    )
end

-- A focused retry repairs one code-detected candidate whose first rewrite
-- was a no-op or failed the bounded split rule. It never broadens the set of
-- rewritable sentences and never delays publication of other findings.
local function retry_rewrites(review, chunk, candidates, done)
  local position = 1

  local function next_request()
    if not is_current(review) then
      return
    end
    if not snapshot_valid(review) then
      discard(review, "buffer changed; discarded stale results", vim.log.levels.WARN)
      return
    end

    local candidate = candidates[position]
    if not candidate then
      done()
      return
    end
    local retry_index = position
    position = position + 1

    progress.update(
      review,
      string.format(
        "rewrite retry %d/%d",
        retry_index,
        #candidates
      )
    )

    local retry_prompt = prompt.build_rewrite(
      candidate.text,
      review.config.long_sentence.max_words
    )
    local provider, provider_config, payload = request_for(
      review,
      retry_prompt,
      true
    )
    local send = review.config._transport or provider.request

    local handle = send(provider_config, payload, function(err, document)
      if not is_current(review) then
        return
      end
      if not snapshot_valid(review) then
        discard(review, "buffer changed; discarded stale results", vim.log.levels.WARN)
        return
      end

      if err then
        record_rejections(review, {
          {
            finding = {
              category = "long_sentence",
              original = candidate.text,
            },
            reason = validator.RejectionReason.REWRITE_RETRY_FAILED,
          },
        })
        next_request()
        return
      end

      local findings, envelope_error = validator.validate_document(document)
      if not findings then
        record_rejections(review, {
          {
            finding = {
              category = "long_sentence",
              original = candidate.text,
            },
            reason = envelope_error,
          },
        })
        next_request()
        return
      end

      local validation = validator.validate_findings(
        findings,
        chunk,
        review.config
      )
      publish(review, validation.valid)
      record_rejections(review, validation.rejected)
      next_request()
    end)
    review.process = handle
  end

  next_request()
end

-- Submit one chunk at a time and publish its result before scheduling the
-- next request. Failures append an empty batch so progress advances without
-- removing findings that are already visible.
local function process_next(review)
  if not is_current(review) then
    return
  end

  local next_index = review.index + 1
  local chunk = review.chunks[next_index]
  if not chunk then
    finish(review)
    return
  end
  review.index = next_index
  progress.update(
    review,
    string.format("requesting chunk %d/%d", review.index, #review.chunks)
  )

  if not snapshot_valid(review) then
    discard(review, "buffer changed; discarded stale results", vim.log.levels.WARN)
    return
  end

  if chunk.unreviewable then
    review.result.complete = false
    review.result.unreviewable_sections[#review.result.unreviewable_sections + 1] = {
      start_byte = chunk.source_start_byte,
      end_byte = chunk.source_end_byte,
    }
    quickfix.append(review, {})
    process_next(review)
    return
  end

  chunk.long_sentence_candidates = {}
  if review.config.checks.long_sentence then
    chunk.long_sentence_candidates = sentence.long_candidates(
      chunk,
      review.config.long_sentence.max_words
    )
  end

  local review_prompt = prompt.build(
    chunk.review_text,
    review.config.checks,
    review.config.long_sentence
  )
  local provider, provider_config, payload = request_for(
    review,
    review_prompt,
    false
  )
  local send = review.config._transport or provider.request

  review.process = send(provider_config, payload, function(err, document)
    if not is_current(review) then
      return
    end

    if not snapshot_valid(review) then
      discard(review, "buffer changed; discarded stale results", vim.log.levels.WARN)
      return
    end

    if err then
      review.result.complete = false
      review.result.failed_chunks[#review.result.failed_chunks + 1] = {
        index = review.index,
        reason = err,
      }
      quickfix.append(review, {})
      process_next(review)
      return
    end

    local findings, envelope_error = validator.validate_document(document)
    if not findings then
      review.result.complete = false
      review.result.failed_chunks[#review.result.failed_chunks + 1] = {
        index = review.index,
        reason = envelope_error,
      }
      quickfix.append(review, {})
      process_next(review)
      return
    end

    local validation = validator.validate_findings(
      findings,
      chunk,
      review.config
    )
    publish(review, validation.valid)

    local candidates, retryable = validator.retry_candidates(
      validation.rejected,
      chunk
    )
    local final_rejections = {}
    for index, rejection in ipairs(validation.rejected) do
      if not retryable[index] then
        final_rejections[#final_rejections + 1] = rejection
      end
    end
    record_rejections(review, final_rejections)

    if #candidates == 0 then
      process_next(review)
      return
    end

    retry_rewrites(review, chunk, candidates, function()
      process_next(review)
    end)
  end)
end

-- Prepare the snapshot baseline and register the edit listener before the
-- first request. The listener is what distinguishes plugin-originated edits
-- from external changes during streaming.
function M.start(buffer, config, selection)
  local filetype = vim.bo[buffer].filetype
  if not config.filetypes[filetype] or not adapters.supports(filetype) then
    notify("unsupported filetype: " .. filetype, vim.log.levels.ERROR)
    return nil
  end

  M.cancel(buffer, true)
  apply.reset(buffer)
  quickfix.clear()

  local text = table.concat(
    vim.api.nvim_buf_get_lines(buffer, 0, -1, true),
    "\n"
  )
  local chunks, err = adapters.prepare(
    filetype,
    text,
    chunk_budget(config),
    config.review.hard_limit,
    selection
  )
  if not chunks then
    notify(err, vim.log.levels.ERROR)
    return nil
  end

  sequence = sequence + 1
  local review = {
    id = sequence,
    buffer = buffer,
    source_window = vim.api.nvim_get_current_win(),
    changedtick = vim.api.nvim_buf_get_changedtick(buffer),
    config = config,
    chunks = chunks,
    index = 0,
    published = 0,
    finished = false, -- Gates the final quickfix context.complete value.
    snapshot_text = text,
    result = {
      complete = true,
      valid_findings = {},
      rejected_findings = {},
      failed_chunks = {},
      unreviewable_sections = {},
    },
  }
  active[buffer] = review
  apply.set_listener(buffer, review.id, function(edits)
    rebase(review, edits)
  end)
  progress.start(review)
  process_next(review)
  return review.id
end

function M.status(buffer)
  return progress.format(buffer)
end

-- Explicit cancellation uses the same cleanup path as stale detection.
function M.cancel(buffer, silent)
  local review = active[buffer]
  if not review then
    return false
  end

  discard(review, silent and nil or "review cancelled")
  return true
end

return M
