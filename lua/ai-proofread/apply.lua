-- Correction application state and extmark tracking.
-- Source verification lives in validate.lua under ADR-016, ADR-019 and
-- ADR-021. ADR-035 adds the edit notifications that let the controller
-- rebase an active review after a plugin-originated edit.
-- See docs/arch/arch_design.adoc: Correction Applier and Correction
-- Application.

local M = {}

local namespace = vim.api.nvim_create_namespace("ai-proofread-apply")
local states = {}

local function notify(message, level)
  vim.notify("AI Proofread: " .. message, level or vim.log.levels.INFO)
end

local function position_less(left_row, left_col, right_row, right_col)
  return left_row < right_row
    or (left_row == right_row and left_col < right_col)
end

local function split_replacement(text)
  return vim.split(text, "\n", { plain = true })
end

-- Quickfix columns and rebase deltas are byte-oriented, never screen columns.
local function byte_offset(buffer, row, column)
  local lines = vim.api.nvim_buf_get_lines(buffer, 0, row, false)
  local offset = 1
  for _, line in ipairs(lines) do
    offset = offset + #line + 1
  end
  return offset + column
end

-- Report a plugin-originated edit to the owning controller. It uses the byte
-- delta to rebase the chunks that have not been validated yet.
local function notify_edit(buffer, edits)
  local state = states[buffer]
  local listener = state and state.listener
  if listener then
    pcall(listener, edits)
  end
end

-- Remove entries by immutable user_data id while preserving list context.
local function remove_quickfix_entries(ids)
  local quickfix = vim.fn.getqflist({
    id = 0,
    idx = 0,
    items = 1,
    title = 1,
    context = 1,
  })
  if quickfix.title ~= "AI Proofread" then
    return
  end

  local items = {}
  for _, item in ipairs(quickfix.items) do
    local user_data = item.user_data
    local id = type(user_data) == "table"
        and user_data.ai_proofread_id
      or nil
    if not ids[id] then
      items[#items + 1] = item
    end
  end

  vim.fn.setqflist({}, "r", {
    id = quickfix.id,
    title = quickfix.title,
    context = quickfix.context,
    items = items,
  })
  if #items > 0 then
    vim.fn.setqflist({}, "a", {
      id = quickfix.id,
      idx = math.min(quickfix.idx, #items),
    })
  end
end

-- The extmark follows edits, but the exact source slice is checked again
-- before any buffer change is allowed.
local function resolve(finding)
  local mark = vim.api.nvim_buf_get_extmark_by_id(
    finding.buffer,
    namespace,
    finding.extmark,
    { details = true }
  )
  if #mark == 0 then
    return nil, "correction range is no longer available"
  end

  local details = mark[3]
  local range = {
    start_row = mark[1],
    start_col = mark[2],
    end_row = details.end_row,
    end_col = details.end_col,
  }
  local current = table.concat(vim.api.nvim_buf_get_text(
    finding.buffer,
    range.start_row,
    range.start_col,
    range.end_row,
    range.end_col,
    {}
  ), "\n")
  if current ~= finding.source_text then
    return nil, "source text changed; correction was not applied"
  end

  return range
end

local function edit(buffer, range, replacement, join)
  vim.api.nvim_buf_call(buffer, function()
    if join then
      vim.cmd("undojoin")
    end
    vim.api.nvim_buf_set_text(
      buffer,
      range.start_row,
      range.start_col,
      range.end_row,
      range.end_col,
      split_replacement(replacement)
    )
  end)
end

local function state_for_quickfix()
  local quickfix = vim.fn.getqflist({
    id = 0,
    idx = 0,
    items = 1,
    title = 1,
  })
  local index = require("ai-proofread.quickfix").selected_index(quickfix)
  local item = quickfix.items[index]
  if not item then
    return nil, nil, "no current AI Proofread finding"
  end

  local user_data = item.user_data
  local id = type(user_data) == "table"
      and user_data.ai_proofread_id
    or nil
  local state = states[item.bufnr]
  local finding = state and state.by_id[id] or nil
  if not finding then
    return nil, nil, "current quickfix entry is not an active correction"
  end

  return state, finding
end

local function state_for_all()
  local buffer = vim.api.nvim_get_current_buf()
  if states[buffer] then
    return states[buffer]
  end

  local state = state_for_quickfix()
  return state
end

-- State is additive per review: a buffer accumulates findings from several
-- published chunks under the same review id.
local function state_for(buffer, review_id)
  local state = states[buffer]
  if not state or state.review_id ~= review_id then
    state = {
      buffer = buffer,
      review_id = review_id,
      findings = {},
      by_id = {},
    }
    states[buffer] = state
  end
  return state
end

-- Register a published batch with stable ids allocated by the controller.
-- Extmarks move with intervening edits and later supply quickfix positions.
function M.add(buffer, review_id, findings, first_index)
  if #findings == 0 then
    return
  end

  local state = state_for(buffer, review_id)

  for index, finding in ipairs(findings) do
    local id = review_id .. ":" .. (first_index + index - 1)
    local tracked = vim.deepcopy(finding)
    tracked.application_id = id
    tracked.buffer = buffer
    tracked.applied = false
    tracked.ignored = false
    tracked.extmark = vim.api.nvim_buf_set_extmark(
      buffer,
      namespace,
      finding.line - 1,
      finding.column - 1,
      {
        end_row = finding.end_line - 1,
        end_col = finding.end_column,
        right_gravity = false,
        end_right_gravity = true,
      }
    )
    finding.application_id = id
    state.findings[#state.findings + 1] = tracked
    state.by_id[id] = tracked
  end
end

function M.register(buffer, review_id, findings)
  M.reset(buffer)
  M.add(buffer, review_id, findings, 1)
end

function M.reset(buffer)
  if vim.api.nvim_buf_is_valid(buffer) then
    vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  end
  states[buffer] = nil
end

-- The controller listener receives only plugin-originated edit deltas.
function M.set_listener(buffer, review_id, callback)
  local state = state_for(buffer, review_id)
  state.listener = callback
end

-- Read positions from extmarks, not from the original model coordinates.
function M.positions(buffer)
  local state = states[buffer]
  local positions = {}
  if not state then
    return positions
  end

  for _, finding in ipairs(state.findings) do
    local mark = vim.api.nvim_buf_get_extmark_by_id(
      buffer,
      namespace,
      finding.extmark,
      { details = true }
    )
    if #mark >= 2 then
      local details = mark[3] or {}
      positions[finding.application_id] = {
        lnum = mark[1] + 1,
        col = mark[2] + 1,
        end_lnum = (details.end_row or mark[1]) + 1,
        end_col = details.end_col or mark[2],
      }
    end
  end
  return positions
end

-- Apply only after exact source verification, then report the byte delta.
function M.current()
  local _, finding, err = state_for_quickfix()
  if not finding then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end
  if finding.applied then
    local message = "correction has already been applied"
    notify(message, vim.log.levels.WARN)
    return nil, message
  end

  local range, range_err = resolve(finding)
  if not range then
    notify(range_err, vim.log.levels.WARN)
    return nil, range_err
  end

  local start_byte = byte_offset(
    finding.buffer,
    range.start_row,
    range.start_col
  )

  edit(finding.buffer, range, finding.suggestion, false)
  finding.applied = true
  pcall(
    vim.api.nvim_buf_del_extmark,
    finding.buffer,
    namespace,
    finding.extmark
  )
  remove_quickfix_entries({ [finding.application_id] = true })
  notify_edit(finding.buffer, {
    {
      start_byte = start_byte,
      delta_bytes = #finding.suggestion - #finding.source_text,
    },
  })
  notify("applied correction")
  return true
end

-- Ignoring changes no buffer text, so no rebase notification is needed.
function M.ignore()
  local _, finding, err = state_for_quickfix()
  if not finding then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  finding.ignored = true
  pcall(
    vim.api.nvim_buf_del_extmark,
    finding.buffer,
    namespace,
    finding.extmark
  )
  remove_quickfix_entries({ [finding.application_id] = true })
  notify("ignored correction")
  return true
end

-- Preflight every range before editing. Edits run from the end of the buffer
-- towards the start, are joined into one undo step, and the aggregate deltas
-- are reported once.
local function apply_findings(state, findings)
  local pending = {}
  for _, finding in ipairs(findings) do
    if not finding.applied and not finding.ignored then
      local range, err = resolve(finding)
      if not range then
        notify(err, vim.log.levels.WARN)
        return nil, err
      end
      pending[#pending + 1] = {
        finding = finding,
        range = range,
        start_byte = byte_offset(
          state.buffer,
          range.start_row,
          range.start_col
        ),
      }
    end
  end

  if #pending == 0 then
    local message = "no unapplied corrections"
    notify(message, vim.log.levels.INFO)
    return nil, message
  end

  table.sort(pending, function(left, right)
    return position_less(
      left.range.start_row,
      left.range.start_col,
      right.range.start_row,
      right.range.start_col
    )
  end)
  for index = 2, #pending do
    local previous = pending[index - 1].range
    local current = pending[index].range
    if position_less(
      current.start_row,
      current.start_col,
      previous.end_row,
      previous.end_col
    ) then
      local message = "overlapping corrections were not applied"
      notify(message, vim.log.levels.WARN)
      return nil, message
    end
  end

  local ok, edit_err = pcall(function()
    for index = #pending, 1, -1 do
      local correction = pending[index]
      edit(
        state.buffer,
        correction.range,
        correction.finding.suggestion,
        index < #pending
      )
    end
  end)
  if not ok then
    pcall(vim.api.nvim_buf_call, state.buffer, function()
      vim.cmd("undo")
    end)
    local message = "bulk application failed: " .. tostring(edit_err)
    notify(message, vim.log.levels.ERROR)
    return nil, message
  end

  for _, correction in ipairs(pending) do
    correction.finding.applied = true
    pcall(
      vim.api.nvim_buf_del_extmark,
      state.buffer,
      namespace,
      correction.finding.extmark
    )
  end
  local applied_ids = {}
  for _, correction in ipairs(pending) do
    applied_ids[correction.finding.application_id] = true
  end
  remove_quickfix_entries(applied_ids)

  local edits = {}
  for _, correction in ipairs(pending) do
    edits[#edits + 1] = {
      start_byte = correction.start_byte,
      delta_bytes = #correction.finding.suggestion
        - #correction.finding.source_text,
    }
  end
  notify_edit(state.buffer, edits)

  notify(string.format("applied %d corrections", #pending))
  return true
end

function M.all()
  local state = state_for_all()
  if not state then
    local message = "no active corrections for this buffer"
    notify(message, vim.log.levels.ERROR)
    return nil, message
  end
  return apply_findings(state, state.findings)
end

-- Explicit Ex ranges refer to quickfix rows, not source-buffer lines.
function M.range(first, last)
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  local quickfix = vim.fn.getqflist({
    id = 0,
    items = 1,
    title = 1,
    context = 1,
  })
  if not info or info.quickfix ~= 1 or info.loclist ~= 0
    or quickfix.title ~= "AI Proofread"
    or type(quickfix.context) ~= "table"
    or first < 1 or first > last or last > #quickfix.items
  then
    local message = "select entries in the AI Proofread quickfix window"
    notify(message, vim.log.levels.ERROR)
    return nil, message
  end

  local findings
  local state
  for index = first, last do
    local item = quickfix.items[index]
    local user_data = item.user_data
    local id = type(user_data) == "table"
        and user_data.ai_proofread_id
      or nil
    local candidate = states[item.bufnr]
    local finding = candidate and candidate.by_id[id] or nil
    if not finding or candidate.review_id ~= quickfix.context.review_id
      or (state and state ~= candidate)
    then
      local message = "selected quickfix entry is not an active correction"
      notify(message, vim.log.levels.ERROR)
      return nil, message
    end
    state = candidate
    findings = findings or {}
    findings[#findings + 1] = finding
  end

  return apply_findings(state, findings)
end

return M
