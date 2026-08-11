# devops-dokandar-infra — BUILD LOG

## postgresql — DONE (2026-07-03)
- setup_env.sh generated 24-char password; setup.sh up → healthy in ~12s (postgres:18, dki_postgres, 0.0.0.0:15432).
- test.sh: **11/11 PASS** (DDL/DML, UTF-8 bangla, rollback, UNIQUE+CHECK rejection, pg_trgm, zero residue) → test-result.txt.
- External: from the laptop, TCP+wire-handshake to 54.169.208.246:15432 answered with a PostgreSQL auth request ('R') — service reachable off-host. Live platform untouched (dokandar_postgres on 5432 unaffected).

## redis — DONE (2026-07-03)
- redis:8, dki_redis, 0.0.0.0:16379, requirepass ON, AOF, 256mb LRU cap. test.sh **8/8 PASS** (strings/UTF-8/INCR/TTL/list/hash + wrong-password rejected + zero residue).
- External: laptop RESP handshake AUTH+PING → `+OK +PONG`.

## mongodb — DONE (2026-07-03)
- mongo:8, dki_mongo, 0.0.0.0:37017, root auth ON. test.sh **8/8 PASS** (insert/find/update/aggregate/index/UTF-8 + wrong-password rejected + dropDatabase zero residue).
- External: laptop OP_MSG ping → 38-byte wire reply.

## rabbitmq — DONE (2026-07-03)
- rabbitmq:4-management, dki_rabbitmq, AMQP 0.0.0.0:25672 + UI :25673. test.sh **6/6 PASS** via management API (declare/publish/consume round-trip incl. Bangla payload + 401 on wrong password + queue deleted).
- External: laptop `curl -u dki:*** http://54.169.208.246:25673/api/overview` → management JSON (v4.3.2).

## INCIDENT + RECOVERY (2026-07-03, 21:28 UTC) — live platform restored, no data loss
- A stack-wide container wipe (kill+destroy) hit BOTH the live dokandar_* substrate AND the dki_* utilities at 1783027738. Cause was NOT the utility composes: each declares a distinct `name:` (dki-<util>), so `docker compose up` is project-scoped and cannot touch dokandar_* (verified: no COMPOSE_* env, default context, distinct project names). Origin = an out-of-band stack reset on the infra host.
- Recovery: `cd ~/dev-infra && docker compose --env-file .env --env-file .env.secrets --profile all up -d` → substrate back; **verify.sh 17/17 pass**, **13 dkd_* databases intact** (bind mounts/volumes persisted — zero data loss), **service host 18/18 healthy** (fleet reconnected).
- Utilities re-deployed from their persisted /data/dki bind mounts (below).

# ===== v2 REBUILD — two dedicated 8GB servers, standard ports, mandatory mem caps =====
# infra-1 52.77.240.60 (observability+messaging) · infra-2 13.250.6.47 (datastores)
# Old single-host attempt retired (that box was overloaded running the live platform + duplicates).

## v2 prep — DONE (2026-07-03)
- SSH config for dokandar-infra-1/2; Docker 28.x + Compose v5.3.0 preinstalled; SG launch-wizard-1 (sg-04916e0ac3a4d32b5) had all needed ports except 9042 (added).
- All 8 existing utilities reworked: standard ports, SERVER_IP per placement, mem_limit on EVERY service, explicit JVM heaps (quoted — unquoted "-Xms -Xmx" values break bash sourcing), postgres converted to ONE-container-MANY-databases (DKD_DATABASES + idempotent provision loop in setup.sh).

## elastic-apm-stack (infra-1) — DONE, BUILT FIRST (2026-07-03)
- ES 9.2.0 (security ON, heap 512m, limit 1500m) + Kibana (1g) + APM server (300m); kibana_system one-shot bootstrap in setup.sh; anonymous APM auth explicitly disabled (RUM would silently accept unauthenticated events — caught by the wrong-token test, fixed to 401).
- test.sh **8/8 PASS** (anon 401 / authed health / UTF-8 round-trip / Kibana status / intake 401-wrong + 202-real / zero residue).
- External from laptop: Kibana http://52.77.240.60:5601 → 302 login + /api/status 200; ES :9200 → 401 (auth on); APM :8200 → 200. Host RAM after: 2.4Gi/7.6Gi used.

## infra-1 chain — kafka, rabbitmq, schema-registry, redis — ALL DONE (2026-07-03)
- kafka (KRaft, advertises 52.77.240.60:9092, heap 512m/limit 1g + ui 512m): test **6/6 PASS**; external: broker answered ApiVersions from the laptop, kafka-ui :8080 shows cluster online.
- rabbitmq (:5672/:15672, limit 512m): test **6/6 PASS** (publish/consume round-trip via mgmt API); external: authed /api/overview → v4.3.2.
- schema-registry (apicurio-mem :8081, heap 384m/limit 768m): test **5/5 PASS** (register/fetch/versions/delete artifact); external: /ui/ 200 + search API JSON.
- redis (:6379 requirepass, 256mb maxmemory/384m limit): test **8/8 PASS**; external: RESP AUTH+PING → +OK +PONG.
- Host RAM after all five utilities (incl. APM stack): **46%** — under the 75% ceiling.

## infra-2 chain — all 8 datastores — DONE (2026-07-03)
- postgresql (:5432, ONE container MANY DBs): test **11/11 PASS**. Consolidation proven twice: 3 dkd_* databases each owned by a same-named role w/ generated password (TCP login as dkd_catalog verified), THEN appended dkd_orders to DKD_DATABASES + re-ran `setup.sh up` → 4th database provisioned idempotently, container count still 1.
- mongodb (:27017): **8/8 PASS** · opensearch (:9200): **7/7 PASS** (cluster green) · clickhouse (:8123/:9004): **7/7 PASS** · timescaledb (:5433): **6/6 PASS** (hypertable + time_bucket).
- neo4j (:7474/:7687): **5/5 PASS** after fixing the test (cypher-shell plain format quotes strings — strip `"` before compare).
- rustfs (:9000/:9001): **6/6 PASS** after switching the test to `mc pipe`/`mc cat` (docker-mode mc can't see host /tmp files). Console UI lives at /rustfs/console/index.html (root path returns S3 AccessDenied XML) — READMEs updated.
- scylladb (:9042): **6/6 PASS** after dropping `--memory` 750M→350M — seastar computes its own ~500MB budget inside a container regardless of the cgroup limit (1500m verified applied) and refuses more; noted in the compose.
- External proofs from the laptop: opensearch cluster green JSON · clickhouse authed SELECT version() (24.8.14.39) · neo4j discovery JSON + Bolt handshake agreed 5.1 · rustfs /health 200 + console 200 · postgres/timescale wire auth-request ('R') on 5432/5433 · mongo wire reply · scylla CQL OPTIONS→SUPPORTED.

## FINAL STATE (2026-07-03) — v2 COMPLETE
- **13/13 utilities green** (setup.sh up healthy + test.sh PASS + external proof): infra-1 = elastic-apm-stack, kafka+ui, rabbitmq, schema-registry, redis · infra-2 = postgresql, timescaledb, mongodb, opensearch, clickhouse, neo4j, rustfs, scylladb.
- **RAM balance: infra-1 47% (3.6Gi/7.6Gi, 8 containers) · infra-2 44% (3.3Gi/7.6Gi, 8 containers)** — both under the 75% ceiling.
- Browser entry points: Kibana :5601 (infra-1) · kafka-ui :8080 · rabbitmq :15672 · apicurio :8081/ui/ · clickhouse :8123/play · neo4j :7474 · rustfs :9001/rustfs/console/index.html (infra-2).
- Deferred: kubernetes + the 3 non-docker-single variants per utility.

## mongo restart-loop RCA + fleet hardening (2026-07-03)
- **Diagnosis (idle watch confirmed a real loop):** RestartCount climbed 32→34 over 4 idle minutes, only dki_mongo affected (all other RC=0). mongod 8.2.11 died every ~60-90s with NO shutdown sequence, NO fatal line, NO kernel OOM event (`journalctl -k` clean), cgroup peak 366MB of the 1GB limit — not memory, not the healthcheck; a silent 8.2 rapid-release-train death. (Note: `.State.ExitCode/.OOMKilled` read while a container is RUNNING are meaningless — they reset on start.)
- **Fix per directive:** pinned mongo:**7.0.37** (data dir purged — FCV 8.0 data cannot downgrade; library data is throwaway, root creds re-initialized from .env), added `stop_grace_period: 30s`, healthcheck → `mongosh --quiet db.adminCommand('ping')` @ 15s/10s/5/30s, mem_limit 1g kept.
- **Verification:** test.sh **8/8 PASS** on 7.0.37; **RestartCount=0 after 5 idle minutes, healthy**.
- **Fleet rule applied to ALL 13 utilities:** exact image pins everywhere (postgres:18.4, redis:8.8.0, rabbitmq:4.3.2-management, neo4j:5.26.28-community, clickhouse:24.8.14.39, timescale:2.28.2-pg17, scylla:2025.1.14, mongo:7.0.37; kafka 4.3.0/ui v0.7.2/opensearch 2.17.1/ES 9.2.0/apicurio 2.6.5.Final/rustfs beta.8 already exact) + `stop_grace_period: 30s` on all 16 services + kafka-ui gained a real actuator healthcheck (was the only container without one).
- **Post-rollout:** all 16 containers healthy RC=0; full test sweep **13/13 PASS**; RAM infra-1 46%, infra-2 41%.

---

## v3 — FLEET ORCHESTRATOR + CANONICAL PORTS + COMBINED CREDENTIALS (2026-07-03)

**Directive:** one authoritative root `setup.sh` driving the whole fleet (target × variant ×
action, SSH fan-out, pull-all-images-first, 5s cooldowns, canonical port map, combined
public-IP credentials report). Deployment moved to SINGLE-MACHINE mode on a fresh 8GB box
`52.77.234.48` (both INFRA1_HOST and INFRA2_HOST point at it; the old 2-server pair was left
untouched). Modeled on the reference orchestrator at gitlab.com/learningdevopstools/utilities
(fetched; kept its framed output, pull-spam collapse, per-tool creds formatter, port
preflight).

**What was built**
- Root `setup.sh` (~600 lines): targets all/infra1/infra2/local/<utility> (auto-routed),
  actions up/down/purge/status/creds/restart/logs/test, flexible any-order args + long flags,
  SSH fan-out with recursion guard (UTIL_LOCAL=1), auto repo shipping (rsync, tar fallback —
  remote `.env` never clobbered/leaked: `--exclude .env` both ways), PHASE-0 pull-all-first,
  per-tool frames + per-server summary + fleet roll-up (##FLEET## machine line), combined
  creds grouped by server on PUBLIC IPs, --mask, RAM guardrail, canonical-port preflight that
  fails naming both offenders.
- Canonical port map baked into every .env.example: ONLY functional change was
  **opensearch 9200→9201** (9200 belongs to elastic-apm ES; transport 9301/9300/9180 reserved,
  not published). All other v2 ports already canonical.
- Per-utility contract extended: `restart` verb added to all 13, `logs` made non-follow
  (orchestrator must not hang), SERVER_IP autofill in every setup_env.sh (IMDSv2 →
  ifconfig.me → local), kafka KAFKA_CLUSTER_ID+EXTERNAL_HOST generation moved into
  setup_env.sh (pre-first-up `status` used to die on `:?` compose interpolation — found by
  the first canary run), stale hard-IP fallbacks removed from all utility setup.sh.

**Proof (all from the laptop, single command each)**
- `bash setup.sh all up`   → preflight OK ("all host ports match the canonical map"), RAM
  guardrail warned as designed (7.6 GiB host), images ready 13/13 pulled BEFORE any boot,
  then 13 OK · 0 FAILED · total 4m56s; roll-up exit 0.
- `bash setup.sh all creds --mask` → all 13 blocks on public IP 52.77.234.48, postgres block
  lists per-DKD database URLs (one container, many DBs).
- `bash setup.sh all status` → 16/16 containers healthy on exact pins, RC=0 everywhere.
- `bash setup.sh all test`  → **13/13 PASS · 1m35s** (every test: throwaway objects, zero
  residue). RAM peak during tests 80%.
- External proof from the laptop: Kibana 200, ES 401(auth on), APM 200, kafka-ui cluster
  online JSON, apicurio 200, rabbit mgmt 200, opensearch GREEN on **9201**, clickhouse Ok.,
  neo4j discovery + Bolt 5.1 handshake, rustfs health+console 200, PG/TSDB SCRAM-SHA-256
  auth-request on 5432/5433, redis -NOAUTH, kafka ApiVersions, scylla CQL SUPPORTED,
  AMQP server hello — every canonical public port answers off-host.
- `bash setup.sh all down` → 13 OK, 0 containers left, /data/dki data PRESERVED (mongo 301M,
  neo4j 517M, pg 85M …). Fleet then re-upped (--no-pull) and left LIVE.

**Notes**
- Single 8GB box carries the whole fleet at ~75-80% RAM warm — acceptable for the lab ONLY
  because every service is mem_limit-capped (the v1 lesson); the guardrail refuses <6 GiB.
- Old two-server layout is one edit away: point INFRA1_HOST/INFRA2_HOST at two IPs again.

### v3.1 — endpoints switched to PRIVATE (VPC) IP (2026-07-03)
User call: printed endpoints must use the machine's private IP, not public. Default endpoint
resolution is now EC2 metadata local-ipv4 → hostname -I (ifconfig.me public fallback removed);
control no longer injects the SSH IP into legs; `--public-host <ip>` remains the explicit
opt-in for off-VPC URLs. All 13 setup_env.sh autofills switched; live .envs migrated
(SERVER_IP=172.31.45.156), kafka re-advertised PLAINTEXT_HOST://172.31.45.156:9092 (container
recreated) and its contract test re-PASSED. `all creds` on-box: every endpoint private.
