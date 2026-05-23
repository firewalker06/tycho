# Claude JSON Schema Research

This note captures the command lines used to inspect Claude Code's local CLI surface and the official Anthropic documentation for structured and streaming output.

Unlike Codex, Claude Code does not currently expose a local `generate-json-schema` command for its stream output. Anthropic's docs currently describe the stream message schema directly and note that a JSONSchema-compatible format is planned but not yet published.

Official docs used:

- <https://docs.anthropic.com/en/docs/claude-code/sdk>

## Local CLI Commands

Check the installed Claude Code version:

```bash
claude --version
```

Inspect the main CLI help:

```bash
claude --help
```

Inspect the non-interactive print mode help, including streaming-related flags:

```bash
claude -p --help
```

The relevant flags surfaced by local help were:

- `-p`, `--print`
- `--output-format text|json|stream-json`
- `--input-format text|stream-json`
- `--include-partial-messages`
- `--include-hook-events`
- `--json-schema`

Installed version observed during this research:

- `2.1.94 (Claude Code)`

## Official Stream Message Types

Anthropic's Claude Code SDK docs describe the top-level streamed JSON message union as:

- `system` with subtype `init`
- `user`
- `assistant`
- `result` with subtype `success`
- `result` with subtype `error_max_turns`
- `result` with subtype `error_during_execution`

The docs also state that:

- each message is emitted as a separate JSON object
- `--output-format stream-json` streams messages in realtime
- `Message` and `MessageParam` are the underlying content shapes for `assistant` and `user`
- a JSONSchema-compatible version of these types is planned but not yet published

## Practical Notes For HQ

- Claude's currently documented stream surface is message-oriented, not item-oriented like Codex App Server `ThreadItem`.
- If HQ wants a unified chat renderer, Claude output will likely need to be normalized from top-level message events into internal UI events such as `assistant_message`, `user_message`, `tool_activity`, and `result`.
- Tool-use detail may still be available inside the Anthropic `Message` content blocks, but that is not exposed in the local help as a standalone schema artifact.
