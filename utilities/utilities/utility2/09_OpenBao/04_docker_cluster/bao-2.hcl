# DOKANDAR — OpenBao node 2 (integrated Raft HA). All 3 nodes share one unseal key; node 1 is
# initialised, nodes 2+3 retry_join and are unsealed with the same key. cluster_addr/api_addr use the
# compose service names so inter-node Raft traffic resolves over the bridge network.
storage "raft" {
  path    = "/openbao/data"
  node_id = "bao-2"
  retry_join { leader_api_addr = "http://bao-1:8200" }
  retry_join { leader_api_addr = "http://bao-2:8200" }
  retry_join { leader_api_addr = "http://bao-3:8200" }
}
listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = true
}
api_addr      = "http://bao-2:8200"
cluster_addr  = "http://bao-2:8201"
ui            = true
disable_mlock = true
