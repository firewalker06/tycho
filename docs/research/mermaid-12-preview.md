# Mermaid 12 preview appearance

Card: [Use New MermaidJS Theme](https://fizzy.startkit.tech/1/cards/667).

The reference image names Mermaid v12.0.0+, `redux-color`, `look: neo`, and ELK state layout. It shows a dark canvas, white plain-state borders, and a fuchsia composite-state border. Tycho has a dark colour scheme. Use `redux-dark-color`, the dark version of `redux-color`, with `look: neo`. Set `state.layout: elk` explicitly. Do not simulate the theme with Tycho CSS.

## Release and build

Checked on 2026-10-21:

- [Mermaid 12.2.0 release](https://github.com/mermaid-js/mermaid/releases/tag/mermaid%4012.2.0) and [npm package metadata](https://registry.npmjs.org/mermaid/latest) both identify 12.2.0 as the current Mermaid release. Pin the [full browser build](https://cdn.jsdelivr.net/npm/mermaid@12.2.0/dist/mermaid.min.js), which returned HTTP 200. The previous pin was 11.15.0.
- [Mermaid 12.0.0 release notes](https://github.com/mermaid-js/mermaid/releases/tag/mermaid%4012.0.0) say the full single-file browser build includes ELK. The tiny build does not. No extra layout package or dynamic module loader is needed here.
- The same release notes set ES2024 and Safari 17.4+ as the browser floor. Node 22.12+ is the package installation floor; Tycho loads the browser build and does not install Mermaid through Node. Older browsers can still show source if the script cannot load. This change does not promise Mermaid previews on older Safari versions.
- [Theme documentation](https://mermaid.js.org/config/theming.html) defines `redux-dark-color` as the dark counterpart of `redux-color`. The [12.2.0 dark theme source](https://github.com/mermaid-js/mermaid/blob/mermaid%4012.2.0/packages/mermaid/src/themes/theme-redux-dark-color.js) uses white state borders and starts the composite border palette with fuchsia `#E879F9`, as in the reference.
- The live theme documentation has stale layout text that says the global default is Dagre and ELK needs a separate package. The [pinned 12.2.0 schema](https://github.com/mermaid-js/mermaid/blob/mermaid%4012.2.0/packages/mermaid/src/schemas/config.schema.yaml) and release notes specify bundled ELK and an ELK global default. Use the pinned release contract and verify it in Chrome. The explicit state layout also records the card's requirement.

## Behaviour and verification

Keep the conditional script load, `startOnLoad: false`, and `securityLevel: strict`. Keep per-block Preview chart / Show code controls. Do not change Markdown sanitization or attachment isolation. Diagram frontmatter can still request a legacy theme, look, or layout. It cannot lower the site's security level.

Run `TYCHO_REMOTE_UI_MERMAID_ONLY=1 bin/remote-ui-smoke` from the repository root. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` with an absolute directory outside the checkout to save synthetic screenshots and JSON facts. This uses the existing temporary server, config, logs, and Google Chrome fixture flow. It checks the reference state chart at desktop and mobile sizes, screen-reader title and description, source round trips, lazy loading, per-block rendering, polling, other common diagram types, legacy overrides, unsafe links/directives, and invalid syntax recovery.

The full `bin/test` suite remains required for the exact published PR head, with the push transport guard and `signoff/tycho-bin-test`. The new browser check is optional local acceptance coverage, like the other Remote UI Chrome checks.
