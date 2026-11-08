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

The request uses straps' provider resolver: `vim.b[bufnr].straps_provider`, then `config.provider`, then the `:StrapsProvider` preference file, then Anthropic. Renamer calls the provider slot's credential function (`fn.anthropic_api_key`, `fn.openai_api_key`, or `fn.llamacpp_api_key`) and uses straps' URL validation and auth-header construction. Stored keys, environment keys, ChatGPT login, and Codex login use the same credential selection as straps. Renamer needs no separate credentials. Provider-preference errors stop the rename.

| Provider | Endpoint | Default model |
| --- | --- | --- |
| anthropic | `{base_url}/v1/messages` (non-streaming, no `thinking` block) | `claude-haiku-4-5-20251001` |
| openai, API key or ChatGPT login | `{openai_base_url}/v1/responses` (non-streaming, `store=false`, no `reasoning` field) | `gpt-4.1-mini` |
| openai, Codex login | straps' Codex Responses endpoint (streaming, `store=false`) | Session's selected OpenAI model; override with `codex_model` |
| llamacpp | `{llamacpp_base_url}/v1/messages` (non-streaming, optional Bearer key) | Session's selected llama.cpp model |

Renamer does not apply the session's `:StrapsEffort`. Anthropic and llama.cpp requests omit thinking. API-key and ChatGPT requests omit reasoning; a reasoning model can spend `openai_max_output_tokens` on reasoning, so raise that cap or keep a non-reasoning `openai_model`.

Codex requests use `fn.openai_codex_request`, including its account/session headers and lowest supported reasoning level when the model entry supplies reasoning metadata. Codex removes `max_output_tokens`. Select a Codex-supported session model or set `codex_model`; inheriting a model does not establish that Codex supports it. In particular, straps' fallback OpenAI model can be absent from the Codex catalog.

Expiring login credentials refresh through straps without blocking the editor. An HTTP 401 triggers one refresh and retry for ChatGPT or Codex credentials. API keys are not retried. Each asynchronous wait uses `timeout_ms`; a timed-out refresh may still complete in straps, but Renamer ignores its late callback. Login credentials retain straps' restriction to the default OpenAI origin.

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
| `openai_max_output_tokens` | `200` | API-key/ChatGPT `max_output_tokens`; Codex omits it. A truncated reply is reported as `response incomplete (max_output_tokens)`. |
| `codex_model` | unset | Override the inherited OpenAI session model for Codex login. Must name a model Codex supports. |
| `max_excerpt_bytes` | `12000` | Excerpt size cap (minimum 64); longer transcripts keep the head and tail around a `[...]` marker. |
| `tool_input_bytes` | `160` | Per-tool-call input cap in the excerpt. |
| `max_title_chars` | `80` | Title length cap, in characters. |
| `timeout_ms` | `30000` | Timeout for each asynchronous wait and curl `--max-time`; a non-numeric or non-positive value falls back to 30000. |

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

`STRAPS_ROOT` names the straps checkout the specs load; the devShell sets it to the flake input and `../straps` is the fallback. The specs use fake `curl` binaries or mocked transport and never reach the network. The shared bootstrap isolates `XDG_CONFIG_HOME` before straps setup so saved credentials do not affect the tests.
