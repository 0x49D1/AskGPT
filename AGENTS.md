# Repository Guidelines

## Project Structure & Module Organization
AskGPT ships as a KOReader plugin. Core entry point `main.lua` registers the `Ask ChatGPT` action when a highlight is made. Conversation UI lives in `dialogs.lua`, which orchestrates history storage and prompts via `chatgptviewer.lua`. Network traffic and OpenAI compatibility reside in `gpt_query.lua`. Place user configuration in `configuration.lua` (copy from `configuration.lua.sample`). Assets and plugin metadata are stored alongside code; there is no nested src/tests directory.

## Build, Test, and Development Commands
No build pipeline is required; KOReader consumes this directory directly. For distribution use `zip -r askgpt.koplugin.zip . -x '*.git*' 'configuration.lua'` from the repo root. Copy the resulting folder into `koreader/plugins/askgpt.koplugin` and reload KOReader to exercise changes.

## Coding Style & Naming Conventions
Use Lua 5.1 syntax with two-space indentation and Unix line endings. Favor descriptive snake_case for locals and camel case only when mirroring KOReader APIs. Guard `require` calls with `pcall` as shown in `gpt_query.lua` and prefer early returns for error branches. Strings shown to end users must pass through `_()` for localization.

## Testing Guidelines
Automated tests are not yet wired in; rely on manual verification inside KOReader. Write scenario notes covering highlight capture, online/offline handling, and history persistence (`plugins/askgpt/history.json`). When adding new prompts or buttons, confirm they appear in the on-device dialog and that API failures surface InfoMessage alerts.

## Commit & Pull Request Guidelines
Follow the existing imperative, single-line commit style (`Fix crash in main.lua network check`). Summaries should mention user impact or subsystem touched (`Support max_completion_tokens for newer OpenAI models`). Each PR should describe behavior changes, configuration impacts, and manual test steps. Link related issue numbers and attach screenshots from the simulator when UI changes are introduced.

## Configuration & Security Tips
Never commit a real `configuration.lua`. Document any new keys inside `.sample` files and sanitize logs before sharing traces. Use environment-specific base URLs when working against local LLM gateways and reset `http.TIMEOUT` if you tweak it for experiments.
