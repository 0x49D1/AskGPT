local CONFIGURATION = nil

-- Attempt to load the configuration module
local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, skipping...")
end

-- Define your queryChatGPT function
local https = require("ssl.https")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local socket = require("socket")
local _ = require("gettext")

-- Fallback to api_key.lua for backward compatibility
if not CONFIGURATION then
  success, result = pcall(function() return require("api_key") end)
  if success then
    CONFIGURATION = {
      api_key = result.api_key,
      model = "gpt-4o-mini",
      base_url = "https://api.openai.com/v1/chat/completions"
    }
  else
    print("api_key.lua not found, skipping...")
  end
end

local function queryChatGPT(messages, options)
  if not CONFIGURATION or not CONFIGURATION.api_key then
    return "Error: API key not found. Please create a configuration.lua file with your OpenAI API key."
  end

  -- Validate messages array
  if not messages or type(messages) ~= "table" or #messages == 0 then
    return "Error: Invalid messages array. At least one message is required."
  end

  -- Use options if provided, otherwise use defaults from CONFIGURATION
  local model = options and options.model or CONFIGURATION.model or "gpt-4o-mini"
  local temperature = options and options.temperature or CONFIGURATION.temperature or 0.7
  local max_tokens = options and options.max_tokens or CONFIGURATION.max_tokens or 1024
  local base_url = CONFIGURATION.base_url or "https://api.openai.com/v1/chat/completions"

  -- Additional parameters from configuration
  local additional_params = CONFIGURATION.additional_parameters or {}

  -- Prepare the request body
  -- Use max_completion_tokens for newer models, fallback to max_tokens for compatibility
  local request_body = {
    model = model,
    messages = messages,
    temperature = temperature,
  }

  -- Check if model supports max_completion_tokens (gpt-4o and newer)
  if model:match("^gpt%-4o") or model:match("^gpt%-4%-turbo") or model:match("^gpt%-3.5%-turbo%-0125") then
    request_body.max_completion_tokens = max_tokens
  else
    request_body.max_tokens = max_tokens
  end
  
  -- Add any additional parameters
  for k, v in pairs(additional_params) do
    request_body[k] = v
  end
  
  local request_json = json.encode(request_body)
  
  -- Set timeout to 60 seconds
  http.TIMEOUT = 60
  
  -- Prepare response table
  local response_body = {}
  
  -- Make the request
  local _, code, headers = http.request {
    url = base_url,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. CONFIGURATION.api_key,
      ["Content-Length"] = #request_json
    },
    source = ltn12.source.string(request_json),
    sink = ltn12.sink.table(response_body)
  }
  
  -- Check for errors
  if code ~= 200 then
    return "Error: " .. code .. " - " .. table.concat(response_body)
  end
  
  -- Parse the response with error handling
  local response_json = table.concat(response_body)
  local success, response = pcall(json.decode, response_json)

  if not success then
    return "Error: Failed to parse API response. The response may be malformed."
  end

  -- Extract the message content
  if response and response.choices and response.choices[1] and
     response.choices[1].message and response.choices[1].message.content then
    return response.choices[1].message.content
  else
    return "Error: Unexpected response format from API"
  end
end

return queryChatGPT