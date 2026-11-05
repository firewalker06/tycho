# Local CI signoff

Tycho uses a maintainer-run local test suite as its required merge attestation.
GitHub's enforced `signoff` ruleset on the default branch requires the
`signoff/tycho-bin-test` status for every pull request head. It also blocks
force pushes and branch deletion. This is a trusted-maintainer workflow, not a
replacement for independent review where that is needed.

The [Interaction Profiler](REMOTE_UI_INTERACTION_PROFILER.md) is optional verification for interaction feature work. Its profiling runs and Chrome smoke check are outside `bin/test`, normal CI, and the required signoff. Lightweight configuration and report-code checks remain in `bin/test`; they do not launch Chrome or run feature profiles.

## Markdown path check

`bin/test` first scans every tracked Markdown file, including root files and
`docs/`. Use repository-relative links, resolved from the file that contains
the link.

The guard scans lines rather than parsing link forms. It removes fenced code
blocks and inline code, then decodes backslash punctuation escapes and HTML
named, decimal, and hexadecimal character references in one pass. The named
reference table is local test data; no network request is needed. Escaped
ampersands and generated character references are not decoded again.

The scan removes scheme URLs, including their paths, queries, and fragments.
File URIs and Windows drive paths remain subject to the local path check.
It rejects remaining absolute local path tokens anywhere on a line, including
quotes, nested lists, tables, reference definitions, and HTML attributes.
Tokens include slash-rooted paths with a directory separator or filename
extension, home-relative paths, file URIs, and Windows drive paths. Relative
repository paths do not count as absolute tokens.

Use fenced or inline code for required path examples. Code examples are
excluded even when they contain link syntax. A `local-path-example` comment
does not exempt path text outside code. The check prints each failed file,
line, and source text, then stops before the regression suite.
`test/markdown_paths_test.rb` covers the line-scan policy and all review
reproductions. The three older expectations that depended on link parsing
now follow this policy: fenced link examples pass, while local path text in
HTML attribute text and backslash-escaped HTML paths fail.

## Test notification safety

`bin/test` gives each command a fresh temporary Tycho home and logs root,
clears inherited config-path overrides and per-run managed-agent variables
(`TYCHO_NATIVE_RELEASE_PATH`, `TYCHO_AGENT_KEY`, and the others listed in
`test/support/test_environment.rb`), and preloads
`test/support/push_safety.rb` for Ruby test files. The helper sets the root
before HQ constants load and blocks real Web Push transport. Scheduler
fixtures inject fake notifiers. Push delivery contract tests must install
their own explicit transport fake. Do not remove these boundaries when
adding a scheduler or notification fixture. The guard records denied transport
attempts and fails at process exit even if production code catches the exception.
Set `TYCHO_TEST_PUSH_AUDIT_FILE=/absolute/temp/path.jsonl` to capture redacted <!-- local-path-example: Sample temporary or placeholder path. -->
per-process attempt counts. An intentional guard probe clears only its own
expected denial. For standalone tests not already requiring the helper, use
`bundle exec ruby -r ./test/support/push_safety.rb test/NAME_test.rb`.
No production entry point loads this helper.

## Supported tool

Use [basecamp/gh-signoff](https://github.com/basecamp/gh-signoff) **v0.4.1**.
Install that exact release with GitHub CLI:

```bash
gh extension install basecamp/gh-signoff --pin v0.4.1
gh signoff version # gh-signoff 0.4.1
```

If it is already installed, use `--force` to replace it with the pinned
release. Upgrade the documented version only after checking the upstream
release and updating this runbook.

## Maintainer workflow

Run the complete suite after pushing the final PR head, then post the required
context against that exact pushed commit:

```bash
git push
git rev-parse HEAD
bin/test
gh signoff --commit HEAD tycho-bin-test
gh signoff status --commit HEAD
```

`gh signoff` refuses an unpublished commit unless forced, so do not sign off
before the push. If another commit is pushed, repeat the complete sequence for
the new SHA. A green status belongs to one commit; it does not approve a later
head.

Use these read-only checks to confirm the repository configuration and the PR
head's attestation:

```bash
gh signoff check --branch main tycho-bin-test
gh signoff contexts --branch main
gh pr view --json headRefOid,mergeStateStatus,statusCheckRollup
```

The expected required context is `signoff/tycho-bin-test`.

## Failures and another clone

If `bin/test` fails, publish a red status for the tested commit instead of
signing it off:

```bash
gh signoff fail --commit HEAD tycho-bin-test \
  --description "bin/test failed; see local output"
```

Another trusted maintainer can attest to a specific pushed SHA from a different
clone. They must fetch the commit, check it out or name it explicitly, run the
same suite, and sign that SHA:

```bash
git fetch origin <sha>
git show --quiet <sha>
bin/test
gh signoff --commit <sha> tycho-bin-test
gh signoff status --commit <sha>
```

Never use `-f` to bypass the published-commit safeguard for a merge
attestation.

## Ruleset maintenance

The repository owner installs the requirement once:

```bash
gh signoff install tycho-bin-test
```

This creates or updates the enforced default-branch `signoff` ruleset. It
manages only its own signoff requirements and preserves other GitHub rulesets
and automation. Check GitHub's Rules page or `gh api repos/OWNER/REPO/rulesets`
afterward; do not remove a workflow or another rule until the requirement is
active and a PR has demonstrated its pending and successful states.
