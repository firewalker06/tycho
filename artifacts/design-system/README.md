# Design-system visual reference

The live `/design-system` HTML page is the canonical visual reference. It covers tokens,
components, interaction states, composite patterns, and responsive behavior without
committing generated image binaries.

Run an isolated preview with:

`bin/remote-ui-smoke`

The smoke check starts Tycho with temporary configuration, fixtures, and logs, then
opens the preview in installed Google Chrome. It does not touch real agents or project
configuration.

Screenshots for pull requests are disposable review artifacts. Save them outside the
repository, for example under `~/.tycho/logs/agents/assets/`, and upload them to the
pull request manually. Do not add generated screenshots to Git.
