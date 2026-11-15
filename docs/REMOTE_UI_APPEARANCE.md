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

Use **Copy agent guide** near the top of Appearance, or open **Read guide**.
Open **Edit or import theme JSON** to edit palettes. Edit the JSON template, or
ask an agent to make a palette. Select **Save theme** to add and select it for
its declared mode. Saving an existing id replaces that palette. Use a new id
to keep both versions. Saving a light palette while Dark is active does not
switch color mode. Select Light to preview it.

Use **Load dark JSON** or **Load light JSON** to edit or copy the selected
custom palette. For a built-in palette, these buttons load a template for that
mode; set its colors before saving. Copy the JSON to transfer it to another
browser. **Delete** on a custom tile, or **Delete selected theme** by a selector,
removes that palette. Deleting a selected theme restores Dracula for Dark or
Nord for Light. Deleting an unselected theme keeps the current selection.
Other themes and server images stay unchanged. Selecting a default alone keeps custom
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

## Themes gallery and photo backdrops

Four bundled photo themes work without Internet access while the local Tycho
server is available. They do not require an upload or a developer's image library.

| Theme | Mode | Photo |
| --- | --- | --- |
| Senggigi Beach | Light | Real Senggigi Beach, Midori, CC BY 3.0 |
| Depok City | Dark | Real Jalan Margonda, Mfikriansori, CC BY-SA 4.0, darkened |
| Waking Up | Light | GPT Image generated fictional morning cafe |
| Cyberpunk | Dark | GPT Image generated fictional neon city |

[Photo sources, licenses, changes and generated provenance](../lib/hq/remote_ui/assets/theme-photos/README.md)
are bundled with the app. **Photo credits** in Settings opens the attribution record.
The adapted Depok photo retains CC BY-SA 4.0; this does not change the code license.

Selecting a photo theme applies its photo and palette. It keeps the saved per-mode
library image. **Use saved image** restores that image; **Use theme photo** restores
the bundled photo. Explicitly choosing or uploading another image uses that image.
Selecting the photo tile again restores its photo. Choices persist and sync across
tabs. A missing saved image falls back to the bundled photo. Theme deletion never
deletes library images. Old vector example ids and custom themes remain compatible;
old examples remain in the selector when selected. Dracula and Nord remain defaults.

The **Themes** gallery includes bundled and imported custom themes. Saving a
new theme adds its tile immediately. Saving the same id updates one tile;
a mode change for an existing id is rejected by the existing validation.
Custom tiles appear first, with the most recently saved theme first. A bounded
scroll area keeps the gallery readable when many themes are saved. Updates,
selection, and deletion persist on reload and update other tabs at this origin.

Palette-only tiles preview canvas, surface, and accent colors. Vector-backed
tiles preview their vector backdrop. Independent image choices are not part
of these previews. Custom tiles have a keyboard-accessible **Delete** button;
bundled tiles have no delete action. Dracula and Nord remain available in
the selectors, including after selected-theme deletion.

The four photo examples are separate from the 30-theme custom limit and cannot
be removed. Their reserved ids start with `builtin:`. A tile selects its theme
and Color mode; the other mode's choice is retained. Each tile has the same
preview, title, metadata and action space. Only custom tiles have Delete.

**Load dark JSON** or **Load light JSON** loads an editable custom copy. A bundled
photo copy contains its palette, not its product photo. Custom JSON cannot name
an asset path or URL. Use the separate image library controls to select a photo.
Old vector JSON still exports and imports its vector backdrop.

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
- `motion`: `none` for a still backdrop, or `slow` for a 28-second eased drift.
  The device's reduced-motion setting stops this movement.

Remove the `backdrop` field to return a custom theme to a flat canvas. Updating
an existing custom id can add or remove a backdrop. The same browser storage,
cold-load, System-mode, cross-tab, and draft-preservation rules apply. Backdrop
art stays behind controls and text panels and cannot receive clicks. Mobile
uses a crop that keeps the right-hand artwork visible. All vector backdrops are local SVG
backgrounds; JSON cannot supply CSS, SVG markup, asset paths, or network URLs.

Example agent prompt for a backdrop:

> Create a custom theme with twelve palette
> roles readable. Change the backdrop to aurora, with teal, blue, and pale green
> hex colors, intensity 0.65, and motion slow. Use a new id and name. Return
> valid theme JSON only. Do not change application code.

Check backdrop strength on desktop and mobile, especially text outside cards,
focus, and disabled controls. The importer checks the field format, not visual
contrast. Use the appearance and theme smoke commands to verify all four photo themes,
preview tiles, theme copying, reduced motion, and old palette-only themes.

## Server image backdrops

Settings → Configuration → Appearance has a visible **Ask an agent to make a
theme** guide with **Copy agent guide** and **Read guide**. The palette editor
and image adjustment fields are separate disclosures. On wide screens, Palette
and Image backdrop use two aligned columns. The guide stays above both groups.
The form uses bounded control widths and stacks the groups on narrower screens.
The visual order follows DOM and keyboard order; the rest of Settings is unchanged. The guide contains the
palette roles, apply steps, CLI commands, API contract, limits, and storage scope.

**Image backdrop** selects an image from this host's shared server library.
Each browser keeps separate Dark and Light selections, strength, palette tint,
and focal position. Uploading from an agent adds an available image. It does
not change any browser's selection. Other users keep their choices. Settings
uses the library of the host whose UI is open; open a peer's UI to select its
images. The CLI and authenticated broker API can target configured peers.

Raster backdrops use a static filter on the fixed image layer only: 3-pixel blur,
78% saturation, 90% contrast, and mode-specific brightness (88% Dark, 102% Light).
The image layer extends 12 pixels past the viewport to avoid blur seams. Text,
controls, Focus, and scrolling content have no added filter or backdrop blur.
Conversation summary cards, the full Summary, and Settings headings use palette
surfaces. There is no opaque center gradient or full-content canvas wash.

Bundled photos use a uniform 10% palette tint. New user images default to the
same tint. **Palette tint** adds 0–20% canvas color evenly across the image;
**Image strength** still controls image opacity. Existing strength and focal
positions are kept. The old numeric `fade` field is retained without rewriting
saved values, and now controls tint strength: 0 means no tint, 1 means 20% tint.
The control displays the effective tint, so an old value of 0.9 displays 18%.
New images use a stored value of 0.5, which displays 10%. Previous fade appearance
is replaced; it is not an accepted default. Vector-only themes are unchanged.

Original files, server library records, browser image blobs, previews, and
downloads are not blurred or recolored. The treatment is CSS presentation only.

### Agent workflow

Create a local PNG, then use these commands from the machine with that file:

```bash
tycho appearance images upload my-backdrop path/to/image.png --name "My backdrop" --json
tycho appearance images list --json
tycho appearance images upload my-backdrop path/to/replacement.png --name "Updated backdrop" --json
tycho appearance images remove my-backdrop --json
```

Add `--server SERVER_KEY` to each command for a configured peer. Without it,
commands use the local machine's Tycho storage, including when the server is
stopped. Target the same host whose Settings will be opened. Commands use
Tycho's existing credential store; never place credentials in prompts or theme
JSON. CLI JSON errors use stdout and a nonzero exit status.

In that server's Settings, open **Image options**, select **Refresh library**,
then choose the uploaded image in **Image backdrop**. Refresh also runs every
30 seconds while the page is visible and when it regains focus. Uploading
with the same id replaces an image. Existing selections of that id use the
replacement on the next successful refresh. **Clear selection** restores the
selected palette/vector backdrop in this browser only. **Delete from server**
requires confirmation and removes the shared image for all users. CLI removal
is explicit and idempotent.

### Limits and storage

| Boundary | Limit |
| --- | --- |
| CLI/API input | PNG, at most 5 MiB |
| Browser input | PNG, JPEG or WebP, at most 5 MiB |
| Input dimensions | 4096 pixels per side, 12,000,000 pixels total |
| Browser normalization | Still PNG, longest edge at most 2560 pixels |
| Saved raster | At most 5 MiB after normalization |
| Server library | 20 images, replacement allowed at the limit |
| HTTP upload body | At most 7 MiB, including base64 and JSON |
| PNG decompression | At most 64 MiB before pixel decode |

The server uses the existing ChunkyPNG library as a declared direct dependency.
It checks the PNG signature, dimensions, chunk bounds, checksums, and bounded
pixel decompression, then decodes and re-encodes pixels. Nonessential chunks
are removed before decode, including compressed metadata. SVG, paths, URLs,
and non-image payloads are rejected. There is no external URL fetch.

The library lives in `backdrop_images` under the configured Tycho logs root,
outside the checkout by default. Each image id owns one private atomic record with a small JSON metadata
header followed by normalized PNG bytes. Listing reads only metadata. A process-shared lock
serializes mutations. Replacement overwrites the record, removal deletes it,
and normal failures remove temporary files. There is no version-file history
to accumulate. Each record has a SHA-256 version derived from normalized pixels.
Back up the logs root to retain this library.

The browser keeps one selected image Blob per mode in IndexedDB database
`tycho-backdrop-images`, store `backdrops`. These records are a cache of server
images plus browser-specific choices and settings. Image bytes and tokens do
not enter theme JSON or localStorage. Server metadata is read with `no-store`;
image reads require the same host authentication as the other APIs and return
`private, no-cache` with a version ETag. The browser reconciles each selected
id/version against fresh metadata before it replaces the cached Blob. Unused
object URLs are revoked. Removing a shared image clears its cached raster at
the next successful reconciliation; the selection remains visible as missing
until cleared or replaced. A network failure can use the last cached selection.
An explicit authentication rejection suppresses server image rendering until
a successful authenticated refresh. Missing or damaged data falls back to the
palette/vector backdrop and shows a recovery message. The server does not promise
revocation of bytes that a browser already downloaded.

### Existing local images and transfer

Old browser-only IndexedDB images remain usable with their settings. They are
not uploaded automatically. **Upload local image** explicitly shares the active
mode's image with this server and keeps its adjustment values. The CLI cannot
read another browser's IndexedDB. **Download saved image** exports the cached
normalized raster with its correct extension.

Palette/vector JSON exports contain no image references, bytes, paths, or URLs.
Importing JSON preserves an existing image choice. Clear that choice to see an
imported backdrop. To move a complete look to another server, copy the palette
JSON, download the raster, upload it to that server, then select it and set its
adjustments there. An image is not silently resolved against an unrelated
server library. Browser data deletion removes choices and caches, while server
assets remain available for selection.

### Authenticated API

All image routes use the host's existing bearer authentication policy.
Tokenless loopback operation retains Tycho's existing local access policy.
The routes are also available through the authenticated peer broker.

| Method | Route | Result |
| --- | --- | --- |
| GET | `appearance/images` | `{images: [...]}` metadata only |
| PUT | `appearance/images/ID` | `{image: {...}}`; JSON body has only `name` and base64 PNG `data` |
| GET | `appearance/images/ID/blob` | Normalized PNG bytes |
| DELETE | `appearance/images/ID` | `{removed: ID}`, including repeated removal |

Prefix each route with a slash. IDs start with a lowercase letter and use
lowercase letters, digits, and hyphens, at most 40 characters. Names use 1–120
characters with no control characters. Missing reads return 404, invalid
uploads return 422, oversized request bodies return 413, and missing or rejected
authentication returns 401. Metadata contains id, name, version, mime, bytes,
width, and height; it contains no server filesystem path. A replacement keeps
its id. Removal and replacement require no browser selection changes.

### Verification

Run `bin/remote-ui-theme-smoke` for the isolated authenticated API/CLI and real
Chrome acceptance test. Set `TYCHO_PLAYWRIGHT_PATH` to an installed Playwright
package, or let the runner install it into its temporary fixture. Set
`TYCHO_REMOTE_UI_CAPTURE_DIR` to an external directory to retain screenshots.
The runner creates a temporary host, config, logs root, library, and browser
profile; it never uses live agents or provider calls. The owned landscape is
generated by canvas. Automated store checks run in `bin/test`.

Set `TYCHO_REMOTE_UI_CONTENT_FADE_ONLY=1` with `bin/remote-ui-smoke` to verify all four photos across Conversation, Settings, Focus and Summary at 1920, 1440 and 390 pixels, plus new image defaults and saved adjustments. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` for temporary screenshots outside the checkout.

Set `TYCHO_REMOTE_UI_BACKDROP_FILTER_COMPARE_ONLY=1` with `bin/remote-ui-smoke` to compare blur-only, muted/tinted, and combined image treatments, with controlled scrolling and Chrome timeline traces. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the checkout. Local viewport emulation is not a real-device performance guarantee.
