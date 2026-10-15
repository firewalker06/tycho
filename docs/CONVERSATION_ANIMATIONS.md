# Conversation animations

[Card 320](https://fizzy.startkit.tech/1/cards/320) adds a small FRED marker at the
bottom of the Remote UI conversation. It stays in normal document flow, above
the existing bottom clearance and composer dock. It adds no controls or live
region. The SVG is decorative; adjacent text identifies the state.

## Source and motion

The source is Tycho's own `lib/hq/remote_ui/assets/fred-avatar.png` at commit
`058577f886b53bff12537db5039e6f824645881e` (Replace FRED avatar asset). This asset
was removed with the FRED feature in commit `c2ebc0d`. It depicts a wide navy
rounded face, cream eyes and smile, and a small blue upper-left reflection.
The inline pixel SVG preserves those features and their proportions. Its fixed
content colors come from that illustration, rather than UI state tokens.
No bitmap is edited or shipped, and the retired assistant is not restored.

The card's GitHub GIF is motion inspiration only. Inspection found eight frames
at 160 ms each, a 1.28-second sequence. No Mona artwork or remote asset is used.

- **Running:** a 2.4-second eye scan and three small signal pixels. The face stays
  still. The label is **Agent is working**.
- **Complete:** one 1.28-second nod and reflection glint, then a resting smile.
  The label is exactly **You have reached the end.**, in a muted color mixed from
  75% muted text and 25% canvas. Text keeps full opacity and readable contrast.
  A run can play only once per loaded UI session.
  Only the decorative SVG uses 20% opacity during motion, at rest, and under
  reduced motion. The status label and running illustration keep full opacity.
- **Reduced motion:** static face and state text. Running keeps three static
  signal pixels. No movement or flashing is required to read either state.

## State and lifecycle

Running requires both the process `running` flag and `running` status, plus a
current run ID. Completion requires `succeeded`, result `success`, exit code 0,
a finish time, and a non-empty trailing successful run summary whose run ID
matches the agent. A later user message suppresses the marker. Older transcripts
without a matching run ID receive no completed marker.

Loading, stale or disconnected resources, pending inquiry, blocked, failed,
stopped, partial, no-action, and empty or missing successful results do not show
completion. Existing header and inquiry status behavior stays in place.

Same-route rendering keeps the marker node and restores its CSS animation time
after DOM replacement. The session replay guard prevents completion from playing
again after route changes or loading recovery. Motion transforms do not affect
layout, conversation tail identity, or auto-scroll decisions. Status text has no
live region, so polling does not produce repeated announcements.

## Verification

Run `bundle exec ruby test/remote_ui_conversation_animation_test.rb` for state
transitions and the replay guard. Run
`TYCHO_REMOTE_UI_CONVERSATION_ANIMATION_ONLY=1 bin/remote-ui-smoke` for actual
Chrome checks. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to a path outside the repository
to retain desktop/mobile screenshots, animation frames, and measurements.
The fixture uses only synthetic conversation content and temporary server data.
