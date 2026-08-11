//! APM placeholder for the skeleton: a TCP reachability probe for /health.apm.
//! Real OTLP→Elastic-APM tracing is wired in the next increment (apm_otlp).
use crate::config::Config;
use std::time::Duration;

pub fn health_check(cfg: &Config) -> (bool, String) {
    let url = if cfg.apm_server_url.is_empty() { return (false, "apm-url-empty".into()); }
              else { cfg.apm_server_url.clone() };
    let hostport = url.trim_start_matches("http://").trim_start_matches("https://");
    let hostport = hostport.split('/').next().unwrap_or(hostport);
    let (host, port) = match hostport.rsplit_once(':') {
        Some((h, p)) => (h.to_string(), p.parse::<u16>().unwrap_or(8200)),
        None => (hostport.to_string(), 8200u16),
    };
    use std::net::ToSocketAddrs;
    match (host.as_str(), port).to_socket_addrs().ok().and_then(|mut a| a.next()) {
        Some(addr) => match std::net::TcpStream::connect_timeout(&addr, Duration::from_secs(2)) {
            Ok(_) => (true, "tcp-ok".into()),
            Err(e) => (false, format!("err:{:?}", e.kind())),
        },
        None => (false, "resolve-failed".into()),
    }
}
