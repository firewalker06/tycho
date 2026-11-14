# Remote UI appearance

Settings → Configuration → Appearance offers **Dark**, **Light**, and
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

CSS selects the light PNG from the resolved app appearance. The main template preloads
both light assets. The shared rendered stylesheet supplies the versioned image
URLs to every consumer, including the Design System preview. The image
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
layout, reduced motion, System changes, and reload checks. The same command also
checks rendered Design System logo pixels with saved Light, System/Light, Dark,
and System/Dark at desktop and mobile sizes. Set
`TYCHO_REMOTE_UI_CAPTURE_DIR` outside the repository to retain before/after
screenshots.


## Startup text and motion

Settings > Configuration > Appearance > Startup text saves plain text as you type.
Use one candidate per line, up to 8,000 characters for the list and 240 characters
per displayed candidate. The empty textarea shows both default phrases as a
two-line placeholder; the placeholder is not saved input. Blank lines are ignored. One candidate is selected at
random once per startup. Absent, all-blank, or unavailable storage uses
“The factory must grow” and “Orchestrating the orchestrator”. Existing saved
single messages remain one candidate. The text uses responsive 21–35 pixel bold
type and wraps long phrases.

This preference uses browser local storage for the current origin (scheme,
host, and port). Other browsers, devices, and server addresses have separate
values. It is not an account or project setting. Storage failure is shown in
Settings; that choice cannot persist for the next startup. The inline shell
reads and renders safe plain text before app scripts run.

A separate random choice selects one of two animations once per startup. The
legacy variant restores the original rotating mark (2 seconds, with a rest for
the first quarter) and radial particles: 3–5 per burst, 100–200 milliseconds
between bursts, and 600–900 milliseconds per particle. The curves variant uses
three sequential curved strokes (1.2 seconds, with 0.4-second offsets) around
a fixed mark. Both variants use the same corrected logo with equal dot gaps.
Neither Retry nor Settings changes select another variant during a load.
Reduced motion stops both animations and removes particles; changing that
preference during loading takes effect immediately. Particles stop and are
removed on failure or readiness. The old source snapshot remains preserved.
No external animation assets or dependencies are used.

The shell leaves when the selected route is ready, without an artificial delay.
The existing 15-second app timeout and offline/error retry paths remain
available. An inline 15-second fallback also offers page reload if the main app
script never starts. This fallback does not delay readiness. The operating
system's installed PWA launch image is outside the page's control; this screen
begins when HTML loads.

Run `TYCHO_REMOTE_UI_STARTUP_ONLY=1 bin/remote-ui-smoke` for real Chrome startup,
both random variants, equal dot gaps, Settings persistence, literal text, reduced
motion, route readiness, missing
script, and offline retry checks in desktop/mobile Dark/Light. Set
`TYCHO_REMOTE_UI_CAPTURE_DIR` outside the repository to retain screenshots.

## Custom dark and light themes

Settings → Configuration → Appearance has independent **Dark theme** and
**Light theme** selectors. The defaults are Dracula for Dark and Nord for
Light. Color mode still controls which selector is active. System switches
between the two selected palettes when the device color mode changes.

Open **Customize themes and agent prompt guide**. Edit the JSON template, or
ask an agent to make a palette. Select **Save theme** to add and select it for
its declared mode. Saving an existing id replaces that palette. Use a new id
to keep both versions. Saving a light palette while Dark is active does not
switch color mode. Select Light to preview it.

Use **Load dark JSON** or **Load light JSON** to edit or copy the selected
custom palette. For a built-in palette, these buttons load a template for that
mode; set its colors before saving. Copy the JSON to transfer it to another
browser. **Remove selected custom dark/light theme** removes that palette and
restores the default for that mode. Selecting a default alone keeps custom
palettes available.

A theme has this format (all twelve color roles are required):

```json
{
  "id": "midnight",
  "name": "Midnight",
  "mode": "dark",
  "colors": {
    "canvas": "#17152b",
    "surface": "#242039",
    "sunken": "#100f20",
    "text": "#f4edff",
    "muted": "#c0b5d4",
    "border": "#807099",
    "accent": "#c9a0ff",
    "inverse": "#17152b",
    "info": "#88dcf0",
    "success": "#9fe3b0",
    "warning": "#f7cc85",
    "danger": "#ff929f"
  }
}
```

- `id`: starts with a lowercase letter, followed by lowercase letters, digits,
  or hyphens; at most 40 characters. `dracula` and `nord` are reserved.
- `name`: 1–60 characters. Names are displayed as text.
- `mode`: `dark` or `light`. Use a new id to change an existing theme's mode.
- Colors: six-digit hex values only. CSS, URLs, unknown fields, and incomplete
  palettes are rejected. A browser can store up to 30 custom themes. Each JSON
  input is limited to 10,000 characters.

Canvas is the page background. Surface is the panel and assistant background.
Sunken is the recessed background and subtle action fill. Text and muted are
foregrounds. Border also supplies boundaries in Light. Accent supplies action
fills, selection and focus. Inverse supplies text on accent fills in Dark.
Info, success, warning and danger supply state colors. Light uses its readable
text role on colored controls and badges, and its border role for focus rings.
Related legacy and Nord/Dracula
roles are mapped together so existing product components follow the palette.

The importer checks format, not contrast. Check text against each adjacent
background (at least 4.5:1), and focus rings and control boundaries (at least
3:1). Check disabled controls, errors, chat, code, PR diffs, and narrow screens.
Colors are shared across many components; changing an accent can affect more
than buttons. Images, uploaded documents, Mermaid's built-in mode palette,
terminal colors, and the PWA launch splash retain their existing behavior.

Example agent prompt:

> Create a Tycho light theme JSON called Sandstone. Use the twelve roles in
> the template above and six-digit hex colors. Use warm surfaces and a blue
> accent. Keep text contrast at least 4.5:1 and control borders and focus rings
> at least 3:1. Return JSON only. Do not change application code.

Palettes and the two choices use `hq.remote.themes.v1` in browser local
storage. They share the same origin scope as Color mode. They are not written
to server configuration or sent to agents. Invalid saved data falls back to
the defaults. If storage is full or blocked, changes apply for this tab and
Settings reports the limit. Clearing browser storage removes custom themes.
The head bootstrap applies the selected palette before CSS and app startup.

## Scene backdrops and four example themes

The reference in [Card 877](https://fizzy.startkit.tech/1/cards/877) and the
[ClaudeDevs video](https://x.com/ClaudeDevs/status/2121392666244186327) shows
scene artwork behind the conversation, including a striped sunset and neon
grid. Tycho's examples use original, code-drawn vector scenes. No reference
images or video are bundled or fetched by the UI.

| Example | Mode | Backdrop |
| --- | --- | --- |
| Synthwave Sunset | Dark | Striped gold/pink sun, stars, outlined mountains, perspective grid |
| Aurora Night | Dark | Green/teal ribbons, stars, distant mountain silhouettes |
| Paper Garden | Light | Sage leaves, curved stems, warm sun, paper-colored ground |
| Coastal Morning | Light | Blue wave layers, gold sun, distant birds |

All four are available without import. In Settings → Configuration → Appearance,
select a theme from the Dark/Light selector, or use a **Scene examples** tile.
A tile selects its theme and its Color mode so you can try it immediately.
The other mode's choice is retained. Dracula and Nord remain the defaults and
have no scene. Existing palette-only custom themes retain their selected ids
and appearance. The examples are separate from the 30-theme custom limit and
cannot be removed. Their reserved ids start with `builtin:`.

Select an example, then open the prompt guide and use **Load dark JSON** or
**Load light JSON**. This loads an editable copy with a new custom id, such as
`synthwave-copy`. Change the id again if you want to keep an existing copy.
Change its colors or backdrop values and select **Save theme**. The built-in
example stays available. Copying and importing this JSON transfers the scene
settings as well as the palette.

Add this optional top-level field beside `colors` in any custom theme JSON:

```json
"backdrop": {
  "style": "synthwave",
  "colors": ["#f6c66e", "#ed4fbd", "#9a9cff"],
  "intensity": 0.8,
  "motion": "slow"
}
```

- `style`: `synthwave`, `aurora`, `garden`, or `coast`.
- `colors`: exactly three six-digit hex colors. For synthwave they are sun
  start, sun end/grid, and glow/mountain lines. For aurora they are ribbon
  start/mountains, ribbon end, and glow/stars. For garden they are leaves,
  stems/alternate leaves, and sun. For coast they are waves/birds, deeper
  waves, and sun/shore.
- `intensity`: a number from 0 to 1. Zero hides the artwork; 1 shows its full
  strength. The palette's canvas remains underneath.
- `motion`: `none` for a still scene, or `slow` for a 28-second eased drift.
  The device's reduced-motion setting stops this movement.

Remove the `backdrop` field to return a custom theme to a flat canvas. Updating
an existing custom id can add or remove a backdrop. The same browser storage,
cold-load, System-mode, cross-tab, and draft-preservation rules apply. Scene
art stays behind controls and text panels and cannot receive clicks. Mobile
uses a crop that keeps the right-hand scene visible. All scenes are local SVG
backgrounds; JSON cannot supply CSS, SVG markup, asset paths, or network URLs.

Example agent prompt for a backdrop:

> Load the Synthwave Sunset example as a custom copy. Keep its twelve palette
> roles readable. Change the backdrop to aurora, with teal, blue, and pale green
> hex colors, intensity 0.65, and motion slow. Use a new id and name. Return
> valid theme JSON only. Do not change application code.

Check scene strength on desktop and mobile, especially text outside cards,
focus, and disabled controls. The importer checks the field format, not visual
contrast. Use the existing appearance smoke command to verify all four scenes,
preview tiles, scene copying, reduced motion, and old palette-only themes.

## Local raster-image backdrops

Settings → Configuration → Appearance → **Local image backdrop** lets you choose
or replace an image for the current Dark or Light mode. Each mode has one image.
The image replaces that mode's vector scene but does not change its selected
palette. Switching palettes keeps the image. **Remove image** restores the
selected theme's scene or flat canvas. The preview shows the saved image and
its crop. **Image strength** controls its opacity; **Soft center fade** adds a
palette-colored fade over the center. This is a fade, not a blur. Horizontal
and vertical focal-position controls choose the crop with percentages from
0 to 100. Images use cover sizing, so narrow screens can crop more of the sides.
Text panels and navigation retain solid semantic surfaces, including peer panels.

Images stay in this browser profile on this device, at this exact origin
(scheme, host, and port). They are not uploaded to Tycho and are not synced to
other devices or server addresses. IndexedDB database `tycho-backdrop-images`,
store `backdrops`, contains one normalized Blob and its settings per mode.
No image bytes, base64 payloads, or object URLs are written to localStorage or
portable theme JSON. Existing theme choices and old palette-only themes are
not migrated or overwritten.

| Input limit | Value |
| --- | --- |
| Formats | PNG, JPEG, WebP |
| Encoded bytes | At most 5 MiB |
| Dimensions before decode | At most 4096 pixels per side and 12,000,000 pixels total |
| Saved longest edge | At most 2560 pixels, with aspect ratio retained |
| Saved bytes | At most 5 MiB per mode |

The controller checks MIME type, file signature, header dimensions, and a real
browser decode. SVG, GIF, file paths, and network URLs are not accepted. It
renders the decoded first frame into a canvas and saves a still WebP copy
(quality 0.9); browsers without canvas WebP encoding can return PNG. This strips
source metadata and animation. Oversized input, corrupt files, decode failures,
and failed saves show an error and keep the previous image. The saved copy can
have different bytes, dimensions, and quality from the original. Keep the
original file if you need it later.

The small localStorage change marker and BroadcastChannel notify other tabs
at this origin. Focus and visibility changes also refresh image state. Reload
reads the saved Blob asynchronously; the existing palette/vector scene is the
fallback while it loads. No image decoding or encoding runs on scroll, and
settings changes reuse the same object URL. Replacement, removal, stale loads,
and page disposal release unused object URLs. Browser data deletion or a
missing image restores the palette/vector fallback. A damaged stored image
shows a recovery message and can be replaced or removed. **Retry image storage**
retries after storage becomes available. A blocked/full store does not silently
replace the previous saved image. Site data can be cleared or evicted by the
browser; keep a downloaded copy of images you want to retain.

### Transfer and theme JSON

**Download saved image** exports the normalized raster copy for the active mode,
with its real file extension. To transfer a complete look, copy the palette or
vector theme JSON separately, download the image, then choose that downloaded
file in the other browser. Image strength, center fade, and focal position are
local mode settings; set them again in the receiving browser. Theme JSON never
contains a local image id, temporary URL, or missing file reference. Importing
JSON does not transfer or remove a mode's existing local image. Remove that
image to see an imported vector scene.

The Settings agent prompt guide keeps this boundary explicit: agents can
prepare portable palette/vector JSON, while the user chooses a raster file
through **Local image backdrop**. Do not ask an agent to put image bytes or
URLs into theme JSON.

### Verification

The existing appearance smoke command also exercises image selection,
replacement/removal, real PNG/JPEG/WebP decode, dimension and byte limits,
normalization, reload, two-tab updates, separate modes, storage failures,
missing records, stale decode cancellation, object URL cleanup, and download
transfer. All browser state belongs to throwaway fixtures. The synthetic
landscape is an owned canvas-generated PNG, selected through the actual file
input. The smoke prints image-load time and measured Settings-scroll frame
gaps for its fixture and Chrome version; those measurements are not a general
performance guarantee.
