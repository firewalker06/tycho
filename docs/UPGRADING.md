# Upgrading Tycho

## Unreleased

## 0.11.1

Configured Remote servers now report whether their own Tycho installation can
be updated through Homebrew. In **Settings → Servers**, the overflow menu shows
**Update Tycho** only for an online peer that reports this capability. The
action confirms the restart, keeps the browser on the UI-serving server while
the peer returns, then refreshes its catalog. Source installs and peers that do
not report support remain unchanged; use Git and `bin/setup` there.

### Intel macOS Homebrew bottles

v0.11.0 is the last Tycho Intel macOS Homebrew bottle. v0.11.1 ships no Intel
macOS bottle; Apple Silicon macOS and Linux bottles remain available. Move the
installation and its `~/.tycho` data to an Apple Silicon Mac, or run Tycho from
source. This does not change source checkout support or non-macOS environments.

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

### Delegation and notifications

Tycho now batches eligible child outcomes into one deterministic callback for
the parent. A terminal child turn owned by the current parent generation does
not increment the child's operator unread count or send a child completion push;
the parent callback remains the attention path. A direct user takeover, a stale
ownership generation, or a detached legacy relationship fails open to ordinary
operator attention instead of suppressing it.

### Schedules and workspace files

Schedules can now be created and updated through the CLI and Remote UI, and can
override the project harness, model, and reasoning effort. Existing schedules
continue to use project defaults when those fields are absent. The workspace
browser adds guarded plain-text editing and file search; its containment,
sensitive-file, binary, size, VCS, and symlink restrictions still apply.

### GitHub integration

The unfinished Tycho GitHub App login and review-posting workflow was removed,
including `tycho github login`, `tycho github status`, and `tycho github logout`.
Remove any automation that invokes those commands. Agent-scoped pull-request
diffs remain available as a read-only feature and now require an authenticated
local GitHub CLI; run `gh auth login` if needed. Tycho no longer posts pull-request
reviews itself.

Inline remote-server `token` values remain temporarily supported but produce a
migration warning. Move each one into Tycho's private credential store with
`tycho server migrate <server-key>` (or `tycho server migrate --all`).

### Verify

Run these checks after upgrading:

```bash
tycho --version
tycho --help
tycho doctor
tycho project list
tycho schedule list
```

For Homebrew installs, `tycho update` performs the package upgrade and safely
restarts a running local Remote server or scheduler daemon when present.
