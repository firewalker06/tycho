# Harness logo assets

Tycho shows official upstream marks next to harness names in the Remote UI agent lists and the Settings harness summaries. The SVG files are byte-identical copies of the upstream files. Do not edit them, recolor them, or redraw them.

| File | Harness | Upstream source | Upstream revision | SHA-256 |
| --- | --- | --- | --- | --- |
| `antigravity-icon-one-color.svg` | Antigravity (`agy`) | [Google press assets](https://antigravity.google/press), [Icon - One Color SVG](https://antigravity.google/assets/image/brand/antigravity-icon__one-color.svg) | fetched 2026-11-13 | `5b5d0cfd07cb79ba5d299d80b754e7c91d782dc1199811688dec67a0a11ba240` |
| `claude-spark-clay.svg` | Claude | Anthropic press kit, "Claude Spark - Clay.svg": https://www.anthropic.com/press-kit | Press kit archive fetched 2026-10-26 | `6d53db4be375e899c937c26cf16684a80d6e869b1928d72b37748bef2560e219` |
| `opencode-logo-dark.svg` | OpenCode | `packages/console/app/src/asset/brand/opencode-logo-dark.svg` in https://github.com/anomalyco/opencode (240x300 rectangle, no gradient) | blob `c28babff1be159160016884695e097d9159d468b`, last changed in commit `37baed99c1ad05aa00fd53462b7d1441ce4a5edb`, default branch `dev` | `5dd4abb4de60204510edf140bbe74b3580d07ebdda79fdb0081cd45acb53d44b` |
| `openai-blossom-dark.svg` | OpenAI / Codex | `docs/src/assets/dark-logo.svg` in https://github.com/openai/openai-agents-js (MIT, Copyright 2025 OpenAI), blob `d0bed40b1ae251a5f9607da7852985a78b13a09c`, default branch `main` | `b9597643cfa068f73990d5387ac2c77b5fd9e54bb660b81d83a845bb90ec513a` |
| `pi-logo-auto.svg` | Pi | https://pi.dev/logo-auto.svg, linked from the Pi README in https://github.com/earendil-works/pi | fetched 2026-10-26 | `abd66e7868b2d24f0f0895f9237ee8a6dcb22337583b0dc54aeb595acecb4d6b` |
| `deepseek-icon.svg` | DeepSeek / dsh | [Official DeepSeek ICON.svg](https://github.com/deepseek-ai/awesome-deepseek-integration/blob/94a834802fd1489db4ced41f3a23c669cb8644b1/docs/_logo%20svg/ICON.svg) | commit `94a834802fd1489db4ced41f3a23c669cb8644b1`, blob `2e4650aee9fd05f4681c426cdb74ee2aeff1fb07` | `b15083e3cbb398bd35619b758c43adc0a632efccc7e2d69f2481a860862910fe` |

## Licensing and usage

- Antigravity: Copyright Google. The official press page offers this one-color product icon. No open-source license is stated for the asset; the Tycho MIT license does not grant rights to Google marks. See [Google brand guidance](https://about.google/brand-resource-center/guidance/). Tycho uses the unchanged icon to identify the `agy` harness, with the existing theme-aware mask. This does not claim Google endorsement.
- DeepSeek: the [official brand asset guidelines](https://github.com/deepseek-ai/awesome-deepseek-integration/blob/94a834802fd1489db4ced41f3a23c669cb8644b1/docs/_logo%20svg/guidelines.md) provide assets for actual DeepSeek model/API integrations, require accurate identification, prohibit misleading affiliation, and restrict arbitrary changes. Tycho preserves the supplied SVG bytes and geometry and uses the existing theme-aware monochrome mask. The mark identifies the native dsh integration; it does not imply endorsement. Retrieved 2026-11-13. These brand terms are not a general trademark license.

- OpenCode: the source repository is MIT licensed. The MIT license covers the repository code. It does not license the OpenCode trademark or logo for other uses.
- Pi: the source repository is MIT licensed. The MIT license does not license the Pi logo for other uses.
- Claude: Anthropic's trademark guidelines (https://www.anthropic.com/legal/trademark-guidelines) prohibit changes to the marks, require clear space, and ask partners to contact marketing@anthropic.com for press, website, or other uses. Tycho uses the mark unchanged to identify the Claude harness. Maintainers must decide if this use needs written permission before a public release.

- OpenAI: the blossom file comes from an OpenAI-owned MIT-licensed repository. The MIT license does not license the OpenAI name or marks. OpenAI's brand guidelines (https://openai.com/brand/, not reachable by automated fetch) say that use is a non-exclusive, revocable license and that the logo must not be paired with the wordmark. Tycho shows the blossom alone.

No file here was recolored, cropped, or redrawn. See `docs/HARNESS_LOGOS.md` for scope.
