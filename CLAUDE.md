# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AskGPT is a KOReader plugin that integrates ChatGPT API to provide AI-powered book analysis, allowing users to ask questions about highlighted text, analyze characters/plot, get recommendations, and more.

**Target Platform**: KOReader (Lua-based e-reader platform)
**Language**: Lua 5.1
**API**: OpenAI Chat Completions API

## Architecture

### Module Structure

The plugin uses a flat module architecture with clear separation of concerns:

1. **main.lua** - Entry point that registers the plugin with KOReader's highlight menu
2. **dialogs.lua** - Main UI controller, manages all dialogs and user interactions
3. **chatgptviewer.lua** - Scrollable viewer widget for displaying conversations
4. **gpt_query.lua** - API client for OpenAI Chat Completions
5. **_meta.lua** - Plugin metadata for KOReader

### Data Flow

```
User highlights text in KOReader
  ↓
main.lua registers callback in highlight menu
  ↓
dialogs.lua shows input dialog with buttons
  ↓
User selects action (Ask, History, Custom Prompts, Book Features)
  ↓
dialogs.lua prepares message history
  ↓
gpt_query.lua sends request to OpenAI API
  ↓
chatgptviewer.lua displays response in scrollable view
  ↓
dialogs.lua saves conversation to history.json
```

### Configuration System

**Configuration File**: `configuration.lua` (user-created, not in repo)

The configuration module is loaded via `pcall` at module initialization time in both `dialogs.lua` and `gpt_query.lua`. The global `CONFIGURATION` table structure:

```lua
CONFIGURATION = {
  api_key = "...",
  model = "gpt-4o-mini",  -- Default model
  base_url = "https://api.openai.com/v1/chat/completions",
  temperature = 0.7,
  max_tokens = 1024,
  additional_parameters = {},  -- Extra API params
  features = {
    custom_prompts = {
      system = "Default system prompt",
      translate = "Translation prompt",
      explain = "Explanation prompt",
      -- ... more custom prompts
    },
    advanced_features = {
      book_analysis = true,
      characters_plot = true,
      discussion = true,
      recommendations = true
    }
  }
}
```

**Important**: If `CONFIGURATION` is nil or missing, the code falls back to defaults.

### History Persistence

**File**: `{DataStorage:getDataDir()}/plugins/askgpt/history.json`

Conversations are stored as JSON (changed from Lua `loadstring()` for security). Structure:
```lua
HISTORY = {
  {
    title = "AskGPT",
    text = "formatted conversation text",
    timestamp = os.time(),
    conversation_history = {
      {role = "system", content = "..."},
      {role = "user", content = "..."},
      {role = "assistant", content = "..."}
    }
  }
}
```

History is loaded at module init in `dialogs.lua` and saved after each conversation.

### OpenAI API Integration

**Key Implementation Details**:

1. **Model Detection**: Automatically uses `max_completion_tokens` for gpt-4o/gpt-4-turbo/gpt-3.5-turbo-0125, falls back to `max_tokens` for older models
2. **Error Handling**: All API responses starting with "Error:" are treated as failures
3. **Conversation Pruning**: Keeps last 20 messages to prevent token limit errors
4. **Network Check**: Uses `NetworkMgr:runWhenOnline()` to ensure connectivity

### UI Component Hierarchy

```
InputDialog (main entry point)
  ├─ Cancel button
  ├─ Ask button → shows ChatGPTViewer
  ├─ History button → shows Menu of conversations
  │   └─ Long-press item → delete with confirmation
  ├─ Custom Prompts (first 5 direct, rest in submenu)
  └─ Book Feature buttons (grouped into submenu)

ChatGPTViewer (conversation display)
  ├─ Ask Another Question
  ├─ Book Features (submenu)
  ├─ Settings
  ├─ Export
  ├─ Scroll buttons (⇱/⇲)
  └─ Close
```

## Critical Implementation Patterns

### Error Handling Pattern

Always check for nil and type before calling string methods:
```lua
if not response or (type(response) == "string" and response:match("^Error:")) then
  -- Handle error
end
```

### Variable Scoping

**Critical**: Avoid variable shadowing with `success` in pcall chains:
```lua
-- BAD:
local success, result = pcall(fn1)
local success, err = pcall(fn2)  -- Shadows previous success!

-- GOOD:
local success, result = pcall(fn1)
local hist_success, hist_err = pcall(fn2)
```

### Module Loading

Modules must handle missing dependencies gracefully:
```lua
local CONFIGURATION = nil
local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, skipping...")
end
```

### Button Creation Pattern

Use helper functions to avoid code duplication when creating similar buttons:
```lua
local function addFeatureButton(feature_name, button_text, loading_text, viewer_method)
  if isFeatureEnabled(feature_name, true) then
    table.insert(buttons, {
      text = _(button_text),
      callback = function()
        -- Implementation with error handling
      end
    })
  end
end
```

## KOReader-Specific APIs

### Required Modules
- `ui/widget/inputdialog` - Text input dialogs
- `ui/widget/infomessage` - Toast-style notifications
- `ui/widget/menu` - List menus
- `ui/widget/confirmbox` - Confirmation dialogs
- `ui/uimanager` - Widget display manager
- `device` - Device capabilities
- `datastorage` - Plugin data directory
- `gettext` - Internationalization (_() function)
- `network/manager` - Network connectivity

### Widget Lifecycle
1. Create widget: `Widget:new{...}`
2. Show widget: `UIManager:show(widget)`
3. Close widget: `UIManager:close(widget)`
4. Schedule: `UIManager:scheduleIn(seconds, callback)`

## Testing Approach

**No automated tests exist.** Manual testing on KOReader device/emulator required:

1. Test all button actions (Ask, History, Custom Prompts, Book Features)
2. Test error scenarios (no network, invalid API key, API errors)
3. Test history operations (save, load, delete individual items)
4. Test settings dialog (temperature/max_tokens validation)
5. Test with different models (gpt-4o-mini, gpt-3.5-turbo, etc.)

## Security Considerations

1. **Path Sanitization**: Export filenames sanitize path traversal (`/`, `\`, `..`)
2. **API Key**: Never log or expose API keys in error messages
3. **JSON over loadstring()**: History uses JSON to prevent code execution
4. **Input Validation**: Empty inputs blocked, numeric ranges validated

## Common Gotchas

1. **Module Load Order**: Configuration must load before accessing `CONFIGURATION` table
2. **Callback Scope**: Buttons capture variables by closure - ensure correct scope
3. **Error Message Format**: Always prefix errors with "Error: " for detection
4. **History Refresh**: After deleting history item, must reconstruct menu from scratch
5. **pcall Return Values**: First return is boolean success, second is result OR error message
6. **Model Names**: Pattern matching for `max_completion_tokens` must be updated for new models
7. **Conversation Pruning**: System message (first) is always preserved when pruning

## Deployment

Users install by:
1. Copying entire directory to `koreader/plugins/`
2. Ensuring directory name is `askgpt.koplugin`
3. Creating `configuration.lua` in plugin directory
4. Restarting KOReader

**No build process required** - Lua is interpreted at runtime.
