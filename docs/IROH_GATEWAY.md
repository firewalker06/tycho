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

The binary is `ext/iroh_gateway/target/release/tycho-iroh-gateway`. The locked
build pins Iroh 1.4.1. The Ruby gem includes helper source but never compiles or
installs Rust dependencies automatically. Cargo fetches dependencies on the
first build; normal `bin/test` does not require Rust or contact crates.io.

`bin/test-iroh-gateway` runs native policy tests, builds the program, then runs
a real HTTPS/Iroh/Tycho proof with temporary HOME, config, logs, keys, and
synthetic tokens. All listeners use loopback. Discovery, relays, multicast,
and router mapping are off. It stops the processes and removes temporary
credentials. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to retain redacted result JSON.
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
