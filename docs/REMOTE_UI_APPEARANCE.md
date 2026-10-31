# Remote UI appearance

Settings → Configuration → Appearance offers **Dark**, **Light (Nord)**, and
**System**. Dark remains the default for a new browser, a missing preference,
or an invalid preference. Selecting System explicitly follows the browser's
`prefers-color-scheme` value and responds to later OS changes. An explicit Light
or Dark choice ignores OS changes.

The preference uses `hq.remote.appearance` in local storage. It is shared by
tabs at the same origin (scheme, host, and port), not by other devices or other
Tycho server addresses. Storage events update open tabs without replacing
forms, drafts, or inquiry answers. Clearing the key restores Dark. If storage
is unavailable or full, the control still works in memory and reports that the
choice lasts for the tab only. System falls back to Dark if the media-query API
is unavailable.

The small appearance controller is embedded in the HTML head before CSS and
app startup. It sets the root mode, native `color-scheme`, and `theme-color`
together, including on cold load. The boot shell uses the same colors. Browser
chrome support varies. The install manifest and platform-controlled PWA launch
splash retain the existing dark colors; those surfaces cannot read this local
preference before the document loads. Uploaded HTML/PDF documents and semantic
images keep their own colors. Tycho does not invert images or inject a theme
into attachment documents. The terminal UI has separate colors.

## Selected Nord mapping

This is Tycho's mapping of the [official Nord palette](https://www.nordtheme.com/docs/colors-and-palettes/),
not an official Nord port. The operator selected it in
[Card 772](https://fizzy.startkit.tech/1/cards/772).

| Role | Color |
| --- | --- |
| Conversation canvas | nord5 `#e5e9f0` |
| Assistant message / surface | nord6 `#eceff4` |
| User message / primary action fill | nord8 `#88c0d0` |
| Main text / action labels | nord0 `#2e3440` |
| Muted text / boundaries / focus | nord3 `#4c566a` |
| Disabled fill | nord4 `#d8dee9` |
| Error cue | nord11 `#bf616a` |
| Warning/required fill | nord13 `#ebcb8b` |
| Success cue | nord14 `#a3be8c` |

The assistant/canvas surface difference is intentionally subtle. Structural
borders use Polar Night. Nord8 alone is not an interactive boundary: its
contrast against nord5 is about 1.64:1. Nord0 text on nord8 is about 6.24:1.
Focus rings use nord3, since even nord10 against nord4 is only about 2.98:1.
Small error, warning, and success labels use readable dark text with Aurora
fills, borders, or markers. Exact palette values are retained; CSS blending
and Mermaid can derive intermediate colors. Code syntax uses readable Polar
Night roles rather than pale accent text on light surfaces.

Dark styles are unchanged by the scoped light stylesheet. Mermaid keeps the
existing dark theme in Dark and uses a custom base theme in Light. Switching
appearance rebuilds visible diagram previews from their retained source,
without rebuilding the rest of the page.

## Verification

`bin/test` includes the appearance controller's default, saved choice, storage
failure, cross-tab event, and OS behavior tests. Run
`TYCHO_REMOTE_UI_APPEARANCE_ONLY=1 bin/remote-ui-smoke` for actual Chrome checks
of persistence before app startup, Settings, cross-tab changes, OS changes,
draft and inquiry preservation, and desktop/mobile states. Set
`TYCHO_REMOTE_UI_CAPTURE_DIR` to a directory outside the repository to retain
screenshots. Use isolated fixtures; do not create production agents for visual
checks. Browser and contrast evidence does not measure physical sunlight.

## Tycho logo artwork

Card 773 uses separate light PNG exports. The original symbol and wordmark
remain the Dark assets. Light uses nord0 `#2e3440` for pale details and lettering,
and nord3 `#4c566a` for the muted ring segment. Alpha, dimensions, geometry, and
all orange pixels are preserved. The boot shell's existing inline SVG uses the
same Light colors without changing its paths or animation.

The website project has SVG versions at
`tycho-site/public/assets/tycho-logo-only.svg` and
`tycho-site/public/assets/tycho-logo-horizontal.svg` (introduced in website commit
`f78daae75cd9027ec65d5ebf4d961ffa7ddcaac5`). Their raster edges differ from these
PNGs, so they are not treated as the exact source. The symbol PNG entered this
repository in `092de464f19eddfe1aa64172a5b533295f7d61f4`; the wordmark entered in
`50aa6e6` (first-run onboarding). Do not trace or redraw them to make variants.

Run `bin/generate-light-logos` from the repository root to reproduce the Light
exports. It requires ImageMagick's `magick` command, uses the original PNGs,
changes RGB channels only, and does not resample. Its orange mask covers the
complete upper-left outer ring, including antialiasing. Keep original geometry
and mask coordinates together if approved source artwork changes later.

CSS selects the light PNG from the resolved app appearance. The template preloads
both light assets and gives their URLs the shared asset version. The image
nodes, decorative alt text, sizing, and loading pulse remain intact. No JavaScript
image replacement or OS-only media query can override the selected app theme.

Favicon PNG/ICO, Apple touch icons, and PWA/maskable icons remain unchanged.
Installed and notification icons are controlled by the browser or OS and do not
follow the app preference. Apple/PWA exports already include a dark background;
the transparent favicon can still be pale on a light browser tab. Its separate
SVG endpoint is not the exact source artwork and is not selected by the page.
This change addresses in-app logos only. Browser chrome can also retain cached
installed icons independently of the shared in-app asset version.

Run `TYCHO_REMOTE_UI_LOGO_ONLY=1 bin/remote-ui-smoke` for Chrome pixel preservation,
first-paint boot colors, live header/onboarding/loading states, desktop/mobile
layout, reduced motion, System changes, and reload checks. Set
`TYCHO_REMOTE_UI_CAPTURE_DIR` outside the repository to retain before/after
screenshots.
