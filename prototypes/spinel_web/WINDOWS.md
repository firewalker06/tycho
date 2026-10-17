# Native Windows prototype

The prototype runs as a native x64 executable on the tested Windows 11 machine
(build 26200). WSL is not used. This is one tested machine, not a general Windows
support claim. The existing Tycho application is unchanged.

## Build

The tested tools are RubyInstaller Ruby 4.0.3 and its existing MSYS2 UCRT64
Devkit, GCC 15.2.0, and Spinel commit
`3e3653a5520df0b620e9a779d116e83429ec662f`. Build in a Devkit shell with Ruby,
GCC, make, ar, curl, tar, and Git available. No runtime Ruby installation is
needed by the resulting executable.

The pinned source archive is available from
[Spinel source archive](https://codeload.github.com/matz/spinel/tar.gz/3e3653a5520df0b620e9a779d116e83429ec662f).
Its SHA-256 is
`c34b5162dc5ccb626a43fe6b7cf28e9d85e30dd5e3d5748fd59cd427bdb5115d`.
Keep the extracted compiler outside the Tycho repository.

Two upstream build problems were observed. The header generator imports a
probe helper that unconditionally requires CRuby's unavailable Windows `pty`
library. Apply `spinel-windows-build.patch` inside the extracted compiler source:

```sh
git apply /absolute/tycho/prototypes/spinel_web/spinel-windows-build.patch
make deps
make -j4 bin/spinel lib/libspinel_rt.a lib/libspinel_rt_mt.a packages/json/sp_json.o packages/json/sp_json_mt.o
```

Use those explicit targets. `make all` also builds the unused PTY package,
which fails at `ptsname` with this toolchain. The targeted build is sufficient
for this application; it does not qualify all Spinel packages. The local patch
does not provide Windows PTY support or test the probe runner.

From the Tycho source root, with Devkit GCC and ar on PATH:

```sh
ruby prototypes/spinel_web/build.rb C:/tycho-prototype/build C:/spinel/bin/spinel.exe
```

Use a build directory without spaces. The build links `windows_native.c` into
the executable through a static archive. It produces `tycho-prototype.exe`.
Copy only that executable for runtime use. The generated Ruby entry is a
Spinel input; the Windows adapter uses Spinel's FFI declarations and is not a
CRuby entry point. POSIX CRuby remains the shared behavior reference.

## Start

Create a disposable workspace. Use a new state path: the application creates
its private access list. Do not create a permissive state directory first.
Use the real `codex.exe`, not the npm `.cmd` or PowerShell wrapper. Codex must
already have authentication and its native `elevated` sandbox configured.
This prototype explicitly passes `windows.sandbox="elevated"` because it
ignores general user config. Read-only mode and approval policy `never` remain
active. Existing command rules remain active. See the
[OpenAI Windows sandbox guide](https://learn.chatgpt.com/docs/windows/windows-sandbox).

In PowerShell:

```powershell
$env:TYCHO_PROTO_STATE='C:/tycho-prototype/private-state'
$env:TYCHO_PROTO_WORKSPACE='C:/tycho-prototype/workspace'
$env:TYCHO_PROTO_EXECUTABLE='C:/absolute/path/to/codex.exe'
$env:TYCHO_PROTO_ORIGIN='https://YOUR-NODE.YOUR-TAILNET.ts.net:9443'
& 'C:/tycho-prototype/build/tycho-prototype.exe'
```

Use the same Tailscale Serve commands as the main README. Port 7483 binds only
to `127.0.0.1`. HTTPS port 9443 is private to the tailnet. Agent API access also
requires the token from the private `access-token` file. Do not enable Funnel.

The operator's test machine uses an isolated directory under the user's profile
and a manually started task named `TychoSpinelPrototype`. It runs with the
logged-in user's limited token. It has no boot or login trigger and stores no
password. To start it after sign-in:

```powershell
Start-ScheduledTask -TaskName TychoSpinelPrototype
```

To stop it, first stop any agent from the page and wait for completion. Stopping
the PowerShell task alone can leave its native server running. Stop the task
and only processes whose executable is the installed prototype:

```powershell
$root=Join-Path $env:USERPROFILE 'tycho-spinel-prototype'
Stop-ScheduledTask -TaskName TychoSpinelPrototype
Get-Process | Where-Object { $_.Path -eq "$root\build\tycho-prototype.exe" } | Stop-Process
```

To remove access, use `tailscale serve --https=9443 off`. Remove only this task
with `Unregister-ScheduledTask -TaskName TychoSpinelPrototype`. Keep private state
if the latest result is needed. This is an experimental manual launcher, not an
installer, Windows service, updater, or production supervisor.

## Platform boundary

- Ruby still owns HTTP, authentication, agent state, persistence, and UI assets.
  A small statically linked C adapter calls Windows APIs for access lists, Job
  Objects, the executable path, and Unicode command-line arguments.
- State directory creation supplies a protected access list from the start.
  It grants full access only to the current user and passes it to child files.
  Startup checks the directory and each known state file. Other users' access,
  null access lists, reparse points, and unexpected owners fail startup. An
  Administrators owner is accepted because elevated Windows processes can
  create files with that owner; the access list must still allow only the user.
  Windows administrators retain their normal ability to take ownership.
- The worker joins a Job Object before it starts Codex. The job disallows
  normal process breakaway and kills its members when the worker exits. Stop
  terminates the worker immediately; Windows has no POSIX TERM grace here.
  The worker holds the sole non-inheritable job handle. See
  [Microsoft Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects).
- Spinel's narrow Windows entry arguments lost Japanese characters on this
  host. The adapter reads the original UTF-16 command line and converts it to
  UTF-8 before passing the fixed argument list to Codex. No shell evaluates the
  prompt.
- A hard server crash can still leave the worker alive. Restart never kills a
  PID from saved state. Job tests cover ordinary child creation, not processes
  started through an unrelated broker or service. These are limits, not a full
  sandbox claim.

## Verification and limits

With the compiled binary and Devkit GCC available, run from the repository root:

```powershell
$env:TYCHO_PROTO_TEST_BINARY='C:/tycho-prototype/build/tycho-prototype.exe'
ruby test/spinel_web_windows_test.rb
```

This test runs the real executable with only System32 on its PATH. It checks
HTTP authentication and origin rejection, Unicode and quoted arguments, shell
injection resistance, credential environment removal, stdout/stderr, nonzero
exit status, concurrent-run rejection, stopping a child tree, cleanup after an
early leader exit, restart persistence, and rejection of a permissive token
access list. It copies only the executable to a path with spaces and Japanese
characters. GCC is used only to build the test fixture.

On the test host, Codex 0.160.0 with `gpt-6.1-sol` read the workspace README
through a real command and returned its heading and success marker. Chrome on
a second tailnet device verified HTTPS, wrong-token rejection, preserved draft
text during polling, desktop/mobile layout, and loss of authentication after
reload. The browser gate now requires a successful read command in the JSON
events; a success marker alone is insufficient.

The PE import table contains Windows system DLLs and UCRT API sets only. The
executable is unsigned. Windows ARM64, Windows 10, minimum OS, clean-machine
installation, denied-device tailnet policy, hard-crash supervision, and all
Spinel packages remain unqualified. Do not infer them from this result. Spinel
describes its native Windows port as community-maintained best effort in its
[pinned Windows notes](https://github.com/matz/spinel/blob/3e3653a5520df0b620e9a779d116e83429ec662f/docs/windows.md).
