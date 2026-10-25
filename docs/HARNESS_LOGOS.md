# Harness logos

This page records where Tycho shows harness marks, where it does not, and why. Asset provenance and usage notes are in `lib/hq/remote_ui/assets/harness-logos/README.md`.

## Scope

| Surface | Marks shown | Notes |
| --- | --- | --- |
| Remote UI agent rows and agent cards | Claude, OpenCode, Pi | The harness name stays as text next to the mark. |
| Remote UI Settings harness summaries | Claude, OpenCode, Pi | The harness name stays as text in the summary heading. |
| Remote UI native `<select>` options, detail key-value rows, form summaries | None | Native options cannot show images. Detail rows and summaries are plain text. |
| TUI (`lib/hq/ui`), CLI output, docs, README | None | Terminal output and prose stay text-only. |

## Marks by harness

| Harness | Mark | Reason |
| --- | --- | --- |
| Claude (`claude`) | Claude Spark, clay color | Official Anthropic press kit. The clay color reads on light and dark backgrounds. |
| OpenCode (`opencode`) | Dark square mark | Official asset from the MIT-licensed OpenCode repository. The Remote UI is dark only, so the dark-square variant is used. |
| Pi (`pi`) | Pi logo | Official asset linked from the Pi project README. The mark uses fixed colors that read on the dark surface. |
| OpenAI / Codex (`codex`) | None, text label only | No official, downloadable OpenAI mark was reachable. The OpenAI brand page (https://openai.com/brand/) returned HTTP 403 to automated fetches, and its public guidance does not link a logo file. Third-party icon sets were not used. Add a mark only after an official asset and its usage terms are confirmed. |

## Usage rules applied

- Marks are unchanged upstream files. Tycho does not recolor, crop, or redraw them.
- Marks are decorative (`alt=""`, `aria-hidden="true"`) because the harness name is always shown as adjacent text.
- The Remote UI is dark only (`color-scheme: dark`), so light-background variants are not shipped.
- Custom harnesses do not get marks. Only built-in harness keys are mapped.

## Trademark note

Anthropic's trademark guidelines ask for permission before using its marks in a press release, website, or similar context: https://www.anthropic.com/legal/trademark-guidelines. Maintainers should confirm that the Remote UI use is acceptable before a public release.
