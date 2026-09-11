# Spinel feasibility for Tycho distribution

Date: 2026-09-11

Fizzy: [#171](https://fizzy.startkit.tech/1/cards/171)

Decision: **Do not adopt Spinel for Tycho distribution.**

## Executive decision

Spinel cannot package the current Tycho application. It is a whole-program
ahead-of-time compiler for a deliberately static Ruby subset and a separate
source-package ecosystem, not a freezer for arbitrary CRuby applications and
their installed gems. Tycho needs CRuby semantics, ordinary RubyGems, three
Go-backed native extensions, Ruby's OpenSSL extension, dynamic CLI and template
code, extensive process management, and packaged non-code assets. Converting
that application to Spinel would be a port of Tycho and several dependencies,
not a distribution change.

The experiment made the boundary concrete. Spinel built and ran a 96,840-byte
single-file hello program on arm64 macOS. Compiling Tycho with Spinel's strict
require gate stopped in 0.02 seconds at `require "rbconfig"`. With the gate
disabled, Spinel ignored 17 unavailable requirements—including `bubbletea`,
`bubbles`, `dry/cli`, `yaml`, `open3`, `rqrcode`, and `web_push`—then
stopped during whole-program analysis because Tycho passes `ENV` as an object.
No Tycho artifact was produced.

Keep the existing bottled Homebrew release path. It already gives the operator
one install command and isolates platform-specific Ruby/native-gem builds in
release CI. If a direct downloadable executable remains important, investigate
a CRuby-preserving packer such as OCRAN in a separate bounded card; do not turn
that experiment into a release path until it passes Tycho's full command,
TUI, Remote UI, native-extension, subprocess, update, and platform matrix.

## Question and decision criteria

The question is not whether Spinel can compile Ruby-looking programs. It is
whether it can materially reduce Tycho's installation burden without changing
Tycho's behavior or replacing its dependency architecture. The evaluation uses:

- operator installation steps;
- artifact portability across macOS/Linux and CPU architectures;
- build and release complexity;
- security and update behavior;
- native dependency support;
- artifact size;
- ongoing maintenance; and
- compatibility with Tycho's actual runtime, assets, configuration, and state.

## Current Tycho distribution

Tycho's primary install is:

```sh
brew tap firewalker06/tycho
brew install tycho
```

The v0.10.2 formula has two runtime dependencies, `ruby` and `openssl@3`; their
transitive formula dependencies are `libyaml` and `ca-certificates`. Go is
build-only. The tap publishes Tycho bottles for Apple Silicon macOS, Intel
macOS, and x86-64 Linux. The published Tycho bottle payloads are 75,545,697,
78,294,939, and 78,942,638 bytes respectively; Ruby and OpenSSL bottles are
separate downloads. See the pinned
[formula](https://github.com/firewalker06/homebrew-tycho/blob/2c4df7c7ff3af62cd3deb7631f9fe81c78e89dad/Formula/tycho.rb),
[v0.10.2 assets](https://github.com/firewalker06/homebrew-tycho/releases/tag/tycho-0.10.2),
and [bottle release process](../RELEASING.md#homebrew-tap).

This dependency chain is substantial, but bottles move compilation to release
CI. Installation remains two shell commands for a new tap and one command for
later upgrades. `tycho update` already delegates upgrades to Homebrew and
restarts local Tycho services through the stable launcher; this was added in
[PR #103](https://github.com/firewalker06/tycho/pull/103) for related Fizzy
card #146.

Source installs remain a separate fallback. They require Ruby 3.2+, Bundler,
Go when a prebuilt Charm gem is unavailable, and native build tools, as
documented in [SETUP_REQUIREMENTS.md](../SETUP_REQUIREMENTS.md).

## What Spinel is

At the tested revision, Spinel parses Ruby with Prism, performs whole-program
type inference, emits C, and invokes a system C compiler. Its output contains
neither CRuby nor a runtime Ruby parser. `require_relative` sources are spliced
into the program at compile time. Named dependencies must be part of Spinel's
bundled libraries, available through `-I`, or expressed as a `spin` source
package. The model enables small native programs but imposes static-language
constraints: no `eval`, general runtime metaprogramming, runtime loading, or
arbitrary CRuby extension ABI.

Primary sources:

- [Spinel README and build model](https://github.com/matz/spinel/blob/a4b7238e78f84cbbc20ec68372bed26c20ee6928/README.md)
- [AOT limitations](https://github.com/matz/spinel/blob/a4b7238e78f84cbbc20ec68372bed26c20ee6928/docs/limitations.md)
- [`require` and source inclusion](https://github.com/matz/spinel/blob/a4b7238e78f84cbbc20ec68372bed26c20ee6928/docs/require.md)
- [`spin` package, native-C, vendoring, and pack model](https://github.com/matz/spinel/blob/a4b7238e78f84cbbc20ec68372bed26c20ee6928/docs/spin.md)
- [FFI model](https://github.com/matz/spinel/blob/a4b7238e78f84cbbc20ec68372bed26c20ee6928/docs/FFI.md)
- [CI platform matrix](https://github.com/matz/spinel/blob/a4b7238e78f84cbbc20ec68372bed26c20ee6928/.github/workflows/ci.yml)
- [MIT license](https://github.com/matz/spinel/blob/a4b7238e78f84cbbc20ec68372bed26c20ee6928/LICENSE)

### Versions, platforms, and maintenance

Spinel does not target a named CRuby compatibility version. It supports a
documented subset of Ruby syntax and core/stdlib behavior. Its benchmark and
parity oracle at the tested revision use CRuby 4.0.4, while CI installs Ruby
3.4 for reference tests; a target program does not run on either interpreter.
That is materially different from Tycho's `required_ruby_version >= 3.2`.

The documented target platforms are Linux x86-64/arm64 with GCC or Clang and
macOS Intel/Apple Silicon with Clang. BSD is expected but absent from CI.
Native Windows is unsupported; WSL runs the Linux target. Each output is tied
to an OS and architecture, so releases still need a target matrix.

The project is active but immature as a release dependency. The repository was
created on 2026-03-25, the tested `master` revision
`a4b7238e78f84cbbc20ec68372bed26c20ee6928` was pushed on 2026-09-11, and its
history changes rapidly. GitHub exposed no tags or releases at evaluation time,
and the locally built compiler identified itself as `unreleased`. High activity
is useful evidence of maintenance, but the lack of a versioned release contract
and the frequency of correctness fixes make it unsuitable for Tycho's release
toolchain today. See [commit history](https://github.com/matz/spinel/commits/master/)
and [releases](https://github.com/matz/spinel/releases).

### Native code and external programs

Spinel does not load CRuby `.bundle`/`.so` extensions. A `spin` package may
carry C sources that compile against Spinel's runtime, or use Spinel's FFI to
link a system library. That requires a port or adapter; an existing extension
written for CRuby's C API or embedding a Go c-archive is not reusable as-is.
System libraries named by FFI remain target-machine or release-build
dependencies. `spin pack` creates a source directory that can rebuild without
Spinel, but still requires GCC-compatible `cc`, `make`, and any linked system
libraries; it is not the end-user single-file result.

Spinel implements selected process operations and can invoke external commands.
That does not bundle those commands. A compiled Tycho would still require the
chosen agent harness and optional tools on `PATH`, exactly as the Homebrew
formula does now.

## Tycho runtime inventory against Spinel

### Required Ruby and gem surface

The locked application uses Ruby 3.4.7 semantics and Bundler 2.7.2. Its direct
gems are `bubbles`, `bubbletea`, `dry-cli`, `erb`, `glamour`, `lipgloss`,
`logger`, `net-http`, `rqrcode`, `uri`, `web-push`, and `yaml`; transitive gems
include `openssl`, `jwt`, `base64`, `chunky_png`, `rqrcode_core`, and
`harmonica`.

The decisive incompatibilities are:

| Requirement | Tycho use | Spinel fit |
|---|---|---|
| `bubbletea`, `lipgloss`, `glamour` | TUI event loop, styles, Markdown rendering | **No.** The installed platform gems load Ruby-ABI-specific Mach-O bundles backed by Go static archives. Spinel cannot load them. Reimplementing their APIs/runtime is a product port. |
| `bubbles` | TUI components layered on Bubbletea/Lipgloss | **No.** Pure Ruby source is not enough because its dependencies are unavailable and it is not a Spinel package. |
| `dry-cli` | Command declaration and dispatch | **No.** Not available to Spinel; adapting the gem would also need proof that its dynamic DSL fits whole-program AOT. |
| `openssl` and `web-push` | HTTPS, credentials, VAPID keys, JWT signing, browser push | **No equivalent contract.** Spinel's OpenSSL package exposes a limited SSL/digest/HMAC subset, not Ruby OpenSSL 4.0.1 or the existing `web-push` gem. |
| `yaml`, `logger`, `rqrcode`, `open3`, `rbconfig`, `shellwords`, `timeout`, `tempfile`, `find`, `date`, `ipaddr` | Config/state, logging, terminal QR, process capture, runtime paths, timeouts, temporary files, discovery, networking | **No current application path.** The feasibility compile reported these or their gems unavailable. Some could be ported individually; together they constitute a second runtime ecosystem. |
| CRuby/Bundler loading | Source checkout and installed gem activation | **No.** Spinel explicitly omits CRuby and does not consume a Bundler installation as an application freezer. |

Spinel has packages named `erb`, `net`, `openssl`, `uri`, and others. Matching a
require name is not API or behavioral compatibility with the Ruby gem Tycho
locks. The experiment therefore used the application itself as the gate rather
than treating package-name overlap as proof.

### Processes and tools

Process ownership is central, not incidental. Tycho uses `Process.spawn`,
process groups, `wait2`/`waitpid2`, `WNOHANG`, signals, detach, `exec`, pipes,
and `Open3.capture3`/`popen3`. It restarts itself via the current Ruby
executable, runs a separate Markdown-rendering worker, records streaming agent
subprocesses, and launches shell hooks. Even where Spinel has a similarly named
primitive, replacing CRuby/Open3 behavior would require lifecycle and signal
regression testing across every supported OS.

Tycho intentionally does not bundle external integrations:

- `codex`, `claude`, `opencode`, or `pi` is required for its chosen managed
  harness; custom profiles may point at other compatible commands;
- `git` supplies project metadata and diffs;
- `gh` optionally supplies the GitHub access token, while Tycho sends GitHub
  API requests itself;
- `tailscale`, `osascript`, `open`, and `wezterm` enable optional platform
  behavior.

There is no Fizzy CLI call in the Tycho runtime. Fizzy is the project workflow
used for this research card. A single Tycho executable would not and should not
absorb agent CLIs, Git, GitHub CLI, Fizzy, or Tailscale; they have independent
credentials and update/security lifecycles.

### Browser and Node assets

The Remote UI server ships static HTML, CSS, JavaScript, images, and service
worker assets inside the gem. It needs a user's web browser, but not a bundled
browser runtime. Node and Playwright 1.56.1 are development-only dependencies
for smoke tests and deterministic screenshots; they are not in `hq.gemspec` or
the Homebrew runtime formula.

Spinel's compile-time source inclusion does not automatically embed arbitrary
files read through `File.binread`. Tycho currently reads roughly 1.2 MiB of
Remote UI and skill assets from paths relative to its installed library, plus
example config and the structured-result schema. A Spinel port would need a
new resource-embedding layer and compatible path behavior.

### Configuration and writable state

Packaging code in one file cannot package user state. Tycho must continue to
create and update configuration, locks, schedules, logs, agent streams,
attachments, metrics, and workspace metadata under `~/.tycho` (or explicit
`TYCHO_*` overrides). Those are correct writable boundaries and must remain
outside any immutable executable.

## Isolated feasibility experiment

The experiment used a temporary directory outside the repository. It did not
read real Tycho config/log roots, start Tycho, or write a generated artifact to
the checkout. The temporary compiler clone, downloads, objects, and binaries
were not committed.

Environment:

```text
host: Darwin 24.6.0 arm64
compiler: Apple clang 16.0.0
host Ruby: ruby 4.0.6 arm64-darwin24
Tycho lock: ruby 3.4.7p58, Bundler 2.7.2
Spinel: a4b7238e78f8 (unreleased)
```

Commands:

```sh
spinel_research_dir=$(mktemp -d /tmp/tycho-spinel-research.XXXXXX)
git clone --depth 1 https://github.com/matz/spinel.git "$spinel_research_dir/spinel"
cd "$spinel_research_dir/spinel"
git rev-parse HEAD
make deps
make -j4 all
./bin/spinel --version

cat > "$spinel_research_dir/hello.rb" <<'RUBY'
puts "hello from spinel"
RUBY

/usr/bin/time -p ./bin/spinel "$spinel_research_dir/hello.rb" \
  -o "$spinel_research_dir/hello"
file "$spinel_research_dir/hello"
stat -f '%N %z bytes' "$spinel_research_dir/hello"
otool -L "$spinel_research_dir/hello"
"$spinel_research_dir/hello"

/usr/bin/time -p ./bin/spinel --require-gate \
  -I /Users/didik/Code/personal/tycho/lib \
  /Users/didik/Code/personal/tycho/bin/tycho \
  -o "$spinel_research_dir/tycho-spinel"

/usr/bin/time -p ./bin/spinel \
  -I /Users/didik/Code/personal/tycho/lib \
  /Users/didik/Code/personal/tycho/bin/tycho \
  -o "$spinel_research_dir/tycho-spinel-no-gate"
```

`make deps` fetched Prism 1.9.0 and RBS 4.0.1 from RubyGems. `make -j4 all`
completed and produced a 4,392,120-byte arm64 compiler. The hello program
compiled in 0.56 seconds, printed the expected line, and exited successfully.
Five warm one-shot runs measured 0.01–0.02 seconds each with `/usr/bin/time`.
The 96,840-byte output had SHA-256
`adc3c06e2470ad7f12c69fdbb9ee6a9ec62d3914ac7f0e239b3c77c0c07c3c38`
and `otool -L` reported only `/usr/lib/libSystem.B.dylib`. It is one file with
no Ruby installation or adjacent application files, but it remains an arm64
macOS binary that relies on the OS system library; it is not a universal
macOS/Linux artifact.

Strict Tycho result:

```text
spinel: cannot load such file -- rbconfig (require "rbconfig")
real 0.02
```

Permissive Tycho result, after the unavailable-require warnings:

```text
spinel: .../bin/tycho:383: `ENV` cannot flow as a value (it is compile-time
modeled as a call receiver only); read ENV["KEY"] at the use site and pass the string
real 1.12
```

No artifact existed after either Tycho command. The hello size is evidence of
Spinel's value for small supported programs, not an estimate of a ported Tycho.

## Options compared

OCRAN is the one alternative worth a later experiment because its architecture
preserves a full Ruby interpreter and claims native-library support instead of
requiring an AOT port. Its current fork has a tagged 1.4.5 release with separate
arm64 macOS, x86-64 macOS, x86-64 Linux, and Windows gems, and is MIT-licensed.
It self-extracts a bundled interpreter/application at runtime, so it trades a
single download for per-platform builds, extraction behavior, a larger
artifact, code-signing/notarization work, and a new security/update pipeline.
Native Charm gems, hardlink-based process naming, subprocess workers, and
read-only packaged assets remain unproven. See the pinned
[OCRAN README](https://github.com/Largo/ocran/blob/6ea0667cb2e506a206fa06757dc583c01aab1d30/README.md)
and [release 1.4.5](https://github.com/Largo/ocran/releases/tag/1.4.5).

| Criterion | Current Homebrew bottles | Spinel | OCRAN candidate |
|---|---|---|---|
| User installation | Two commands initially; `brew upgrade tycho` or `tycho update` later | Could be one downloaded file only after a major port | Could be one platform-specific download after successful packaging |
| Portability | Published arm64 macOS, Intel macOS, x86-64 Linux bottles; Homebrew selects the match | Separate native builds for Linux x86-64/arm64 and macOS Intel/arm64; no native Windows | Separate platform/architecture artifacts; current release lacks Linux arm64 |
| Build/release complexity | Existing tested bottle and checksum workflow | New compiler pin plus dependency ports, target matrix, behavioral parity suite, and resource embedding | New interpreter/app build matrix, extraction/signing/notarization, and end-to-end packaging tests |
| Security/update story | Homebrew checksums, formula dependency updates, established `tycho update` lifecycle | Static code requires rebuilding/reissuing every target; no tagged Spinel release to pin today | Bundled interpreter/gems require Tycho rebuilds for Ruby/gem CVEs and a new trusted-download/update channel |
| Native dependencies | Proven with platform Charm gems and Ruby OpenSSL; Go is build-only | Cannot load CRuby extensions; each dependency needs a Spinel-native port/FFI design | Claims native library support but Tycho's Go-backed gems are unverified |
| Artifact size | Tycho bottle 75.5–78.9 MB plus shared Homebrew Ruby/OpenSSL dependencies | Hello is 96.8 KB; no Tycho artifact or credible estimate | Not measured for Tycho; includes CRuby, gems, and native libraries, so expect tens of MB or more |
| Maintenance | Existing Tycho/tap release ownership and repeated successful bottles | Very active, six months old, no tags/releases, compiler reports `unreleased` | Active tagged fork, but small project and an additional critical release dependency |
| Spec fit today | **Pass** | **Fail** | **Unknown; bounded experiment only** |

CosmoRuby was also considered because it ships a current one-file CRuby 4.0.6
interpreter across multiple OSes. Its official documentation says additional
native extensions cannot be loaded into the portable executable. That excludes
Tycho's three Charm extensions, so it is weaker than OCRAN for this application
and does not justify another experiment. See the
[CosmoRuby repository](https://github.com/Largo/cosmoruby) and
[current release](https://github.com/Largo/cosmoruby/releases/latest).

## Evidence that would change the decision

Reconsider Spinel only if all of the following become true:

1. Spinel publishes versioned releases with a compatibility/change policy that
   Tycho can pin and reproduce.
2. Spinel or maintained `spin` packages implement the actual APIs and behavior
   Tycho uses from Bubbletea, Bubbles, Lipgloss, Glamour, Dry CLI, YAML,
   OpenSSL/web-push, QRCode, Open3, and the remaining stdlib—not just packages
   with similar names.
3. An unmodified or narrowly adapted Tycho compiles under `--require-gate` with
   zero ignored requirements and produces no unresolved/degraded-call warnings.
4. The result passes `bin/test`-equivalent behavior plus real TUI, Remote UI,
   scheduler, update, signal, child-process, and agent-harness tests on macOS
   arm64/x86-64 and Linux arm64/x86-64.
5. Release artifacts have reproducible inputs, license notices, checksums,
   provenance/SBOM, signing where appropriate, and a documented response for
   compiler, OS-library, and embedded dependency vulnerabilities.
6. The measured install-time or disk-size improvement is large enough to
   justify owning the new compiler and compatibility layer.

The smallest next step is to keep Homebrew as the supported release mechanism
and close Fizzy #171 with this evidence. If direct-download installation becomes
a prioritized product requirement, open a separate card for a time-boxed OCRAN
experiment with explicit stop conditions: stop on any Charm extension failure,
temporary-extraction incompatibility, self-restart/worker failure, missing
target, or need to patch OCRAN before Tycho's smoke suite can run.
