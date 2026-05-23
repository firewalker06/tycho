# Rendering Glamour markdown inside a Bubbletea program

HQ renders user and assistant message detail views as markdown via the
[Glamour](https://github.com/charmbracelet/glamour) Ruby gem. Both
`bubbletea-ruby` and `glamour-ruby` embed Charm's Go libraries as native
extensions. Running them together in one Ruby process produced
unpredictable, multi-second render stalls that froze the TUI. This note
documents the investigation and the fix now wired into the codebase.

## Symptom

First click on a User or Assistant message detail froze the Chat screen
for 1.7 – 11 seconds (observed range across runs at the same width). The
UI thread was fully blocked: queued keystrokes fired one-by-one against
stale screens, which manifested as the Chat screen closing and the agent
being re-started with the default "Continue from the current HQ
managed-agent state." prompt.

## Diagnosis

- A standalone benchmark rendering the same markdown — same width, same
  style — through `Glamour.render` outside Bubbletea finished in ~1–10ms.
- The same call inside a running Bubbletea program took 5000ms+ and
  varied run-to-run.
- No Ruby-side contention explained it: moving the render to a
  `Thread.new` or a process-wide cache lookup did not reduce the in-TUI
  latency. The stall lived below Ruby, in the Go runtime.

The root cause is that **`bubbletea-ruby` and `glamour-ruby` each embed
their own Go runtime**, and when both are loaded in the same MRI process
their schedulers contend for OS threads and GVL re-entry. Bubbletea is
already spinning its event loop on Go goroutines when Glamour's native
extension is invoked, and the call path through `cgo` serializes badly
under that load.

No amount of Ruby-level threading can untangle this — both gems share
the same embedded Go runtime inside `libruby`'s process.

## Fix

Render Glamour in a **separate Ruby subprocess** so it gets its own
fresh Go runtime, uncontended.

- `bin/worker --type glamour` — a minimal Ruby entry point that reads
  `width\n<markdown>` from stdin and writes ANSI-rendered output to
  stdout. No shared state with the HQ process.
- `HQ::UI::Rendering::ChatRendering.glamour_subprocess_render` spawns
  the worker via `IO.popen([RbConfig.ruby, WORKER_PATH, "--type", "glamour"], "r+")`
  per render.
- Results go into a process-wide `GLAMOUR_CACHE` keyed by
  `[width, content]` and capped at 256 entries (FIFO eviction), so the
  subprocess cost (~170ms cold) is paid once per unique message.
- Renders dispatch on a Ruby `Thread.new` to keep the UI responsive; a
  `ChatRenderPollMessage` scheduled through `Bubbletea.tick(0.2)` in
  `HQ::App` polls until the render lands in cache, then stops.
- Tests set `ENV["TYCHO_GLAMOUR_SYNC"] = "1"` to force the synchronous
  code path and get deterministic output.

### Observed latencies

| Render path                         | Time        |
| ----------------------------------- | ----------- |
| Glamour in isolation                | ~1–10ms     |
| Glamour in running Bubbletea        | 1700–11000ms (variable) |
| Glamour via subprocess worker       | ~170ms cold, 0ms cached |

## Gotchas encountered while building the worker

1. **`style: "auto"` emits plain text.** Glamour detects `$stdout.tty?`;
   when the worker's stdout is an `IO.popen` pipe that check returns
   false and styling is skipped (URLs unstyled, `**bold**` rendered as
   literal asterisks). Force a real style explicitly:

   ```ruby
   style = ENV.fetch("TYCHO_GLAMOUR_STYLE", "dark")
   Glamour.render(markdown, style: style, width: width)
   ```

   `TYCHO_GLAMOUR_STYLE` lets operators override the theme without
   editing code.

2. **Glamour's document block adds padding.** The default dark style
   inserts a leading blank line, trailing blank lines, and a uniform
   2-column left indent on every line. HQ's chat bubble already
   provides its own padding, so the worker post-processes the output
   to strip the document block's blanks and left-align all lines.
   The strip must be ANSI-aware — Glamour wraps the leading spaces in
   style escapes — so the logic walks each line character-by-character,
   preserving `\e[…m` sequences while consuming up to `N` literal
   spaces.

3. **List continuations wrap at column 0.** The dark style puts the
   bullet (`•`) at column 0 and wraps continuation lines back to
   column 0 as well, so wrapped list-item text visually aligns under
   the bullet rather than under the item text. The worker fixes this
   by tagging any non-bullet, non-blank line that follows a bullet
   line with a two-space hanging indent, until the next bullet or
   blank line.

## Regression coverage

`test/rendering_test.rb::assert_glamour_worker_renders_sample_markdown`
spawns the worker at three widths against a representative assistant
message (bold, URLs, bulleted list). It asserts:

- ANSI styling is present (catches the `style: "auto"` regression).
- Leading and trailing document-padding blank lines are stripped.
- At least one line is flush at column 0 (catches the 2-column indent
  returning).
- The first continuation line after a bullet is indented at least 2
  columns (catches hanging-indent loss).

## When to revisit

If a future release of `bubbletea-ruby` or `glamour-ruby` ships with a
shared Go runtime, or if the GVL/cgo interaction is fixed upstream, the
subprocess worker can be replaced with an in-process render. Verify by
running the sample markdown inside a live Bubbletea program at several
widths and confirming sub-50ms latency consistently before deleting
`bin/worker --type glamour`.
