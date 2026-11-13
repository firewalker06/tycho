# Local CI signoff

Tycho uses a maintainer-run local test suite as its required merge attestation.
GitHub's enforced `signoff` ruleset on the default branch requires the
`signoff/tycho-bin-test` status for every pull request head. It also blocks
force pushes and branch deletion. This is a trusted-maintainer workflow, not a
replacement for independent review where that is needed.

The [Interaction Profiler](REMOTE_UI_INTERACTION_PROFILER.md) is optional verification for interaction feature work. Its profiling runs and Chrome smoke check are outside `bin/test`, normal CI, and the required signoff. Lightweight configuration and report-code checks remain in `bin/test`; they do not launch Chrome or run feature profiles.

See [test fixtures and prerequisites](TEST_FIXTURES.md) for normal checks,
optional browser tools, and installed harness checks.

## Markdown path check

`bin/test` first scans every line of every tracked Markdown file, including
root files, `docs/`, and bundled skill Markdown. There are no fenced-code,
inline-code, HTML, quote, list, or table exemptions. Use repository-relative
links, resolved from the file that contains the link.

The guard decodes backslash punctuation escapes and HTML named, decimal,
and hexadecimal character references once. It removes scheme URLs, including
their paths, queries, and fragments. File URIs and Windows drive paths remain
subject to the check. The named-reference table is local test data; no network
request is needed. Escaped ampersands and generated references are not decoded
again.

Remaining absolute local path tokens fail, including home-relative paths,
file URIs, Windows drive paths, and slash-rooted paths with a directory
separator or filename extension. Code formatting never exempts a token.

For examples, use relative placeholders such as `path/to/workspace` or
`HOME`. No token-level placeholder exemption exists. The end-of-line marker
below is the only allow mechanism.

If an exact literal is required, put `<!-- local-path-ok -->` at the end of
that source line. This is an explicit, line-only exception. Use it for a
required path literal, API route, or sample log route; it also works inside a
code block. Only trailing spaces or tabs may follow it. A marker on an earlier
line, a marker followed by more text, an encoded marker, or the old
`local-path-example` comment does not grant an exception.

The check prints each failed file, original line number, and source text,
then stops before the regression suite. `test/markdown_paths_test.rb` covers
the strict policy, marker scope, placeholders, URLs, decoding, and all review
reproductions, including code containers that end without a closing fence.

## Test notification safety

`bin/test` gives each command a fresh temporary HOME, Tycho home, skills home, and logs root,
clears inherited config-path overrides and per-run managed-agent variables
(`TYCHO_NATIVE_RELEASE_PATH`, `TYCHO_AGENT_KEY`, and the others listed in
`test/support/test_environment.rb`), and preloads
`test/support/push_safety.rb` for Ruby test files. The helper sets the root
before HQ constants load and blocks real Web Push transport. Scheduler
fixtures inject fake notifiers. Push delivery contract tests must install
their own explicit transport fake. Do not remove these boundaries when
adding a scheduler or notification fixture. The guard records denied transport
attempts and fails at process exit even if production code catches the exception.
Set `TYCHO_TEST_PUSH_AUDIT_FILE=path/to/temp/path.jsonl` to capture redacted
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
