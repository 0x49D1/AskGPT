--[[--
Displays some text in a scrollable view.

@usage
    local chatgptviewer = ChatGPTViewer:new{
        title = _("I can scroll!"),
        text = _("I'll need to be longer than this example to scroll."),
    }
    UIManager:show(chatgptviewer)
]]
local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local CheckButton = require("ui/widget/checkbutton")
local Device = require("device")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Notification = require("ui/widget/notification")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen

-- Import queryChatGPT function and configuration
local queryChatGPT = nil
local CONFIGURATION = nil

local success, result = pcall(function() return require("gpt_query") end)
if success then
  queryChatGPT = result
else
  print("gpt_query.lua not found, advanced features will be disabled")
end

-- Try to load configuration
success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, using default settings")
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

local ChatGPTViewer = InputContainer:extend {
  title = nil,
  text = nil,
  width = nil,
  height = nil,
  buttons_table = nil,
  -- See TextBoxWidget for details about these options
  -- We default to justified and auto_para_direction to adapt
  -- to any kind of text we are given (book descriptions,
  -- bookmarks' text, translation results...).
  -- When used to display more technical text (HTML, CSS,
  -- application logs...), it's best to reset them to false.
  alignment = "left",
  justified = true,
  lang = nil,
  para_direction_rtl = nil,
  auto_para_direction = true,
  alignment_strict = false,

  title_face = nil,               -- use default from TitleBar
  title_multilines = nil,         -- see TitleBar for details
  title_shrink_font_to_fit = nil, -- see TitleBar for details
  text_face = Font:getFace("x_smallinfofont"),
  fgcolor = Blitbuffer.COLOR_BLACK,
  text_padding = Size.padding.large,
  text_margin = Size.margin.small,
  button_padding = Size.padding.default,
  -- Bottom row with Close, Find buttons. Also added when no caller's buttons defined.
  add_default_buttons = nil,
  default_hold_callback = nil,   -- on each default button
  find_centered_lines_count = 5, -- line with find results to be not far from the center

  onAskQuestion = nil,
  conversation_history = {}, -- Store conversation history
  model = "gpt-3.5-turbo", -- Default model
  temperature = 0.7, -- Default temperature
  max_tokens = 1024, -- Default max tokens
  system_prompt = "You are a helpful assistant.", -- Default system prompt
  book_title = nil,
  book_author = nil,
}

function ChatGPTViewer:init()
  -- calculate window dimension
  self.align = "center"
  self.region = Geom:new {
    x = 0, y = 0,
    w = Screen:getWidth(),
    h = Screen:getHeight(),
  }
  self.width = self.width or Screen:getWidth() - Screen:scaleBySize(30)
  self.height = self.height or Screen:getHeight() - Screen:scaleBySize(30)

  self._find_next = false
  self._find_next_button = false
  self._old_virtual_line_num = 1

  if Device:hasKeys() then
    self.key_events.Close = { { Device.input.group.Back } }
  end

  if Device:isTouchDevice() then
    local range = Geom:new {
      x = 0, y = 0,
      w = Screen:getWidth(),
      h = Screen:getHeight(),
    }
    self.ges_events = {
      TapClose = {
        GestureRange:new {
          ges = "tap",
          range = range,
        },
      },
      Swipe = {
        GestureRange:new {
          ges = "swipe",
          range = range,
        },
      },
      MultiSwipe = {
        GestureRange:new {
          ges = "multiswipe",
          range = range,
        },
      },
      -- Allow selection of one or more words (see textboxwidget.lua):
      HoldStartText = {
        GestureRange:new {
          ges = "hold",
          range = range,
        },
      },
      HoldPanText = {
        GestureRange:new {
          ges = "hold",
          range = range,
        },
      },
      HoldReleaseText = {
        GestureRange:new {
          ges = "hold_release",
          range = range,
        },
        -- callback function when HoldReleaseText is handled as args
        args = function(text, hold_duration, start_idx, end_idx, to_source_index_func)
          self:handleTextSelection(text, hold_duration, start_idx, end_idx, to_source_index_func)
        end
      },
      -- These will be forwarded to MovableContainer after some checks
      ForwardingTouch = { GestureRange:new { ges = "touch", range = range, }, },
      ForwardingPan = { GestureRange:new { ges = "pan", range = range, }, },
      ForwardingPanRelease = { GestureRange:new { ges = "pan_release", range = range, }, },
    }
  end

  local titlebar = TitleBar:new {
    width = self.width,
    align = "left",
    with_bottom_line = true,
    title = self.title,
    title_face = self.title_face,
    title_multilines = self.title_multilines,
    title_shrink_font_to_fit = self.title_shrink_font_to_fit,
    close_callback = function() self:onClose() end,
    show_parent = self,
  }

  -- Callback to enable/disable buttons, for at-top/at-bottom feedback
  local prev_at_top = false -- Buttons were created enabled
  local prev_at_bottom = false
  local function button_update(id, enable)
    local button = self.button_table:getButtonById(id)
    if button then
      if enable then
        button:enable()
      else
        button:disable()
      end
      button:refresh()
    end
  end
  self._buttons_scroll_callback = function(low, high)
    if prev_at_top and low > 0 then
      button_update("top", true)
      prev_at_top = false
    elseif not prev_at_top and low <= 0 then
      button_update("top", false)
      prev_at_top = true
    end
    if prev_at_bottom and high < 1 then
      button_update("bottom", true)
      prev_at_bottom = false
    elseif not prev_at_bottom and high >= 1 then
      button_update("bottom", false)
      prev_at_bottom = true
    end
  end

  -- Initialize conversation history if not provided
  self.conversation_history = self.conversation_history or {}

  -- buttons
  local default_buttons =
  {
    {
      text = _("Ask Another Question"),
      id = "ask_another_question",
      callback = function()
        self:askAnotherQuestion()
      end,
    },
  }

  -- Add book features submenu if any features are enabled
  if queryChatGPT then
    local has_features = isFeatureEnabled("book_analysis", true) or
                         isFeatureEnabled("characters_plot", true) or
                         isFeatureEnabled("discussion", true) or
                         isFeatureEnabled("recommendations", true)

    if has_features then
      table.insert(default_buttons, {
        text = _("Book Features"),
        id = "book_features",
        callback = function()
          self:showBookFeaturesMenu()
        end,
      })
    end
  end

  -- Always add these basic buttons
  table.insert(default_buttons, {
    text = _("Settings"),
    id = "settings",
    callback = function()
      self:showSettings()
    end,
  })

  table.insert(default_buttons, {
    text = _("Export"),
    id = "export",
    callback = function()
      self:exportConversation()
    end,
  })

  table.insert(default_buttons, {
    text = "⇱",
    id = "top",
    callback = function()
      self.scroll_text_w:scrollToTop()
    end,
    hold_callback = self.default_hold_callback,
    allow_hold_when_disabled = true,
  })

  table.insert(default_buttons, {
    text = "⇲",
    id = "bottom",
    callback = function()
      self.scroll_text_w:scrollToBottom()
    end,
    hold_callback = self.default_hold_callback,
    allow_hold_when_disabled = true,
  })

  table.insert(default_buttons, {
    text = _("Close"),
    callback = function()
      self:onClose()
    end,
    hold_callback = self.default_hold_callback,
  })

  local buttons = self.buttons_table or {}
  if self.add_default_buttons or not self.buttons_table then
    table.insert(buttons, default_buttons)
  end
  self.button_table = ButtonTable:new {
    width = self.width - 2 * self.button_padding,
    buttons = buttons,
    zero_sep = true,
    show_parent = self,
  }

  local textw_height = self.height - titlebar:getHeight() - self.button_table:getSize().h

  self.scroll_text_w = ScrollTextWidget:new {
    text = self.text,
    face = self.text_face,
    fgcolor = self.fgcolor,
    width = self.width - 2 * self.text_padding - 2 * self.text_margin,
    height = textw_height - 2 * self.text_padding - 2 * self.text_margin,
    dialog = self,
    alignment = self.alignment,
    justified = self.justified,
    lang = self.lang,
    para_direction_rtl = self.para_direction_rtl,
    auto_para_direction = self.auto_para_direction,
    alignment_strict = self.alignment_strict,
    scroll_callback = self._buttons_scroll_callback,
  }
  self.textw = FrameContainer:new {
    padding = self.text_padding,
    margin = self.text_margin,
    bordersize = 0,
    self.scroll_text_w
  }

  self.frame = FrameContainer:new {
    radius = Size.radius.window,
    padding = 0,
    margin = 0,
    background = Blitbuffer.COLOR_WHITE,
    VerticalGroup:new {
      titlebar,
      CenterContainer:new {
        dimen = Geom:new {
          w = self.width,
          h = self.textw:getSize().h,
        },
        self.textw,
      },
      CenterContainer:new {
        dimen = Geom:new {
          w = self.width,
          h = self.button_table:getSize().h,
        },
        self.button_table,
      }
    }
  }
  self.movable = MovableContainer:new {
    -- We'll handle these events ourselves, and call appropriate
    -- MovableContainer's methods when we didn't process the event
    ignore_events = {
      -- These have effects over the text widget, and may
      -- or may not be processed by it
      "swipe", "hold", "hold_release", "hold_pan",
      -- These do not have direct effect over the text widget,
      -- but may happen while selecting text: we need to check
      -- a few things before forwarding them
      "touch", "pan", "pan_release",
    },
    self.frame,
  }
  self[1] = WidgetContainer:new {
    align = self.align,
    dimen = self.region,
    self.movable,
  }
end

function ChatGPTViewer:showBookFeaturesMenu()
  local ButtonDialogTitle = require("ui/widget/buttondialogtitle")

  local buttons = {}

  if isFeatureEnabled("book_analysis", true) then
    table.insert(buttons, {{
      text = _("Book Analysis"),
      callback = function()
        UIManager:close(self.book_features_dialog)
        self:analyzeBook()
      end,
    }})
  end

  if isFeatureEnabled("characters_plot", true) then
    table.insert(buttons, {{
      text = _("Characters & Plot"),
      callback = function()
        UIManager:close(self.book_features_dialog)
        self:trackCharactersAndPlot()
      end,
    }})
  end

  if isFeatureEnabled("discussion", true) then
    table.insert(buttons, {{
      text = _("Discussion Questions"),
      callback = function()
        UIManager:close(self.book_features_dialog)
        self:generateDiscussionQuestions()
      end,
    }})
  end

  if isFeatureEnabled("recommendations", true) then
    table.insert(buttons, {{
      text = _("Book Recommendations"),
      callback = function()
        UIManager:close(self.book_features_dialog)
        self:getBookRecommendations()
      end,
    }})
  end

  self.book_features_dialog = ButtonDialogTitle:new{
    title = _("Select a book feature"),
    buttons = buttons,
  }
  UIManager:show(self.book_features_dialog)
end

function ChatGPTViewer:askAnotherQuestion()
  local input_dialog
  input_dialog = InputDialog:new {
    title = _("Ask another question"),
    input = "",
    input_type = "text",
    description = _("Enter your question for ChatGPT."),
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(input_dialog)
          end,
        },
        {
          text = _("Ask"),
          is_enter_default = true,
          callback = function()
            local input_text = input_dialog:getInputText()

            -- Validate empty input
            if not input_text or input_text:match("^%s*$") then
              UIManager:show(Notification:new {
                text = _("Please enter a question."),
              })
              return
            end

            -- Add user message to conversation history
            table.insert(self.conversation_history, {role = "user", content = input_text})
            self:onAskQuestion(input_text, self.conversation_history)
            UIManager:close(input_dialog)
          end,
        },
      },
    },
  }
  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard()
end

function ChatGPTViewer:showSettings()
  local MultiInputDialog = require("ui/widget/multiinputdialog")
  local CheckButton = require("ui/widget/checkbutton")
  local VerticalGroup = require("ui/widget/verticalgroup")
  local VerticalSpan = require("ui/widget/verticalspan")
  local HorizontalGroup = require("ui/widget/horizontalgroup")
  local FrameContainer = require("ui/widget/container/framecontainer")
  local TextBoxWidget = require("ui/widget/textboxwidget")
  local Size = require("ui/size")
  local Font = require("ui/font")
  
  -- Get current feature settings
  local book_analysis_enabled = isFeatureEnabled("book_analysis", true)
  local characters_plot_enabled = isFeatureEnabled("characters_plot", true)
  local discussion_enabled = isFeatureEnabled("discussion", true)
  local recommendations_enabled = isFeatureEnabled("recommendations", true)
  
  -- Create checkboxes for features
  local book_analysis_checkbox = CheckButton:new{
    text = _("Book Analysis"),
    checked = book_analysis_enabled,
    callback = function() book_analysis_enabled = not book_analysis_enabled end,
  }
  
  local characters_plot_checkbox = CheckButton:new{
    text = _("Characters & Plot"),
    checked = characters_plot_enabled,
    callback = function() characters_plot_enabled = not characters_plot_enabled end,
  }
  
  local discussion_checkbox = CheckButton:new{
    text = _("Discussion"),
    checked = discussion_enabled,
    callback = function() discussion_enabled = not discussion_enabled end,
  }
  
  local recommendations_checkbox = CheckButton:new{
    text = _("Recommendations"),
    checked = recommendations_enabled,
    callback = function() recommendations_enabled = not recommendations_enabled end,
  }
  
  -- Create feature settings group
  local feature_settings = VerticalGroup:new{
    TextBoxWidget:new{
      text = _("Enable/Disable Features:"),
      face = Font:getFace("smallinfofont"),
      width = self.width * 0.8,
    },
    VerticalSpan:new{ width = Size.span.vertical_small },
    book_analysis_checkbox,
    characters_plot_checkbox,
    discussion_checkbox,
    recommendations_checkbox,
  }
  
  local settings_dialog
  
  settings_dialog = MultiInputDialog:new {
    title = _("ChatGPT Settings"),
    fields = {
      {
        text = self.model or "gpt-3.5-turbo",
        hint = _("Model (e.g., gpt-3.5-turbo, gpt-4)"),
        label = _("Model:"),
      },
      {
        text = tostring(self.temperature or 0.7),
        hint = _("Temperature (0.0-2.0)"),
        label = _("Temperature:"),
      },
      {
        text = tostring(self.max_tokens or 1024),
        hint = _("Max tokens (e.g., 1024)"),
        label = _("Max tokens:"),
      },
      {
        text = self.system_prompt or "You are a helpful assistant.",
        hint = _("System prompt"),
        label = _("System prompt:"),
      },
    },
    width = self.width * 0.8,
    height = self.height * 0.8,
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(settings_dialog)
          end,
        },
        {
          text = _("Clear History"),
          callback = function()
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
              text = _("Are you sure you want to clear the conversation history? This cannot be undone."),
              ok_text = _("Clear"),
              ok_callback = function()
                self.conversation_history = {}
                UIManager:show(Notification:new {
                  text = _("Conversation history cleared."),
                })
                UIManager:close(settings_dialog)
              end,
            })
          end,
        },
        {
          text = _("Save"),
          is_enter_default = true,
          callback = function()
            local fields = settings_dialog:getFields()
            self.model = fields[1]

            -- Validate temperature (0.0-2.0)
            local temp = tonumber(fields[2])
            if temp and temp >= 0 and temp <= 2 then
              self.temperature = temp
            else
              UIManager:show(Notification:new {
                text = _("Invalid temperature. Using default 0.7. Valid range: 0.0-2.0"),
              })
              self.temperature = 0.7
            end

            -- Validate max_tokens (must be positive)
            local tokens = tonumber(fields[3])
            if tokens and tokens > 0 then
              self.max_tokens = tokens
            else
              UIManager:show(Notification:new {
                text = _("Invalid max tokens. Using default 1024. Must be > 0"),
              })
              self.max_tokens = 1024
            end

            self.system_prompt = fields[4]
            
            -- Add system message at the beginning if history is empty
            if #self.conversation_history == 0 then
              table.insert(self.conversation_history, {role = "system", content = self.system_prompt})
            else
              -- Update system message if it exists
              if self.conversation_history[1].role == "system" then
                self.conversation_history[1].content = self.system_prompt
              else
                -- Insert system message at the beginning
                table.insert(self.conversation_history, 1, {role = "system", content = self.system_prompt})
              end
            end
            
            -- Save feature settings (only if CONFIGURATION exists)
            if CONFIGURATION then
              if not CONFIGURATION.features then
                CONFIGURATION.features = {}
              end
              if not CONFIGURATION.features.advanced_features then
                CONFIGURATION.features.advanced_features = {}
              end

              CONFIGURATION.features.advanced_features.book_analysis = book_analysis_enabled
              CONFIGURATION.features.advanced_features.characters_plot = characters_plot_enabled
              CONFIGURATION.features.advanced_features.discussion = discussion_enabled
              CONFIGURATION.features.advanced_features.recommendations = recommendations_enabled
            end
            
            UIManager:show(Notification:new {
              text = _("Settings saved."),
            })
            UIManager:close(settings_dialog)
            
            -- Refresh the UI to reflect new settings
            self:update(self.text, true)
          end,
        },
      },
    },
  }
  
  -- Add feature settings to dialog
  settings_dialog[1] = VerticalGroup:new{
    settings_dialog[1],
    VerticalSpan:new{ width = Size.span.vertical_large },
    FrameContainer:new{
      padding = Size.padding.default,
      margin = Size.margin.small,
      bordersize = 0,
      feature_settings,
    }
  }
  
  UIManager:show(settings_dialog)
end

function ChatGPTViewer:onCloseWidget()
  UIManager:setDirty(nil, function()
    return "partial", self.frame.dimen
  end)
end

function ChatGPTViewer:onShow()
  UIManager:setDirty(self, function()
    return "partial", self.frame.dimen
  end)
  return true
end

function ChatGPTViewer:onTapClose(arg, ges_ev)
  if ges_ev.pos:notIntersectWith(self.frame.dimen) then
    self:onClose()
  end
  return true
end

function ChatGPTViewer:onMultiSwipe(arg, ges_ev)
  -- For consistency with other fullscreen widgets where swipe south can't be
  -- used to close and where we then allow any multiswipe to close, allow any
  -- multiswipe to close this widget too.
  self:onClose()
  return true
end

function ChatGPTViewer:onClose()
  UIManager:close(self)
  return true
end

function ChatGPTViewer:onSwipe(arg, ges)
  if ges.pos:intersectWith(self.textw.dimen) then
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" then
      self.scroll_text_w:scrollText(1)
      return true
    elseif direction == "east" then
      self.scroll_text_w:scrollText(-1)
      return true
    else
      -- trigger a full-screen HQ flashing refresh
      UIManager:setDirty(nil, "full")
      -- a long diagonal swipe may also be used for taking a screenshot,
      -- so let it propagate
      return false
    end
  end
  -- Let our MovableContainer handle swipe outside of text
  return self.movable:onMovableSwipe(arg, ges)
end

-- The following handlers are similar to the ones in DictQuickLookup:
-- we just forward to our MoveableContainer the events that our
-- TextBoxWidget has not handled with text selection.
function ChatGPTViewer:onHoldStartText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  return self.movable:onMovableHold(_, ges)
end

function ChatGPTViewer:onHoldPanText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  -- We only forward it if we did forward the Touch
  if self.movable._touch_pre_pan_was_inside then
    return self.movable:onMovableHoldPan(arg, ges)
  end
end

function ChatGPTViewer:onHoldReleaseText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  return self.movable:onMovableHoldRelease(_, ges)
end

-- These 3 event processors are just used to forward these events
-- to our MovableContainer, under certain conditions, to avoid
-- unwanted moves of the window while we are selecting text in
-- the definition widget.
function ChatGPTViewer:onForwardingTouch(arg, ges)
  -- This Touch may be used as the Hold we don't get (for example,
  -- when we start our Hold on the bottom buttons)
  if not ges.pos:intersectWith(self.textw.dimen) then
    return self.movable:onMovableTouch(arg, ges)
  else
    -- Ensure this is unset, so we can use it to not forward HoldPan
    self.movable._touch_pre_pan_was_inside = false
  end
end

function ChatGPTViewer:onForwardingPan(arg, ges)
  -- We only forward it if we did forward the Touch or are currently moving
  if self.movable._touch_pre_pan_was_inside or self.movable._moving then
    return self.movable:onMovablePan(arg, ges)
  end
end

function ChatGPTViewer:onForwardingPanRelease(arg, ges)
  -- We can forward onMovablePanRelease() does enough checks
  return self.movable:onMovablePanRelease(arg, ges)
end

function ChatGPTViewer:handleTextSelection(text, hold_duration, start_idx, end_idx, to_source_index_func)
  if self.text_selection_callback then
    self.text_selection_callback(text, hold_duration, start_idx, end_idx, to_source_index_func)
    return
  end
  if Device:hasClipboard() then
    Device.input.setClipboardText(text)
    UIManager:show(Notification:new {
      text = start_idx == end_idx and _("Word copied to clipboard.")
          or _("Selection copied to clipboard."),
    })
  end
end

function ChatGPTViewer:update(new_text, is_error)
  -- Add assistant response to conversation history if not an error
  if not is_error then
    table.insert(self.conversation_history, {role = "assistant", content = new_text})
  end
  
  UIManager:close(self)
  local updated_viewer = ChatGPTViewer:new {
    title = self.title,
    text = new_text,
    width = self.width,
    height = self.height,
    buttons_table = self.buttons_table,
    onAskQuestion = self.onAskQuestion,
    conversation_history = self.conversation_history,
    model = self.model,
    temperature = self.temperature,
    max_tokens = self.max_tokens,
    system_prompt = self.system_prompt,
    book_title = self.book_title,
    book_author = self.book_author
  }
  updated_viewer.scroll_text_w:scrollToBottom()
  UIManager:show(updated_viewer)
end

function ChatGPTViewer:exportConversation()
  local InputDialog = require("ui/widget/inputdialog")
  local filename_dialog
  
  filename_dialog = InputDialog:new {
    title = _("Export Conversation"),
    input = "chatgpt_conversation.txt",
    input_type = "text",
    description = _("Enter filename to save the conversation:"),
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(filename_dialog)
          end,
        },
        {
          text = _("Save"),
          is_enter_default = true,
          callback = function()
            local filename = filename_dialog:getInputText()
            if filename and filename ~= "" then
              self:saveConversationToFile(filename)
            end
            UIManager:close(filename_dialog)
          end,
        },
      },
    },
  }
  UIManager:show(filename_dialog)
end

function ChatGPTViewer:saveConversationToFile(filename)
  local DocumentRegistry = require("document/documentregistry")
  local lfs = require("libs/libkoreader-lfs")

  -- Sanitize filename to prevent path traversal
  filename = filename:gsub("[/\\%.]+", "_")

  -- Ensure filename has .txt extension
  if not filename:match("%.txt$") then
    filename = filename .. ".txt"
  end

  -- Get documents path
  local documents_dir = G_reader_settings:readSetting("home_dir") or lfs.currentdir()
  local full_path = documents_dir .. "/" .. filename
  
  -- Format conversation
  local content = ""
  for _, message in ipairs(self.conversation_history) do
    if message.role == "system" then
      content = content .. "System: " .. message.content .. "\n\n"
    elseif message.role == "user" then
      content = content .. "User: " .. message.content .. "\n\n"
    elseif message.role == "assistant" then
      content = content .. "Assistant: " .. message.content .. "\n\n"
    end
  end
  
  -- Write to file
  local file = io.open(full_path, "w")
  if file then
    file:write(content)
    file:close()
    UIManager:show(Notification:new {
      text = T(_("Conversation saved to %1"), filename),
    })
  else
    UIManager:show(Notification:new {
      text = T(_("Failed to save conversation to %1"), filename),
    })
  end
end

function ChatGPTViewer:analyzeBook()
  if not queryChatGPT then
    UIManager:show(Notification:new {
      text = _("Advanced features unavailable. Check gpt_query.lua"),
    })
    return
  end
  
  local DocumentRegistry = require("document/documentregistry")
  local InfoMessage = require("ui/widget/infomessage")
  local UIManager = require("ui/uimanager")
  
  -- Get book metadata from parent UI
  local book_title = self.book_title or _("Unknown Title")
  local book_author = self.book_author or _("Unknown Author")
  
  UIManager:show(InfoMessage:new{
    text = _("Analyzing book content..."),
    timeout = 2
  })
  
  -- Get the language from the conversation history
  local detected_language = self:detectLanguage()
  
  -- Create a prompt for book analysis
  local analysis_prompt = {
    role = "system",
    content = "You are a literary analyst. Provide insights about themes, writing style, and historical context. " ..
              "Respond in the same language as the user's text. If the text is in a non-English language, provide your response in that language."
  }
  
  local book_context = {
    role = "user",
    content = string.format("I'm reading '%s' by %s. Based on the excerpts I've shared with you so far, can you provide analysis of themes, writing style, and historical context?", 
      book_title, book_author)
  }
  
  -- Use existing conversation history to inform analysis
  local analysis_messages = {analysis_prompt, book_context}
  
  -- Add relevant parts of conversation history that contain book excerpts
  for _, msg in ipairs(self.conversation_history) do
    if msg.role == "user" and msg.content:match("highlighted text") then
      table.insert(analysis_messages, msg)
    end
  end
  
  -- Add language instruction if detected
  if detected_language and detected_language ~= "english" then
    table.insert(analysis_messages, {
      role = "user",
      content = "Please respond in " .. detected_language .. " language."
    })
  end
  
  -- Query ChatGPT for analysis with error handling
  local success, analysis = pcall(queryChatGPT, analysis_messages, {
    model = self.model,
    temperature = self.temperature,
    max_tokens = self.max_tokens
  })
  
  if not success then
    UIManager:show(InfoMessage:new{
      text = _("Error: Failed to get analysis from ChatGPT"),
      timeout = 3
    })
    return
  end
  
  -- Show analysis in a new viewer
  local analysis_viewer = ChatGPTViewer:new {
    title = _("Book Analysis"),
    text = analysis,
    width = self.width,
    height = self.height,
    conversation_history = self.conversation_history,
    model = self.model,
    temperature = self.temperature,
    max_tokens = self.max_tokens,
    system_prompt = self.system_prompt,
    book_title = book_title,
    book_author = book_author
  }
  
  UIManager:show(analysis_viewer)
end

function ChatGPTViewer:trackCharactersAndPlot()
  if not queryChatGPT then
    UIManager:show(Notification:new {
      text = _("Advanced features unavailable. Check gpt_query.lua"),
    })
    return
  end
  
  local UIManager = require("ui/uimanager")
  local InfoMessage = require("ui/widget/infomessage")
  
  UIManager:show(InfoMessage:new{
    text = _("Analyzing characters and plot..."),
    timeout = 2
  })
  
  -- Get the language from the conversation history
  local detected_language = self:detectLanguage()
  
  -- Create a prompt for character and plot tracking
  local tracking_prompt = {
    role = "system",
    content = "You are a literary assistant specializing in character and plot analysis. " ..
              "For the book excerpts provided, create a detailed analysis with these sections: " ..
              "1. CHARACTERS: List all characters mentioned with brief descriptions and their relationships to others. " ..
              "2. PLOT SUMMARY: Summarize the key events and plot points revealed so far. " ..
              "3. TIMELINE: Create a chronological sequence of events if possible. " ..
              "4. THEMES & MOTIFS: Identify recurring themes or motifs. " ..
              "Format your response with clear headings and bullet points for readability. " ..
              "Respond in the same language as the user's text. If the text is in a non-English language, provide your response in that language."
  }
  
  local book_context = {
    role = "user",
    content = string.format("I'm reading '%s' by %s. Based on the excerpts I've shared with you, can you track the characters and plot developments so far?", 
      self.book_title or _("Unknown Title"), 
      self.book_author or _("Unknown Author"))
  }
  
  -- Use existing conversation history to inform tracking
  local tracking_messages = {tracking_prompt, book_context}
  
  -- Add relevant parts of conversation history that contain book excerpts
  for _, msg in ipairs(self.conversation_history) do
    if msg.role == "user" and msg.content:match("highlighted text") then
      table.insert(tracking_messages, msg)
    end
  end
  
  -- Add language instruction if detected
  if detected_language and detected_language ~= "english" then
    table.insert(tracking_messages, {
      role = "user",
      content = "Please respond in " .. detected_language .. " language."
    })
  end
  
  -- Query ChatGPT for character and plot tracking with error handling
  local success, tracking_result = pcall(queryChatGPT, tracking_messages, {
    model = self.model,
    temperature = 0.7,
    max_tokens = self.max_tokens
  })
  
  if not success then
    UIManager:show(InfoMessage:new{
      text = _("Error: Failed to get character and plot analysis from ChatGPT"),
      timeout = 3
    })
    return
  end
  
  -- Show tracking in a new viewer
  local tracking_viewer = ChatGPTViewer:new {
    title = _("Characters & Plot"),
    text = tracking_result,
    width = self.width,
    height = self.height,
    conversation_history = self.conversation_history,
    model = self.model,
    temperature = self.temperature,
    max_tokens = self.max_tokens,
    system_prompt = self.system_prompt,
    book_title = self.book_title,
    book_author = self.book_author
  }
  
  UIManager:show(tracking_viewer)
end

function ChatGPTViewer:generateDiscussionQuestions()
  if not queryChatGPT then
    UIManager:show(Notification:new {
      text = _("Advanced features unavailable. Check gpt_query.lua"),
    })
    return
  end
  
  local UIManager = require("ui/uimanager")
  local InfoMessage = require("ui/widget/infomessage")
  
  -- Get the language from the conversation history
  local detected_language = self:detectLanguage()
  
  -- Create a prompt for discussion questions
  local discussion_prompt = {
    role = "system",
    content = "You are a book club facilitator. Generate thought-provoking discussion questions about themes, characters, plot, writing style, and societal implications based on the book excerpts shared. " ..
              "Respond in the same language as the user's text. If the text is in a non-English language, provide your response in that language."
  }
  
  local book_context = {
    role = "user",
    content = string.format("I'm reading '%s' by %s for my book club. Based on the excerpts I've shared with you, can you generate 10 discussion questions that would lead to interesting conversations?", 
      self.book_title or _("Unknown Title"), 
      self.book_author or _("Unknown Author"))
  }
  
  -- Use existing conversation history to inform discussion questions
  local discussion_messages = {discussion_prompt, book_context}
  
  -- Add relevant parts of conversation history that contain book excerpts
  for _, msg in ipairs(self.conversation_history) do
    if msg.role == "user" and msg.content:match("highlighted text") then
      table.insert(discussion_messages, msg)
    end
  end
  
  -- Add language instruction if detected
  if detected_language and detected_language ~= "english" then
    table.insert(discussion_messages, {
      role = "user",
      content = "Please respond in " .. detected_language .. " language."
    })
  end
  
  -- Query ChatGPT for discussion questions with error handling
  local discussion_questions = ""
  local success = pcall(function()
    discussion_questions = queryChatGPT(discussion_messages, {
      model = self.model,
      temperature = 0.8, -- Slightly higher temperature for creative questions
      max_tokens = self.max_tokens
    })
  end)
  
  if not success then
    UIManager:show(InfoMessage:new{
      text = _("Error: Failed to get discussion questions from ChatGPT"),
      timeout = 3
    })
    return
  end
  
  -- Show discussion questions in a new viewer
  local discussion_viewer = ChatGPTViewer:new {
    title = _("Book Club Discussion Questions"),
    text = discussion_questions,
    width = self.width,
    height = self.height,
    model = self.model,
    temperature = self.temperature,
    max_tokens = self.max_tokens,
    book_title = self.book_title,
    book_author = self.book_author,
    conversation_history = self.conversation_history
  }
  
  UIManager:show(discussion_viewer)
end

function ChatGPTViewer:getBookRecommendations()
  if not queryChatGPT then
    UIManager:show(Notification:new {
      text = _("Advanced features unavailable. Check gpt_query.lua"),
    })
    return
  end
  
  local UIManager = require("ui/uimanager")
  local InfoMessage = require("ui/widget/infomessage")
  
  -- Get the language from the conversation history
  local detected_language = self:detectLanguage()
  
  -- Create a prompt for book recommendations
  local rec_prompt = {
    role = "system",
    content = "You are a literary recommendation expert. Suggest 5 books similar to the one being discussed, with brief descriptions of why they might appeal to the reader. " .. 
              "Respond in the same language as the user's text. If the text is in a non-English language, provide your response in that language."
  }
  
  -- Store book title and author for use in the result viewer
  local book_title = self.book_title or _("Unknown Title")
  local book_author = self.book_author or _("Unknown Author")
  
  local book_context = {
    role = "user",
    content = string.format("I'm reading '%s' by %s and enjoying it. Can you recommend 5 similar books I might enjoy?", 
      book_title, book_author)
  }
  
  -- Use existing conversation history to inform recommendations
  local rec_messages = {rec_prompt, book_context}
  
  -- Add relevant parts of conversation history that contain book excerpts
  for _, msg in ipairs(self.conversation_history) do
    if msg.role == "user" and msg.content:match("highlighted text") then
      table.insert(rec_messages, msg)
    end
  end
  
  -- Add language instruction if detected
  if detected_language and detected_language ~= "english" then
    table.insert(rec_messages, {
      role = "user",
      content = "Please respond in " .. detected_language .. " language."
    })
  end
  
  -- Query ChatGPT for recommendations with error handling
  local recommendations = ""
  local success = pcall(function()
    recommendations = queryChatGPT(rec_messages, {
      model = self.model,
      temperature = 0.7,
      max_tokens = self.max_tokens
    })
  end)
  
  if not success then
    UIManager:show(InfoMessage:new{
      text = _("Error: Failed to get recommendations from ChatGPT"),
      timeout = 3
    })
    return
  end
  
  -- Show recommendations in a new viewer
  local rec_viewer = ChatGPTViewer:new {
    title = _("Book Recommendations"),
    text = recommendations,
    width = self.width,
    height = self.height,
    buttons_table = nil,
    add_default_buttons = true,
    -- Explicitly pass book title and author to the new viewer
    book_title = book_title,
    book_author = book_author,
    -- Pass other important properties
    model = self.model,
    temperature = self.temperature,
    max_tokens = self.max_tokens,
    conversation_history = self.conversation_history
  }
  
  UIManager:show(rec_viewer)
end

-- Add this function to detect language from conversation history
function ChatGPTViewer:detectLanguage()
  -- First check if we have any user messages in the conversation history
  if self.conversation_history then
    for _, msg in ipairs(self.conversation_history) do
      if msg.role == "user" and msg.content:match("highlighted text") then
        -- Extract the highlighted text
        local highlighted_text = msg.content:match("\"(.-)\"")
        if highlighted_text and #highlighted_text > 10 then
          -- Use a simple heuristic for common languages
          -- Cyrillic characters (Russian, Ukrainian, etc.)
          if highlighted_text:match("[\208\209][\128-\191]") then
            return "russian"
          end
          -- Chinese characters
          if highlighted_text:match("[\228-\233][\128-\191][\128-\191]") then
            return "chinese"
          end
          -- Japanese characters (Hiragana, Katakana, Kanji)
          if highlighted_text:match("[\227][\129-\131][\128-\191]") then
            return "japanese"
          end
          -- Korean characters
          if highlighted_text:match("[\234-\237][\176-\191][\128-\191]") then
            return "korean"
          end
          -- Arabic characters
          if highlighted_text:match("[\216-\217][\128-\191]") then
            return "arabic"
          end
          -- Spanish/French/German/Italian - harder to detect reliably with simple patterns
          -- We'll rely on ChatGPT's language detection for these
        end
      end
    end
  end
  
  -- Default to English if we can't detect
  return "english"
end

return ChatGPTViewer
