# HQ Open Source Plan

## Goal

Prepare HQ to become a public open-source project without exposing private
configuration, local runtime artifacts, company-specific data, or unclear
security assumptions.

HQ should be presented as a local-first developer dashboard for Kamal-deployed
applications and managed coding agents.

## Readiness Snapshot

HQ already has useful internal architecture docs and sample config files:

- `config/hq.yml.example`
- `config/system_prompts.yml.example`
- `.env.sample`
- `docs/REMOTE_SERVER.md`
- `docs/PROJECT_STATUS.md`

The main release blockers are public-facing polish, privacy hardening, packaging,
and contributor infrastructure.

Current blockers:

- No `README.md`, `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, or
  GitHub workflow.
- No gemspec or versioned package story yet. The current install path is clone,
  `bundle install`, and `bin/tycho`.
- Tracked parser fixtures and tests contain private-looking paths,
  company/project references, PR numbers, and real agent-log-shaped data,
  especially under `test/fixtures/parser/claude/*.jsonl` and
  `test/memory_entries_test.rb`.
- Real local files are ignored by `.gitignore`, including `.env`, real config,
  logs, and temp files, but git history still needs a secret and privacy scan
  before publishing.
- Remote UI authentication is optional. That is acceptable for localhost, but
  public users need clearer safe defaults when binding to Tailscale or another
  non-loopback address.

## Phase 1: Decide The Public Contract

Define the public positioning:

- HQ is a local-first dashboard for monitoring Kamal apps and supervising managed
  coding agents.
- Supported runtime: Ruby 3.2+.
- Initial platform expectation: macOS-first, with Linux support where the runtime
  paths work.
- Optional integrations: `mise`, `kamal`, `tailscale`, Codex, Claude, and
  custom Claude-compatible harnesses.
- License: MIT.

## Phase 2: Scrub Private Data

Replace real agent-log fixtures with synthetic fixtures that preserve parser edge
cases but remove:

- Personal paths.
- Company names.
- Private repository names.
- PR numbers.
- Bedrock or model-provider IDs.
- Real task prompts.
- Real command output.

Audit or remove bulky/internal docs if they contain private workflow assumptions.
Keep public docs that explain stable behavior. Move personal roadmap notes to a
private location if they are not meant for contributors.

Run tracked-file scans:

```bash
git ls-files -z | xargs -0 rg -n 'personal-name|company-name|/Users/real-user|TOKEN|SECRET|PRIVATE|PASSWORD|AWS_|OPENAI|ANTHROPIC'
```

Run secret scanners:

```bash
gitleaks detect --source .
trufflehog git file://$PWD --only-verified
```

Also scan git history. If history contains private data, publish from a clean
repository or rewrite history before making the repo public.

## Phase 3: Add Public Project Files

Create the standard public-facing files:

- `README.md`
- `LICENSE`
- `CHANGELOG.md`
- `CONTRIBUTING.md`
- `CODE_OF_CONDUCT.md`
- `SECURITY.md`
- `.github/workflows/ci.yml`
- Issue templates
- Pull request template

The README should cover:

- What HQ is.
- Who it is for.
- Screenshots or a short demo GIF with private data redacted.
- Install requirements.
- First-run setup.
- TUI usage.
- Remote UI usage.
- Security model.
- Optional integrations.
- Troubleshooting.

Recommended first-run flow:

```bash
bundle install
cp config/hq.yml.example config/hq.yml
cp config/system_prompts.yml.example config/system_prompts.yml
bin/tycho
```

## Phase 4: Harden Defaults For Public Users

Review local-machine assumptions and document or soften them:

- `/opt/homebrew/bin/mise` should have a clear fallback or setup note.
- Missing optional tools should produce clear messages.
- `bin/tycho serve` should warn or require `TYCHO_REMOTE_TOKEN` when binding to a
  non-loopback address.
- Tailscale and push-notification behavior should stay documented as local-first,
  with public screenshots redacting MagicDNS URLs, IP addresses, and QR codes.

Add startup validation for optional tools:

- `kamal`
- `mise`
- `tailscale`
- `codex`
- `claude`
- custom Claude-compatible harnesses

## Phase 5: Create A Repeatable Test And Release Path

Add a single test entrypoint, such as `bin/test` or a `Rakefile`, so contributors
do not need to memorize individual test files.

The public CI suite should run at least:

```bash
bundle exec ruby -c bin/tycho
bundle exec ruby test/registry_test.rb
bundle exec ruby test/rendering_test.rb
bundle exec ruby test/parser_test.rb
bundle exec ruby test/managed_agent_test.rb
bundle exec ruby test/remote_server_test.rb
bundle exec ruby test/tailscale_test.rb
bundle exec ruby test/terminal_qr_test.rb
```

Decide packaging:

- Minimum viable release: source install only.
- Better release: add `lib/hq/version.rb`, `hq.gemspec`, executable metadata,
  release tags, and a changelog.
- Later release: publish to RubyGems once the CLI and config contract stabilize.

## Phase 6: Prepare The Public Launch Branch

Create a dedicated branch:

```bash
git switch -c open-source-prep
```

Suggested commit sequence:

1. Sanitize fixtures and docs.
2. Add license and README.
3. Add contributor and security docs.
4. Add CI and a test runner.
5. Add release/version metadata.
6. Apply final privacy scan fixes.

Before changing repository visibility:

```bash
bundle exec ruby -c bin/tycho
bundle exec ruby test/registry_test.rb
bundle exec ruby test/rendering_test.rb
bundle exec ruby test/parser_test.rb
bundle exec ruby test/managed_agent_test.rb
bundle exec ruby test/remote_server_test.rb
bundle exec ruby test/tailscale_test.rb
bundle exec ruby test/terminal_qr_test.rb
```

Then rerun tracked-file, secret, and history scans.

## Launch Criteria

HQ is ready to open source when:

- A new user can get from clone to running TUI using only README instructions.
- No tracked file or git history contains private paths, names, tokens, logs, or
  company-specific data.
- CI is green on a clean checkout.
- Remote UI security expectations are documented and safe by default.
- License and contribution terms are explicit.
- The first public release has a clear scope, known limitations, and a small
  roadmap.

## Recommended Next Work

Current-tree privacy scrubbing, public docs, CI, MIT licensing, gem metadata,
Remote UI token warnings, and synthetic fixtures are in place.

Do not make the existing git history public as-is. History scans still show old
commits with private paths and project names. Publish from a clean repository or
approve an explicit history rewrite before changing visibility.
