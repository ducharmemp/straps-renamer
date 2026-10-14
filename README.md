# straps-renamer

`:StrapsRename` with no argument asks a cheap model for a title and stores it as the session's durable title, the same `<session>.straps.meta` file straps' own `:StrapsRename {title}` writes. The same rename runs on its own when a session's first run starts and after every few runs (see Automatic renames). The resume picker, the agents buffer and `:StrapsResume<Tab>` show that title, and `grep -l 'lexer.lua' ~/.local/share/nvim/straps/sessions/*.meta` finds the session.

The prompt asks for 4 to 12 words naming the concrete subject (file names, function names, commands, error strings) with identifiers kept as written.

## Command

| Form | Effect |
| --- | --- |
| `:StrapsRename` | Send a transcript excerpt to the cheap model, store the reply as the title. |
| `:StrapsRename {title}` | Set the title directly (straps' own behaviour). |
| `:StrapsRename!` | Open straps' manual prompt, pre-filled with the current title. |

The command replaces straps' `:StrapsRename`. `plugin/straps_renamer.lua` defines it at load, again on `VimEnter`, and again whenever `plugin/straps.lua` is sourced later (a lazy-loaded straps), so the replacement holds in every load order; `setup()` defines it once more.

## Automatic renames

The plugin file installs `User StrapsRunStart` / `User StrapsRunEnd` autocmds (augroup `straps_renamer_auto`), so automatic titles work without calling `setup()`. With the defaults, a session is titled when its first run starts and again after every third run ends. A title you typed yourself (`:StrapsRename {title}`, `:StrapsRename!`, or the agents buffer's rename key) is never overwritten; only titles the plugin generated are regenerated. The plugin marks its own titles with a `generated_by` field in the `.meta` file, so the distinction survives a Neovim restart; clearing a title (`:StrapsRename!` with an empty answer) removes the file and re-enables automatic titles. A title you set while a model request is in flight is kept and the model's reply is dropped. Runs that end with reason `blank` or `error` count toward `every_runs` but do not trigger a rename. Subagent sessions (`b:straps_parent` set) are skipped unless `auto.subagents` is true. A first run whose transcript is empty does not use up the `on_start` rename; the next run start tries again.

| Key | Default | Meaning |
| --- | --- | --- |
| `auto.enabled` | `true` | Master switch for automatic renames. |
| `auto.on_start` | `true` | Rename when a session's first run starts. |
| `auto.every_runs` | `3` | Rename after every Nth run ends; `0` disables. Fractions are floored. |
| `auto.subagents` | `false` | Also rename subagent sessions. |
| `auto.keep_manual` | `true` | Never overwrite a title the plugin did not generate. |
| `auto.notify` | `true` | Report automatic titles at INFO level; `false` reports nothing on success. Failures, including an error raised inside the handler, are reported at WARN either way. |

`b:straps_renamer_runs` holds the per-session run count the `every_runs` check reads; `b:straps_renamer_started` records that the `on_start` rename was sent.

## Backend

The request goes to the backend the session uses, resolved the way `fn.provider` resolves it: `vim.b[bufnr].straps_provider`, then `config.provider`, then the `:StrapsProvider` preference file, then Anthropic. Keys come from straps' `fn.api_key` / `fn.openai_api_key`, so no extra credentials are needed.

| Provider | Endpoint | Default model |
| --- | --- | --- |
| anthropic | `{base_url}/v1/messages` (non-streaming, no `thinking` block) | `claude-haiku-4-5-20251001` |
| openai | `{openai_base_url}/v1/responses` (non-streaming, `store=false`, no `reasoning` field) | `gpt-4.1-mini` |

Both requests are one-shot: no extended thinking on Anthropic and no reasoning on OpenAI, whatever `:StrapsEffort` is set to for the session. If you point `openai_model` at a reasoning model (the `gpt-5` or `o` families), the model reasons at its own default and the reasoning tokens count against `openai_max_output_tokens`; raise that cap or keep a non-reasoning model.

## Install

With nixvim, import the module next to straps':

```nix
imports = [ straps.nixvimModules.default straps-renamer.nixvimModules.default ];
plugins.straps.enable = true;
plugins.straps-renamer.enable = true;
plugins.straps-renamer.settings.max_title_chars = 60;
```

With any other plugin manager, put this repository on the runtimepath after straps and call:

```lua
require("straps_renamer").setup({})
```

## Configuration

Every key of `require("straps_renamer").config` (`lua/straps_renamer/init.lua`) can be passed to `setup()`:

| Key | Default | Meaning |
| --- | --- | --- |
| `anthropic_model` | `claude-haiku-4-5-20251001` | Model for the anthropic backend. |
| `anthropic_max_tokens` | `200` | `max_tokens` for the Messages request. |
| `openai_model` | `gpt-4.1-mini` | Model for the openai backend; a non-reasoning model. |
| `openai_max_output_tokens` | `200` | `max_output_tokens`. A truncated reply is reported as `response incomplete (max_output_tokens)`. |
| `max_excerpt_bytes` | `12000` | Excerpt size cap (minimum 64); longer transcripts keep the head and tail around a `[...]` marker. |
| `tool_input_bytes` | `160` | Per-tool-call input cap in the excerpt. |
| `max_title_chars` | `80` | Title length cap, in characters. |
| `timeout_ms` | `30000` | curl `--max-time`; a non-numeric value falls back to 30000. |

## Registry entries

The three judgement steps are `fn.*` registry entries, so `:StrapsEdit fn.renamer_prompt` changes the prompt without editing this plugin:

| Entry | Signature | Default |
| --- | --- | --- |
| `fn.renamer_excerpt` | `(bufnr, { max_bytes, tool_input_bytes }) -> string` | User and assistant text plus tool names and inputs; the system prompt, tool results and `[straps] ` harness notices are skipped. An orphaned tool result that straps has already downgraded to user text is kept, since it is user text by then. |
| `fn.renamer_prompt` | `(excerpt) -> { system, user }` | `lua/straps_renamer/title.lua` `SYSTEM`. |
| `fn.renamer_clean` | `(raw, max_chars) -> string\|nil` | First non-blank line, `Title:` prefix, quotes and trailing period stripped, whitespace collapsed, capped. |

## Tests

```sh
nix develop
busted tests/title_spec.lua
for t in tests/*_spec.lua; do busted "$t" || exit 1; done
```

`STRAPS_ROOT` names the straps checkout the specs load; the devShell sets it to the flake input and `../straps` is the fallback. The specs run against fake `curl` binaries and never reach the network.
