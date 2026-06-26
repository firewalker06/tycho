# Tycho Harness Functionality Inventory

Date: 2026-06-26

Scope: inventory Tycho's current Codex and Claude managed-agent harness behavior, then compare what additional CLI adapters can reuse, adapt, or must leave unsupported until verified. Cursor notes capture the earlier adapter study; OpenCode notes capture the next planned integration target.

## Executive Summary

Tycho's managed-agent system is not just a command launcher. A harness participates in configuration, executable discovery, command construction, detached process management, native session resume, stream parsing, structured result extraction, memory capture, skill discovery, TUI and Remote UI forms, schedules, hooks, setup readiness, and interactive terminal open flows.

Cursor can fit the same high-level lifecycle, but it should be implemented as a third built-in adapter, not as a Claude-compatible custom harness. It has a Claude-like `stream-json` run mode, a Codex-like captured native session id, and its own command, sandbox, model, auth, skill, and parser contracts.

OpenCode should also be a built-in adapter. It has a direct non-interactive `opencode run` surface, `--format json` raw event output, explicit session continuation flags, provider/model/agent catalogs, first-class permissions, MCP support, and local skills/commands concepts. The main unknown is not command construction; it is the exact JSON event schema Tycho should parse and how reliably OpenCode emits a session id/result summary in headless runs.

## Current Harness Architecture

| Area | Codex | Claude | Cursor fit | OpenCode fit |
| --- | --- | --- | --- | --- |
| Built-in registration | `codex` in `HQ::BUILTIN_HARNESSES` | `claude` in `HQ::BUILTIN_HARNESSES` | Add `cursor`; update every UI and setup fallback that assumes only Codex/Claude | Add `opencode`; update resolver/setup/UI fallback exactly like a built-in, not as a custom Claude-compatible harness |
| Custom harness adapter | Not supported | Supported as `adapter: claude` with `execution_command` | Do not expose custom `adapter: cursor` in v1 unless parser and command contracts are stable | Do not expose custom `adapter: opencode` in v1; OpenCode has its own run/session/parser/permission contracts |
| Config validation | Project/template `agent` must be supported | Same | Add `cursor` to supported harnesses and reject custom key collision automatically via built-in list | Add `opencode` to supported harnesses and rely on built-in collision rejection |
| Default project/template harness | `codex` fallback when empty | Selected explicitly | Cursor can be selected wherever harness keys are listed | OpenCode can be selected wherever harness keys are listed; OpenCode-specific `--agent` should remain separate from Tycho's harness field |
| CLI create | `tycho agent create --harness codex` | `--harness claude` or custom Claude key | Works once `HQ.supported_harness?("cursor")` is true | Works once `HQ.supported_harness?("opencode")` is true |
| AgentStore create/clone/scheduled | Persists `agent`, `model`, `reasoning_effort` | Same | Reuses generic paths; scheduled runs will work after command builder support | Reuses generic paths; `reasoning_effort` can map to `opencode run --variant` |

## Command Execution

| Function | Codex implementation | Claude implementation | Cursor adaptation | OpenCode adaptation |
| --- | --- | --- | --- | --- |
| Executable lookup | `TYCHO_CODEX_BIN`, fallback paths, then `codex` | `TYCHO_CLAUDE_BIN`, fallback paths, then `claude` | Add `TYCHO_CURSOR_BIN`; default command should be verified as `agent`, with `cursor-agent` considered as a fallback or documented alias | Add `TYCHO_OPENCODE_BIN`, fallback paths, then `opencode`; version command is `opencode --version` |
| Detached process | Spawned through Tycho's Ruby runner; stdout/stderr appended to raw log | Same | Reuse unchanged | Reuse unchanged |
| Headless command | `codex exec` | `claude --print --output-format stream-json --verbose` | Likely `agent -p --output-format stream-json --stream-partial-output`; verify exact flag spelling from installed CLI | `opencode run --format json --dir <workspace> [message...]` |
| Prompt delivery | Prompt is argv after `--` | Prompt is argv | Prefer stdin or prompt file for Cursor to avoid argv limits on large composed HQ prompts | Prompt is argv `message`; no documented prompt-file flag, so keep prompts bounded or consider server API later |
| Workspace | `-C <workspace>` on cold run | Process `chdir`, no explicit workspace flag | Cursor should pass `--workspace <workspace>` and also keep process `chdir` | Pass `--dir <workspace>` and keep process `chdir` |
| Model | `--model <model>` | `--model <model>` | Cursor appears to support `--model`; pass when set | Pass `--model <provider/model>` when set |
| Reasoning effort | `-c model_reasoning_effort="..."` | `--effort <value>` | No Tycho-equivalent Cursor flag found; hide or ignore effort for Cursor until CLI advertises one | Pass `--variant <value>`; OpenCode describes this as provider-specific reasoning effort |
| Sandbox full access | `--dangerously-bypass-approvals-and-sandbox` | `--dangerously-skip-permissions` | Likely needs `--force`, `--trust`, `--approve-mcps`; decide whether `--sandbox disabled` is required for true full access | Use `--dangerously-skip-permissions`; explicit OpenCode `deny` permissions still win |
| Sandbox restricted | `--full-auto --sandbox <mode>` on cold run | No non-danger mapping | Cursor has `--sandbox enabled`, but real restrictions depend on `.cursor/sandbox.json`; treat as partially supported | No direct Tycho sandbox-mode mapping; rely on OpenCode config/agent permissions (`allow`, `ask`, `deny`) |
| Output files | `-o <last_message.json>` | Structured output is in stream | Cursor has no Tycho output file equivalent; structured result must come from stream text/result events | No output-file flag; structured result must come from `--format json` events or final assistant text |
| Missing binary failure | Start records failed run with clear log entry | Same | Reuse once executable resolver knows Cursor | Reuse once executable resolver knows OpenCode |
| Stop running agent | Process group TERM/KILL via existing `stop!` | Same | Reuse unchanged | Reuse unchanged |
| Hooks | Generic lifecycle hooks fire before/after runs and memory capture | Same | Reuse unchanged | Reuse unchanged |

## Native Session And Prompt Policy

| Function | Codex | Claude | Cursor adaptation | OpenCode adaptation |
| --- | --- | --- | --- | --- |
| First run session id | Captured from stream (`thread_id`, `session_id`, `id`) | Tycho pre-generates UUID and passes `--session-id`; later confirms stream session | Cursor should not pre-generate; capture emitted `session_id` or equivalent from stream | Do not pre-generate; capture emitted session id from raw JSON events, or use `session list --format json` / `export` only as fallback |
| Resume flag | `codex exec resume <id>` and prompt after `--` | `--resume <id>` | Cursor appears to support `--resume <id>`; verify if it is a flag or subcommand in current CLI | `opencode run --session <id> ...`; avoid `--continue` because it resumes last global session, not Tycho's selected agent |
| Native resume prompt | If native session exists and prior runs exist, send latest user message only | If bootstrapped session exists, send latest user message only | Cursor should follow Codex-style eligibility: resume only after an emitted or created native session is known | Same native resume policy once session id is captured |
| Bootstrap fallback | None needed beyond stream capture | Not applicable because Tycho supplied id | PRD proposes `agent create-chat`; verify command and output before relying on it | Use initial `opencode run` to create a session; no separate bootstrap command needed |
| Restart self-heal | Codex capture is simple | Claude has log-based reconciliation for unfinalized first run | Cursor needs log-based reconciliation if session id was captured but HQ restarted before finalization | Add log-based reconciliation for captured session id if HQ restarts before finalization |

## Parsing And Chat Rendering

| Function | Codex parser | Claude parser | Cursor adaptation | OpenCode adaptation |
| --- | --- | --- | --- | --- |
| Parser registration | `HQ::Parser::Codex` selected for adapter `codex` | `HQ::Parser::Claude` selected for adapter `claude` | Add `HQ::Parser::Cursor` and select by adapter `cursor` | Add `HQ::Parser::OpenCode` and select by adapter `opencode` |
| Assistant messages | `item.completed` with `item.type=agent_message` | `assistant` content text or `item.completed agent_message` | Cursor assistant events can be deltas plus final/cumulative messages; parser must dedupe partial output | Capture OpenCode `--format json` fixtures first; parser should emit final assistant text and dedupe any deltas/thinking blocks |
| Tool calls | `command_execution`, `file_change`, `todo_list` as system tool calls | `tool_use` as call, `tool_result` as result | Cursor needs native event mapping for `tool_call` started/completed and read/write/search/shell variants | Map OpenCode tool/permission events into Tycho system/tool entries after fixture capture |
| Usage/run result | `turn.completed` usage | `result` usage/cost/duration | Cursor `result` should become run summary and structured-result input when present | Prefer run/session events if present; otherwise use `opencode export <sessionID>` or `stats` only for diagnostics/backfill |
| Unknown events | Mostly ignored unless known error/failure | Mostly ignored unless known types | Cursor should log unknown, connection, retry, and thinking events as system metadata or summaries, not fail | Log unknown event names as metadata during early support; do not fail the run for new OpenCode event types |
| Live chat | `raw.log` tail is parsed into conversation/system blocks | Same | Reuse after parser emits common `ConversationEntry` and `SystemEntry` | Reuse after parser emits common `ConversationEntry` and `SystemEntry` |
| Memory capture | Assistant messages, token usage, tool summaries, structured inquiry, attachments, run summary | Same | Reuse after parser and structured result are implemented | Reuse after parser and structured result are implemented |

## Structured Results, Inquiry, And Attachments

| Function | Codex | Claude | Cursor adaptation | OpenCode adaptation |
| --- | --- | --- | --- | --- |
| Schema enforcement | `--output-schema <agent_result.json>` on cold runs | `--json-schema <compact schema>` | Cursor has no known schema flag; use prompt-only best effort | No schema flag found in OpenCode CLI/config docs; use prompt-only best effort |
| Structured result source | Last message output file and JSON agent messages | `StructuredOutput` tool or `result.structured_output` | Parse JSON object from result/assistant text, then fallback to prose summary | Parse a final JSON object from result/assistant events, then fallback to prose summary |
| Required normalized shape | `status`, `summary`, optional `inquiry`, optional `attachments` | Same | Reuse `AgentResultNormalizer` after `AgentStructuredResult` learns Cursor payload shapes | Reuse `AgentResultNormalizer` after `AgentStructuredResult` learns OpenCode payload shapes |
| Inquiry form | Generic from normalized structured result | Generic | Reuse unchanged | Reuse unchanged |
| Attachments | Generic normalized links/files persisted into memory and attachments file | Generic | Reuse unchanged | Reuse unchanged; later pass initial local files with `opencode run --file` |
| Final-output checklist | Appended to every execution prompt | Same | Reuse, but make Cursor prompt explicitly ask for a single JSON object because there is no schema enforcement | Reuse, but make OpenCode prompt explicitly ask for a single JSON object because there is no schema enforcement |

## Catalog, Readiness, And Model UX

| Function | Codex | Claude | Cursor adaptation | OpenCode adaptation |
| --- | --- | --- | --- | --- |
| Setup readiness | Resolver checks executable and returns catalog | Resolver checks executable and returns catalog | Add Cursor readiness payload with binary, version/auth if available | Add OpenCode readiness payload with binary, version, auth providers, and model-catalog availability |
| Model suggestions | `codex debug models` JSON | Static defaults plus `claude --help` effort parsing | Cursor likely has `agent models`; verify output format and timeout behavior | Use `opencode models [provider]` with a timeout; avoid `--refresh` in normal readiness because it updates cache from models.dev |
| Auth status | Not explicitly probed | Not explicitly probed | Cursor should probe `agent status` or `agent about`; support `CURSOR_API_KEY` and login guidance | Probe `opencode auth list`; report provider names/count and guide operators to `opencode auth login` |
| Reasoning effort suggestions | From Codex model catalog | Claude defaults or help | Empty for Cursor unless real values exist | Offer provider-specific `--variant` values only when model metadata or explicit defaults are known; otherwise keep free-form/empty |
| Remote UI harness list | Built from setup payload; fallback hardcodes Codex/Claude | Same | Update fallback and adapter helper so Cursor is not treated as Codex | Update fallback and adapter helper so OpenCode is not treated as Codex |

## Skills

| Function | Codex | Claude | Cursor adaptation | OpenCode adaptation |
| --- | --- | --- | --- | --- |
| Discovery roots | `~/.codex/skills`, `~/.agents/skills`, workspace `.agents/skills` | `~/.claude/skills`, workspace `.claude/skills` | Cursor skill roots are unverified; likely `.cursor` conventions, but do not assume `SKILL.md` support without local proof | Official docs list `.opencode/skills`, `~/.config/opencode/skills`, `.claude/skills`, `~/.claude/skills`, `.agents/skills`, and `~/.agents/skills` |
| Trigger character | `$` | `/` | Cursor UI uses `/` commands, but Tycho skill trigger needs verification against Cursor-compatible skill mechanism | No manual trigger character; OpenCode exposes skills to agents through the native `skill` tool, so Tycho autocomplete should use a harness-specific insertion/prompt strategy |
| Remote skills endpoint | Generic `GET /projects/:key/skills/:harness` | Same | Reuse after `SkillDiscovery.roots_for` and trigger rules support Cursor | Reuse after `SkillDiscovery.roots_for` adds OpenCode roots and permissions/duplicates are handled |

## UI And Operator Surfaces

| Surface | Current behavior | Cursor adaptation | OpenCode adaptation |
| --- | --- | --- | --- |
| TUI project editor | Harness choices from `HQ.harness_keys` | Mostly automatic after registration | Mostly automatic after registration |
| TUI agent editor | Harness choices from `HQ.harness_keys`; free-form model/effort inputs | Register Cursor; decide whether to suppress effort for Cursor | Register OpenCode; label effort as OpenCode `variant` or leave it free-form/optional |
| TUI chat/detail | Uses generic parser entries, memory, summary, attachments, session id | Works after parser/session/structured result support | Works after parser/session/structured result support |
| Interactive terminal open | Codex and Claude command builders each have an interactive branch | Add Cursor interactive branch using native `agent` plus resume/workspace/model | Add OpenCode interactive branch using plain `opencode` or `opencode run -i`, plus `--dir`, `--session`, `--model`, and optional `--agent` |
| Remote UI project/agent forms | Harness options come from setup payload; frontend adapter fallback maps unknown to Codex | Add Cursor setup item and JS adapter fallback for `cursor` | Add OpenCode setup item and JS adapter fallback for `opencode` |
| Remote UI setup | Shows built-in Codex/Claude plus custom harnesses | Add Cursor readiness and auth messages | Add OpenCode readiness, version, auth-provider, model-catalog, and config-path messages |
| CLI `tycho agent create` | Generic supported-harness validation | Works after registration | Works after registration |
| Schedules | Use project default harness through `AgentStore.create_scheduled` | Works after command builder/parser support | Works after command builder/parser support |
| Clone/archive | Generic agent state/log handling | Works unchanged | Works unchanged |

## Cursor Capability Classification

| Tycho capability | Cursor status | Notes |
| --- | --- | --- |
| Built-in selection in config/TUI/Remote UI/CLI | Adaptable | Low risk after registration and frontend fallback changes |
| Detached run lifecycle, logs, stop, hooks | Adaptable | Existing process wrapper works |
| Headless live streaming | Adaptable with parser work | Cursor supports `stream-json` and partial streaming, but event forms are unstable enough to require fixtures |
| Native session resume | Adaptable with verification | `--resume` exists in examples; exact bootstrap and emitted id fields need real capture |
| Structured result parity | Partial | Prompt-only, best-effort; no schema guarantee like Codex/Claude |
| Inquiry and attachments | Adaptable after structured normalization | Generic Tycho flows can consume normalized hashes |
| Model selection | Adaptable | `--model` is visible in docs/examples |
| Reasoning effort | Unsupported for now | Do not present a control unless Cursor exposes a stable equivalent |
| Full access sandbox | Partial/needs decision | `--force`, `--trust`, `--approve-mcps`; possibly `--sandbox disabled` |
| Restricted sandbox | Partial/needs real tests | `--sandbox enabled` exists, but `.cursor/sandbox.json` behavior has had contradictory reports |
| Skill autocomplete | Unknown | Need proof of Cursor-compatible skill roots and invocation syntax |
| Catalog/readiness | Adaptable with probing | `agent status/about/models` appear available in references; output shape must be captured |
| Interactive terminal mode | Adaptable | Native `agent` interactive exists; resume behavior needs verification |

## OpenCode Capability Classification

| Tycho capability | OpenCode status | Notes |
| --- | --- | --- |
| Built-in selection in config/TUI/Remote UI/CLI | Adaptable | Low risk after registration and frontend fallback changes |
| Detached run lifecycle, logs, stop, hooks | Adaptable | Existing process wrapper works with `opencode run` |
| Headless live streaming | Adaptable with parser work | `opencode run --format json` provides raw JSON events, but Tycho needs captured fixtures for event names and final-message behavior |
| Native session resume | Adaptable with verification | Use `opencode run --session <id>` after capturing the emitted session id; avoid global `--continue` |
| Structured result parity | Partial | Prompt-only, best-effort; no schema flag found in OpenCode CLI/config docs |
| Inquiry and attachments | Adaptable after structured normalization | Generic Tycho flows can consume normalized hashes; local file inputs can later map to `--file` |
| Model selection | Adaptable | `--model <provider/model>` is supported by `opencode run` |
| Reasoning effort | Adaptable | `--variant` maps reasonably to Tycho's effort field, but values are provider-specific |
| Full access sandbox | Partial | `--dangerously-skip-permissions` auto-approves non-denied permissions; OpenCode `deny` rules still take precedence |
| Restricted sandbox | Partial | Use OpenCode permission config (`allow`, `ask`, `deny`) rather than trying to emulate Codex sandbox modes |
| Skill autocomplete | Adaptable with UX decision | Skill roots are documented, but OpenCode uses a native skill tool rather than a slash/dollar trigger |
| Catalog/readiness | Adaptable with probing | `auth list`, `models`, `agent list`, and `debug paths` provide enough readiness data with timeouts/caching |
| Interactive terminal mode | Adaptable | Plain `opencode` and `opencode run -i` exist; resume behavior needs real interactive verification |

## OpenCode Capability Inventory

Local version inspected: `opencode 1.15.13` at `/opt/homebrew/bin/opencode`.

Primary docs inspected: OpenCode CLI, config, agents, permissions, MCP servers, commands, and skills docs at `https://opencode.ai/docs/`.

### OpenCode CLI Surface

| Capability | Local/official fact | Tycho implication |
| --- | --- | --- |
| Executable | `opencode --version` prints `1.15.13`; command is available at `/opt/homebrew/bin/opencode` | Add built-in harness `opencode`, resolver env `TYCHO_OPENCODE_BIN`, fallback paths, and version command `opencode --version` |
| Non-interactive run | `opencode run [message..]` sends a prompt from argv | Implement headless command around `opencode run`; consider prompt length limits because there is no documented prompt-file flag |
| Raw output | `opencode run --format json` is documented locally as raw JSON events | Add `HQ::Parser::OpenCode`; first implementation needs real NDJSON fixtures before treating parser mapping as stable |
| Workspace | `opencode run --dir <path>` runs in a directory; top-level default command accepts a project path | Use `--dir <workspace>` plus process `chdir` for parity with Tycho's detached runner |
| Model | `-m, --model` accepts `provider/model` | Map Tycho model directly to `--model` |
| Reasoning effort | `--variant` is described as provider-specific reasoning effort | Map Tycho `reasoning_effort` to OpenCode `--variant`, but label it as provider-specific and allow empty |
| Agent selection | `--agent` selects an OpenCode agent; `opencode agent list` lists primary/subagents | Tycho can expose model separately from harness; agent selection is probably an OpenCode-specific advanced option, not Tycho's `agent` field |
| Session resume | `-s, --session` continues a session id; `-c, --continue` continues the last session; `--fork` can fork before continuing | Persist emitted OpenCode session id and resume with `--session <id>`; avoid `--continue` because Tycho needs deterministic agent-specific sessions |
| Attachments | `-f, --file` attaches one or more files | Tycho already has attachment normalization; later integration can pass local file attachments through `--file` for initial prompts |
| Dangerous mode | `--dangerously-skip-permissions` auto-approves permissions not explicitly denied | Map `danger-full-access` to this flag only when operator intent is clear; explicit deny rules still matter |
| Interactive mode | `opencode run -i` runs direct interactive split-footer mode; plain `opencode [project]` starts TUI | Add an interactive command branch using either `opencode run -i` or plain `opencode`, then verify resume behavior |
| Headless server | `opencode serve` starts an HTTP API server; `opencode acp` starts an Agent Client Protocol server | Tycho v1 can use `opencode run`; server/ACP are future integration paths if process-per-run becomes limiting |
| Remote attach | `opencode run --attach http://localhost:4096` attaches to a running OpenCode server | Not needed for v1; useful if Tycho later manages an OpenCode server per project |
| Auth/readiness | `opencode auth list` lists configured provider credentials; local machine shows Anthropic, Google, and Z.AI credentials | Setup readiness can report credential count/provider names without validating every model |
| Model catalog | `opencode models [provider] [--verbose] [--refresh]` lists models | Harness catalog can call `opencode models` with timeout; avoid `--refresh` during normal readiness |
| Agent catalog | `opencode agent list` lists built-in/custom agents and permissions | Useful for diagnostics, but too verbose for every setup call unless summarized/cached |
| Sessions | `opencode session list --format json` exists; `opencode export <sessionID>` exports session JSON | Use for diagnostics/backfill if raw log parsing misses a session id |
| Debug paths | `opencode debug paths` prints data/config/cache/state/tmp roots | Readiness can include path hints when troubleshooting auth, logs, and config |

### OpenCode Agent, Permission, And Tool Model

| Area | Fact | Tycho implication |
| --- | --- | --- |
| Built-in agents | Official docs describe primary agents `build` and `plan`, and subagents `general`, `explore`, and `scout`; local `agent list` also showed additional configured primary agents like `summary`, `title`, and `compaction` | Tycho should not equate OpenCode agents with Tycho harnesses. Harness remains `opencode`; OpenCode `--agent` is a harness-specific option or template setting |
| Agent permissions | Official docs describe permission actions `allow`, `ask`, and `deny`; local `agent list` prints merged rules | Tycho sandbox mapping should rely on OpenCode permission config plus `--dangerously-skip-permissions`; do not assume Tycho can fully emulate Codex sandbox modes |
| Plan-style operation | Official docs position `plan` as analysis/review without edits by default | Tycho can recommend `--agent plan` for review-only templates once adapter-specific template options exist |
| MCP | Official docs support local and remote MCP servers configured under `mcp`; local CLI has `opencode mcp add/list/auth/logout/debug` | Tycho should not manage OpenCode MCP directly in v1; readiness can mention MCP availability and rely on OpenCode config |
| Commands | Official docs support custom slash commands in global `~/.config/opencode/commands/` and project `.opencode/commands/` | This is parallel to Tycho skills, not a direct replacement. Skill autocomplete should not surface commands unless Tycho intentionally indexes them |
| Skills | Official docs list OpenCode-native, Claude, and Agents skill roots; local CLI has `opencode debug skill` | Add OpenCode roots to discovery, but make the UI/prompt behavior harness-specific because OpenCode uses a native skill tool instead of manual `$` or `/` insertion |

### OpenCode Parser And Structured Result Plan

| Tycho capability | OpenCode status | Notes |
| --- | --- | --- |
| Raw log parsing | Adaptable, requires fixtures | `--format json` provides raw events, but event names and shapes must be captured from real runs before implementing parser logic |
| Assistant text | Likely adaptable | Parser should handle streaming deltas and final message events without duplicating partial output |
| Tool calls | Likely adaptable | Map OpenCode permission/tool events into Tycho system/tool entries after fixture capture |
| Usage/cost | Likely adaptable | OpenCode has `stats` and session export; raw run events may include usage, but this must be verified |
| Session id | Likely adaptable | Use emitted session id if present; otherwise derive from session list/export only as a fallback |
| Structured output | Partial | No schema flag found in local help or official CLI docs. Use prompt-only final JSON instructions and Tycho's existing fallback parser |
| Inquiry and attachments | Partial | Reuse Tycho normalizer after parser extracts a final JSON object; pass initial local files with `--file` later |
| Native resume prompt policy | Adaptable | Once a session id is known, send only the latest user message using `--session <id>` like Codex/Claude native resume paths |

### OpenCode Implementation Slices

1. Foundation: register `opencode`, add executable/version resolution, setup readiness, command-builder branch, and tests for `opencode run --format json --dir`.
2. Fixture capture: run a tiny real OpenCode prompt with `--format json`, a tool-using prompt, a permission prompt/deny case, and a resumed session; store sanitized fixtures under `test/fixtures/`.
3. Parser/session: implement `HQ::Parser::OpenCode`, capture session id, normalize assistant/tool/result events, and reuse native resume prompt policy.
4. Structured result: prompt for Tycho's final JSON shape, parse final assistant/result JSON best-effort, and document that schema enforcement is weaker than Codex/Claude.
5. Catalog/UI: expose version/auth/model readiness, map `reasoning_effort` to `--variant`, and consider adapter-specific OpenCode agent selection only after v1 works.

## Cursor Recommended Implementation Slices

1. Foundation: add `cursor` built-in key, executable resolver, setup payload placeholder, command builder branch, and tests for argv/stdin command shape.
2. Parser: capture realistic Cursor NDJSON fixtures and implement `HQ::Parser::Cursor`, including partial-output dedupe and unknown event handling.
3. Session and summary: capture/persist session id, resume with latest user message only, normalize result/prose fallback, and append memory.
4. UI/catalog: add Cursor readiness, auth/model probes, Remote UI adapter fallback, and hide unsupported effort controls.
5. Skills/docs: add Cursor skill discovery only after verifying roots and trigger behavior; document auth, sandbox, and headless gotchas.

## Cursor Verification Checklist

- `bin/test` includes Cursor command-builder, parser, structured-result, session, registry, setup, and skill tests.
- A local real-run capture records Cursor CLI version, `agent --help`, `agent status/about/models` output shapes, and a small `stream-json` run with assistant text, tool calls, result, and session id.
- Browser verification covers Remote UI harness selection, setup readiness, chat streaming, details toggle, and skill picker behavior if Cursor skills are enabled.

## Sources

- Local Tycho files inspected: `lib/hq/harness_registry.rb`, `lib/hq/domain/agent_command_builder.rb`, `lib/hq/domain/managed_agent.rb`, `lib/hq/parser.rb`, `lib/hq/parser/codex.rb`, `lib/hq/parser/claude.rb`, `lib/hq/domain/agent_structured_result.rb`, `lib/hq/domain/harness_catalog.rb`, `lib/hq/domain/skill_discovery.rb`, `lib/hq/remote_server.rb`, `lib/hq/remote_ui/assets/app.js`, `lib/hq/cli_command.rb`, and related tests.
- Cursor CLI product/docs: <https://cursor.com/cli>, <https://cursor.com/docs/cli/reference/output-format>.
- Cursor CLI parser/sandbox references: <https://forum.cursor.com/t/stream-partial-output-assistant-events-have-multiple-undocumented-forms-how-should-consumers-parse-them/156289>, <https://forum.cursor.com/t/tool-call-completed-event-lost-after-connection-reconnect-in-stream-json-mode/157593>, <https://forum.cursor.com/t/headless-agent-p-ignores-sandbox-json-and-generates-helper-policy-with-disabletmpwrite-false/157095>.
- External integration reference: <https://github.com/mattpocock/sandcastle/issues/673>.
- Proposal reviewed: <https://github.com/firewalker06/tycho/issues/45>.
- Local OpenCode CLI inspected: `opencode --version`, `opencode --help`, `opencode run --help`, `opencode auth list`, `opencode models --help`, `opencode agent list`, `opencode session list --help`, `opencode serve --help`, `opencode acp --help`, `opencode mcp --help`, `opencode debug --help`, `opencode debug paths`, and `opencode debug skill --help`.
- OpenCode official docs: <https://opencode.ai/docs/cli/>, <https://opencode.ai/docs/config/>, <https://opencode.ai/docs/models/>, <https://opencode.ai/docs/agents/>, <https://opencode.ai/docs/permissions/>, <https://opencode.ai/docs/tools/>, <https://opencode.ai/docs/skills/>, <https://opencode.ai/docs/mcp-servers/>, <https://opencode.ai/docs/commands/>, and <https://opencode.ai/docs/server/>.
