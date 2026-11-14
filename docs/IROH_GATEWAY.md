# Optional Iroh HTTPS gateway (experimental)

Card 850 selects a phone browser with no installed client program. The operator
accepts a trusted HTTPS gateway that can read requests, bearer tokens, and
responses. This is not browser-to-host end-to-end confidentiality.

The optional `tycho-iroh-gateway` program has two roles:

1. On a reachable gateway server, accept browser HTTPS and forward HTTP over
   Iroh to one pinned host identity.
2. On the Tycho computer, accept only the pinned gateway identity and forward
   to one loopback Tycho API socket.

The phone uses the existing UI and normal HTTPS. It installs no helper,
application, extension, Wasm build, or VPN. Both server roles are explicit
operator-run processes. Tycho does not start them, install a service, alter
configuration, or change the existing HTTP/Tailscale defaults. No deployment
is included.

## Build and verification

Prerequisites: a source checkout, Rust 1.91 or later, Cargo, Python 3, OpenSSL,
and Tycho's normal Ruby dependencies. The helper is Unix-only. macOS arm64 has
been tested; Linux builds are not yet verified. Windows is unsupported.

```sh
cargo build --release --locked --manifest-path ext/iroh_gateway/Cargo.toml
bin/test-iroh-gateway
```

Without a selected build target or custom target directory, the release binary
is `ext/iroh_gateway/target/release/tycho-iroh-gateway`. The locked
build pins Iroh 1.4.1. The Ruby gem includes helper source but never compiles or
installs Rust dependencies automatically. Cargo fetches dependencies on the
first build; normal `bin/test` does not require Rust or contact crates.io.

`bin/test-iroh-gateway` always runs `cargo test --locked` and
`cargo build --locked` against the checked-out source before it starts the
real transport proof. It never selects an installed helper from PATH or
continues after a Cargo failure. The build uses
`--message-format=json-render-diagnostics`. The proof executable comes only
from the matching non-test binary artifact for this package manifest in that
current build output, including a fresh cached artifact. The runner requires
successful Cargo exit and build-finished messages, exactly one matching
executable, and an available executable file. It does not guess a debug path
or fall back to an old default-path file. Missing, malformed, foreign-only,
test-only, or ambiguous artifacts stop the runner before the proof.

The default persistent build cache is `ext/iroh_gateway/target`, shared with
the normal manifest build. An explicit nonempty `CARGO_TARGET_DIR` overrides
it. Relative target and capture paths resolve from the repository root,
including when the runner is started from another working directory.
Cargo validates source freshness on every run and reuses unchanged artifacts.
The runner does not delete the build cache after success or failure.

```sh
# Default cache: first run compiles; subsequent runs reuse unchanged artifacts.
bin/test-iroh-gateway
bin/test-iroh-gateway

# Explicit persistent cache, including a path with spaces.
CARGO_TARGET_DIR="path/to/cargo cache" bin/test-iroh-gateway

# Retain redacted evidence; credentials and fixture config still stay temporary.
TYCHO_REMOTE_UI_CAPTURE_DIR=path/to/evidence bin/test-iroh-gateway
```

`CARGO_BUILD_TARGET` and Cargo `build.target` configuration can place the
binary in a target-specific subdirectory. The runner prints `Cargo executable:`
with the path reported by Cargo and uses that exact path. A target must be
runnable on this computer for native tests and the proof; this is not a
cross-platform execution layer. Multiple reported helper executables are
rejected rather than guessed.

An additional offline reproduction with actual Cargo checks environment and
config target selection while an older default-path binary remains present:

```sh
ruby test/iroh/artifact_selection_proof.rb path/to/result.json
```

It uses a tiny dependency-free fixture and removes its temporary files.
Normal `bin/test` also covers these selection cases with a deterministic
Cargo-output fixture, without requiring a Rust installation.

The runner builds the debug profile. A separate `cargo build --release`
uses the release profile and can still need a first release compilation.
Changing compiler, source, flags, or target can also cause a valid rebuild.
Do not delete the target directory unless you intend a cold build.

The proof uses temporary HOME, config, logs, keys, and synthetic tokens.
All listeners use loopback. Discovery, relays, multicast, and router mapping
are off. It stops the processes and removes temporary credentials. Without
`TYCHO_REMOTE_UI_CAPTURE_DIR`, its temporary evidence directory is also
removed, including after proof failure. An explicit capture directory retains
redacted result JSON and any requested screenshots. No fixture secrets or
logs are retained in that directory.
Set `TYCHO_PLAYWRIGHT_PATH` to an existing Playwright package to add actual
Chrome checks of the current UI at desktop and phone-sized viewports. This
browser check uses a fixture certificate exception; Python independently
verifies the fixture certificate with its private CA. It does not install a
system certificate or test a public certificate.

The test uses Google Chrome's usual macOS application location. It does not
install Chrome, Playwright, or other global tools. A mobile viewport is not a
physical phone or Safari compatibility test.

## Explicit enrollment

Build first. In a private directory owned by the process user, run
`tycho-iroh-gateway init-key host.key` on the Tycho host and
`tycho-iroh-gateway init-key gateway.key` on the gateway. These commands create
new mode-0600 files exclusively. They refuse to overwrite existing files and
print only each public endpoint ID. Never copy a private identity key to the
other computer. Exchange and verify the full public IDs through a trusted
channel. Enroll exactly one identity on each side.

Prepare a strong bearer token in a private `token` file through a secure local
editor or credential provisioning tool. Use the same token for Tycho Remote
and both helpers. Tokens must have 16–4096 printable non-space ASCII bytes;
a final line ending is allowed. Do not put a token in shell arguments, an
Iroh ticket, an address, a URL, a client bundle, or logs. The user enters the
token through the existing UI token control. Its existing browser-local
storage behavior stays in use.

Each helper reads its token once at startup. To rotate a token or identity,
stop both helpers, update private files and enrollment, then restart them.
Do not reuse a gateway origin for a different Tycho identity without clearing
browser credentials and explicitly enrolling the new identity. The gateway
is a new browser origin; existing tokens do not migrate automatically.

All config, token, key, and certificate files must be regular, owned by the
current user, and mode 0600. The helper opens each with no-follow semantics
and checks its opened inode. Keep containing directories private too.
Same-user processes and root remain trusted. The helper rejects symlinks,
permissive files, empty/short tokens, unknown config fields, and disabled
configs. It never prints parsed configuration or dependency error details.
Startup failures report a generic configuration/credential/transport error.

## Practical start commands

These commands describe operator setup; they were not run against a live
service. Run from the repository root. First build the debug helper used by
the examples:

```sh
cargo build --locked --manifest-path ext/iroh_gateway/Cargo.toml
```

Create each identity on its own computer. Replace the private directory
placeholders with an existing directory owned by that process user, mode
0700. Do not store private keys or tokens in the checkout.

```sh
# On the Tycho host: prints only HOST_PUBLIC_ENDPOINT_ID.
ext/iroh_gateway/target/debug/tycho-iroh-gateway init-key path/to/private/host.key

# On the gateway computer: prints only GATEWAY_PUBLIC_ENDPOINT_ID.
ext/iroh_gateway/target/debug/tycho-iroh-gateway init-key path/to/private/gateway.key
```

The binary paths above assume no build target is selected. With an explicit
`CARGO_TARGET_DIR`, `CARGO_BUILD_TARGET`, or Cargo `build.target`, use the
executable path reported by the current Cargo build. Do not assume the
binary is directly inside `target/debug`. The test runner prints the selected
path after validating the current build. Prepare the two JSON configs below
with verified public IDs and correct private file paths. All config, token,
key, and PEM certificate files must be mode 0600. The same bearer value goes
in the host token file, gateway token file, and Tycho server environment.
Supply it with a secure editor or credential tool; do not paste it into a
command, URL, or bundle.

Start Tycho itself on loopback. This command reads the private token into
the server process environment without putting its value in arguments or
shell history. It removes only final CR/LF characters, as the helper does:

```sh
bundle exec ruby -e '
  ENV["TYCHO_REMOTE_TOKEN"] = File.read(ARGV.fetch(0)).sub(/[\r\n]+\z/, "")
  abort "Empty remote token" if ENV["TYCHO_REMOTE_TOKEN"].empty?
  exec "./bin/tycho", "serve", "--host", "127.0.0.1", "--port", "7373"
' path/to/private/token
```

The actual serve flags are `--host` and `--port`. There is no serve
`--token`, `--token-file`, or HTTPS flag. Bearer authentication comes from
`TYCHO_REMOTE_TOKEN`. An explicit host bypasses automatic Tailscale bind
selection. This command runs in the foreground and does not install a
service. The helper supplies HTTPS on the gateway; Tycho remains loopback
HTTP.

In separate terminals, start the two helper roles:

```sh
# On the Tycho host, with host.json targeting 127.0.0.1:7373.
ext/iroh_gateway/target/debug/tycho-iroh-gateway host path/to/private/host.json

# On the gateway computer, with its trusted certificate and enrolled host ID.
ext/iroh_gateway/target/debug/tycho-iroh-gateway gateway path/to/private/gateway.json
```

For two computers with an already routable direct UDP path, the minimal
configuration changes from the loopback examples are:

- Host: set `allow_network` to `true` and `udp_bind` to the chosen local
  interface IP and UDP port, or `0.0.0.0:7375`. Keep `target` loopback.
- Gateway: set `allow_network` to `true`, use its chosen local UDP bind
  (for example `0.0.0.0:7376`), and set `peer_addr` to the host's already
  reachable IP and UDP port. The gateway must not use the host's loopback IP.
- For phone access, set gateway `https_bind` to its chosen reachable
  interface, for example `0.0.0.0:8443`, and `public_origin` to its exact
  trusted HTTPS origin, including port 8443. Supply a matching browser-trusted
  PEM certificate and key. Then open that origin on the phone.

This is explicit direct-IP configuration, not a verified NAT or relay
recipe. It assumes routing, firewall permissions, DNS, and certificate
provisioning already exist. No commands here create them. Leave `relay_url`
absent for this direct path; do not claim that a public address or wildcard
bind alone makes NAT traversal work. Stop these foreground processes with
Ctrl-C. Neither a deployment nor a real remote-network test is included.

## Host configuration

The following values are placeholders. Use the actual full public peer ID
and private file locations. Paths are resolved relative to the process's
working directory; keep that directory stable, or use absolute paths in
operator-created JSON.

```json
{
  "enabled": true,
  "key_file": "host.key",
  "token_file": "token",
  "udp_bind": "127.0.0.1:7375",
  "peer_id": "GATEWAY_PUBLIC_ENDPOINT_ID",
  "target": "127.0.0.1:7373"
}
```

Run `tycho-iroh-gateway host host.json`. The target must be an explicit
nonzero loopback IP socket. Requests cannot select another target. Start the
existing Tycho server separately with loopback binding and its normal bearer
authentication. The bridge also checks the bearer, so forwarding cannot
silently expose a tokenless loopback server.

Loopback UDP works only on the same computer and is the safe proof setup.
A real remote route needs explicit network opt-in on the relevant helpers.
Set `allow_network` to `true` and choose a suitable UDP bind address. No
address lookup is enabled. Configure the gateway's `peer_addr` with the
host's known direct UDP address, or explicitly configure a suitable HTTPS
`relay_url` on both helpers. A direct address may not work through NAT.

## Gateway configuration

The gateway must have a trusted HTTPS certificate for its browser origin.
Supply the full PEM certificate chain and PEM private key. The example binds
only loopback and is not a remote phone deployment.

```json
{
  "enabled": true,
  "key_file": "gateway.key",
  "token_file": "token",
  "udp_bind": "127.0.0.1:7376",
  "peer_id": "HOST_PUBLIC_ENDPOINT_ID",
  "peer_addr": "127.0.0.1:7375",
  "https_bind": "127.0.0.1:8443",
  "public_origin": "https://localhost:8443",
  "tls_cert_file": "gateway-chain.pem",
  "tls_key_file": "gateway-tls.key"
}
```

Run `tycho-iroh-gateway gateway gateway.json`. Open the configured origin in
the browser. `public_origin` must be one exact HTTPS origin without a path,
query, embedded credentials, or trailing slash. Host and Origin checks use
that exact authority, including a nondefault port. All externally bound
sockets, non-loopback peers, and relay use need `allow_network: true`.
This opt-in does not configure DNS, certificates, firewall rules, or hosting.

For a real phone deployment, the operator must provide a reachable gateway,
DNS, a browser-trusted certificate, process supervision, updates, and access
policy. Certificate renewal requires process restart. Use a separate origin
for each Tycho host. Do not place a shared gateway token into HTML or inject
one into anonymous requests.

Only known UI bootstrap GET routes may load without a bearer, as in the
existing server. API requests need exactly one correct bearer at the gateway
and host bridge, followed by the existing Tycho API authorization. The
bridge does not alter roles, tokens, ownership generations, or receipt
semantics. It passes the original bearer; it does not replace missing or
wrong credentials.

## Access and resource limits

The helper supports HTTP/1.1, one request per connection, without upgrades,
CONNECT, proxy destination selection, HTTP/2, HTTP/3, or WebTransport.
It removes hop-by-hop headers and regenerates HTTP framing. It preserves
status, application headers, and body bytes. Public assets and API responses
use `Cache-Control: no-store` through the helper.

Each process admits at most 16 concurrent connections. Excess sockets are
closed. Total request lifetime is 30 seconds, including TLS, headers, body,
transport, and upstream work. Iroh connect has a five-second limit. Headers
are limited to 128 fields and a 32 KiB buffer. Request bodies are buffered
up to 16 MiB; responses are buffered up to 64 MiB. Bodies above those limits
fail closed. These are preview limits, not the direct Tycho API's limits.
At the maximum admitted sizes, buffering can consume about 1.25 GiB per
process; size process/container memory accordingly. Large attachments, long
operations, or sustained high concurrency should continue to use the
existing direct transport until this preview is extended.

Missing/wrong credentials return 401. Invalid origin or destination form is
rejected. Unavailable or rejected Iroh peers and a broken upstream return
502, or close when the total deadline expires. There is no fallback to a
public or direct transport and no automatic mutation replay. Use Tycho's
existing explicit retry and receipt recovery controls after an uncertain
write. A write may have completed before the connection failed.

Logs contain only readiness with a public identity and generic failure
messages. No request paths, query strings, headers, bodies, bearer tokens,
private keys, or underlying error chains are logged. `RUST_LOG` does not
enable a tracing subscriber in this program.

## Relay and operational boundary

There are no default public relays, DNS lookup, mDNS discovery, or automatic
router port mappings. Portmapper support is also absent from Cargo features.
An explicitly configured relay URL must be an HTTPS origin without a query
or credentials. Authenticated relay provisioning is not part of this preview.
The relay policy is independent of the Tycho bearer token.

A trusted HTTPS gateway is an endpoint. It can see plaintext after TLS
termination. The Iroh hop is encrypted between the gateway and host helper;
a relay on that hop cannot decrypt its payload. Relays can see connection
metadata. Public shared relays are not a production availability guarantee.
The operator must separately select and authorize production relay service.
No relay or NAT path has been verified by the loopback proof.

Iroh peer keys do not issue a phone-trusted HTTPS certificate. Browser
WebTransport is a different protocol; sharing QUIC does not make it an Iroh
client. No browser Wasm transport is part of this implementation.

The current Settings page can still show the Tycho server's internal direct
URL and direct transport facts. Keep the gateway origin in operator records;
this preview does not rewrite discovery, QR codes, or settings metadata.
Push URL handling, native app activation, multiple Tycho hosts per origin,
physical phone/Safari behavior, public HTTPS, NAT, relay availability,
Linux packaging, background mobile polling, and deployment automation remain
unverified or unsupported by this preview.

## Official references

- [Iroh endpoint builder](https://docs.rs/iroh/1.4.1/iroh/endpoint/struct.Builder.html)
- [Iroh protocols and ALPN](https://docs.iroh.computer/concepts/protocols)
- [Iroh browser limits](https://docs.iroh.computer/languages/wasm-browser.md)
- [Iroh network and router behavior](https://docs.iroh.computer/configuring-networks)
- [Iroh security and privacy](https://docs.iroh.computer/concepts/security-privacy)
- [Iroh release policy](https://docs.iroh.computer/about/release-policy)
