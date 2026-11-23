local M = {}
local limits = require("ai-proofread.limits")

local source = debug.getinfo(1, "S").source:sub(2)
local schema_path = vim.fs.joinpath(
  vim.fs.dirname(source),
  "fm_response_schema.json"
)

function M.build_request(prompt, system)
  return {
    prompt = prompt,
    system = system,
  }
end

function M.decode_response(body)
  if type(body) ~= "string" or #body > limits.max_response_bytes then
    return nil, "response_too_large"
  end
  local ok, document = pcall(vim.json.decode, body)
  if not ok or type(document) ~= "table" then
    return nil, "invalid_model_json"
  end
  return document
end

function M.request(config, payload, callback)
  local command = {
    config.command,
    "respond",
    "--model",
    config.model,
    "--no-stream",
    "--greedy",
    "--schema",
    schema_path,
    "--instructions",
    payload.system,
  }

  return vim.system(command, {
    text = true,
    stdin = payload.prompt,
    timeout = config.timeout_ms,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback("transport_error", nil, result)
        return
      end
      local document, err = M.decode_response(result.stdout)
      callback(err, document, result)
    end)
  end)
end

function M.check(config)
  if vim.fn.executable(config.command) ~= 1 then
    return false, "Apple Foundation Models CLI is unavailable: "
      .. config.command
  end
  return true
end

return M
