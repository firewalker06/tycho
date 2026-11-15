# Now empty state

[Card 881](https://fizzy.startkit.tech/1/cards/881) uses the three approved FRED
expression studies. One immutable record binds each image to its text:

| ID | Expression | Text |
| --- | --- | --- |
| D | Delighted grin and raised arms | All done. Hooray! |
| E | Curious tilt and smug smile | Nothing left? Thought so. |
| F | Relieved exhale and stretch | And… relax. All done. |

Selection occurs on entry to a confirmed empty Now state. Routine rendering and
polling retain that record. A single 30-second timer selects a different record
while the page is visible. Hidden pages suspend the timer; return starts a fresh
30-second interval. Navigation, nonempty work, unavailable data, and page disposal
stop it. Reduced motion keeps the selected record static. There are no animated
transitions or live announcements. Loading and unavailable data never show the
all-clear illustration. The existing attention card surface remains for readable
text over photo backgrounds; PR 368's transparent navigation surfaces remain.

## Assets

The approved raster studies used the original FRED PNG from commit
`058577f886b53bff12537db5039e6f824645881e` as an imagegen identity reference.
See [conversation animations](CONVERSATION_ANIMATIONS.md) for the original art and
current conversation SVG. Only the Now state uses these new raster expressions.

The three transparent WebPs are in `lib/hq/remote_ui/assets/now-fred/`. Each is
384 × 256 pixels, displayed at 192 × 128 CSS pixels for 2× rendering. ImageMagick
resized the approved PNGs with `-resize 384x256 -define webp:method=6 -quality 85`.

| File | Dimensions | Bytes |
| --- | --- | ---: |
| d.webp | 384 × 256 | 7,626 |
| e.webp | 384 × 256 | 7,556 |
| f.webp | 384 × 256 | 8,190 |

Assets use the existing public UI asset boundary, correct WebP MIME type,
`nosniff`, a one-hour cache, and participate in the UI asset version digest.
Only the selected image is requested by the page.

## Verification

`test/remote_ui_now_fred_test.rb` uses a controlled clock and random source to
check bound records, all three choices, no repeat, stable polling, hidden and
reduced-motion suspension, route exit, reentry and disposal.

Run `TYCHO_REMOTE_UI_NOW_FRED_ONLY=1 bin/remote-ui-smoke` for the isolated Chrome
checks and desktop/mobile Dark/Light/plain/photo captures. Set
`TYCHO_REMOTE_UI_CAPTURE_DIR` to an outside-repository evidence directory.
