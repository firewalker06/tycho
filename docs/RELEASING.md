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

5. Before tagging, prepare the website change list and screenshot audit plan
   described in **Required Website Delivery**. Record the site owner, affected
   version/release links, user and CLI documentation, image inventory, planned
   checks, and the previous verified deployment for rollback. Preparation can
   start before the tag exists; public release claims and new captures must use
   the exact published tag.

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

## Required Website Delivery

Use the [site release checklist](https://github.com/firewalker06/tycho-site/blob/main/docs/RELEASING.md)
and [ADR 004: release version and screenshot policy](https://github.com/firewalker06/tycho-site/blob/main/docs/decisions/adr-004-release-version-and-screenshots.md).
The site checklist must be merged and available before this phase can be marked
complete. A published GitHub release or Homebrew bottle does not prove website
delivery. The release is incomplete on the website surface until production
verification below passes.

### Prepare before tagging

Include a website delivery plan in the release checklist before creating the
release tag. List the homepage version and exact release URL, install and upgrade
guidance, configuration/reference pages, CLI examples, and changed feature claims.
Inventory every screenshot with its page, capture source, fixture version, and
retain-or-recapture decision. Record planned desktop/mobile and link checks, plus
the last verified site commit and deployment URL for rollback.

Do not advertise an unpublished version as available. A site refresh for an older
published release is separate from delivery of the next release.

### Align and verify after the exact published tag exists

1. Confirm the intended product tag and GitHub release exist. Record the full
   tag commit and exact release URL. Use that immutable source for product facts
   and captures; do not copy behavior from unmerged work.
2. In the site change, set an explicit public version and link it to
   `https://github.com/firewalker06/tycho/releases/tag/v<version>`. Align user
   documentation, upgrade notes, CLI examples, and feature claims to that tag.
   Do not fetch a volatile latest version during the site build.
3. Audit every screenshot against ADR 004. Recapture only when the pictured UI
   changed materially, its fixture names an old release, or it no longer supports
   the page's claim. Use the exact published tag and synthetic data for replacement
   images. Keep unaffected images with a recorded reason; do not force screenshot
   churn. Record capture provenance and new asset names/checksums. Exclude private
   prompts, paths, credentials, tokens, and real operational data.
4. Use the site's declared Node version requirements and pinned `packageManager`
   through Corepack. From the site repository root, run:

   ```sh
   corepack pnpm install --frozen-lockfile
   corepack pnpm build
   corepack pnpm check:links
   ```

   Serve the built output with the supported preview command and check it in an
   actual browser at desktop and mobile sizes. Check the homepage version/release
   link, navigation, changed screenshots, representative user/upgrade/CLI pages,
   overflow, and keyboard access. Save results with the exact site commit.
5. Obtain independent review of the site change and its evidence. The operator
   merges the site PR. Record the review, PR, and merged commit URLs. A reviewed
   source tree or successful local build is not production completion evidence.
6. With deployment authorization, deploy the exact merged site commit through
   the existing supported Pages workflow documented in the site checklist. Use
   the repository's deployment script and configured credential mechanism, not
   an improvised direct upload or replacement hosting setup. Keep secrets out of
   commits, logs, reports, and screenshots. Record the Pages deployment URL and
   deployed commit URL.
7. Verify the production URL after deployment. For example:

   ```sh
   curl --fail --show-error --location "<production-url>/"
   curl --fail --show-error --location "<production-url>/<representative-doc-path>/"
   curl --fail --show-error --location "<production-url>/<new-asset-path>"
   ```

   Check HTTP success and actual content, not only a successful deploy command.
   In a desktop and mobile browser, confirm the explicit version, exact GitHub
   release link and its target, new image bytes/rendering, representative docs,
   and internal/external navigation links. Compare the deployed commit and new
   asset checksums with the reviewed output. Record production URLs, verification
   results, and the commit/deployment URLs in the release checklist. Mark website
   delivery complete only when all checks pass. Keep an explicit incomplete or
   failed website result if verification has not passed.

### Website rollback

Before deployment, retain the previous verified commit and deployment URL. If
production checks fail, record the failed deployment and use the supported Pages
rollback process in the site checklist to restore that previously verified
deployment. Do not move the product release tag. Verify production HTTP, version,
release link, assets, representative docs, and navigation again, and record the
rollback deployment/commit URLs and results. A successful rollback restores the
prior site; it does not complete website delivery of the new release. Keep that
release's website gate open until a corrected deployment passes verification.

## Post-Release Verification

After publishing:

Record separate results for GitHub, Homebrew, website delivery, and social work.
Do not mark the website surface complete until **Required Website Delivery**
passes production verification.

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
