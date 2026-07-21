# Releasing Tycho

This is the maintainer runbook for cutting Tycho releases. Keep releases small,
tagged from `main`, and backed by a passing `bin/test` run.

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

   The formula test should include `tycho doctor`. On Intel macOS bottles this
   confirms the Ruby Lipgloss compatibility backend is selected and the native
   Lipgloss extension is not loaded into the Bubbletea process.

5. Push the branch, open a pull request in `firewalker06/homebrew-tycho`, and
   wait for every `brew test-bot` job to pass. The standard matrix builds Apple
   Silicon macOS and Linux bottles. The separate `macos-15-intel` job builds the
   Intel macOS bottle; confirm its `bottles_macos-15-intel` artifact contains a
   `sequoia` bottle before publishing.

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

## Post-Release Verification

After publishing:

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
