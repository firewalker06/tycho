# Codex JSON Schema Research

This note captures the command lines used to inspect Codex App Server JSON schemas locally and extract the currently available thread item types for chat UI design.

## Generate Schemas

Generate the full Codex App Server JSON schema set into a temporary directory:

```bash
mkdir -p /tmp/codex-schema && /opt/homebrew/bin/codex app-server generate-json-schema --out /tmp/codex-schema
```

List the generated files:

```bash
find /tmp/codex-schema -maxdepth 2 -type f | sort
```

## Inspect Item Types

Open the generated `ItemCompletedNotification` schema directly:

```bash
sed -n '1,260p' /tmp/codex-schema/v2/ItemCompletedNotification.json
```

Find the `ThreadItem` definitions and related type names:

```bash
rg -n '"ThreadItem"|"enum": \[|"title": ".*ThreadItem|AgentMessage' /tmp/codex-schema/v2/ItemCompletedNotification.json
```

Read the `ThreadItem` section containing the canonical item variants:

```bash
sed -n '520,760p' /tmp/codex-schema/v2/ItemCompletedNotification.json
sed -n '760,980p' /tmp/codex-schema/v2/ItemCompletedNotification.json
sed -n '980,1160p' /tmp/codex-schema/v2/ItemCompletedNotification.json
```

Extract the item type enum values with Ruby:

```bash
ruby -rjson -e 'j=JSON.parse(File.read(%q[/tmp/codex-schema/v2/ItemCompletedNotification.json])); types=j.dig("definitions","ThreadItem","oneOf").map{|i| i.dig("properties","type","enum",0)}; puts types.join("\n")'
```

At the time of writing, that command returned:

- `userMessage`
- `hookPrompt`
- `agentMessage`
- `plan`
- `reasoning`
- `commandExecution`
- `fileChange`
- `mcpToolCall`
- `dynamicToolCall`
- `collabAgentToolCall`
- `webSearch`
- `imageView`
- `imageGeneration`
- `enteredReviewMode`
- `exitedReviewMode`
- `contextCompaction`

## Streaming-Related Notifications

List the generated delta and update notifications:

```bash
find /tmp/codex-schema/v2 -maxdepth 1 -type f | xargs -n1 basename | rg 'DeltaNotification|UpdatedNotification'
```

This is useful for identifying item types that support incremental UI updates, such as:

- `AgentMessageDeltaNotification`
- `CommandExecutionOutputDeltaNotification`
- `FileChangeOutputDeltaNotification`
- `PlanDeltaNotification`
- `ReasoningTextDeltaNotification`
- `TurnDiffUpdatedNotification`
- `TurnPlanUpdatedNotification`

## Notes

- These schemas come from the local Codex CLI, not from a checked-in repository artifact.
- The App Server protocol uses camelCase item type names such as `agentMessage`.
- `codex exec --json` may emit a simplified event stream, so consumers should normalize any protocol differences before rendering.
