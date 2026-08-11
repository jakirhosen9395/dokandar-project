# DOKANDAR — OpenBao server config (docker single-node). File storage, plaintext listener (dev),
# built-in UI. setup.sh initialises + unseals the server and enables a KV v2 engine after `up`.
storage "file" {
  path = "/openbao/data"
}
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}
api_addr      = "http://127.0.0.1:8200"
ui            = true
disable_mlock = true
