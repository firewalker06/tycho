---
name: SYSTEM_PROMPT_AUDIT
description: Inventory of Tycho-authored system prompts and automatically injected managed-agent prompt context
type: audit
last_audited: 2026-07-12
---

# System Prompt and Automatic Prompt Injection Audit

## Scope

This audit covers prompt text that Tycho authors, stores, transforms, or adds automatically before invoking a managed-agent harness. It includes selectable agent templates, project and schedule context, replayed memory, attachment and inquiry context, resume fallbacks, and structured-output controls.

It does not attempt to inventory instructions owned by Codex, Claude, OpenCode, custom harness wrappers, installed skills, or repository instruction files such as `AGENTS.md` and `CLAUDE.md`. Tycho passes the workspace and skill trigger text to the harness, but those external systems decide if and how their own prompts or repository instructions are loaded. UI labels, validation errors, notifications, hook payloads, and the TUI memory-rebuild confirmation are also outside scope because they are not sent to the managed agent.

## Executive Summary

Tycho does not use a harness-native system-message API. On a cold or non-resumable run, it reads `memory.jsonl`, renders every retained entry into one text argument with role headers (`SYSTEM:`, `USER:`, and `ASSISTANT:`), appends the current response-style policy and an ephemeral final-output checklist, and supplies that string to the selected harness. On a native resumed run, it normally sends only the latest user message plus the same execution-time guidance and relies on the harness session for earlier context.

The stable system context at agent creation is two separate pinned memory events: generated project identity followed by the selected template or schedule system message. Additional history-derived context can be injected on cold replay: unresolved inquiry context, tool summaries, run summaries, and attachment locations.

The audit originally found two high-priority contract mismatches and three lower-priority clarity risks. Follow-up work on 2026-07-11 and 2026-07-12 resolved them, including a later focused `no_action_needed` status-classification ambiguity:

1. Resolved: `no_action_needed` is now allowed by the canonical schema and inherited by Claude's compact schema.
2. Resolved: the Remote UI now consumes the backend-provided schedule system-message template, with an equivalent compatibility fallback.
3. Resolved: editing an agent now replaces matching prior base-prompt events in `memory.jsonl`, deduplicating identical prior copies while preserving project context.
4. Resolved: prompt transport and unsliced cold-replay documentation now match the command builders.
5. Resolved: outstanding inquiry reminders read normalized `fields` labels first and retain `requested_schema.properties` as a legacy fallback.
6. Resolved: global guidance now classifies what happened during the run, contrasts `no_action_needed` with `success`, discloses quiet-notification behavior, and is reinforced by schema descriptions and result normalization.

## End-to-End Introduction Order

For a newly created, non-resumed agent, effective prompt order is:

1. Project context system event.
2. Selected template prompt or schedule system-message event.
3. Outstanding inquiry context, when an inquiry is unresolved.
4. Persisted user, assistant, tool-summary, and run-summary events in memory order.
5. Attachment-use instructions immediately after each user message that has attachments.
6. Ephemeral response-style policy.
7. Ephemeral final-output checklist.
8. Harness structured-output schema, supplied separately as a CLI option where supported.

`ManagedAgent#composed_prompt` renders items 1–5 as:

```text
SYSTEM:
<system content>

USER:
<user content>

ASSISTANT:
<assistant content>
```

On native resume, items 1–5 are normally not replayed. Tycho sends the latest user message after the previous run boundary, or the continuation fallback, then appends items 6–7. The harness's native session is expected to retain the earlier context. The schema remains attached where the command builder supports it.

## Prompt Inventory

### 1. Configured system-prompt templates

**Introduced:** Registry load reads `~/.tycho/config/system_prompts.yml` (or `TYCHO_SYSTEM_PROMPTS_PATH`). When an agent is created from a template, `AgentStore#create_from_template` persists the resolved prompt as the second pinned system event. The TUI, Remote UI, and CLI all converge on this creation path. Agent edits replace matching prior base-prompt events rather than appending another active copy.

**Content:** Operator-defined text. A top-level scalar is the prompt; a mapping uses `prompt` or `content`. Mapping metadata can also choose name, harness, model, reasoning effort, and sandbox mode. Template text supports Ruby `format` placeholders:

- `%{project_key}`
- `%{project_name}`
- `%{project_path}`
- `%{project_group}`
- `%{workspace}` (alias of project path)

The shipped example defines `custom`, `implementer`, `reviewer`, and `maintenance`; their full sample wording remains canonical in [`config/system_prompts.yml.example`](../config/system_prompts.yml.example).

**Purpose:** Give an agent its long-lived role, task policy, and operator-selected working instructions.

**Source:** `Registry#system_prompt_templates`, `#resolve_template_prompt`, `#interpolate_prompt`, and `AgentStore#create_from_template`.

### 2. Registry fallback template

**Introduced:** Only when `system_prompts.yml` is missing or empty. It becomes the project's sole `default` template and is persisted at agent creation like any configured template.

**Content:**

```text
Work inside <expanded project path>. Inspect the repository, identify the highest-value next task, implement it if safe, run the relevant checks, and summarize the result.
```

**Purpose:** Keep agent creation usable without a separate prompt-template file.

**Source:** `Registry#default_template`.

### 3. Project identity context

**Introduced:** As the first pinned system event whenever a normal or scheduled agent is created. It is also prepended once when loading legacy agents that lack it, and re-checked after create, edit, clone, CLI, TUI, or Remote UI flows. Exact-content deduplication prevents the same current block being added twice.

**Content:**

```text
Project:
- Key: <project key>
- Name: <project name>
- Path: <project path>
```

**Purpose:** Anchor the agent to Tycho's project identity and workspace even when the selected template is generic.

**Source:** `AgentStore#project_context_prompt`, `#system_messages_for`, `#backfill_project_context_prompt!`, and `ManagedAgent#ensure_project_context_prompt!`.

### 4. Scheduled-agent system message

**Introduced:** Once when the scheduler creates its persistent schedule-owned managed agent. It is not re-added for each due run. If `target.system_message` is non-empty, that exact custom text is used; otherwise the backend generates the default below. Each due run separately appends the configured schedule `message` as a normal user message.

**Backend default content:**

```text
This managed agent is owned by the Tycho schedule <name and/or key>.
Treat each scheduled user message as one recurring run in the same long-lived session.
Use prior session context when it helps, but make each run's outcome clear and operator-facing.
Choose `status: no_action_needed` only for a successful observational or recurring check where no new condition required action and you did not complete a requested change, answer, commit, review, or deliverable. Use `status: success` when you completed any requested action or produced the requested result, even if nothing remains to do afterward. `no_action_needed` is a quiet outcome that suppresses operator unread and push notifications, so do not use it as a synonym for "finished" or "no next steps."
If you need human input, ask a precise structured inquiry and stop instead of guessing.
```

**Remote UI pre-filled content:** The Remote `/setup` payload exposes this backend template with a `%{title}` placeholder. The UI substitutes the visible schedule label/key and uses an equivalent local fallback only for compatibility with older servers.

**Purpose:** Define recurring-session semantics, distinguish no-op checks from completed actions, and require structured escalation rather than guessing.

**Source:** `AgentStore#scheduled_system_prompt`, `#create_scheduled`, `Scheduler#build_scheduled_agent`, and `defaultScheduleSystemMessage` in `lib/hq/remote_ui/assets/app.js`.

### 5. Role labels and cold memory replay

**Introduced:** At every execution for which native resume is not eligible: no known session ID, a Codex/OpenCode session with no prior run, or a Claude-like session that has not bootstrapped. All `AgentMemory#prompt_messages` entries are flattened into the execution prompt.

**Content transformations:**

- Pinned system prompts become `SYSTEM:\n<content>`.
- User messages become `USER:\n<content>`.
- Assistant messages become `ASSISTANT:\n<content>`.
- Tool summaries become system entries containing `tool: <stored summary>`.
- Run summaries become system entries containing `run summary — <status>: <summary>` (status is omitted if empty).

There is currently no slicing in `prompt_messages`; cold replay includes the complete memory file. Token-usage events, inquiry-response events, and attachment events are not separately rendered, although an inquiry answer is also stored as a user message and attachment metadata is rendered with that user message.

**Purpose:** Reconstruct local conversation and operational context when no harness-native session can supply it.

**Source:** `AgentMemory#prompt_messages`, `ManagedAgent#composed_prompt`, and `#native_resume?`.

### 6. Outstanding inquiry reminder

**Introduced:** During cold prompt composition only when memory contains a latest `inquiry_request` with no matching later response. It is inserted as a system entry after pinned system prompts and before the replayed event stream.

**Content:**

```text
Outstanding inquiry from the previous run:
<inquiry message>
Requested fields: <schema property titles or keys, comma-separated>
```

The `Requested fields` line is omitted when the legacy `requested_schema.properties` shape is absent. Current normalized `fields` arrays are not listed by this formatter.

**Purpose:** Stop a cold-started agent from losing track of unresolved human input.

**Source:** `AgentMemory#unresolved_inquiry_event` and `#format_inquiry_context`.

### 7. Attachment context

**Introduced:** When a persisted user message has normalized file or link attachments. It is appended to that message during cold composition. On native resume, `latest_user_message_after` adds the same block to the latest user text. If the Remote UI receives attachments without prompt text, it first creates the user message `Please review the attached files.`

**Content:**

```text
<user message>

Attachments are available as files or links. Use the targets below when you need to inspect them:
- <type> <title>: <path or URL>
```

There is one bullet per normalized attachment. A missing title falls back to the target.

**Purpose:** Turn attachment metadata into actionable local paths or links for harnesses that otherwise receive only text.

**Source:** `ManagedAgent#prompt_message_content`, `AgentMemory#message_with_attachment_context`, and `RemoteService#prompt_text`.

### 8. Native-resume continuation fallback

**Introduced:** On a native resumed run when no non-ignored user message exists after the previous run's finish/start boundary.

**Content:**

```text
Continue from the current HQ managed-agent state.
```

**Purpose:** Give resume commands a non-empty turn and ask the harness to continue from its server-side session state.

**Source:** `ManagedAgent#prompt_for_execution`.

### 9. Ephemeral response-style policy

**Introduced:** At every execution, cold or resumed, after task/session context and before the final-output checklist. Tycho loads the current `~/.tycho/config/response_style.md` (or `TYCHO_RESPONSE_STYLE_PATH`) at execution time, so existing native sessions receive policy updates without memory migration. A project may replace the global text with `response_style`; a structured prompt template may override the project, and either scope may set `response_style: false` to opt out.

**Default content:** The shipped policy asks the harness to lead with the outcome, use simple accurate words, active verbs, concrete details, logical flow, and a natural human voice; remove filler and repetition; revise once; and stop when the point has landed. It explicitly defers to technical precision, required terminology, formats, code, commands, schemas, quotations, and a user-requested genre or tone. The exact text is canonical in [`config/response_style.md.example`](../config/response_style.md.example).

**Purpose:** Give all harnesses a shared default for operator-facing prose while keeping task content, memory, and structured-output requirements separate. Persisted run metadata records the native harness `session_id` captured from the run, rather than a fingerprint of the policy text.

**Source:** `ResponseStylePolicy`, `ManagedAgent#with_execution_guidance`, and registry project/template `response_style` resolution.

### 10. Ephemeral final-output checklist

**Introduced:** At the end of every execution prompt, cold or resumed, immediately before command construction. It is not stored in `memory.jsonl`, so it does not accumulate across runs. Exact substring detection avoids appending it twice if the incoming prompt already contains the full checklist.

**Content:**

```text
For `summary`, write a concise operator-facing Markdown summary of the outcome, key changes or findings, blockers, and next steps in 1-3 short paragraphs or bullets. Choose `status: no_action_needed` only for a successful observational or recurring check where no new condition required action and you did not complete a requested change, answer, commit, review, or deliverable. Use `status: success` when you completed any requested action or produced the requested result, even if nothing remains to do afterward. `no_action_needed` is a quiet outcome that suppresses operator unread and push notifications, so do not use it as a synonym for "finished" or "no next steps." Before final structured output, check whether this run created or referenced a PR, plan, review, report, markdown file, image, or other durable artifact. If yes, include it in `attachments`: use `type: file` with `path` for local files, or `type: link` with an http(s) `url` for web links.
```

**Purpose:** Standardize operator summaries, suppress false-positive work notifications for healthy no-op checks, and preserve durable outputs as structured attachments.

**Source:** `ManagedAgent::FINAL_OUTPUT_CHECKLIST`, `.with_final_output_checklist`, and `#prompt_for_execution`.

### 11. Structured-output schema controls

**Introduced:** Separately from prompt text by `AgentCommandBuilder`:

- Cold Codex runs receive `--output-schema config/schemas/agent_result.json` and `-o <last-message path>`.
- Resumed Codex runs receive only `-o`; the resume subcommand does not currently get `--output-schema`.
- Claude-compatible runs receive a compact `--json-schema` on both cold and resumed runs.
- OpenCode receives no schema option; output is best-effort and normalized after parsing.

**Content:** The canonical schema requires `status`, `summary`, `inquiry`, and `attachments`, and its status enum includes `no_action_needed`. The Claude projection keeps canonical `status` and `summary`, including that enum, but requires string fields `inquiry_json` and `attachments_json` because of Claude CLI schema constraints. Their descriptions tell the agent to return JSON-encoded values or the literal string `null`.

**Purpose:** Constrain final agent output into the shape Tycho needs for statuses, summaries, structured inquiries, and artifact attachments.

**Source:** `config/schemas/agent_result.json`, `ManagedAgent#claude_result_schema`, and `AgentCommandBuilder`.

### 11. Skill trigger insertion (user-mediated, not automatic context)

**Introduced:** Only when the operator selects a discovered skill or accepts skill autocomplete in the TUI/Remote UI. Tycho inserts `$<skill>` for Codex-style harnesses or `/<skill>` for Claude-style harnesses into the editable user prompt. It does not read `SKILL.md` content and inject it itself.

**Content:** The harness-specific trigger token and skill name, followed by a space.

**Purpose:** Help the operator ask the external harness to activate a skill. Actual skill instruction loading belongs to the harness and is outside this audit's Tycho-authored prompt inventory.

**Source:** `SkillDiscovery`, `ChatComposer`, and Remote UI `insertSkill`/skill-autocomplete helpers.

## Lifecycle Matrix

| Event | Project context | Base template / schedule system | History-derived context | Response style | Final checklist | Schema |
|---|---|---|---|---|---|---|
| Normal agent creation | Persisted once | Persisted once | None yet | Resolved, not persisted to memory | Not until run | Not until run |
| Scheduled agent creation | Persisted once | Custom or generated schedule context, persisted once | First run message is persisted as user text | Project setting inherited | Added only at execution | Harness-dependent |
| Cold/non-resumed run | Replayed | Replayed with the current replacement base prompt | Entire promptable memory replayed | Added | Added | Codex/Claude enforced; OpenCode none |
| Native resumed run | Not resent by Tycho | Not resent by Tycho | Latest user message only; attachment block may be included | Added | Added | Claude enforced; resumed Codex not enforced; OpenCode none |
| Agent edit | Existing context retained | Matching prior base-prompt copies replaced by one new pinned event | Existing non-prompt history retained | Current template setting applied | Added on next run | Harness-dependent |
| Legacy-agent load | Backfilled if exact current project block is absent | Existing prompt retained | Existing memory retained | Global default unless configured later | Added on next run | Harness-dependent |
| Clone | Fresh project context | Cloned/current prompt becomes fresh system event | Source conversation is not copied | Source setting copied | Added on first clone run | Harness-dependent |

## Findings and Recommended Follow-up

### Resolved: `no_action_needed` schema parity

`ManagedAgent::FINAL_OUTPUT_CHECKLIST`, the backend schedule contract, scheduler state handling, rendering, and schemas now all recognize `no_action_needed`. The canonical enum is the source for Claude's compact schema.

**Resolution:** Added the enum value and regression coverage for both canonical and compact Claude schemas.

### Resolved: Remote UI and backend schedule defaults share one contract

The Remote UI reads `config.schedule_system_message_template` from the backend setup payload and substitutes the schedule title. Its older-server fallback mirrors the same recurring-session and status guidance.

**Resolution:** Added the setup payload field, UI consumption, compatibility fallback, API regression coverage, and browser verification.

### Resolved: Agent edits replace prior base-prompt copies

`ManagedAgent#update!` now passes the old and new base prompts to `AgentMemory#replace_system_prompt!`. Matching old prompt events are collapsed into one replacement event, while differently worded system context such as the project block is preserved.

**Resolution:** Added cold-replay regression coverage proving the project context remains, the old base prompt is absent, and the replacement appears once.

### Resolved: Prompt transport and replay documentation

`docs/AGENT_MEMORY.md`, `AGENTS.md`, and `CLAUDE.md` now state that command builders append prompt text as a harness argument and that cold replay includes complete promptable memory history.

**Resolution:** Documentation updated to match current Codex, Claude-compatible, and OpenCode command construction.

### Resolved: Inquiry reminder supports normalized fields

The outstanding-inquiry reminder now reads labels from canonical `inquiry.fields`, falls back from an empty label to the field key, and uses legacy `inquiry.requested_schema.properties` only when normalized labels are unavailable.

**Resolution:** Added normalized-first and legacy-fallback regression coverage.

## Focused Audit: `no_action_needed`

### Intended Runtime Meaning

`no_action_needed` is a successful, quiet outcome for an observational check that found no new condition requiring intervention. The canonical example is a recurring PR-review run that inspected the current set and found no new or changed PR to review.

It is not intended as a synonym for “the task is finished” or “nothing remains after I completed the work.” A completed implementation, requested answer, commit, generated asset, or other requested deliverable should use `success`, even when there are no remaining next steps.

This distinction matters operationally. When Tycho receives `no_action_needed`, it:

- shows the result as `no action`;
- does not mark the managed agent unread;
- suppresses agent push notifications;
- records a scheduled run as `no_action_needed` without first-success or recovery notification;
- clears schedule failure tracking as a healthy outcome.

A false `no_action_needed` can therefore hide meaningful completed work from the operator.

### Current Prompt Text

Every managed-agent execution, scheduled or interactive, ends with this global instruction from `ManagedAgent::FINAL_OUTPUT_CHECKLIST`:

```text
Choose `status: no_action_needed` only for a successful observational or recurring check where no new condition required action and you did not complete a requested change, answer, commit, review, or deliverable. Use `status: success` when you completed any requested action or produced the requested result, even if nothing remains to do afterward. `no_action_needed` is a quiet outcome that suppresses operator unread and push notifications, so do not use it as a synonym for "finished" or "no next steps."
```

The rest of that checklist asks for a concise summary and attachment reporting.

Backend-generated schedule sessions include the same guidance in their stable system message. The Remote `/setup` payload exposes that schedule template with a `%{title}` placeholder, and the Remote UI uses it for schedule creation and editing. Its compatibility fallback carries the same wording.

The canonical JSON schema now describes the complete status decision rule and quiet consequence; Claude inherits that property in its compact schema. Result normalization preserves legitimate no-op checks, converts `no_action_needed` with a structured inquiry to `input_required`, and converts high-confidence completed-work summaries to `success`.

### Observed Local Behavior

A read-only scan of local agent raw logs on 2026-07-11 found 40 structured results with `status: no_action_needed`:

- 31 were recurring PR-review checks reporting no new or changed review work. These match the intended meaning.
- 9 completed concrete requests and are inconsistent with the intended meaning. They included implementation changes, visual/content changes, commits, a direct cron-expression answer, and an explicit “reply with OK” task.

This sample is correlated—31 correct outcomes came from one long-lived scheduled review session—so the ratio is not a general model-quality metric. It does demonstrate that the current wording repeatedly produces the same classification error across multiple task types and sessions.

### Root Causes Before Remediation

1. **The rule tests the end state, not whether action occurred.** After successfully implementing or committing work, there is often “nothing for the operator or agent to act on.” The sentence therefore literally matches both `success` and `no_action_needed`.
2. **“Requested check” is underspecified.** Models can treat audits, questions, reviews, implementation verification, and even arbitrary requests as checks.
3. **The rule is global.** It is appended to every execution, including implementation, writing, image, commit, and question-answer tasks where a no-op outcome is usually inapplicable.
4. **The contrast with `success` is inconsistent.** Only the backend schedule default explains that completed actions and deliverables are `success`; Remote UI schedules and ordinary agents do not receive that contrast.
5. **The quiet consequence is hidden.** The model is not told that this status suppresses unread state and notifications, so it cannot account for the cost of a false classification.
6. **The schema supplies choices without definitions.** An enum constrains spelling, not meaning. There are no per-status descriptions or conditional rules.
7. **There is no semantic validation.** Tycho permits `no_action_needed` alongside attachments or other content and does not reject summaries that describe implemented changes or commits. An inquiry paired with this status is also schema-valid even though the states conflict operationally.
8. **The name invites a “no further action” reading.** `no_action_needed` can naturally mean either “no action was necessary” or “no further action is necessary after completion.” Tycho intends only the first meaning for quiet checks.

### Implemented Decision Rule

Status selection should classify what happened during the run, in this order:

1. Use `input_required` when human input is necessary to proceed.
2. Use `blocked` when progress cannot continue without an external change and no immediate structured answer can resolve it.
3. Use `failed` when the requested work or check failed.
4. Use `partial` when meaningful requested work was completed but required work remains.
5. Use `success` when the run completed a requested action, change, answer, commit, review, or deliverable.
6. Use `no_action_needed` only when the task was observational/checking in nature, the check completed successfully, and it found no new condition requiring action. It must not be selected merely because completed work leaves no next step.

An incidental report or log from a no-op check may still be attached. If producing the document, answer, or artifact was itself the requested deliverable, the status should be `success`.

### Implemented Replacement Prompt

```text
Choose `status: no_action_needed` only for a successful observational or recurring check where no new condition required action and you did not complete a requested change, answer, commit, review, or deliverable. Use `status: success` when you completed any requested action or produced the requested result, even if nothing remains to do afterward. `no_action_needed` is a quiet outcome that suppresses operator unread and push notifications, so do not use it as a synonym for “finished” or “no next steps.”
```

This definition is now shared by the global final-output checklist, backend schedule template, Remote UI schedule defaults, and canonical status schema description. Result normalization also guards contradictory inquiries and high-confidence summaries beginning with completed-work verbs such as `implemented`, `committed`, `created`, `fixed`, or `deployed`.

Residual risk remains: models can ignore instructions, older user-copied schema files may lack the new description, and the completed-work safeguard intentionally uses a narrow high-confidence pattern rather than trying to infer all task semantics from prose. The global execution checklist still carries the new rule on every run, including native resumes.

## Verification Notes

The inventory was cross-checked against prompt-related source and regression coverage in:

- `lib/hq/domain/managed_agent.rb`
- `lib/hq/domain/agent_memory.rb`
- `lib/hq/domain/agent_store.rb`
- `lib/hq/domain/agent_command_builder.rb`
- `lib/hq/domain/scheduler.rb`
- `lib/hq/registry.rb`
- `lib/hq/remote_server.rb`
- `lib/hq/remote_ui/assets/app.js`
- `config/system_prompts.yml.example`
- `config/schemas/agent_result.json`
- `test/managed_agent_test.rb`
- `test/registry_test.rb`
- `test/scheduler_test.rb`
- `test/remote_server_test.rb`

The original document was a behavior-only audit. Its follow-up status was updated after the schema, prompt replacement, inquiry-label, and documentation changes landed locally on 2026-07-11.
