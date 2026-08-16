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
  |   Remote UI        |                 |   AgentStore errors   |
  |   request failures |                 |                      |
  +--------------------+                 +----------------------+

  Log format:
  [INFO] [2026-04-25 10:30:00] [App] Starting HQ
  [WARN] [2026-04-25 10:30:05] [Remote] GET /agents 502 1002.4ms
  [ERROR] [2026-04-25 10:31:00] [Agent] Memory capture failed for agent-1: ...

  Configurable via TYCHO_LOG_LEVEL env var (default: INFO)

 ============================================================================

  Tier 2: Process Capture Logs (raw output, unchanged)
 ----------------------------------------

  +--------------------------+     +-------------------------------+
  | logs/{project}.log       |     | logs/agents/{project}-{time}-{id}.raw.log |
  |                          |     |                               |
  | Raw stdout/stderr from   |     | Raw stdout/stderr from        |
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
  logs/managed_agents.json   Agent metadata (PIDs, config, status)

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

  TUI Chat Viewport (durable incremental rendering)
  ----------------------------------------

  Harness process --> AgentStreamRecorder --> raw.log (unchanged)
                              |
                              v
                     AgentStreamProjector
                              |
                              v
                     AgentEventJournal
                              |
                              v
                    memory.jsonl (agent-wide sequence)
                              |
                              v
                   AgentChatLog.chat_blocks
                       |
                       v
                 TUI chat sidebar
              (rendered incrementally)

  User sends message --> memory.jsonl --> appears immediately
  Agent streams output -> recorder -----> raw.log + memory.jsonl
  Delegation events ----> memory.jsonl --> share the same sequence
  Run finishes ---------> capture_run_memory! reconciles missing IDs
```
