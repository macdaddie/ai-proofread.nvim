-- Visible review progress for Neovim 0.12 and later.
-- A stable message id updates one progress message instead of filling the
-- message history with one notification per chunk.

local uv = vim.uv or vim.loop

local M = {}
local active = {}

local function elapsed_seconds(state)
  return math.floor((uv.hrtime() - state.started) / 1e9)
end

local function render(state, status)
  if not state then
    return
  end

  local total = state.total or 0
  local done = state.review and state.review.index or 0
  local percent = total > 0
    and math.min(100, math.floor(done * 100 / total))
    or 0
  local position = "preparing"
  if total > 0 and done > 0 then
    position = string.format("chunk %d/%d", math.min(done, total), total)
  end
  local message = string.format(
    "%s: %s, %s (%ds)",
    state.backend,
    position,
    state.phase,
    elapsed_seconds(state)
  )

  vim.api.nvim_echo({ { message } }, true, {
    id = state.id,
    kind = "progress",
    title = "AI Proofread",
    source = state.backend,
    percent = percent,
    status = status or "running",
  })
end

local function close_timer(state)
  if not state.timer then
    return
  end
  state.timer:stop()
  state.timer:close()
  state.timer = nil
end

function M.start(review)
  if active[review.buffer] then
    close_timer(active[review.buffer])
  end

  local state = {
    review = review,
    buffer = review.buffer,
    id = "ai-proofread:" .. review.id,
    backend = review.config.backend,
    total = #review.chunks,
    phase = "starting",
    started = uv.hrtime(),
    timer = uv.new_timer(),
  }
  active[review.buffer] = state

  state.timer:start(2000, 2000, function()
    vim.schedule(function()
      if active[review.buffer] == state then
        render(state, "running")
      end
    end)
  end)
  render(state, "running")
end

function M.update(review, phase)
  local state = active[review.buffer]
  if not state or state.review ~= review then
    return
  end
  if phase then
    state.phase = phase
  end
  render(state, "running")
end

function M.stop(buffer, status, phase)
  local state = active[buffer]
  if not state then
    return
  end
  active[buffer] = nil
  close_timer(state)
  if phase then
    state.phase = phase
  end
  render(state, status or "success")
end

function M.status(buffer)
  local state = active[buffer or vim.api.nvim_get_current_buf()]
  if not state then
    return nil
  end

  local total = state.total or 0
  local done = state.review and state.review.index or 0
  return {
    backend = state.backend,
    done = done,
    total = total,
    percent = total > 0
      and math.min(100, math.floor(done * 100 / total))
      or 0,
    phase = state.phase,
    elapsed = elapsed_seconds(state),
    running = true,
  }
end

function M.format(buffer)
  local status = M.status(buffer)
  if not status then
    return ""
  end
  if status.total == 0 then
    return string.format(
      "AI Proofread: %s starting (%ds)",
      status.backend,
      status.elapsed
    )
  end
  if status.done == 0 then
    return string.format(
      "AI Proofread: %s starting %s (%ds)",
      status.backend,
      status.phase,
      status.elapsed
    )
  end
  return string.format(
    "AI Proofread: %s %d/%d %s (%ds)",
    status.backend,
    math.min(status.done, status.total),
    status.total,
    status.phase,
    status.elapsed
  )
end

return M
