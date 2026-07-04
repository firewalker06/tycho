# Tool Log Shapes - Claude Raw Stream

This note documents the synthetic stream shapes used by
`lib/hq/parser/claude.rb` and `test/fixtures/parser/claude/*.jsonl`.

The fixtures intentionally avoid real workspace paths, repository names, PR
numbers, provider IDs, and command output. Keep them synthetic so the parser
regression suite can be published safely.

## Event Shape

Claude-like harnesses emit one JSON object per line.

Tool calls appear in `assistant` events:

```json
{
  "type": "assistant",
  "message": {
    "role": "assistant",
    "content": [
      {
        "type": "tool_use",
        "id": "toolu_demo_bash",
        "name": "Bash",
        "input": {
          "description": "Inspect demo project status",
          "command": "bin/tycho agent status demo-agent"
        }
      }
    ]
  }
}
```

Tool results appear in `user` events and are correlated by `tool_use_id`:

```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": [
      {
        "type": "tool_result",
        "tool_use_id": "toolu_demo_bash",
        "content": "Demo agent status: complete\nResult: ready"
      }
    ]
  }
}
```

The result `content` is usually a string. The `Agent` tool can return an array
of text parts:

```json
[
  {
    "type": "text",
    "text": "Here are the demo findings:\n\n- Parser fixtures use synthetic data."
  }
]
```

## Tool Labels

HQ renders compact labels for each tool call:

| Tool | Input keys | Compact label |
| --- | --- | --- |
| `Bash` | `description`, `command`, `timeout` | Description plus command on the next line |
| `Read` | `file_path`, `offset`, `limit` | Basename, with range suffix when present |
| `Write` | `file_path`, `content` | Basename |
| `Edit` | `file_path`, `old_string`, `new_string` | Basename |
| `Grep` | `pattern`, `path` or `glob` | Pattern plus scope |
| `Glob` | `pattern`, `path` | Pattern plus scope |
| `Agent` | `description`, `subagent_type`, `prompt` | Description, falling back to subagent type |
| `Skill` | `skill`, `args` | Slash command form |
| `StructuredOutput` | `status`, `summary`, `inquiry`, `attachments` | Status plus first summary line |

## Tool Result Preview

Tool results preserve the full raw body in `metadata["raw"]`, but the compact
preview uses the first non-empty line. This keeps chat and system views compact
while preserving the detail payload for expanded views.

## Fixture Maintenance

When adding a new tool shape:

1. Add a synthetic two-line fixture under `test/fixtures/parser/claude/`.
2. Add parser assertions in `test/parser_test.rb`.
3. Add memory persistence assertions in `test/memory_entries_test.rb`.
4. Run `bundle exec ruby test/parser_test.rb` and
   `bundle exec ruby test/memory_entries_test.rb`.
