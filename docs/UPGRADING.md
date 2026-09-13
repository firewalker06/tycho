# Upgrading Tycho

## 0.11.0

Upgrade from `0.10.2` normally through Homebrew, or update a source checkout
with Git and rerun `bin/setup` when its dependency check requests it. Existing
projects, schedules, managed-agent logs, delegation ledgers, and Remote UI
settings do not require manual data migration.

### Command change

The implicit project-creation shortcut has been removed. Replace every use of:

```bash
tycho project my-project
```

with:

```bash
tycho project create my-project [options]
```

Use `tycho project show my-project` to inspect an existing project. Bare or
malformed project commands now fail without writing to `hq.yml`.

### Skills

The bundled `tycho` skill changed with this release. In **Settings → Skills**,
run the confirmed **Update** action for each Tycho-owned installation, then
restart a harness if needed. Tycho never overwrites unmarked or locally changed
skills; reconcile those copies manually. See [Tycho skills](TYCHO_SKILLS.md).

### Custom profiles and FRED

Existing `adapter: claude` custom harness entries remain supported. New custom
profiles must declare a supported native adapter (`codex`, `claude`,
`opencode`, or `pi`). FRED is opt-in and disabled until it is configured in
Remote UI. It uses protected daily sessions, so ordinary agent lifecycle and
delegation APIs cannot control it.

Inline remote-server `token` values remain temporarily supported but produce a
migration warning. Move each one into Tycho's private credential store with
`tycho server migrate <server-key>` (or `tycho server migrate --all`).

### Verify

Run these checks after upgrading:

```bash
tycho --help
tycho doctor
tycho project list
tycho schedule list
```

For Homebrew installs, `tycho update` performs the package upgrade and safely
restarts a running local Remote server or scheduler daemon when present.
