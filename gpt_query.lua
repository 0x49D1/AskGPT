local CONFIGURATION = nil
local RESPONSE_LOG_SNIPPET = 2048
local ERROR_LOG_MAX_BYTES = 1024 * 1024 -- 1MB cap

local function convertMessagesToResponseInput(messages)
  local input = {}
  local instructions = nil

  for _, msg in ipairs(messages) do
    local content = msg.content
    local text_value
    if type(content) == "string" then
      text_value = content
    elseif type(content) == "table" then
      local buffer = {}
      for _, part in ipairs(content) do
        if type(part) == "string" then
          table.insert(buffer, part)
        elseif type(part) == "table" and type(part.text) == "string" then
          table.insert(buffer, part.text)
        end
      end
      text_value = table.concat(buffer, "\n")
    else
      text_value = tostring(content)
    end

    if msg.role == "system" then
      if text_value and text_value ~= "" then
        instructions = instructions and (instructions .. "\n\n" .. text_value) or text_value
      end
    else
      local role = msg.role
      if role ~= "user" and role ~= "assistant" then
        role = "user"
      end
      local content_type = role == "assistant" and "output_text" or "input_text"

      table.insert(input, {
        role = role,
        content = {
          {
            type = content_type,
            text = text_value,
          }
        }
      })
    end
  end

  return input, instructions
end

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
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

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

local function appendErrorLogLine(line)
  pcall(function()
    local dir = DataStorage:getDataDir() .. "/plugins/askgpt"
    if not lfs.attributes(dir, "mode") then
      lfs.mkdir(dir)
    end
    local path = dir .. "/errors.log"
    local file = io.open(path, "a")
    if file then
      file:write(line .. "\n")
      file:close()
    end
    local stat = lfs.attributes(path)
    if stat and stat.size and stat.size > ERROR_LOG_MAX_BYTES then
      local tmp = io.open(path, "r")
      if tmp then
        local data = tmp:read("*all")
        tmp:close()
        local overflow = stat.size - ERROR_LOG_MAX_BYTES
        local trimmed = data:sub(overflow + 1)
        local out = io.open(path, "w")
        if out then
          out:write(trimmed)
          out:close()
        end
      end
    end
  end)
end

local function writeErrorLogEntry(entry)
  local ok, line = pcall(json.encode, entry)
  if ok and line then
    appendErrorLogLine(line)
  end
end

local function collectTextSegments(root, seen, depth, buffer)
  if depth > 10 then
    return
  end

  local value_type = type(root)

  if value_type == "string" then
    if root ~= "" then
      table.insert(buffer, root)
    end
    return
  elseif value_type ~= "table" then
    return
  end

  if seen[root] then
    return
  end
  seen[root] = true

  if type(root.text) == "string" and root.text ~= "" then
    table.insert(buffer, root.text)
  end

  if type(root.output_text) == "string" and root.output_text ~= "" then
    table.insert(buffer, root.output_text)
  end

  if type(root.generated_text) == "string" and root.generated_text ~= "" then
    table.insert(buffer, root.generated_text)
  end

  if type(root.content) == "string" and root.content ~= "" then
    table.insert(buffer, root.content)
  elseif type(root.content) == "table" then
    collectTextSegments(root.content, seen, depth + 1, buffer)
  end

  if type(root.message) == "table" then
    collectTextSegments(root.message, seen, depth + 1, buffer)
  end

  if type(root.delta) == "table" then
    collectTextSegments(root.delta, seen, depth + 1, buffer)
  end

  if type(root.output) == "table" then
    collectTextSegments(root.output, seen, depth + 1, buffer)
  end

  -- Traverse array part
  local length = #root
  if length > 0 then
    for i = 1, length do
      collectTextSegments(root[i], seen, depth + 1, buffer)
    end
  end

  -- Traverse selected keyed entries, skipping known metadata-only fields
  for key, value in pairs(root) do
    if key ~= "text" and key ~= "output_text" and key ~= "generated_text" and
       key ~= "content" and key ~= "message" and key ~= "delta" and key ~= "output" and
       key ~= "role" and key ~= "finish_reason" and key ~= "index" and key ~= "refusal" and
       key ~= "safety_ratings" then
      collectTextSegments(value, seen, depth + 1, buffer)
    end
  end

  if type(root.annotations) == "table" then
    collectTextSegments(root.annotations, seen, depth + 1, buffer)
  end
end

local function flattenToText(value)
  local buffer = {}
  collectTextSegments(value, {}, 1, buffer)
  if #buffer > 0 then
    return table.concat(buffer, "\n\n")
  end
  return nil
end

local function extractMessageContent(choice)
  if not choice or type(choice) ~= "table" then
    return nil
  end

  -- Direct text shortcut
  if type(choice.text) == "string" and choice.text ~= "" then
    return choice.text
  end

  if type(choice.message) == "table" then
    local flattened = flattenToText(choice.message)
    if flattened and flattened ~= "" then
      return flattened
    end
  end

  if type(choice.content) == "table" then
    local flattened = flattenToText(choice.content)
    if flattened and flattened ~= "" then
      return flattened
    end
  end

  if type(choice.output) == "table" then
    local flattened = flattenToText(choice.output)
    if flattened and flattened ~= "" then
      return flattened
    end
  end

  return flattenToText(choice)
end

local function queryChatGPT(messages, options)
  local configured_model = CONFIGURATION and CONFIGURATION.model
  local configured_temperature = CONFIGURATION and CONFIGURATION.temperature
  local configured_max_tokens = CONFIGURATION and CONFIGURATION.max_tokens
  local base_url = (CONFIGURATION and CONFIGURATION.base_url) or "https://api.openai.com/v1/chat/completions"
  local normalized_url = base_url:lower()
  local api_key = CONFIGURATION and CONFIGURATION.api_key

  -- Use options if provided, otherwise use defaults from configuration
  local model = (options and options.model) or configured_model or "gpt-4o-mini"
  local default_temperature = 0.7
  if model:match("^gpt%-5") then
    default_temperature = 1
  end
  local temperature = (options and options.temperature) or configured_temperature or default_temperature
  local max_tokens = (options and options.max_tokens) or configured_max_tokens or 1024

  local function logError(kind, detail)
    writeErrorLogEntry({
      timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      kind = kind,
      model = model,
      endpoint = base_url,
      detail = detail
    })
  end

  if not api_key or api_key == "" then
    logError("missing_api_key", { has_configuration = CONFIGURATION ~= nil })
    return "Error: API key not found. Please create a configuration.lua file with your OpenAI API key."
  end

  -- Validate messages array
  if not messages or type(messages) ~= "table" or #messages == 0 then
    logError("invalid_messages", { message_count = messages and #messages or 0 })
    return "Error: Invalid messages array. At least one message is required."
  end

  -- Additional parameters from configuration
  local additional_params = (CONFIGURATION and CONFIGURATION.additional_parameters) or {}

  local is_responses_endpoint = normalized_url:find("/responses") ~= nil

  -- Prepare the request body
  local request_body
  if is_responses_endpoint then
    local response_input, instructions = convertMessagesToResponseInput(messages)
    request_body = {
      model = model,
      input = response_input,
    }
    if instructions then
      request_body.instructions = instructions
    end
  else
    request_body = {
      model = model,
      messages = messages,
    }
  end

  local include_temperature = true
  if model:match("^gpt%-5") then
    if temperature and temperature ~= 1 then
      logError("unsupported_temperature", { requested = temperature })
    end
    include_temperature = false
  end

  if include_temperature and temperature ~= nil then
    request_body.temperature = temperature
  end

  -- Decide which token field to send based on endpoint and model family
  local token_field
  if is_responses_endpoint then
    token_field = "max_output_tokens"
  elseif model:match("^gpt%-5") or model:match("^gpt%-4o") or model:match("^gpt%-4%-turbo") or model:match("^gpt%-3.5%-turbo%-0125") or model:match("^o%d") then
    token_field = "max_completion_tokens"
  else
    token_field = "max_tokens"
  end

  request_body[token_field] = max_tokens

  if model:match("^gpt%-5") and not is_responses_endpoint then
    if request_body.response_format == nil then
      request_body.response_format = { type = "text" }
    end
    if request_body.modalities == nil then
      request_body.modalities = { "text" }
    end
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
      ["Authorization"] = "Bearer " .. api_key,
      ["Content-Length"] = #request_json
    },
    source = ltn12.source.string(request_json),
    sink = ltn12.sink.table(response_body)
  }
  
  -- Check for errors
  local response_json = table.concat(response_body)

  if code ~= 200 then
    logError("http_error", {
      status = code,
      response_excerpt = response_json and response_json:sub(1, RESPONSE_LOG_SNIPPET) or ""
    })
    return "Error: " .. tostring(code) .. " - " .. response_json
  end
  
  -- Parse the response with error handling
  local success, response = pcall(json.decode, response_json)

  if not success then
    logError("json_parse_failure", {
      response_excerpt = response_json and response_json:sub(1, RESPONSE_LOG_SNIPPET) or ""
    })
    return "Error: Failed to parse API response. The response may be malformed."
  end

  -- Extract the message content
  if response and response.choices and response.choices[1] then
    local content = extractMessageContent(response.choices[1])
    if content and content ~= "" then
      return content
    end
  end

  if response and response.output then
    local content = flattenToText(response.output)
    if content and content ~= "" then
      return content
    end
  end

  logError("unexpected_response_format", {
    response_excerpt = response_json and response_json:sub(1, RESPONSE_LOG_SNIPPET) or ""
  })
  return "Error: Unexpected response format from API"
end

return queryChatGPT
