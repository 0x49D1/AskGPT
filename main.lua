local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")

local showChatGPTDialog
local success, result = pcall(function() return require("dialogs") end)
if success then
  if type(result) == "function" then
    showChatGPTDialog = result
  else
    print("Error: dialogs module returned", type(result), "instead of function")
    print("Result value:", tostring(result))
  end
else
  print("Error loading dialogs module:", tostring(result))
end

if not showChatGPTDialog then
  showChatGPTDialog = function()
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
      text = "Error: ChatGPT dialog module failed to load. Check logs.",
      timeout = 3
    })
  end
end

local AskGPT = InputContainer:new {
  name = "askgpt",
  is_doc_only = true,
}

function AskGPT:init()
  self.ui.highlight:addToHighlightDialog("askgpt_ChatGPT", function(_reader_highlight_instance)
    return {
      text = _("Ask ChatGPT"),
      enabled = Device:hasClipboard(),
      callback = function()
        NetworkMgr:runWhenOnline(function()
          showChatGPTDialog(self.ui, _reader_highlight_instance.selected_text.text)
        end)
      end,
    }
  end)
end

return AskGPT