-- Quickfix presentation for validated findings.
-- Per ADR-035 the list is append-only: rebuilding it from the controller
-- accumulator would restore entries removed by apply or ignore.
-- See docs/arch/arch_design.adoc, Quickfix Integration.

local M = {}
local configured = {
  height_ratio = 1 / 3,
  keep_focus_on_select = true,
}
local current_id

local function quickfix_window()
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local info = vim.fn.getwininfo(window)[1]
    if info and info.quickfix == 1 and info.loclist == 0 then
      return window
    end
  end
end

-- Moving the quickfix cursor does not update getqflist().idx until the
-- built-in Enter action runs. Keep it in sync for previews and corrections.
function M.selected_index(quickfix)
  if quickfix.title ~= "AI Proofread" then
    return quickfix.idx
  end
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  if not info or info.quickfix ~= 1 or info.loclist ~= 0 then
    return quickfix.idx
  end
  local index = vim.api.nvim_win_get_cursor(0)[1]
  if index < 1 or index > #quickfix.items then
    return quickfix.idx
  end
  if index ~= quickfix.idx then
    vim.fn.setqflist({}, "a", { id = quickfix.id, idx = index })
  end
  return index
end

local function select_current()
  local quickfix = vim.fn.getqflist({
    id = 0,
    context = 1,
    idx = 0,
    items = 1,
    title = 1,
  })
  if quickfix.title ~= "AI Proofread" then
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "n", false)
    return
  end
  local index = M.selected_index(quickfix)
  if index < 1 then
    return
  end

  if not configured.keep_focus_on_select then
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "n", false)
    return
  end

  local item = quickfix.items[index]
  if not item or item.bufnr < 1 then
    return
  end
  if not vim.api.nvim_buf_is_valid(item.bufnr) then
    return
  end

  local target = quickfix.context
    and quickfix.context.source_window
    or nil
  if target and (not vim.api.nvim_win_is_valid(target)
      or vim.fn.getwininfo(target)[1].quickfix == 1)
  then
    target = nil
  end
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local info = vim.fn.getwininfo(window)[1]
    if info and info.quickfix == 0 then
      if vim.api.nvim_win_get_buf(window) == item.bufnr then
        target = window
        break
      end
    end
  end
  if not target then
    vim.notify(
      "AI Proofread: source window is no longer available",
      vim.log.levels.WARN
    )
    return
  end

  vim.api.nvim_win_set_buf(target, item.bufnr)
  local line_count = vim.api.nvim_buf_line_count(item.bufnr)
  local line_number = math.min(math.max(item.lnum, 1), line_count)
  local line = vim.api.nvim_buf_get_lines(
    item.bufnr,
    line_number - 1,
    line_number,
    true
  )[1] or ""
  vim.api.nvim_win_set_cursor(target, {
    line_number,
    math.min(math.max(item.col - 1, 0), #line),
  })
  vim.api.nvim_win_call(target, function()
    vim.cmd.normal({ args = { "zz" }, bang = true })
  end)
end

local function configure_window(window)
  if not window or not vim.api.nvim_win_is_valid(window) then
    return
  end

  local buffer = vim.api.nvim_win_get_buf(window)
  vim.keymap.set("n", "<CR>", select_current, {
    buffer = buffer,
    desc = "Preview AI Proofread finding",
    silent = true,
  })
end

function M.setup(config)
  configured = vim.tbl_extend("force", configured, config or {})

  local group = vim.api.nvim_create_augroup(
    "AIProofreadQuickfix",
    { clear = true }
  )
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "qf",
    callback = function(args)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(args.buf) and current_id() then
          configure_window(quickfix_window())
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(args)
      if vim.bo[args.buf].filetype == "qf" and current_id() then
        configure_window(quickfix_window())
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
      if not info or info.quickfix ~= 1 or info.loclist ~= 0 then
        return
      end
      local quickfix = vim.fn.getqflist({
        id = 0,
        idx = 0,
        items = 1,
        title = 1,
      })
      M.selected_index(quickfix)
    end,
  })
end

local function entry(buffer, finding)
  local function display(value)
    return value
      :gsub("\r", "\\r")
      :gsub("\n", "\\n")
      :gsub("\t", "\\t")
  end
  return {
    bufnr = buffer,
    lnum = finding.line,
    col = finding.column,
    end_lnum = finding.end_line,
    end_col = finding.end_column,
    type = "W",
    text = string.format(
      "[%s] %s Suggestion: %s",
      finding.category,
      display(finding.message),
      display(finding.suggestion)
    ),
    user_data = {
      ai_proofread_id = finding.application_id,
    },
  }
end

local function sort_items(items)
  table.sort(items, function(left, right)
    return left.lnum < right.lnum
      or (left.lnum == right.lnum and left.col < right.col)
  end)
end

-- Progress lives in context so the list title can remain fixed.
local function context_for(review)
  local result = review.result
  return {
    -- False until finish(), and false afterwards for partial reviews.
    complete = review.finished and result.complete,
    rejected = #result.rejected_findings,
    failed_chunks = #result.failed_chunks,
    unreviewable_sections = #(result.unreviewable_sections or {}),
    chunks_done = review.index,
    chunks_total = #review.chunks,
    review_id = review.id,
    source_window = review.source_window,
  }
end

current_id = function()
  local list = vim.fn.getqflist({ id = 0, title = 1 })
  if list.title ~= "AI Proofread" then
    return nil
  end
  return list.id
end

local function create(review)
  vim.fn.setqflist({}, "r", {
    title = "AI Proofread",
    items = {},
    context = context_for(review),
  })
  review.quickfix_id = vim.fn.getqflist({ id = 0 }).id
  review.quickfix_opened = false
end

-- Refresh context without reconstructing entries. `idx = 0` requests every
-- item; `idx = 1` filters the result to the current entry and truncates the
-- list on the following write.
local function rewrite(review, id)
  local list = vim.fn.getqflist({ id = id, items = 1, idx = 0 })
  vim.fn.setqflist({}, "r", {
    id = id,
    title = "AI Proofread",
    items = list.items,
    idx = list.idx,
    context = context_for(review),
  })
  return #list.items
end

-- Append one validated batch. The window opens once, on the first published
-- finding, and the source window is restored immediately afterwards.
function M.append(review, findings)
  local id = review.quickfix_id
  if not id or current_id() ~= id then
    create(review)
    id = review.quickfix_id
  end

  local items = {}
  for _, finding in ipairs(findings) do
    items[#items + 1] = entry(review.buffer, finding)
  end
  sort_items(items)

  if #items > 0 then
    vim.fn.setqflist({}, "a", { id = id, items = items })
  end

  local count = rewrite(review, id)
  local config = review.config.quickfix
  if config.auto_open and not review.quickfix_opened and count > 0 then
    local source_window = vim.api.nvim_get_current_win()
    local height = math.max(
      1,
      math.ceil(vim.o.lines * config.height_ratio)
    )
    vim.cmd("botright copen " .. height)
    local window = quickfix_window()
    if window then
      vim.api.nvim_win_set_height(window, height)
      configure_window(window)
    end
    if vim.api.nvim_win_is_valid(source_window) then
      vim.api.nvim_set_current_win(source_window)
    end
    review.quickfix_opened = true
  end
end

function M.finish(review)
  local id = review.quickfix_id
  if not id or current_id() ~= id then
    create(review)
    id = review.quickfix_id
  end
  rewrite(review, id)
end

-- Extmarks are authoritative after a plugin-originated edit. Preserve the
-- existing context while swapping in the refreshed coordinates.
function M.refresh_positions(id, positions)
  if not id or current_id() ~= id then
    return
  end

  local list = vim.fn.getqflist({ id = id, items = 1, idx = 0 })
  for _, item in ipairs(list.items) do
    local user_data = item.user_data
    local key = type(user_data) == "table"
        and user_data.ai_proofread_id
      or nil
    local position = key and positions[key] or nil
    if position then
      item.lnum = position.lnum
      item.col = position.col
      item.end_lnum = position.end_lnum
      item.end_col = position.end_col
    end
  end

  vim.fn.setqflist({}, "r", {
    id = id,
    title = "AI Proofread",
    items = list.items,
    idx = list.idx,
    context = list.context,
  })
end

-- Used by cancel and stale detection; unrelated quickfix lists are untouched.
function M.clear(id)
  local list = vim.fn.getqflist({ id = id or 0, title = 1 })
  if list.title ~= "AI Proofread" then
    return
  end
  vim.fn.setqflist({}, "r", {
    id = list.id,
    title = "AI Proofread",
    items = {},
    context = { complete = false },
  })
end

return M
