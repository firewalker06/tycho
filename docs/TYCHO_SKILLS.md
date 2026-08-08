# Tycho skill installation

Tycho ships a versioned `tycho` agent skill and manages personal installations from Remote UI **Settings → Skills**. The bundled source is [`lib/hq/skill_assets/tycho/SKILL.md`](../lib/hq/skill_assets/tycho/SKILL.md); [`lib/hq/skill_assets.json`](../lib/hq/skill_assets.json) records its source URL, release version, and SHA-256 checksum. The repository-local Claude skill is a small loader for the same packaged source.

## Supported harnesses

Tycho uses each harness's current personal skill directory. `TYCHO_SKILLS_HOME` can replace the home prefix for isolated tests or a deliberately separate harness profile; normal installations should leave it unset.

| Harness | Install root | Official convention |
| --- | --- | --- |
| Codex | `~/.agents/skills` | [OpenAI Codex skills](https://developers.openai.com/codex/skills) |
| Claude Code | `~/.claude/skills` | [Claude Code skills](https://code.claude.com/docs/en/skills) |
| OpenCode | `~/.config/opencode/skills` | [OpenCode agent skills](https://opencode.ai/docs/skills) |

Each skill lives in `<root>/tycho/SKILL.md`. Tycho places a `.tycho-owned.json` marker beside it. The marker records the Tycho source, installed version, and checksums used to prove that a later update is safe.

## Status and actions

- **Missing**: no `tycho` directory exists. **Install** is available.
- **Installed**: the source version, ownership marker, and file checksums match. Repeated install or update requests make no changes.
- **Outdated**: a valid, unmodified Tycho-owned installation differs from the bundled source. **Update** is available.
- **Blocked**: the name belongs to an unmarked skill, the ownership marker is invalid, or a managed file has local edits. Tycho does not overwrite it.
- **Error**: Tycho cannot read its bundled source or the target path. The UI reports whether the problem is a permission, network/source, or compatibility failure and gives the affected path.

Install and update require a confirmation in the Remote UI and `{"confirmed":true}` through the Remote API. Updates build a staged copy, preserve extra files in the Tycho-owned directory, atomically replace managed files, and roll back the directory swap if replacement fails. Other skill directories are never changed.

## Verify an installation

1. Open **Settings → Skills** and confirm the harness reads **Installed** with the expected source version.
2. Open that harness's skill picker and invoke `tycho`: use `$tycho` in Codex or OpenCode and `/tycho` in Claude Code.
3. If a new top-level skill directory is not detected, restart the harness. Claude Code usually detects changes live; Codex documents restart as a fallback.

The read-only API is `GET /skills`. A confirmed mutation uses `POST /skills/{harness}/install` or `POST /skills/{harness}/update`.
