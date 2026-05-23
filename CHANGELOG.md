# Changelog

All notable changes to Tycho will be documented in this file.

## Unreleased

- Add MIT license and public contribution/security/code-of-conduct documentation.
- Add open-source readiness plan.
- Add source-install README.
- Add CI and `bin/test` test runner.
- Add version and gemspec metadata.
- Replace real parser fixtures and tool-shape notes with synthetic examples.
- Replace provider-specific Claude wrapper support with generic custom Claude harness configuration.
- Add Remote UI warning for unauthenticated non-loopback binds.
- Use `TYCHO_*` environment variables as the public runtime override contract.
- Add `bin/tycho serve` and `bin/tycho schedule daemon` so packaged installs can use one `tycho` command.
- Move default config, schedule prompts, runtime state, and logs under `~/.tycho`.
