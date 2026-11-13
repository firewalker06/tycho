//! Optional HTTPS gateway and fixed-target host bridge. No global Tycho changes.
use anyhow::{Result, bail, ensure};
use bytes::Bytes;
use http_body_util::{BodyExt, Full, Limited};
use hyper::body::Body as _;
use hyper::{
    Request, Response, StatusCode,
    body::Incoming,
    header::{AUTHORIZATION, CONNECTION, HOST, ORIGIN},
    service::service_fn,
};
use hyper_util::rt::TokioIo;
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayConfig, RelayMap, RelayMode, SecretKey};
use serde::Deserialize;
use std::{
    convert::Infallible,
    fs::OpenOptions,
    io::Read,
    net::SocketAddr,
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::Path,
    sync::{Arc, LazyLock},
    time::Duration,
};
use subtle::ConstantTimeEq;
use tokio::{
    net::{TcpListener, TcpStream},
    sync::Semaphore,
    time::timeout,
};
use tokio_rustls::TlsAcceptor;

const ALPN: &[u8] = b"tycho/http-gateway/1";
const BODY_LIMIT: usize = 16 * 1024 * 1024;
const RESPONSE_LIMIT: usize = 64 * 1024 * 1024;
const REQUEST_TIME: Duration = Duration::from_secs(30);
const CONNECTION_LIMIT: usize = 16;
type Body = Full<Bytes>;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    enabled: bool,
    key_file: String,
    token_file: String,
    udp_bind: SocketAddr,
    peer_id: EndpointId,
    #[serde(default)]
    peer_addr: Option<SocketAddr>,
    #[serde(default)]
    relay_url: Option<String>,
    #[serde(default)]
    allow_network: bool,
    #[serde(default)]
    target: Option<SocketAddr>,
    #[serde(default)]
    https_bind: Option<SocketAddr>,
    #[serde(default)]
    public_origin: Option<String>,
    #[serde(default)]
    tls_cert_file: Option<String>,
    #[serde(default)]
    tls_key_file: Option<String>,
}

fn private_read(path: impl AsRef<Path>) -> Result<Vec<u8>> {
    // Check the opened inode, not a separate metadata lookup that can race a replacement.
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let meta = file.metadata()?;
    ensure!(
        meta.is_file()
            && meta.uid() == unsafe { libc::geteuid() }
            && meta.permissions().mode() & 0o777 == 0o600,
        "private regular files must be owned by the current user with mode 0600"
    );
    ensure!(meta.len() <= 1024 * 1024, "configuration file is too large");
    let mut bytes = Vec::new();
    file.take(1024 * 1024 + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= 1024 * 1024,
        "configuration file is too large"
    );
    Ok(bytes)
}

fn token(bytes: Vec<u8>) -> Result<String> {
    let value = String::from_utf8(bytes)?;
    let value = value.trim_end_matches(['\r', '\n']).to_owned();
    ensure!(
        (16..=4096).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_graphic()),
        "token must contain 16 to 4096 printable non-space ASCII bytes"
    );
    Ok(value)
}

fn response(status: StatusCode, text: &'static str) -> Response<Body> {
    Response::builder()
        .status(status)
        .header("Cache-Control", "no-store")
        .header(CONNECTION, "close")
        .body(Full::new(Bytes::from_static(text.as_bytes())))
        .unwrap()
}

fn authorized<B>(req: &Request<B>, expected: &str) -> bool {
    let values: Vec<_> = req.headers().get_all(AUTHORIZATION).iter().collect();
    if values.len() != 1 {
        return false;
    }
    let value = values[0].as_bytes();
    value.len() >= 7
        && value[..7].eq_ignore_ascii_case(b"Bearer ")
        && bool::from(value[7..].ct_eq(expected.as_bytes()))
}

static PUBLIC_ASSETS: LazyLock<Vec<String>> = LazyLock::new(|| {
    serde_json::from_str(include_str!("../public_assets.json")).expect("bundled asset manifest")
});

fn public_asset<B>(req: &Request<B>) -> bool {
    req.method() == hyper::Method::GET && PUBLIC_ASSETS.iter().any(|path| path == req.uri().path())
}

fn valid_request<B>(req: &Request<B>) -> bool {
    matches!(
        req.method().as_str(),
        "GET" | "HEAD" | "POST" | "PUT" | "PATCH" | "DELETE" | "OPTIONS"
    ) && req.uri().scheme().is_none()
        && req.uri().authority().is_none()
        && req.uri().path().starts_with('/')
        && !req.uri().path().starts_with("//")
}

fn valid_origin<B>(req: &Request<B>, origin: &str) -> bool {
    let Ok(uri) = origin.parse::<hyper::Uri>() else {
        return false;
    };
    req.headers().get_all(HOST).iter().count() == 1
        && req.headers().get(HOST).and_then(|h| h.to_str().ok())
            == uri.authority().map(|a| a.as_str())
        && req.headers().get_all(ORIGIN).iter().count() <= 1
        && req
            .headers()
            .get(ORIGIN)
            .is_none_or(|h| h.as_bytes() == origin.as_bytes())
        && req
            .headers()
            .get("Sec-Fetch-Site")
            .is_none_or(|h| h.as_bytes() != b"cross-site")
}

fn strip_hop_headers(headers: &mut hyper::HeaderMap) {
    // RFC 9110: Connection can nominate additional fields to remove.
    let nominated: Vec<String> = headers
        .get_all(CONNECTION)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(',').map(|s| s.trim().to_owned()))
        .collect();
    for name in nominated {
        headers.remove(name);
    }
    for name in [
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
        "proxy-connection",
        "content-length",
    ] {
        headers.remove(name);
    }
}

async fn buffered(req: Request<Incoming>) -> Result<Request<Body>> {
    let (mut parts, body) = req.into_parts();
    let data = Limited::new(body, BODY_LIMIT)
        .collect()
        .await
        .map_err(|_| anyhow::anyhow!("body unavailable or exceeds limit"))?
        .to_bytes();
    strip_hop_headers(&mut parts.headers);
    parts.headers.insert(CONNECTION, "close".parse()?);
    Ok(Request::from_parts(parts, Full::new(data)))
}

struct AbortDriver(tokio::task::JoinHandle<()>);
impl Drop for AbortDriver {
    fn drop(&mut self) {
        self.0.abort();
    }
}

async fn exchange<T>(io: T, request: Request<Body>) -> Result<Response<Body>>
where
    T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    let (mut sender, conn) = hyper::client::conn::http1::handshake(TokioIo::new(io)).await?;
    let _driver = AbortDriver(tokio::spawn(async move {
        let _ = conn.await;
    }));
    let reply = sender.send_request(request).await?;
    let (mut parts, body) = reply.into_parts();
    let data = Limited::new(body, RESPONSE_LIMIT)
        .collect()
        .await
        .map_err(|_| anyhow::anyhow!("body unavailable or exceeds limit"))?
        .to_bytes();
    strip_hop_headers(&mut parts.headers);
    parts.headers.insert(CONNECTION, "close".parse()?);
    parts.headers.insert("cache-control", "no-store".parse()?);
    Ok(Response::from_parts(parts, Full::new(data)))
}

async fn serve<T, F, Fut>(io: T, handler: F) -> Result<()>
where
    T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
    F: Fn(Request<Incoming>) -> Fut + Send + 'static,
    Fut: std::future::Future<Output = Response<Body>> + Send,
{
    let service = service_fn(move |req| {
        let future = handler(req);
        async move { Ok::<_, Infallible>(future.await) }
    });
    hyper::server::conn::http1::Builder::new()
        .keep_alive(false)
        .max_headers(128)
        .max_buf_size(32 * 1024)
        .serve_connection(TokioIo::new(io), service)
        .await?;
    Ok(())
}

async fn endpoint(config: &Config, secret: SecretKey) -> Result<Endpoint> {
    // No default preset: no discovery, default relays, multicast, or automatic port mapping.
    let mut builder = iroh::endpoint::Builder::empty()
        .clear_ip_transports()
        .portmapper_config(iroh::endpoint::PortmapperConfig::Disabled)
        .crypto_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .bind_addr(config.udp_bind)?
        .secret_key(secret)
        .alpns(vec![ALPN.to_vec()]);
    if let Some(url) = &config.relay_url {
        ensure!(url.starts_with("https://"), "relay must use HTTPS");
        builder = builder.relay_mode(RelayMode::Custom(RelayMap::from_iter([RelayConfig::new(
            url.parse()?,
            None,
        )])));
    }
    Ok(builder.bind().await?)
}

fn validate(config: &Config, mode: &str) -> Result<()> {
    ensure!(config.enabled, "gateway support must be explicitly enabled");
    if !config.allow_network {
        ensure!(
            config.relay_url.is_none()
                && config.peer_addr.is_none_or(|addr| addr.ip().is_loopback()),
            "external peers or relays need allow_network"
        );
    }
    if let Some(url) = &config.relay_url {
        let uri: hyper::Uri = url.parse()?;
        ensure!(
            uri.scheme_str() == Some("https")
                && uri.authority().is_some()
                && uri.path() == "/"
                && uri.query().is_none()
                && !url.contains('@')
                && !url.contains('#'),
            "relay must be an HTTPS origin without credentials or query"
        );
    }

    ensure!(
        config.allow_network || config.udp_bind.ip().is_loopback(),
        "network binding needs allow_network"
    );
    if mode == "host" {
        let target = config
            .target
            .ok_or_else(|| anyhow::anyhow!("host needs target"))?;
        ensure!(
            target.ip().is_loopback() && target.port() != 0,
            "target must be a fixed loopback socket"
        );
        ensure!(
            config.https_bind.is_none()
                && config.public_origin.is_none()
                && config.tls_cert_file.is_none()
                && config.tls_key_file.is_none(),
            "host config contains gateway fields"
        );
    } else {
        ensure!(
            config.target.is_none(),
            "gateway cannot select a TCP target"
        );
        let bind = config
            .https_bind
            .ok_or_else(|| anyhow::anyhow!("gateway needs https_bind"))?;
        ensure!(
            config.allow_network || bind.ip().is_loopback(),
            "network binding needs allow_network"
        );
        let origin = config
            .public_origin
            .as_deref()
            .ok_or_else(|| anyhow::anyhow!("gateway needs public_origin"))?;
        let uri: hyper::Uri = origin.parse()?;
        ensure!(
            uri.scheme_str() == Some("https")
                && uri.authority().is_some()
                && uri.path() == "/"
                && uri.query().is_none()
                && !origin.ends_with('/')
                && !origin.contains('@'),
            "public_origin must be an HTTPS origin with no path or credentials"
        );
        ensure!(
            config.peer_addr.is_some() || config.relay_url.is_some(),
            "gateway needs an explicit peer address or relay"
        );
    }
    Ok(())
}

async fn run(config: Config, mode: &str) -> Result<()> {
    validate(&config, mode)?;
    let secret_bytes: [u8; 32] = private_read(&config.key_file)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("identity key must be 32 bytes"))?;
    let auth = Arc::new(token(private_read(&config.token_file)?)?);
    let endpoint = endpoint(&config, SecretKey::from_bytes(&secret_bytes)).await?;
    ensure!(
        endpoint.id() != config.peer_id,
        "peer must have a separate identity"
    );
    let limit = Arc::new(Semaphore::new(CONNECTION_LIMIT));
    if mode == "host" {
        let target = config.target.unwrap();
        println!("ready host {}", endpoint.id());
        loop {
            let incoming = tokio::select! { _ = tokio::signal::ctrl_c() => break, incoming = endpoint.accept() => incoming };
            let Some(incoming) = incoming else {
                break;
            };
            let Ok(permit) = limit.clone().try_acquire_owned() else {
                incoming.refuse();
                continue;
            };
            let peer = config.peer_id;
            let auth = auth.clone();
            tokio::spawn(async move {
                let _permit = permit;
                let result = timeout(REQUEST_TIME, async {
                    let conn = incoming.await?;
                    if conn.remote_id() != peer {
                        conn.close(1u8.into(), b"unauthorized peer");
                        bail!("unauthorized peer");
                    }
                    let (send, recv) = conn.accept_bi().await?;
                    let result = serve(tokio::io::join(recv, send), move |req| {
                        let auth = auth.clone();
                        async move {
                            if !public_asset(&req) && !authorized(&req, &auth) {
                                return response(StatusCode::UNAUTHORIZED, "Unauthorized");
                            }
                            if !valid_request(&req) {
                                return response(StatusCode::BAD_REQUEST, "Bad request");
                            }
                            if req.body().size_hint().lower() > BODY_LIMIT as u64 {
                                return response(
                                    StatusCode::PAYLOAD_TOO_LARGE,
                                    "Request too large",
                                );
                            }
                            match async {
                                let mut request = buffered(req).await?;
                                request
                                    .headers_mut()
                                    .insert(HOST, target.to_string().parse()?);
                                exchange(TcpStream::connect(target).await?, request).await
                            }
                            .await
                            {
                                Ok(reply) => reply,
                                Err(_) => response(StatusCode::BAD_GATEWAY, "Upstream unavailable"),
                            }
                        }
                    })
                    .await;
                    // Let QUIC acknowledge response bytes before dropping the connection.
                    let _ = timeout(Duration::from_secs(2), conn.closed()).await;
                    result
                })
                .await;
                if !matches!(result, Ok(Ok(()))) {
                    eprintln!("host connection rejected or unavailable");
                }
            });
        }
    } else {
        let cert = private_read(
            config
                .tls_cert_file
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("missing certificate"))?,
        )?;
        let key = private_read(
            config
                .tls_key_file
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("missing TLS key"))?,
        )?;
        let certs =
            rustls_pemfile::certs(&mut &cert[..]).collect::<std::result::Result<Vec<_>, _>>()?;
        let key = rustls_pemfile::private_key(&mut &key[..])?
            .ok_or_else(|| anyhow::anyhow!("missing TLS key"))?;
        let tls = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(certs, key)?;
        let acceptor = TlsAcceptor::from(Arc::new(tls));
        let listener = TcpListener::bind(config.https_bind.unwrap()).await?;
        let mut addr = EndpointAddr::new(config.peer_id);
        if let Some(socket) = config.peer_addr {
            addr = addr.with_ip_addr(socket);
        }
        if let Some(url) = &config.relay_url {
            addr = addr.with_relay_url(url.parse()?);
        }
        let origin = Arc::new(config.public_origin.unwrap());
        println!("ready gateway {}", endpoint.id());
        loop {
            let accepted = tokio::select! { _ = tokio::signal::ctrl_c() => break, next = listener.accept() => next? };
            let Ok(permit) = limit.clone().try_acquire_owned() else {
                drop(accepted);
                continue;
            };
            let (stream, _) = accepted;
            let acceptor = acceptor.clone();
            let auth = auth.clone();
            let origin = origin.clone();
            let endpoint = endpoint.clone();
            let addr = addr.clone();
            tokio::spawn(async move {
                let _permit = permit;
                let result = timeout(REQUEST_TIME, async {
                    let tls = acceptor.accept(stream).await?;
                    serve(tls, move |req| {
                        let auth = auth.clone();
                        let origin = origin.clone();
                        let endpoint = endpoint.clone();
                        let addr = addr.clone();
                        async move {
                            if !public_asset(&req) && !authorized(&req, &auth) {
                                return response(StatusCode::UNAUTHORIZED, "Unauthorized");
                            }
                            if !valid_request(&req) || !valid_origin(&req, &origin) {
                                return response(StatusCode::FORBIDDEN, "Forbidden");
                            }
                            if req.body().size_hint().lower() > BODY_LIMIT as u64 {
                                return response(
                                    StatusCode::PAYLOAD_TOO_LARGE,
                                    "Request too large",
                                );
                            }
                            match async {
                                let request = buffered(req).await?;
                                let conn =
                                    timeout(Duration::from_secs(5), endpoint.connect(addr, ALPN))
                                        .await??;
                                let (send, recv) = conn.open_bi().await?;
                                let result = exchange(tokio::io::join(recv, send), request).await;
                                conn.close(0u8.into(), b"request complete");
                                result
                            }
                            .await
                            {
                                Ok(reply) => reply,
                                Err(_) => {
                                    response(StatusCode::BAD_GATEWAY, "Transport unavailable")
                                }
                            }
                        }
                    })
                    .await
                })
                .await;
                if !matches!(result, Ok(Ok(()))) {
                    eprintln!("gateway connection rejected or unavailable");
                }
            });
        }
    }
    endpoint.close().await;
    Ok(())
}

#[tokio::main]
async fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let args: Vec<_> = std::env::args().collect();
    let result = async {
        ensure!(
            args.len() == 3,
            "usage: tycho-iroh-gateway init-key PATH | host CONFIG | gateway CONFIG"
        );
        match args[1].as_str() {
            "init-key" => {
                use std::io::Write;
                let key = SecretKey::generate();
                let mut file = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(&args[2])?;
                file.write_all(&key.to_bytes())?;
                file.sync_all()?;
                println!("{}", key.public());
                Ok(())
            }
            "host" | "gateway" => {
                let config: Config = serde_json::from_slice(&private_read(&args[2])?)?;
                run(config, &args[1]).await
            }
            _ => bail!("unsupported command"),
        }
    }
    .await;
    if result.is_err() {
        // Dependency errors can include addresses, headers, or file contents. Do not print them.
        eprintln!("Iroh gateway failed: check private configuration, credentials, and transport");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(method: &str, path: &str) -> Request<()> {
        Request::builder()
            .method(method)
            .uri(path)
            .body(())
            .unwrap()
    }

    #[test]
    fn credentials_cannot_be_ambiguous_or_inferred() {
        let mut req = request("GET", "/agents");
        assert!(!authorized(&req, "synthetic-test-token"));
        req.headers_mut().append(
            AUTHORIZATION,
            "Bearer synthetic-test-token".parse().unwrap(),
        );
        assert!(authorized(&req, "synthetic-test-token"));
        req.headers_mut().insert(
            AUTHORIZATION,
            "bearer synthetic-test-token".parse().unwrap(),
        );
        assert!(authorized(&req, "synthetic-test-token"));
        req.headers_mut()
            .append(AUTHORIZATION, "Bearer attacker".parse().unwrap());
        assert!(!authorized(&req, "synthetic-test-token"));
        assert!(token(b"\n".to_vec()).is_err());
        assert!(token(b"short".to_vec()).is_err());
        assert!(token(b"synthetic token with spaces".to_vec()).is_err());
        assert!(token(b"synthetic-test-token\n".to_vec()).is_ok());
    }

    #[test]
    fn ui_bootstrap_does_not_make_api_or_mutations_public() {
        assert!(public_asset(&request("GET", "/ui?v=1")));
        for path in [
            "/agents",
            "/setup/summary",
            "/settings",
            "/ui/../agents",
            "/ui.js/agents",
        ] {
            assert!(!public_asset(&request("GET", path)));
        }
        assert!(!public_asset(&request("POST", "/ui")));
        assert!(!valid_request(&request("CONNECT", "/agents")));
        assert!(!valid_request(&request(
            "GET",
            "https://attacker.invalid/agents"
        )));
        assert!(!valid_request(&request("GET", "//attacker.invalid/agents")));
    }

    #[test]
    fn origin_is_exact_not_a_prefix_or_wildcard() {
        let mut req = request("POST", "/agents");
        req.headers_mut()
            .insert(HOST, "gateway.example:8443".parse().unwrap());
        req.headers_mut()
            .insert(ORIGIN, "https://gateway.example:8443".parse().unwrap());
        assert!(valid_origin(&req, "https://gateway.example:8443"));
        req.headers_mut().insert(
            ORIGIN,
            "https://gateway.example:8443.attacker.invalid"
                .parse()
                .unwrap(),
        );
        assert!(!valid_origin(&req, "https://gateway.example:8443"));
        req.headers_mut().remove(ORIGIN);
        req.headers_mut()
            .insert("Sec-Fetch-Site", "cross-site".parse().unwrap());
        assert!(!valid_origin(&req, "https://gateway.example:8443"));
    }

    #[test]
    fn hop_headers_cannot_smuggle_proxy_credentials_or_framing() {
        let mut headers = hyper::HeaderMap::new();
        headers.insert(CONNECTION, "x-nominated, keep-alive".parse().unwrap());
        headers.insert("x-nominated", "secret".parse().unwrap());
        headers.insert("proxy-authorization", "secret".parse().unwrap());
        headers.insert("content-length", "42".parse().unwrap());
        headers.insert("transfer-encoding", "chunked".parse().unwrap());
        headers.insert(
            AUTHORIZATION,
            "Bearer synthetic-test-token".parse().unwrap(),
        );
        strip_hop_headers(&mut headers);
        assert_eq!(headers.len(), 1);
        assert!(headers.contains_key(AUTHORIZATION));
    }

    #[test]
    fn private_files_reject_symlinks_and_other_user_read_access() {
        let dir = std::env::temp_dir().join(format!(
            "tycho-private-test-{}",
            SecretKey::generate().public()
        ));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("token");
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&path)
            .unwrap();
        std::io::Write::write_all(&mut file, b"synthetic-test-token").unwrap();
        assert!(private_read(&path).is_ok());
        let link = dir.join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(private_read(&link).is_err());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(private_read(&path).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
