---
name: MODEL_ARGUMENTS_PLAN
description: Implementation plan for model and reasoning argument support in Tycho managed agents
type: project-plan
---

# Model Arguments Plan

## Goal

Add first-class optional agent-level `model` and `reasoning_effort` settings for Tycho managed agents, then show the selected model and effort consistently in the TUI and Remote UI.

The first implementation should accept model names as free-form strings instead of hardcoding current provider catalogs. Model availability changes outside Tycho, and users may need aliases, full provider model IDs, or custom wrapper-specific IDs.

For reasoning/thinking controls, use `reasoning_effort` as Tycho's cross-harness field and display it as `Effort`. This maps cleanly to Codex's `model_reasoning_effort` and Claude Code's `--effort`. Do not introduce a generic `thinking` object in the first version; Claude's visible thinking, adaptive thinking, fixed thinking budgets, and Codex reasoning summaries are related but not equivalent.

Implementation status: implemented on 2026-06-03 with free-form model/effort fields, project/template inheritance, agent persistence, command argument mapping, Codex/Claude suggestion hints, and TUI/Remote UI display/editing.

## Current Findings

### Codex CLI

Checked on 2026-06-03 using local `codex` help and OpenAI Codex docs.

- `codex exec` supports `--model <MODEL>` and `-m <MODEL>`.
- `codex exec resume` also supports `--model <MODEL>` and `-m <MODEL>`.
- `codex` interactive top-level help exposes `--model <MODEL>` as a global option.
- Codex config also has a `model` string key in `~/.codex/config.toml`.
- OpenAI's Codex CLI reference describes `--model, -m` as overriding the configured model for the run, and the config reference documents `model` as the configured default model.
- Current local `codex` help does not expose a dedicated `--reasoning` or `--effort` CLI flag, but all relevant entry points accept `-c/--config <key=value>`.
- OpenAI's Codex config reference documents `model_reasoning_effort` with `minimal`, `low`, `medium`, `high`, and `xhigh` values for supported Responses API models.
- The same config reference also documents `plan_mode_reasoning_effort`, `model_reasoning_summary`, `model_verbosity`, and reasoning display flags. Treat these as later, separate features unless a user explicitly needs them.
- `codex debug models` can render Codex's raw model catalog as JSON, including a `--bundled` mode. Local `codex debug models --bundled` prints JSON directly; there is no separate `--json` flag in the checked build.
- The Codex model catalog includes `slug`, `display_name`, `visibility`, `supported_in_api`, `default_reasoning_level`, and `supported_reasoning_levels`. Use this as the preferred source for Codex model and effort suggestions.

Sources:

- OpenAI Codex CLI reference: <https://developers.openai.com/codex/cli/reference#codex-exec>
- OpenAI Codex config reference: <https://developers.openai.com/codex/config-reference#configtoml>
- Local help: `codex --help`, `codex exec --help`, `codex exec resume --help`, `codex debug models --help`

### Claude Code CLI

Checked on 2026-06-03 using local `claude` help and Anthropic docs.

- `claude` supports `--model <model>` for the current session.
- The flag works with print mode (`claude -p`) because `claude -p --help` exposes the same option.
- The flag can be combined with `--resume` or `--session-id` because local help lists all of these as session options.
- Anthropic's CLI reference says `--model` accepts aliases for the latest model, such as `sonnet` or `opus`, or a full model name.
- Local `claude` help exposes `--effort <level>` for the current session, with `low`, `medium`, `high`, `xhigh`, and `max`.
- Anthropic's model configuration docs describe effort as adaptive reasoning control. Available levels depend on the model; unsupported levels fall back to the highest supported level at or below the requested level.
- Claude Code's settings docs expose `effortLevel` for persistent settings, while the model configuration docs say `--effort` is the right per-session startup override. `max` is session-only.
- Claude Code also has extended-thinking controls such as `alwaysThinkingEnabled`, `MAX_THINKING_TOKENS`, and `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING`, but those are not the same as a per-run effort level.
- No non-interactive model-catalog command was found in local Claude Code 2.1.150. Official docs say `/model` is the source of truth for account-specific model availability, and the `/model` picker can also show the effort slider for supported models.
- Claude Code can restrict model selection through `availableModels` settings and can add one custom picker entry through `ANTHROPIC_CUSTOM_MODEL_OPTION`. For LLM gateways, docs mention `/v1/models` discovery when `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1`, but that still affects Claude's picker rather than exposing a general CLI list command.

Sources:

- Anthropic Claude Code CLI reference: <https://docs.anthropic.com/en/docs/claude-code/cli-usage>
- Anthropic Claude Code model configuration: <https://code.claude.com/docs/en/model-config>
- Anthropic Claude Code settings: <https://code.claude.com/docs/en/settings>
- Local help: `claude --help`, `claude -p --help`, `claude --version`

## Harness Discovery Strategy

Use discovered catalogs for suggestions only. Do not use catalog data as a hard validation gate, because users may need aliases, newly released models, custom gateway IDs, or wrapper-specific names before Tycho knows about them.

Codex discovery:

- Preferred command: `codex debug models`.
- Fallback command: `codex debug models --bundled`.
- Parse JSON into lightweight suggestion records: `model`, `display_name`, `default_reasoning_effort`, `supported_reasoning_efforts`, and `visibility`.
- Filter hidden models from ordinary pickers unless Tycho is in a debug/admin view.
- Cache the result for the current Tycho process or a short TTL. If the command fails, keep the form free-form and show no suggestions.

Claude discovery:

- Do not screen-scrape interactive `/model` or `/effort` in the first version. It is account-specific and interactive; automating it would be brittle and could start real sessions.
- Keep model input free-form, with lightweight suggestions for stable aliases such as `default`, `best`, `sonnet`, `opus`, `haiku`, and `opusplan`.
- Optionally read local `availableModels` from accessible Claude settings files later, but treat that as an incomplete hint because managed/policy settings and account availability may still differ.
- For effort suggestions, parse `claude --help` at runtime when possible and fall back to `low`, `medium`, `high`, `xhigh`, `max`. Let Claude Code apply its documented model-specific fallback when the chosen model does not support an effort level.

Custom harness discovery:

- Keep custom harnesses free-form by default.
- Add optional custom harness config later if needed, such as `model_catalog_command` returning JSON with model and effort suggestions. This avoids maintaining static Tycho tables for wrappers that already know their own provider.

## Dynamic Selection Rules

Agent-level values are part of the plan. `ManagedAgent` should persist the model and reasoning effort actually selected for that agent, even when those values came from a project/template default at creation time.

Effective defaults when creating a new agent:

1. Selected template `model` / `reasoning_effort`.
2. Project `model` / `reasoning_effort`.
3. Empty value, meaning harness default.

Effective values when editing an existing agent:

1. Existing agent-level `model` / `reasoning_effort`.
2. Empty value, meaning harness default.

Dynamic form behavior:

- Track whether the user has manually edited model and effort fields during the current form session.
- When the selected harness changes, refresh the model catalog/suggestions for the new harness.
- If the model field is not dirty, replace it with the inherited default for the new template/project/harness context.
- If the model field is dirty, preserve the user's current value even when it is not in the suggestion list. Display it as custom/free-form instead of clearing it.
- When the selected model changes, recompute effort suggestions from the selected harness and model. For Codex, use that model's `supported_reasoning_levels` and `default_reasoning_level` from the catalog.
- If the effort field is not dirty, replace it with the catalog/model default when available, otherwise use the inherited effort default, otherwise keep it empty.
- If the effort field is dirty, preserve the user's current value even when the new model does not advertise it. Provider CLIs remain the final validator.
- On template changes, update harness, model, effort suggestions, and defaults together. Preserve dirty model/effort fields unless the user explicitly resets them to template defaults.
- Cloned agents should copy the source agent-level model and effort, not recalculate from current template/project defaults.

## Existing Tycho Shape

Tycho currently has no model or reasoning-effort field. The relevant state today is:

- `Registry::ProjectConfig`: project-level `agent`.
- `Registry::AgentTemplateConfig`: template-level `agent` and `sandbox_mode`.
- `ManagedAgent`: persisted `agent`, `template_key`, `workspace`, `prompt`, `sandbox_mode`, session state, run history, summary, and structured result.
- `AgentStore`: creates agents from project templates, clones agents, and creates scheduled agents.
- `ManagedAgent#build_codex_command`: builds `codex exec` and `codex exec resume`.
- `ManagedAgent#build_claude_like_command`: builds Claude-compatible print-mode runs.
- `ManagedAgent#build_interactive_*_command`: builds interactive terminal commands.
- `RemoteServer#agent_payload` and `#agent_template_summaries`: expose agent/template data to the Web UI.
- `UI::AgentEditor` and `renderAgentForm`: already provide harness selectors, which can be mirrored for model input.

## Proposed Data Model

Use `model` and `reasoning_effort` as the field names everywhere.

Configuration inheritance for new agents:

1. Template-level `model` wins.
2. Project-level `model` is the fallback.
3. Empty or omitted `model` means use the harness default, such as `~/.codex/config.toml`, Claude settings, or wrapper defaults.
4. Template-level `reasoning_effort` wins.
5. Project-level `reasoning_effort` is the fallback.
6. Empty or omitted `reasoning_effort` means use the harness/model default.

After creation, the resolved values are agent-level settings on `ManagedAgent`. Editing an agent should update those agent-level values directly; later template/project default changes should not silently rewrite existing agents.

Recommended config examples:

```yaml
projects:
- key: app
  name: App
  path: /Users/you/Code/app
  agent: codex
  model: gpt-5.1-codex-max
  reasoning_effort: high
```

```yaml
reviewer:
  name: Reviewer
  agent: claude
  model: sonnet
  reasoning_effort: xhigh
  prompt: Review %{project_name}.
```

Implementation notes:

- Add `:model` and `:reasoning_effort` to `AgentTemplateConfig` and `ProjectConfig`.
- Add `model:` and `reasoning_effort:` to `ManagedAgent#initialize`, `from_hash`, `to_hash`, `update!`, and `clone_agent`.
- Store `model` and `reasoning_effort` only when non-empty to keep existing `managed_agents.json` compatible.
- Normalize by trimming whitespace. Do not downcase model names; provider IDs can be case-sensitive or include punctuation.
- Normalize `reasoning_effort` by trimming whitespace and downcasing. Keep it as a string rather than a hard enum so Tycho does not need a release when providers add new levels.
- Suggested known values:
  - Codex: `minimal`, `low`, `medium`, `high`, `xhigh`
  - Claude: `low`, `medium`, `high`, `xhigh`, `max`
- Avoid validating against a static allowlist in the first version.
- Add a small display helper such as `model_label`, returning the configured model or `default`.
- Add a small display helper such as `reasoning_effort_label`, returning the configured effort or `default`.

## Command Construction

Add a helper:

```ruby
def model_arguments
  @model.to_s.strip.empty? ? [] : ["--model", @model.to_s.strip]
end

def codex_reasoning_effort_arguments
  effort = @reasoning_effort.to_s.strip.downcase
  effort.empty? ? [] : ["-c", "model_reasoning_effort=\"#{effort}\""]
end

def claude_effort_arguments
  effort = @reasoning_effort.to_s.strip.downcase
  effort.empty? ? [] : ["--effort", effort]
end
```

Apply it to all built-in adapter paths:

- Codex first run: `codex exec --model <model> -c model_reasoning_effort="<effort>" ...`
- Codex resume: `codex exec resume --model <model> -c model_reasoning_effort="<effort>" ... <session_id> -- <prompt>`
- Codex interactive: `codex --model <model> -c model_reasoning_effort="<effort>" ...` before `resume <session_id>` when resuming.
- Claude print mode: `claude --model <model> --effort <effort> --print --output-format stream-json ...`
- Claude resume/session-id print mode: same `--model` and `--effort` before session arguments or prompt.
- Claude interactive: `claude --model <model> --effort <effort> ... --resume <session_id>` when applicable.

Use no argument when the corresponding field is empty. Model and effort should be independently optional.

Custom Claude-compatible harnesses need one explicit decision:

- Recommended first behavior: pass `--model` to custom harnesses whose `adapter: claude`, because Tycho already appends Claude CLI flags to those wrappers.
- Also pass `--effort` to custom harnesses whose `adapter: claude` when `reasoning_effort` is configured.
- Document that custom wrappers must either forward or consume `--model` and `--effort`.
- If this is too risky for local wrappers, add `supports_model_argument: false` and `supports_effort_argument: false` custom harness config later. Do not add those switches until a real wrapper needs them.

## TUI Display And Editing

Agent creation/editing:

- Add a `Model` field to `UI::AgentEditor`.
- Add an `Effort` field to `UI::AgentEditor`.
- Keep both as text inputs, not fixed selects, for the first version.
- When catalog suggestions are available, surface them as autocomplete/picker hints while preserving manual entry.
- On harness changes, refresh model and effort suggestions for the new harness.
- On model changes, refresh effort suggestions for the selected model when the harness exposes per-model effort metadata.
- On template changes, update the model field from the selected template's inherited model unless editing an existing agent or the field is dirty.
- On template changes, update the effort field from the selected template's inherited effort unless editing an existing agent or the field is dirty.
- Add an explicit "use default" or "clear" affordance later if users need to reset an agent-level value back to harness default without deleting text manually.
- Show a short hint such as `empty uses harness default`.
- Include `model` and `reasoning_effort` in `AgentEditor#attributes`.

Agent detail:

- Add model and effort to the hero crumb or footer metadata. Preferred:
  - crumb: `Project · template · harness · model · effort`
  - footer row: `Model default` and `Effort default` or configured values
- Keep the agent list compact. If adding model or effort to the list, put them in secondary text after harness only when width allows.

Rendering tests:

- Agent editor renders the model field and template default.
- Agent editor renders the effort field and template default.
- Agent detail shows configured model.
- Agent detail shows configured effort.
- Empty model renders as `default`.
- Empty effort renders as `default`.
- Existing agents without `model` or `reasoning_effort` still render.

## Remote API And Web UI

Remote API:

- Add `model` to `agent_payload`.
- Add `model` to `agent_template_summaries`.
- Add `reasoning_effort` to `agent_payload`.
- Add `reasoning_effort` to `agent_template_summaries`.
- Accept `model` and `reasoning_effort` in create, update, and clone payloads through `agent_attrs`.
- Update `docs/REMOTE_SERVER.md` with the new request and response field.

Remote UI:

- Add a model text input to `renderAgentForm`.
- Add an effort input to `renderAgentForm`, with suggested values in placeholder/help text such as `default, minimal, low, medium, high, xhigh, max`.
- Use Codex catalog suggestions when available, especially per-model effort suggestions from `supported_reasoning_levels`.
- For Claude, show alias and effort suggestions as hints only; do not imply the list is complete.
- Populate model and effort from `agent.model` and `agent.reasoning_effort` when editing/cloning, or from selected template/project defaults when creating.
- Add `data-model`, `data-reasoning-effort`, and harness/catalog metadata to template `<option>` nodes and update the fields when the template changes.
- Track dirty state for model and effort inputs so polling, template changes, and harness changes do not overwrite user-entered values.
- When the selected harness changes, refresh model suggestions and effort suggestions.
- When the selected model changes, refresh effort suggestions and default effort if the effort field is not dirty.
- Add `model` and `reasoning_effort` to `agentFormPayload`.
- Include model and effort in:
  - `agentMeta(agent)`, probably `project / harness / model / effort`
  - agent settings grid
  - archive/clone confirmation metadata
  - project template detail if enough room
- Add `agent.model` and `agent.reasoning_effort` to search matching.
- Render empty model and effort as `default` in display contexts.

Browser verification for Remote UI changes should cover:

- Create form preserves typed model across polling/refresh.
- Create form preserves typed effort across polling/refresh.
- Changing harness updates model and effort suggestion sets.
- Changing model updates effort suggestions for Codex catalog-backed models.
- Changing template updates the model and effort defaults only while the corresponding fields are not dirty.
- Editing an existing agent preserves its model and effort.
- Agent row/card/settings display the model and effort after create/update.
- Mobile viewport does not overflow long provider model IDs.

## Tests

Add or update focused tests:

- `test/registry_test.rb`
  - project-level model inheritance
  - template-level model override
  - project-level reasoning effort inheritance
  - template-level reasoning effort override
  - empty model normalizes to nil/empty
  - empty reasoning effort normalizes to nil/empty
- `test/managed_agent_test.rb`
  - created agents persist resolved model and reasoning effort as agent-level values
  - editing an agent updates agent-level model and reasoning effort without changing template/project defaults
  - cloning an agent copies agent-level model and reasoning effort
  - Codex first-run command includes `--model`
  - Codex resume command includes `--model`
  - Codex first-run command includes `-c model_reasoning_effort="..."`
  - Codex resume command includes `-c model_reasoning_effort="..."`
  - Claude print command includes `--model`
  - Claude print command includes `--effort`
  - Claude-compatible custom harness command includes `--model`
  - Claude-compatible custom harness command includes `--effort`
  - `ManagedAgent#from_hash` handles old persisted agents with no model or reasoning effort
- catalog/discovery tests
  - Codex catalog parser extracts visible model suggestions and per-model reasoning effort options
  - Codex catalog discovery falls back from refreshed catalog to `--bundled` when refresh fails
  - Claude effort discovery parses `claude --help` output when available
  - Discovery failure leaves fields free-form and does not block create/update
- `test/remote_server_test.rb`
  - create/update/clone accept and return `model` and `reasoning_effort`
  - project detail template summaries include `model` and `reasoning_effort`
- `test/rendering_test.rb`
  - TUI agent editor and detail display model and effort correctly
  - TUI agent editor updates model/effort suggestions on harness changes
  - TUI agent editor preserves dirty model/effort fields on template changes
  - long model names fit without corrupting layout
  - long effort values fit without corrupting layout
- Manual Web UI verification or Playwright fallback for visible Remote UI behavior.

Run at least:

```sh
bundle exec ruby -c bin/tycho
bundle exec ruby test/registry_test.rb
bundle exec ruby test/managed_agent_test.rb
bundle exec ruby test/remote_server_test.rb
bundle exec ruby test/rendering_test.rb
bin/test
```

## Rollout Plan

1. Add the model and reasoning-effort fields to config and domain persistence.
2. Pass `--model` and the harness-specific effort argument through Codex and Claude command builders.
3. Add harness catalog discovery for suggestions, with Codex JSON catalog support first and Claude help/alias hints second.
4. Add TUI editor/detail/list display with dirty-field-aware dynamic suggestion updates.
5. Add Remote API request/response support.
6. Add Web UI form/display/search support with the same dynamic suggestion behavior.
7. Update `config/hq.yml.example`, `docs/REMOTE_SERVER.md`, and any README config examples that show managed-agent fields.
8. Add tests and run the verification suite.

## Risks And Decisions

- Do not hardcode current model catalogs in Tycho. Use free-form input first.
- Do not expose provider-specific thinking budgets in the first version. Use `reasoning_effort` because it has a clean mapping across Codex and Claude Code.
- Do not hard-reject unknown effort strings initially. Provider CLIs will produce the authoritative error, and Tycho can add suggestions or validation later.
- Do not maintain static model catalogs per harness version. Prefer harness discovery where available, and keep a free-form fallback everywhere.
- Codex catalog data can include hidden/internal models. Filter by `visibility` for normal UI suggestions.
- Claude Code's `/model` picker is the account-specific source of truth, but there is no non-interactive catalog command in the checked local build. Tycho should present Claude suggestions as hints, not as a complete list.
- Passing `--model` on resume is supported by current local CLI help for both Codex and Claude, but behavior can still depend on provider/session rules. Tycho should record the configured model it requested, not try to infer the model actually used unless parser events expose it reliably later.
- Passing effort on resume should be treated similarly: Tycho records the requested effort and passes the current harness argument, but the harness decides how it applies to existing sessions.
- Claude stream events include `message.model` in observed fixtures, but Codex/Claude output parsing should not be the primary source of truth for display. Persist the requested model on the agent.
- Custom harnesses may not accept `--model` or `--effort` even if they claim Claude compatibility. Document the expectation first; add opt-outs only if needed.
- Existing agents should remain valid. Missing `model` and `reasoning_effort` should display as `default` and should not add model or effort flags to commands.
