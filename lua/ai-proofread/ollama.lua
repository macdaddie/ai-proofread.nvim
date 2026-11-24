local schema = require("ai-proofread.schema")
local limits = require("ai-proofread.limits")

local M = {}

local function decode_json(value)
  local ok, decoded = pcall(vim.json.decode, value)
  if not ok then
    return nil, decoded
  end
  return decoded
end

function M.build_request(model, prompt, system, keep_alive, format)
  local request = {
    model = model,
    prompt = prompt,
    system = system,
    stream = false,
    think = false,
    options = { temperature = 0 },
    format = format or schema,
  }
  if keep_alive ~= nil then
    request.keep_alive = keep_alive
  end
  return request
end

function M.build_preload_request(model, keep_alive)
  local request = {
    model = model,
    stream = false,
  }
  if keep_alive ~= nil then
    request.keep_alive = keep_alive
  end
  return request
end

function M.decode_response(body)
  if type(body) ~= "string" or #body > limits.max_response_bytes then
    return nil, "response_too_large"
  end
  local transport, transport_error = decode_json(body)
  if not transport then
    return nil, "invalid_transport_json: " .. tostring(transport_error)
  end
  if type(transport) ~= "table" then
    return nil, "invalid_transport_envelope"
  end
  if type(transport.response) ~= "string"
    or transport.response == ""
  then
    return nil, "empty_response"
  end

  local document, document_error = decode_json(transport.response)
  if document == nil then
    return nil, "invalid_model_json: " .. tostring(document_error)
  end

  if type(document) == "string" then
    document, document_error = decode_json(document)
    if document == nil then
      return nil, "invalid_nested_model_json: "
        .. tostring(document_error)
    end
  end

  if type(document) ~= "table" then
    return nil, "invalid_model_envelope"
  end
  return document
end

local function generate_command(config, timeout_ms)
  return {
    "curl",
    "--silent",
    "--show-error",
    "--fail-with-body",
    "--max-time",
    tostring(math.ceil(timeout_ms / 1000)),
    "--max-filesize",
    tostring(limits.max_response_bytes),
    "--header",
    "Content-Type: application/json",
    "--data-binary",
    "@-",
    config.url:gsub("/$", "") .. "/api/generate",
  }
end

---Classify a failed curl invocation
--
-- @param result table|nil: Completed process result
-- @return string: Stable failure code
-- @return string|nil: Human-readable detail
function M.classify_failure(result)
  local code = type(result) == "table" and result.code or nil
  if code == 28 or code == 124 then
    return "timeout",
      "the model may be queued behind another loaded model"
  end
  if code == 7 then
    return "connection_failed",
      "could not connect to the Ollama service"
  end
  if type(result) == "table" and type(result.stderr) == "string" then
    local detail = vim.trim(result.stderr)
    if detail ~= "" then
      return "transport_error", detail
    end
  end
  return "transport_error", nil
end

function M.request(config, payload, callback)
  return vim.system(generate_command(config, config.timeout_ms), {
    text = true,
    stdin = vim.json.encode(payload),
    timeout = config.timeout_ms,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local code, detail = M.classify_failure(result)
        callback(code, nil, result, detail)
        return
      end

      local document, err = M.decode_response(result.stdout)
      callback(err, document, result)
    end)
  end)
end

function M.preload(config, callback)
  local timeout_ms = config.preload_timeout_ms or config.timeout_ms
  local payload = M.build_preload_request(
    config.model,
    config.keep_alive
  )

  return vim.system(generate_command(config, timeout_ms), {
    text = true,
    stdin = vim.json.encode(payload),
    timeout = timeout_ms,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local code, detail = M.classify_failure(result)
        callback(code, result, detail)
        return
      end
      callback(nil, result)
    end)
  end)
end

---Decode the identifier list returned by /api/ps
--
-- @param body string: Raw response body
-- @return table|nil: Loaded model names
function M.parse_loaded_models(body)
  local ps = decode_json(body)
  if type(ps) ~= "table" or type(ps.models) ~= "table" then
    return nil
  end

  local names = {}
  for _, model in ipairs(ps.models) do
    local name = model.name or model.model
    if type(name) == "string" then
      table.insert(names, name)
    end
  end
  return names
end

---Report the models currently held in memory
--
-- @param config table: Ollama backend configuration
-- @return table|nil: Loaded model names, or nil when unavailable
function M.loaded_models(config)
  local result = vim.system({
    "curl",
    "--silent",
    "--show-error",
    "--fail-with-body",
    "--max-time",
    tostring(math.ceil(config.timeout_ms / 1000)),
    config.url:gsub("/$", "") .. "/api/ps",
  }, { text = true }):wait()

  if result.code ~= 0 then
    return nil
  end
  return M.parse_loaded_models(result.stdout)
end

function M.check(config)
  local result = vim.system({
    "curl",
    "--silent",
    "--show-error",
    "--fail-with-body",
    "--max-time",
    tostring(math.ceil(config.timeout_ms / 1000)),
    config.url:gsub("/$", "") .. "/api/tags",
  }, { text = true }):wait()

  if result.code ~= 0 then
    return false, "Ollama is not responding at " .. config.url
  end

  local tags = decode_json(result.stdout)
  if type(tags) ~= "table" or type(tags.models) ~= "table" then
    return false, "Ollama returned an invalid model list"
  end

  for _, model in ipairs(tags.models) do
    if model.name == config.model or model.model == config.model then
      return true
    end
  end
  return false, "Ollama model is not installed: " .. config.model
end

return M
