local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("chatgptviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local queryChatGPT = require("gpt_query")

local CONFIGURATION = nil
local buttons, input_dialog

local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, skipping...")
end

-- Helper function to check if a feature is enabled
local function isFeatureEnabled(feature_name, default)
  -- Always default to true if not specified
  default = default == nil and true or default
  
  if not CONFIGURATION or not CONFIGURATION.features or not CONFIGURATION.features.advanced_features then
    return default -- Return default value if configuration doesn't exist
  end
  
  if CONFIGURATION.features.advanced_features[feature_name] == nil then
    return default -- Return default if not specified
  end
  
  return CONFIGURATION.features.advanced_features[feature_name]
end

local function createResultText(highlightedText, message_history)
  local result_text = _("Highlighted text: ") .. "\"" .. highlightedText .. "\"\n\n"

  for i = 3, #message_history do
    if message_history[i].role == "user" then
      result_text = result_text .. _("User: ") .. message_history[i].content .. "\n\n"
    else
      result_text = result_text .. _("Assistant: ") .. message_history[i].content .. "\n\n"
    end
  end

  return result_text
end

local function showLoadingDialog()
  local loading = InfoMessage:new{
    text = _("Loading..."),
    timeout = 0.1
  }
  UIManager:show(loading)
end

local function showChatGPTDialog(ui, highlightedText, message_history)
  if not highlightedText or highlightedText == "" then
    UIManager:show(InfoMessage:new{
      text = _("Please highlight some text first."),
    })
    return
  end

  local title, author =
    ui.document:getProps().title or _("Unknown Title"),
    ui.document:getProps().authors or _("Unknown Author")

  local default_prompt = "The following is a conversation with an AI assistant. The assistant is helpful, creative, clever, and very friendly. Answer as concisely as possible. Detect the language and answer using that language."
  local system_prompt = CONFIGURATION 
    and CONFIGURATION.features 
    and CONFIGURATION.features.custom_prompts 
    and CONFIGURATION.features.custom_prompts.system
    or default_prompt

  -- Get model and temperature from configuration if available
  local model = CONFIGURATION and CONFIGURATION.model or "gpt-3.5-turbo"
  local temperature = CONFIGURATION and CONFIGURATION.temperature or 0.7
  local max_tokens = CONFIGURATION and CONFIGURATION.max_tokens or 1024

  local message_history = message_history or { {
    role = "system",
    content = system_prompt
  } }

  local function handleNewQuestion(chatgpt_viewer, question, conversation_history)
    -- Use the conversation history from the viewer if provided
    local history_to_use = conversation_history or message_history
    
    -- Add the new question to the history
    table.insert(history_to_use, {
      role = "user",
      content = question
    })

    -- Use model and temperature from viewer if available
    local query_model = chatgpt_viewer.model or model
    local query_temperature = chatgpt_viewer.temperature or temperature
    local query_max_tokens = chatgpt_viewer.max_tokens or max_tokens
    
    -- Query ChatGPT with the updated parameters
    local answer = queryChatGPT(history_to_use, {
      model = query_model,
      temperature = query_temperature,
      max_tokens = query_max_tokens
    })

    -- Add the answer to the history
    table.insert(history_to_use, {
      role = "assistant",
      content = answer
    })

    local result_text = createResultText(highlightedText, history_to_use)

    -- Update the viewer with the new text and pass the updated history
    chatgpt_viewer:update(result_text)
  end

  buttons = {
    {
      text = _("Cancel"),
      id = "close",
      callback = function()
        UIManager:close(input_dialog)
      end
    },
    {
      text = _("Ask"),
      callback = function()
        local question = input_dialog:getInputText()
        UIManager:close(input_dialog)
        showLoadingDialog()

        UIManager:scheduleIn(0.1, function()
          local context_message = {
            role = "user",
            content = "I'm reading something titled '" .. title .. "' by " .. author .. 
              ". I have a question about the following highlighted text: " .. highlightedText
          }
          table.insert(message_history, context_message)

          local question_message = {
            role = "user",
            content = question
          }
          table.insert(message_history, question_message)

          local answer = queryChatGPT(message_history, {
            model = model,
            temperature = temperature,
            max_tokens = max_tokens
          })
          
          local answer_message = {
            role = "assistant",
            content = answer
          }
          table.insert(message_history, answer_message)

          local result_text = createResultText(highlightedText, message_history)

          local chatgpt_viewer = ChatGPTViewer:new {
            title = _("AskGPT"),
            text = result_text,
            onAskQuestion = handleNewQuestion,
            conversation_history = message_history,
            model = model,
            temperature = temperature,
            max_tokens = max_tokens,
            system_prompt = system_prompt,
            book_title = title,
            book_author = author
          }

          UIManager:show(chatgpt_viewer)
        end)
      end
    }
  }

  -- Add buttons for each custom prompt
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.custom_prompts then
    for prompt_name, prompt in pairs(CONFIGURATION.features.custom_prompts) do
      if prompt_name ~= "system" and type(prompt) == "string" then  -- Ensure prompt is valid
        if not prompt:lower():find("translate") then
          prompt = prompt .. " Detect the language and answer using that language."
        end
        table.insert(buttons, {
          text = _(prompt_name:gsub("^%l", string.upper)),  -- Capitalize first letter
          callback = function()
            showLoadingDialog()

            UIManager:scheduleIn(0.1, function()
              message_history = {  -- Reset message history for new prompt
                {
                  role = "system",
                  content = prompt
                },
                {
                  role = "user",
                  content = "I'm reading something titled '" .. title .. "' by " .. author .. 
                    "'. Here's the text I want you to process: " .. highlightedText
                }
              }
              
              local success, response = pcall(queryChatGPT, message_history, {
                model = model,
                temperature = temperature,
                max_tokens = max_tokens
              })
              
              if not success then
                UIManager:show(InfoMessage:new{
                  text = _("Error: Failed to get response from ChatGPT"),
                })
                return
              end

              table.insert(message_history, { 
                role = "assistant", 
                content = response 
              })

              local result_text = createResultText(highlightedText, message_history)

              local chatgpt_viewer = ChatGPTViewer:new {
                title = _(prompt_name:gsub("^%l", string.upper)),
                text = result_text,
                onAskQuestion = handleNewQuestion,
                conversation_history = message_history,
                model = model,
                temperature = temperature,
                max_tokens = max_tokens,
                system_prompt = prompt,
                book_title = title,
                book_author = author
              }

              UIManager:show(chatgpt_viewer)
            end)
          end
        })
      end
    end
  end

  -- Add Book Analysis button
  if isFeatureEnabled("book_analysis", true) then
    table.insert(buttons, {
      text = _("Book Analysis"),
      callback = function()
        UIManager:close(input_dialog)
        
        -- Show loading indicator
        local loading = InfoMessage:new{
          text = _("Analyzing book..."),
          timeout = 0 -- No timeout, we'll close it manually
        }
        UIManager:show(loading)
        
        -- Use pcall to handle errors
        local success, err = pcall(function()
          -- Create a ChatGPTViewer instance to use its analyzeBook method
          local chatgpt_viewer = ChatGPTViewer:new {
            title = _("Book Analysis"),
            text = "",
            conversation_history = message_history,
            model = model,
            temperature = temperature,
            max_tokens = max_tokens,
            system_prompt = system_prompt,
            book_title = title,
            book_author = author
          }
          
          chatgpt_viewer:analyzeBook()
        end)
        
        -- Close loading indicator
        UIManager:close(loading)
        
        -- Show error if failed
        if not success then
          UIManager:show(InfoMessage:new{
            text = _("Error: ") .. tostring(err),
            timeout = 3
          })
        end
      end
    })
  end

  -- Add Characters & Plot button
  if isFeatureEnabled("characters_plot", true) then
    table.insert(buttons, {
      text = _("Characters & Plot"),
      callback = function()
        UIManager:close(input_dialog)
        
        -- Show loading indicator
        local loading = InfoMessage:new{
          text = _("Analyzing characters and plot..."),
          timeout = 0 -- No timeout, we'll close it manually
        }
        UIManager:show(loading)
        
        -- Use pcall to handle errors
        local success, err = pcall(function()
          -- Create a ChatGPTViewer instance to use its trackCharactersAndPlot method
          local chatgpt_viewer = ChatGPTViewer:new {
            title = _("Characters & Plot"),
            text = "",
            conversation_history = message_history,
            model = model,
            temperature = temperature,
            max_tokens = max_tokens,
            system_prompt = system_prompt,
            book_title = title,
            book_author = author
          }
          
          chatgpt_viewer:trackCharactersAndPlot()
        end)
        
        -- Close loading indicator
        UIManager:close(loading)
        
        -- Show error if failed
        if not success then
          UIManager:show(InfoMessage:new{
            text = _("Error: ") .. tostring(err),
            timeout = 3
          })
        end
      end
    })
  end

  -- Add Discussion button
  if isFeatureEnabled("discussion", true) then
    table.insert(buttons, {
      text = _("Discussion"),
      callback = function()
        UIManager:close(input_dialog)
        
        -- Show loading indicator
        local loading = InfoMessage:new{
          text = _("Generating discussion questions..."),
          timeout = 0 -- No timeout, we'll close it manually
        }
        UIManager:show(loading)
        
        -- Use pcall to handle errors
        local success, err = pcall(function()
          -- Create a ChatGPTViewer instance to use its generateDiscussionQuestions method
          local chatgpt_viewer = ChatGPTViewer:new {
            title = _("Discussion"),
            text = "",
            conversation_history = message_history,
            model = model,
            temperature = temperature,
            max_tokens = max_tokens,
            system_prompt = system_prompt,
            book_title = title,
            book_author = author
          }
          
          chatgpt_viewer:generateDiscussionQuestions()
        end)
        
        -- Close loading indicator
        UIManager:close(loading)
        
        -- Show error if failed
        if not success then
          UIManager:show(InfoMessage:new{
            text = _("Error: ") .. tostring(err),
            timeout = 3
          })
        end
      end
    })
  end

  -- Add Recommendations button
  if isFeatureEnabled("recommendations", true) then
    table.insert(buttons, {
      text = _("Recommendations"),
      callback = function()
        UIManager:close(input_dialog)
        
        -- Show loading indicator
        local loading = InfoMessage:new{
          text = _("Finding book recommendations..."),
          timeout = 0 -- No timeout, we'll close it manually
        }
        UIManager:show(loading)
        
        -- Use pcall to handle errors
        local success, err = pcall(function()
          -- Create a ChatGPTViewer instance to use its getBookRecommendations method
          local chatgpt_viewer = ChatGPTViewer:new {
            title = _("Recommendations"),
            text = "",
            conversation_history = message_history,
            model = model,
            temperature = temperature,
            max_tokens = max_tokens,
            system_prompt = system_prompt,
            book_title = title,
            book_author = author
          }
          
          chatgpt_viewer:getBookRecommendations()
        end)
        
        -- Close loading indicator
        UIManager:close(loading)
        
        -- Show error if failed
        if not success then
          UIManager:show(InfoMessage:new{
            text = _("Error: ") .. tostring(err),
            timeout = 3
          })
        end
      end
    })
  end

  input_dialog = InputDialog:new{
    title = _("Ask a question about the highlighted text"),
    input_hint = _("Type your question here..."),
    input_type = "text",
    buttons = { buttons }
  }
  UIManager:show(input_dialog)
end

return showChatGPTDialog
