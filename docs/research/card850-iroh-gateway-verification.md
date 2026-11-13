# Card 850 Iroh gateway verification

## Accepted scope

The operator selected phone browser access with no installed client program,
then accepted an HTTPS gateway that can read requests and bearer tokens.
The earlier desktop-client design and simulated transport proof are superseded.
The implementation is an optional server-side program. It does not claim
browser-to-host end-to-end confidentiality or deploy any gateway.

- [Card 850](https://fizzy.startkit.tech/1/cards/850)
- [Accepted gateway decision](https://fizzy.startkit.tech/1/cards/850/comments/03h89wfpa4vvt7yx62n4nu3pu)
- [Configuration and boundaries](../IROH_GATEWAY.md)

Beta was clean with this task as its only active agent. Main updated by
fast-forward from a41dff6 to 2dfcc0a before the fresh implementation branch.
Alpha and Charlie were not changed.

## Dependency findings

The crates.io HTTP API returned 403. The official sparse index and crate
archive were reachable. Iroh 1.4.1 declares Rust 1.91; installed Rust 1.92
built the locked native helper. Dependencies came from Cargo, without a
global tool installation or cloned upstream repository.

The first real fixture failed before readiness. Iroh's empty builder has no
crypto provider, even when a rustls default provider exists. The fix supplies
Ring explicitly. The empty builder, precise IP binding, absent portmapper
feature, explicit disabled portmapper setting, and absent discovery/relay
configuration keep the acceptance proof on loopback.

## Actual local evidence

The native policy suite checks ambiguous bearer credentials, UI/API public
route separation, exact origins, proxy/header framing removal, and private
file permissions/symlink rejection. Clippy with warnings denied and rustfmt
checks cover the helper.

The Python acceptance fixture uses the actual helper binary, HTTPS, real
Iroh QUIC/TLS over loopback UDP, and the existing Ruby RemoteServer. It uses
separate persistent fixture identities for host, gateway, and an unenrolled
peer. There are no real projects, agents, provider credentials, or provider
calls. Temporary HOME/config/logs and fake harness executables isolate Tycho.

The proof covers:

- API rejection without a bearer and with a wrong bearer; authorized reads.
- Public UI bootstrap without embedded credentials.
- Unauthorized writes; oversized declared bodies; wrong Host and Origin.
- Rejected CONNECT and unenrolled Iroh peer.
- Host rejection when gateway and host bearer files differ.
- Exact PNG bytes and synthetic Unicode/NUL/line-ending JSON error behavior.
- Closed failure after the upstream and Iroh endpoint stop, without a direct
  fallback or anonymous credential injection.
- Explicit enable/network gates, private file modes, symlink rejection,
  and no bearer in helper/server logs.

With an existing local Playwright package, Chrome 157 loads the current UI
through the HTTPS/Iroh path at desktop and 390-by-844 phone-sized viewports.
The browser checks both missing-token rejection and an authorized API call,
waits for the boot screen to close, checks horizontal overflow, and captures
the loaded UI. The screenshots were visually inspected. The empty fixture
shows the existing onboarding screen; it does not create an agent or project.

The browser uses a fixture-only certificate exception. Python independently
verifies HTTPS with the fixture CA; neither path changes system certificate
trust. All processes stop and temporary private keys, bearer files, config,
and logs are removed. Only redacted results and screenshots are retained
outside the repository. The full runner is `bin/test-iroh-gateway`.

## Exact limits

This is a preview of the optional gateway, not a production deployment.
No public listener, public certificate, physical phone, Safari, NAT, relay,
Linux build, push notification, native activation, or mobile background
polling path is verified. It does not add browser Wasm or WebTransport.

The gateway trusts one enrolled host; the host trusts one gateway. No relay
or lookup is selected by default. External sockets, peers, and an explicit
HTTPS relay need network opt-in. Relay credentials/provisioning are outside
scope. The fixed loopback target and gateway origin are configuration-owned;
requests cannot choose new destinations.

The implementation buffers bounded bodies and closes each HTTP connection
after one request. Limits are 16 admitted connections, 30 seconds total,
5 seconds for Iroh connect, 128 headers, 32 KiB header buffer, 16 MiB request,
and 64 MiB response. Full buffers can require about 1.25 GiB per process.
Large/long requests may fail; uncertain writes retain normal Tycho receipt
recovery semantics and are never retried automatically by the helper.
Internal Settings/QR/notification metadata is not rewritten for the gateway.

The required `bin/test` attestation belongs to the exact published PR head.
The draft PR remains for parent independent review before ready; no merge or
deployment is part of this work.
