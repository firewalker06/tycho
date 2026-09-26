# Local CI signoff

Tycho uses a maintainer-run local test suite as its required merge attestation.
GitHub's enforced `signoff` ruleset on the default branch requires the
`signoff/tycho-bin-test` status for every pull request head. It also blocks
force pushes and branch deletion. This is a trusted-maintainer workflow, not a
replacement for independent review where that is needed.

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
