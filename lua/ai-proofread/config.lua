-- AI Proofread: Configuration
-- Default settings and user configuration validation

local M = {}

---Default configuration
M.default_config = {
  language = "en-GB",
  backend = "ollama",

  ollama = {
    url = "http://127.0.0.1:11434",
    model = "gemma4:12b-it-qat",
    temperature = 0,
    timeout_ms = 120000,
    preload = false,
    preload_timeout_ms = 120000,
  },

  fm = {
    command = "fm",
    model = "system",
    timeout_ms = 30000,
    chunk_size = 800,
  },

  filetypes = {
    asciidoc = true,
    markdown = true,
    text = true,
  },

  checks = {
    spelling = true,
    grammar = true,
    punctuation = true,
    long_sentence = true,
  },

  long_sentence = {
    max_words = 30,
  },

  review = {
    chunk_size = 2500,
    hard_limit = 12000,
    max_concurrent = 1,
  },

  quickfix = {
    auto_open = true,
    height_ratio = 1 / 3,
    keep_focus_on_select = true,
  },

  keymaps = {
    review = "<leader>ar",
    review_selection = "<leader>ar",
    apply = "<leader>aa",
    apply_all = "<leader>aA",
    ignore = "<leader>ai",
  },
}

local supported_checks = {
  spelling = true,
  grammar = true,
  punctuation = true,
  long_sentence = true,
}

local function is_loopback_url(url)
  if type(url) ~= "string" then
    return false
  end
  local authority, suffix = url:match("^https?://([^/]+)(.*)$")
  if not authority or (suffix ~= "" and suffix ~= "/") then
    return false
  end
  authority = authority:lower()
  local host, port
  if authority == "[::1]" then
    host, port = authority, nil
  elseif authority:match("^%[::1%]:") then
    host, port = authority:match("^(%[::1%]):(%d+)$")
  else
    host = authority:match("^([^:]+)$")
    if not host then
      host, port = authority:match("^([^:]+):(%d+)$")
    end
  end
  if not host or (host ~= "localhost" and host ~= "127.0.0.1"
      and host ~= "[::1]") then
    return false
  end
  if not port then
    return true
  end
  local number = tonumber(port)
  return number >= 1 and number <= 65535
end

---Validate configuration
--
-- @param config table: User-provided configuration
-- @return table: Validated configuration
-- @return string|nil: Error message if invalid
function M.validate(config)
  if type(config) ~= "table" then
    return nil, "configuration must be a table"
  end

  if config.backend
    and config.backend ~= "ollama"
    and config.backend ~= "fm"
  then
    return nil, "backend must be 'ollama' or 'fm'"
  end

  for _, section in ipairs({
    "ollama",
    "fm",
    "filetypes",
    "checks",
    "long_sentence",
    "review",
    "quickfix",
    "keymaps",
  }) do
    if config[section] ~= nil and type(config[section]) ~= "table" then
      return nil, section .. " must be a table"
    end
  end

  if config.ollama then
    if config.ollama.url and not is_loopback_url(config.ollama.url) then
      return nil, "ollama.url must use a loopback host"
    end

    if config.ollama.timeout_ms
      and (type(config.ollama.timeout_ms) ~= "number"
        or config.ollama.timeout_ms < 1000)
    then
      return nil, "ollama.timeout_ms must be at least 1000ms"
    end

    if config.ollama.preload ~= nil
      and type(config.ollama.preload) ~= "boolean"
    then
      return nil, "ollama.preload must be a boolean"
    end

    if config.ollama.preload_timeout_ms
      and (type(config.ollama.preload_timeout_ms) ~= "number"
        or config.ollama.preload_timeout_ms < 1000)
    then
      return nil, "ollama.preload_timeout_ms must be at least 1000ms"
    end

    if config.ollama.keep_alive ~= nil
      and type(config.ollama.keep_alive) ~= "string"
      and type(config.ollama.keep_alive) ~= "number"
    then
      return nil, "ollama.keep_alive must be a string or number"
    end
  end

  if config.filetypes then
    for ft, enabled in pairs(config.filetypes) do
      if type(enabled) ~= "boolean" then
        return nil, string.format("filetypes.%s must be a boolean", ft)
      end
    end
  end

  if config.fm then
    if config.fm.command
      and (type(config.fm.command) ~= "string"
        or config.fm.command == "")
    then
      return nil, "fm.command must be a non-empty string"
    end
    if config.fm.timeout_ms
      and (type(config.fm.timeout_ms) ~= "number"
        or config.fm.timeout_ms < 1000)
    then
      return nil, "fm.timeout_ms must be at least 1000ms"
    end

    if config.fm.chunk_size ~= nil then
      local chunk_size = config.fm.chunk_size
      if type(chunk_size) ~= "number"
        or chunk_size < 1
        or chunk_size % 1 ~= 0
      then
        return nil, "fm.chunk_size must be a positive integer"
      end
      local hard_limit = config.review
          and config.review.hard_limit
        or M.default_config.review.hard_limit
      if type(hard_limit) == "number" and chunk_size > hard_limit then
        return nil, "fm.chunk_size must not exceed review.hard_limit"
      end
    end
  end

  if config.checks then
    for check, enabled in pairs(config.checks) do
      if not supported_checks[check] then
        return nil, string.format("unsupported check: %s", check)
      end
      if type(enabled) ~= "boolean" then
        return nil, string.format("checks.%s must be a boolean", check)
      end
    end
  end

  if config.long_sentence then
    local max_words = config.long_sentence.max_words
    if max_words ~= nil
      and (type(max_words) ~= "number"
        or max_words < 1
        or max_words % 1 ~= 0)
    then
      return nil, "long_sentence.max_words must be a positive integer"
    end
  end

  if config.review then
    local chunk_size = config.review.chunk_size
      or M.default_config.review.chunk_size
    local hard_limit = config.review.hard_limit
      or M.default_config.review.hard_limit
    if type(chunk_size) ~= "number" or chunk_size < 1 then
      return nil, "review.chunk_size must be positive"
    end
    if type(hard_limit) ~= "number" or hard_limit < chunk_size then
      return nil, "review.hard_limit must not be smaller than chunk_size"
    end
  end

  if config.quickfix then
    if config.quickfix.auto_open ~= nil
      and type(config.quickfix.auto_open) ~= "boolean"
    then
      return nil, "quickfix.auto_open must be a boolean"
    end
    local height_ratio = config.quickfix.height_ratio
    if height_ratio ~= nil
      and (type(height_ratio) ~= "number"
        or height_ratio <= 0
        or height_ratio > 1)
    then
      return nil, "quickfix.height_ratio must be between 0 and 1"
    end
    if config.quickfix.keep_focus_on_select ~= nil
      and type(config.quickfix.keep_focus_on_select) ~= "boolean"
    then
      return nil, "quickfix.keep_focus_on_select must be a boolean"
    end
  end

  return config, nil
end

---Merge with defaults
--
-- @param user_config table: User-provided configuration
-- @return table: Merged configuration
function M.merge(user_config)
  return vim.tbl_deep_extend(
    "force",
    vim.deepcopy(M.default_config),
    user_config or {}
  )
end

return M
