# Focus empty state

[Card 902](https://fizzy.startkit.tech/1/cards/902) gives an empty Focus panel a
full-width surface. The surface grows inside the existing panel body. It uses
normal flex layout on desktop and mobile. Its text is exactly
“Nothing in the Focus board”. The image is decorative; the text supplies the
accessible meaning. Populated Focus sections keep their existing rendering.

## FRED asset

The built-in imagegen tool generated `lib/hq/remote_ui/assets/fred-zen.png`.
The identity reference was the existing `now-mascot/f.webp` study, described in
[Now empty state](NOW_EMPTY_STATE.md). ImageMagick resized the transparent source
to 384 × 256 pixels. The UI displays it at 192 × 128 CSS pixels. The PNG uses
the existing public asset route and participates in the UI asset version digest.

Final generation prompt:

> Use case: stylized-concept. Asset type: small transparent UI mascot. Reference image: existing FRED identity and painterly style. Generate FRED with a zen expression: same wide rounded navy blue face/body, small blue upper-left highlight, cream closed eyes as gentle curved arcs, small peaceful cream smile. Relaxed little arms, calm symmetric pose. Match the reference's soft painted edges and navy/cream/blue palette. Center the complete character with generous transparent margin in a landscape 3:2 composition. No text, no scenery, no symbols, no watermark. Genuine transparent background.

## Verification

Run `TYCHO_REMOTE_UI_SIDE_CONVERSATIONS_ONLY=1 TYCHO_REMOTE_UI_FOCUS_EMPTY_ONLY=1 bin/remote-ui-smoke`
for desktop/mobile Dark/Light checks. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to an
outside-repository evidence directory. The check measures panel width and height,
image centering, overflow, and mobile composer clearance. It also checks polling,
draft retention, the served image, and empty/populated transitions through explicit
Focus refresh.
