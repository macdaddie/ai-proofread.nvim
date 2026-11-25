local config_module = require("ai-proofread.config")

local M = {}
local current_config = config_module.merge({})

local function notify(message, level)
  vim.notify("AI Proofread: " .. message, level or vim.log.levels.INFO)
end

local function character_width(line, column)
  local leading = line:byte(column + 1)
  if not leading or leading < 0x80 then
    return 1
  end
  if leading < 0xE0 then
    return 2
  end
  if leading < 0xF0 then
    return 3
  end
  return 4
end

local function visual_selection(buffer)
  local mode = vim.fn.visualmode()
  if mode == "\22" then
    return nil, "blockwise visual review is not supported"
  end

  local first = vim.api.nvim_buf_get_mark(buffer, "<")
  local last = vim.api.nvim_buf_get_mark(buffer, ">")
  if first[1] == 0 or last[1] == 0 then
    return nil, "no visual selection is available"
  end

  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, true)
  if not lines[first[1]] or not lines[last[1]] then
    return nil, "visual selection is no longer valid"
  end
  local starts = {}
  local absolute = 1
  for row, line in ipairs(lines) do
    starts[row] = absolute
    absolute = absolute + #line + 1
  end

  local start_column = mode == "V" and 0 or first[2]
  local end_column
  if mode == "V" then
    end_column = #lines[last[1]] - 1
  else
    end_column = last[2]
      + character_width(lines[last[1]], last[2])
      - 1
  end

  local selection = {
    start_byte = starts[first[1]] + start_column,
    end_byte = starts[last[1]] + end_column,
  }
  if selection.end_byte < selection.start_byte then
    return nil, "visual selection is empty"
  end
  return selection
end

function M.setup(options)
  options = options or {}

  local valid, err = config_module.validate(options)
  if not valid then
    error("ai-proofread: " .. err)
  end

  current_config = config_module.merge(options)
  require("ai-proofread.quickfix").setup(
    current_config.quickfix,
    current_config.keymaps.apply
  )

  local mappings = {
    review = {
      callback = M.review,
      desc = "Review buffer prose",
      mode = "n",
    },
    review_selection = {
      callback = M.review_selection,
      desc = "Review selected prose",
      mode = "x",
    },
    apply = { callback = M.apply, desc = "Apply review correction" },
    apply_all = {
      callback = M.apply_all,
      desc = "Apply all review corrections",
    },
    ignore = {
      callback = M.ignore,
      desc = "Ignore review correction",
    },
  }
  for name, definition in pairs(mappings) do
    local mapping = current_config.keymaps[name]
    if type(mapping) == "string" and mapping ~= "" then
      vim.keymap.set(definition.mode or "n", mapping, definition.callback, {
        desc = definition.desc,
        silent = true,
      })
    end
  end

  if current_config.backend == "ollama"
    and current_config.ollama.preload
  then
    local ollama = require("ai-proofread.ollama")
    local preload = current_config._preload_transport or ollama.preload
    preload(current_config.ollama, function(preload_error, _, detail)
      if preload_error then
        local message = "model preload failed: " .. preload_error
        if detail then
          message = message .. ": " .. detail
        end
        notify(message, vim.log.levels.DEBUG)
      end
    end)
  end

  return current_config
end

function M.get_config()
  return vim.deepcopy(current_config)
end

function M.review()
  return require("ai-proofread.controller").start(
    vim.api.nvim_get_current_buf(),
    current_config
  )
end

function M.review_selection()
  local buffer = vim.api.nvim_get_current_buf()
  local selection, err = visual_selection(buffer)
  if not selection then
    notify(err, vim.log.levels.ERROR)
    return nil
  end
  return require("ai-proofread.controller").start(
    buffer,
    current_config,
    selection
  )
end

function M.cancel()
  return require("ai-proofread.controller").cancel(
    vim.api.nvim_get_current_buf()
  )
end

function M.status()
  return require("ai-proofread.controller").status(
    vim.api.nvim_get_current_buf()
  )
end

function M.health()
  return require("ai-proofread.health").check(current_config)
end

function M.apply(first, last)
  if first then
    return require("ai-proofread.apply").range(first, last)
  end
  return require("ai-proofread.apply").current()
end

function M.apply_all()
  return require("ai-proofread.apply").all()
end

function M.ignore()
  return require("ai-proofread.apply").ignore()
end

return M
