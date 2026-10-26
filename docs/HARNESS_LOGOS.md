# Harness logos

This page records where Tycho shows harness marks, where it does not, and why. Asset provenance and usage notes are in `lib/hq/remote_ui/assets/harness-logos/README.md`.

## Scope

| Surface | Marks shown | Notes |
| --- | --- | --- |
| Remote UI agent rows and agent cards | Codex, Claude, OpenCode, Pi | The harness name stays as text next to the mark. |
| Remote UI Settings harness summaries and agent `Harness` rows, skill installation rows | Codex, Claude, OpenCode, Pi | The harness name stays as text in the summary heading. |
| Remote UI native `<select>` options, form summaries, Settings/schedule/project selectors | None | Native options cannot show images. Form summaries are plain text. |
| TUI (`lib/hq/ui`), CLI output, docs, README | None | Terminal output and prose stay text-only. |

## Marks by harness

| Harness | Mark | Reason |
| --- | --- | --- |
| Claude (`claude`) | Claude Spark, clay color | Official Anthropic press kit. The clay color reads on light and dark backgrounds. |
| OpenCode (`opencode`) | Dark rectangle mark (`opencode-logo-dark.svg`) | Official asset from the MIT-licensed OpenCode repository. The rectangle has no gradient. It is rendered with luminance masking so the frame stays solid and the window stays open. The Remote UI is dark only, so the dark variant is used. |
| Pi (`pi`) | Pi logo | Official asset linked from the Pi project README. The mark uses fixed colors that read on the dark surface. |
| OpenAI / Codex (`codex`) | OpenAI blossom, dark-background file | Taken from `docs/src/assets/dark-logo.svg` in the OpenAI-owned MIT repository https://github.com/openai/openai-agents-js. The downloadable brand portal (https://openai.com/brand/) returned HTTP 403 to automated fetches, so the repository file is the official source used. Third-party icon sets were not used. The mark is shown without the wordmark. |

## Usage rules applied

- Marks are unchanged upstream files. Tycho does not recolor, crop, or redraw them.
- Marks render as one plain color: each file is a CSS mask filled with `--harness-mark-color`, which is `#ffffff` in the dark Remote UI. The colored panels and two-tone fills are not shown. A light palette overrides the variable to a dark ink.
- Marks are decorative (`alt=""`, `aria-hidden="true"`) because the harness name is always shown as adjacent text.
- The Remote UI is dark only (`color-scheme: dark`), so light-background variants are not shipped.
- Harness identity is also shown in the agent detail `Harness` row, the agent Settings `Harness` row, and the skill installation rows. Native `<select>` options, prose, and the TUI stay text-only.
- Custom harnesses do not get marks. Only built-in harness keys are mapped.

## Source limits

- OpenAI brand portal: https://openai.com/brand/ returned HTTP 403 to automated fetches. Its public text describes a non-exclusive, revocable license and a no-wordmark-pairing rule. Maintainers should check the portal in a browser before a public release.
- The OpenAI Cookbook also ships an OpenAI logomark (https://github.com/openai/openai-cookbook/blob/main/examples/agents_sdk/deployment_manager/frontend/src/openai-logomark.svg). Tycho uses the Agents SDK file because it has an explicit dark variant.

## Trademark note

Anthropic's trademark guidelines ask for permission before using its marks in a press release, website, or similar context: https://www.anthropic.com/legal/trademark-guidelines. Maintainers should confirm that the Remote UI use is acceptable before a public release.
