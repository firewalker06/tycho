# Releasing Tycho

This is the maintainer runbook for cutting Tycho releases. Keep releases small,
tagged from `main`, and backed by a passing `bin/test` run. Website delivery is
required for each release. Track GitHub release, Homebrew, website, and social
results separately; success on one surface does not complete another.

This runbook describes the process, not permission to publish. The operator owns
merges. Tagging, package publication, deployment, and social scheduling require
their applicable authorization.

## Version Policy

- Patch releases (`0.1.x`) are for bug fixes, documentation fixes, and small
  UX improvements that do not change the public config or command contract.
- Minor releases (`0.x.0`) are for new user-facing commands, config keys,
  packaging behavior, or Remote UI/TUI workflows.
- Major releases are reserved for breaking changes after Tycho reaches `1.0`.

## Preconditions

Before preparing a release:

1. Confirm all intended changes are merged into `main`.
2. Sync `main` locally with `git pull --ff-only`.
3. Confirm the working tree is clean with `git status -sb`.
4. Review changes since the previous tag:

   ```sh
   git log --oneline <previous-tag>..main
   ```

5. Decide the next version and check that the tag does not already exist:

   ```sh
   git tag --list v<next-version>
   ```

## Release-Prep PR

Prepare releases through a small pull request. The release-prep PR should:

1. Bump `lib/hq/version.rb`.
2. Move relevant `CHANGELOG.md` entries from `Unreleased` into a dated version
   section.
3. Update durable project status or roadmap notes when a release milestone
   changes.
4. Run:

   ```sh
   bin/test
   ```

Use an imperative commit message such as:

```sh
Prepare v0.1.1 release
```

Merge the release-prep PR before tagging.

## Publish GitHub Release

After the release-prep PR is merged:

1. Sync `main`:

   ```sh
   git switch main
   git pull --ff-only
   ```

2. Create and push an annotated tag:

   ```sh
   git tag -a v<next-version> -m "Tycho v<next-version>"
   git push origin v<next-version>
   ```

3. Create the GitHub release:

   ```sh
   gh release create v<next-version> --title "Tycho v<next-version>" --notes-file /path/to/notes.md
   ```

Release notes should summarize user-visible changes, compatibility notes, and
validation.

## Homebrew Tap

Tycho's public tap is `firewalker06/homebrew-tycho`.
Its authoritative bottle workflow is documented in the tap's
[`docs/RELEASING.md`](https://github.com/firewalker06/homebrew-tycho/blob/main/docs/RELEASING.md).
The tap uses `brew test-bot` to build bottle artifacts and the `pr-pull`
pull-request label to publish them. Do not merge the formula PR manually before
the publish workflow runs.

### Intel macOS Homebrew bottles

v0.11.0 is the last Tycho Intel macOS bottle. Starting with v0.11.1, publish
Apple Silicon macOS and Linux bottles only. Do not add an Intel job, artifact,
or checksum to the tap workflow or formula. Intel users can run Tycho from
source.

After the GitHub release exists:

1. Confirm the upstream tag is visible:

   ```sh
   git ls-remote --tags https://github.com/firewalker06/tycho.git \
     "refs/tags/v<next-version>*"
   ```

2. Download the release tarball and calculate its SHA-256:

   ```sh
   curl -L -o tycho-v<next-version>.tar.gz \
     https://github.com/firewalker06/tycho/archive/refs/tags/v<next-version>.tar.gz
   shasum -a 256 tycho-v<next-version>.tar.gz
   ```

3. Create a branch such as `tycho-<next-version>` in the tap and update
   `Formula/tycho.rb`:

   ```ruby
   url "https://github.com/firewalker06/tycho/archive/refs/tags/v<next-version>.tar.gz"
   sha256 "..."
   ```

   Use commit subject `tycho <next-version>`.

4. Validate the formula from the installed tap checkout:

   ```sh
   cd "$(brew --repository firewalker06/tycho)"
   brew audit --strict --online firewalker06/tycho/tycho
   brew install --build-from-source firewalker06/tycho/tycho
   brew test firewalker06/tycho/tycho
   brew uninstall firewalker06/tycho/tycho
   ```

   The formula test should include `tycho doctor`.

5. Push the branch, open a pull request in `firewalker06/homebrew-tycho`, and
   wait for every `brew test-bot` job to pass. The standard matrix builds Apple
   Silicon macOS and Linux bottles only. Confirm no Intel job or artifact is
   present before publishing.

6. After all bottle jobs pass, have a trusted maintainer add the `pr-pull`
   label to the formula pull request. The tap's `pull_request_target` workflow
   has write access and will:

   - download the bottle artifacts from the pull-request workflow;
   - create or update the `tycho-<next-version>` GitHub Release;
   - upload the bottle assets;
   - merge the generated `bottle do` checksums into `Formula/tycho.rb`;
   - push the result to the tap's `main` branch; and
   - delete the pull-request branch when it belongs to the tap repository.

   Only trusted maintainers should apply `pr-pull`. Confirm the tap has the
   label and that GitHub Actions can write repository contents before relying
   on this step.

7. Verify the published bottle:

   ```sh
   brew update
   brew reinstall firewalker06/tycho/tycho
   brew test firewalker06/tycho/tycho
   brew info firewalker06/tycho/tycho
   ```

## Website Delivery

Website delivery is a separate surface. It is owned by the registered `tycho-site`
project, not by this repository. After the operator merges the release-prep PR and
the exact tag exists, a Tycho agent registered for `tycho-site` takes over website
delivery. That agent follows the site-owned
[site release checklist](https://github.com/firewalker06/tycho-site/blob/main/docs/RELEASING.md)
and its decision records, including
[ADR 004: release version and screenshot policy](https://github.com/firewalker06/tycho-site/blob/main/docs/decisions/adr-004-release-version-and-screenshots.md).
Site planning, screenshot inventories, owner records, rollback evidence,
deployment, and production verification are recorded in `tycho-site`.

Product release PRs in this repository do not contain a website plan. Do not add
website planning, screenshot inventories, or site rollback records to a
release-prep PR. Do not start the site agent before the operator merges the
release-prep PR.

After the tag exists, give the site agent the exact product tag and commit URLs.
Those are the immutable source for product facts and captures.

Track website delivery as its own result. A GitHub release or a Homebrew
publication does not complete the website surface. The website surface is
incomplete until the site agent records production verification under its own
workflow.

Website rollback belongs to the site workflow. A website rollback never moves the
product release tag.

## Post-Release Verification

After publishing:

Record separate results for GitHub, Homebrew, website delivery, and social work.
Do not mark the website surface complete until the registered `tycho-site`
workflow records production verification. See **Website Delivery**.

1. Confirm the GitHub release page exists.
2. Confirm the Homebrew formula points at the new tag and SHA.
3. Run a source checkout smoke test:

   ```sh
   bin/tycho --help
   bin/tycho doctor
   bin/tycho agent list
   bin/tycho schedule list
   ```

4. If the Homebrew tap was updated, run:

   ```sh
   brew update
   brew install firewalker06/tycho/tycho
   tycho --help
   tycho doctor
   ```

## Corrections

If a release is wrong but harmless, cut a new patch release. Do not move an
existing public tag unless the release is private and no one could have fetched
it.

If a release is broken enough to hide, mark the GitHub release as a prerelease
or delete the release page, then cut a corrected patch version from `main`.
