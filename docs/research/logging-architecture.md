# HQ Logging Architecture

## Overview

HQ uses a three-tier logging architecture. Tier 1 is the centralized application log.
Tiers 2 and 3 are per-process output capture and structured log parsing, respectively.
Key lifecycle events from Tiers 2 and 3 emit summary lines into Tier 1, giving you
one file to grep when debugging.

## Architecture Diagram

```text
                          HQ Logging Architecture
 ============================================================================

  Tier 1: Application Log (HQ.logger)
 ----------------------------------------
  logs/hq.log  (daily rotation, 7-day retention)

  Sources:
  +-------------+  +-------------+  +--------------+  +-----------+
  |    App       |  |   Config    |  | KamalAction  |  |   Agent   |
  |  lifecycle   |  |   loading   |  |  start/stop  |  | start/stop|
  |  errors      |  |   errors    |  |  completion  |  | exit code |
  |  refresh     |  |   project   |  |              |  | errors    |
  |  spawn       |  |   count     |  |              |  | memory    |
  +------+-------+  +------+------+  +------+-------+  +-----+----+
         |                 |                |                  |
         +--------+--------+--------+-------+---------+-------+
                  |                                   |
                  v                                   v
  +---------------+---+                  +------------+---------+
  |   Health check     |                 |   ActionStore /       |
  |   failures         |                 |   AgentStore errors   |
  +--------------------+                 +----------------------+

  Log format:
  [INFO] [2026-04-25 10:30:00] [App] Starting HQ
  [WARN] [2026-04-25 10:30:05] [Health] myapp: Net::ReadTimeout
  [ERROR] [2026-04-25 10:31:00] [Agent] Memory capture failed for agent-1: ...

  Configurable via TYCHO_LOG_LEVEL env var (default: INFO)

 ============================================================================

  Tier 2: Process Capture Logs (raw output, unchanged)
 ----------------------------------------

  Kamal Actions                    Managed Agents
  +--------------------------+     +-------------------------------+
  | logs/{project}.log       |     | logs/agents/{project}-{time}-{id}.raw.log |
  |                          |     |                               |
  | Raw stdout/stderr from   |     | Raw stdout/stderr from        |
  | kamal deploy/maintenance |     | codex/claude-compatible       |
  +--------------------------+     +-------------------------------+
                                                  |
                                                  | AgentLogParser
                                                  v
 ============================================================================

  Tier 3: Derived/Structured Logs (parsed from Tier 2)
 ----------------------------------------

  +---------------------------+  +---------------------------+
  | same-stem conversation.log |  | same-stem system.log      |
  | User/assistant turns      |  | Tool calls, system events |
  | (human-readable artifact) |  | (human-readable artifact) |
  +---------------------------+  +---------------------------+

  +---------------------------+
  | same-stem memory.jsonl     |
  | Canonical event log       |
  | (persists across runs)    |
  | TUI reads history from    |
  | this file directly        |
  +---------------------------+

 ============================================================================

  State Files
 ----------------------------------------
  logs/actions.json          Kamal action state (PIDs, status)
  logs/managed_agents.json   Agent metadata (PIDs, config, status)
  logs/healthcheck.log       Health check results per project

 ============================================================================

  Data Flow Summary
 ----------------------------------------

  Agent process stdout ----> {project}-{time}-{id}.raw.log -----> AgentLogParser
                                  |                     |
                                  |              +------+------+
                                  |              |             |
                                  |              v             v
                                  |         .convo.log    .system.log
                                  |        (artifact)     (artifact)
                                  |
                                  v
                            HQ.logger <----+
                         (summary lines)   |
                                           |
  Kamal process stdout -> {project}.log ---+

  TUI Chat Viewport (hybrid rendering)
 ----------------------------------------

  +-------------------+     +-------------------+
  | memory.jsonl      |     | raw.log           |
  | (history: past    |     | (live: current    |
  |  runs, user msgs, |     |  run tool calls,  |
  |  assistant msgs)  |     |  assistant msgs)  |
  +--------+----------+     +--------+----------+
           |                          |
           v                          v
      AgentChatLog.chat_blocks (merged ChatBlock[])
                       |
                       v
                 TUI chat sidebar
              (rendered in real-time)

  User sends message --> memory.jsonl --> appears immediately
  Agent streams output -> raw.log ------> appears on next tick
  Run finishes ---------> capture_run_memory! --> raw.log content
                          moves into memory.jsonl as history
```
