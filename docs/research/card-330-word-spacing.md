# Card 330: word spacing in agent messages

[Card 330: Whitespaces appear missing](https://fizzy.startkit.tech/1/cards/330)
reports joined words in a Personal Work message sent to
`tycho-beta-agent-20261017-121243-065367`.

## Finding

The sending model wrote the joined words before Tycho accepted the message.
The card image, sender tool input, receiver raw log, receiver memory, and Chrome
all show the same pattern. Examples include `allthree`, `temporarybranch`, and
`fullbin/test`. This is a source composition issue for this message.

The native sender input contains a JavaScript `const msg` string with those
words. Its complete value equals the receiver's stored user message: 1,086 UTF-8
bytes, SHA-256
`acf36b2f6ce92e0bd24bb5c30b6b4e1d7bde965680779f869d80effc34437711`.
The model's reason for writing compact prose is unknown. The trace proves where
the joined words first appear; it does not prove a model-internal cause.

## Ranked hypotheses and probes

1. **Sender composition.** Prediction: joined words occur in the native tool
   input before the send command runs. Confirmed by an exact string comparison.
2. **Transport or storage.** Prediction: sender text has spaces that receiver
   memory lacks. Rejected for this message: the complete strings are equal.
3. **Rendering.** Prediction: valid source spaces disappear in Chrome. Rejected
   for this message: both DOM `textContent` and visible `innerText` equal source.

The Chrome probe used the real Remote UI with temporary config, logs, workspace,
and fake harnesses. It replayed the exact message at 1440 x 900 and 390 x 844.
Then it changed one variable: `allthree` became `all three`. All four comparisons
preserved the complete source text. No message-content horizontal overflow was
found. These are source/control captures, not UI before/after captures.

## Source evidence

All source files were read only. Only the card 330 message was replayed. Work
from card 329 was not resumed.

| Boundary | Evidence |
| --- | --- |
| Card image | `/Users/didik/.tycho/artifacts/cards-330-327-337-2026-10-20/card-330.png`; inspected directly |
| Native sender | `rollout-2026-10-16T09-01-17-01a14271-3182-7890-9f9d-e43b718296d2.jsonl`, line 3116, `custom_tool_call` / `exec`, `const msg` |
| Sender Tycho raw stream | `secondbrain-20261015-140014-d40053f2.raw.log`, lines 5636-5637, `agent send` command |
| Receiver raw stream | Archived `tycho-beta-20261017-121243-4e213d94.raw.log`, line 152, `prompt=` contains exact message |
| Receiver memory | Same archived log stem, `.memory.jsonl`, sequence 68, `user_message`, author `Personal Work` |
| Native receiver | `rollout-2026-10-17T19-12-45-01a149c7-5f7f-73e2-9d60-40e018ea6f1c.jsonl`, line 472, user input contains exact message |
| Conversation/system artifacts | The archive has no saved `.conversation.log` or `.system.log`; these derived files were not generated in the source archive |

The receiver archive is under
`/Users/didik/.tycho/logs/agents/archive/20261018-215326-tycho-beta-agent-20261017-121243-065367/`.
The native sender and receiver files are under
`/Users/didik/.codex/sessions/2026/10/16/` and `2026/10/17/` respectively.
The receiver's accepted `original.png` attachment was also inspected. It shows
a prototype connection screen and is not the card's reported text block.

## Change and limits

Every managed execution prompt now asks the model to use normal spaces in prose,
including messages to other agents. It asks the model to shorten prose by removing
unnecessary words. It also asks the model to preserve code, commands, paths, URLs,
identifiers, and quoted source exactly. The guidance is added at execution time,
including native resume, even when response style is disabled.

This is generation guidance, not a text repair algorithm. It cannot guarantee
model compliance or repair existing messages. Storage, API payloads, and rendering
are unchanged. No evidence supports a whitespace insertion heuristic.

The regression uses the original joined-word pattern at the command-building
boundary. It fails on the old code because the composition guidance is absent.
It passes after the change for cold and native-resumed Codex, Claude, OpenCode,
and Pi runs. It also checks that the original message reaches the command and
remains unchanged in canonical memory. These checks prove guidance delivery and
source preservation; they do not measure model compliance.

## Review evidence

The retained evidence is outside the checkout at
`/Users/didik/.tycho/artifacts/card-330-investigation/`.
It includes the exact replay source, source hash comparison, Chrome script and
fixture runner, DOM results, desktop/mobile source/control captures, and the
old-fail/new-pass test output. No review images are committed.

There is no UI change, so UI before/after screenshots and accepted native GitHub
UI images are not applicable. The local captures document the investigation.
Independent review must assess the finding and the scope of the guidance before
the draft PR becomes ready. Full-suite and exact-head signoff results belong in
the PR body.
