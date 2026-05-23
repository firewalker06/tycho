# Security Policy

Tycho is local-first software. It reads local project checkouts, launches local
CLI tools, stores logs on disk, and can expose a local JSON API through
`bin/tycho serve`.

## Supported Versions

Security fixes are handled on the default branch until formal releases begin.

## Reporting A Vulnerability

Open a private security advisory if the repository host supports it. If not,
contact the maintainers through the repository owner profile.

Please include:

- Affected version or commit.
- Reproduction steps.
- Expected and actual behavior.
- Whether local files, credentials, agent transcripts, or Remote UI access are
  exposed.

## Remote UI

`bin/tycho serve` accepts unauthenticated API requests when `TYCHO_REMOTE_TOKEN` is unset.
That mode is intended for localhost only.

Set `TYCHO_REMOTE_TOKEN` before binding to a non-loopback address or exposing Tycho
through Tailscale:

```bash
TYCHO_REMOTE_TOKEN="$(ruby -rsecurerandom -e 'puts SecureRandom.hex(24)')" bundle exec bin/tycho serve
```

Public screenshots should redact MagicDNS URLs, Tailscale IPs, QR codes, local
paths, project names, PR URLs, and agent transcripts.

## Secrets And Logs

Do not commit:

- `.env`
- `~/.tycho/config/hq.yml`
- `~/.tycho/config/system_prompts.yml`
- `~/.tycho/config/hooks.yml`
- `~/.tycho/logs/`
- `tmp/`
- Agent raw logs, memory files, status files, or attachments
- Provider account IDs or model profile ARNs
