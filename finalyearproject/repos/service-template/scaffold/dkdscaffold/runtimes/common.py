"""
dkdscaffold.runtimes.common — language-agnostic files shared by every generated service:
Helm chart, Kubernetes manifests, docker-compose (local infra), README, docs, .env.example, VERSION.

These deploy a container exposing the service's HTTP port (health/ready/live/version) plus a metrics
port, so they are identical across runtimes. Runtime emitters add the source, Dockerfile, CI, and
dependency manifest.
"""
from __future__ import annotations
from ..blueprint import Service, CAPABILITIES


def emit_common(w, svc: Service) -> None:
    name = svc.slug
    port = svc.http_port

    w.write("VERSION", "0.1.0\n")
    w.write(".env.example",
            "# Local/dev configuration (synthetic only). See config loader for the full set.\n"
            "DKD_SERVICE_NAME=%s\nDKD_CONTEXT=%s\nDKD_HTTP_PORT=%d\nDKD_LOG_LEVEL=info\n"
            "DKD_ENV=local\nDKD_KAFKA_BROKERS=localhost:9092\nDKD_RABBITMQ_URL=amqp://guest:guest@localhost:5672/\n"
            "DKD_DB_DSN=postgres://dkd:dkd@localhost:5432/%s?sslmode=disable\n"
            "DKD_OTEL_ENDPOINT=localhost:4317\nDKD_JWT_ISSUER=https://identity.dokandar.local\n"
            % (name, svc.context, port, svc.pkg))

    # --- docker-compose: local infra a service needs (no business data) ---
    w.write("docker-compose.yml", '''services:
  %s:
    build: .
    env_file: [.env.example]
    ports: ["%d:%d", "9090:9090"]
    depends_on: [postgres, kafka, rabbitmq, otel-collector]
  postgres:
    image: postgres:17-alpine
    environment: { POSTGRES_USER: dkd, POSTGRES_PASSWORD: dkd, POSTGRES_DB: %s }
    ports: ["5432:5432"]
  kafka:
    image: redpandadata/redpanda:v24.3.6
    command: ["redpanda","start","--smp","1","--overprovisioned","--node-id","0","--kafka-addr","PLAINTEXT://0.0.0.0:9092","--advertise-kafka-addr","PLAINTEXT://localhost:9092"]
    ports: ["9092:9092"]
  rabbitmq:
    image: rabbitmq:4.0-management-alpine
    ports: ["5672:5672","15672:15672"]
  otel-collector:
    image: otel/opentelemetry-collector:0.115.0
    ports: ["4317:4317"]
''' % (name, port, port, svc.pkg))

    # --- Helm chart ---
    w.write("deploy/helm/%s/Chart.yaml" % name,
            "apiVersion: v2\nname: %s\ndescription: DOKANDAR %s service (generated)\n"
            "type: application\nversion: 0.1.0\nappVersion: \"0.1.0\"\n" % (name, svc.context))
    w.write("deploy/helm/%s/values.yaml" % name, '''replicaCount: 2
image:
  repository: registry.gitlab.com/%s/%s
  tag: "0.1.0"
  pullPolicy: IfNotPresent
service:
  port: %d
  metricsPort: 9090
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits: { cpu: 500m, memory: 512Mi }
env:
  DKD_ENV: staging
  DKD_LOG_LEVEL: info
probes:
  liveness: /live
  readiness: /ready
  startup: /health
''' % (svc.group, name, port))
    w.write("deploy/helm/%s/templates/_helpers.tpl" % name,
            '{{- define "%s.fullname" -}}\n{{ .Release.Name }}-%s\n{{- end -}}\n' % (name, name))
    w.write("deploy/helm/%s/templates/deployment.yaml" % name, '''apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "%s.fullname" . }}
  labels: { app: %s, context: %s }
spec:
  replicas: {{ .Values.replicaCount }}
  selector: { matchLabels: { app: %s } }
  template:
    metadata:
      labels: { app: %s, context: %s }
      annotations: { prometheus.io/scrape: "true", prometheus.io/port: "{{ .Values.service.metricsPort }}" }
    spec:
      containers:
        - name: %s
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - { name: http, containerPort: {{ .Values.service.port }} }
            - { name: metrics, containerPort: {{ .Values.service.metricsPort }} }
          envFrom: [{ configMapRef: { name: {{ include "%s.fullname" . }}-config } }]
          livenessProbe:  { httpGet: { path: {{ .Values.probes.liveness }},  port: http }, initialDelaySeconds: 10 }
          readinessProbe: { httpGet: { path: {{ .Values.probes.readiness }}, port: http }, initialDelaySeconds: 5 }
          startupProbe:   { httpGet: { path: {{ .Values.probes.startup }},   port: http }, failureThreshold: 30, periodSeconds: 2 }
          resources: {{ toYaml .Values.resources | nindent 12 }}
''' % (name, name, svc.context, name, name, svc.context, name, name))
    w.write("deploy/helm/%s/templates/service.yaml" % name, '''apiVersion: v1
kind: Service
metadata:
  name: {{ include "%s.fullname" . }}
  labels: { app: %s }
spec:
  selector: { app: %s }
  ports:
    - { name: http, port: {{ .Values.service.port }}, targetPort: http }
    - { name: metrics, port: {{ .Values.service.metricsPort }}, targetPort: metrics }
''' % (name, name, name))
    w.write("deploy/helm/%s/templates/configmap.yaml" % name, '''apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "%s.fullname" . }}-config
data:
  {{- range $k, $v := .Values.env }}
  {{ $k }}: {{ $v | quote }}
  {{- end }}
  DKD_SERVICE_NAME: %s
  DKD_CONTEXT: %s
  DKD_HTTP_PORT: "%d"
''' % (name, name, svc.context, port))

    # --- raw k8s manifests (kustomize-friendly) ---
    w.write("deploy/k8s/namespace.yaml",
            "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: dkd-%s\n" % svc.context)
    w.write("deploy/k8s/deployment.yaml", '''apiVersion: apps/v1
kind: Deployment
metadata: { name: %s, namespace: dkd-%s, labels: { app: %s } }
spec:
  replicas: 2
  selector: { matchLabels: { app: %s } }
  template:
    metadata: { labels: { app: %s }, annotations: { prometheus.io/scrape: "true", prometheus.io/port: "9090" } }
    spec:
      containers:
        - name: %s
          image: registry.gitlab.com/%s/%s:0.1.0
          ports: [{ name: http, containerPort: %d }, { name: metrics, containerPort: 9090 }]
          livenessProbe:  { httpGet: { path: /live,  port: http } }
          readinessProbe: { httpGet: { path: /ready, port: http } }
''' % (name, svc.context, name, name, name, name, svc.group, name, port))
    w.write("deploy/k8s/service.yaml", '''apiVersion: v1
kind: Service
metadata: { name: %s, namespace: dkd-%s }
spec:
  selector: { app: %s }
  ports: [{ name: http, port: %d, targetPort: http }, { name: metrics, port: 9090, targetPort: metrics }]
''' % (name, svc.context, name, port))

    # --- docs ---
    caps = "\n".join("- %s" % c for c in CAPABILITIES)
    w.write("README.md", '''# %s

> DOKANDAR **%s** service — generated by `dkd-scaffold` from the canonical service blueprint.
> **Infrastructure only — no business logic.** Runtime: **%s**. Consumes `dkd-platform-libs` (`%s`).

## What you get out of the box

Every generated service realises the full blueprint capability contract automatically (health/ready/
live/version, config, DI, structured logging, metrics, tracing, correlation IDs, JWT auth + authz,
Kafka + RabbitMQ bootstrap, DB abstraction + migrations + repository base + tx helpers, Docker, Helm,
k8s, GitLab CI, unit + integration tests). See `docs/architecture.md`.

## Run locally

```bash
cp .env.example .env
docker compose up --build          # service + postgres + redpanda + rabbitmq + otel-collector
curl localhost:%d/health           # 200 once dependencies are ready
```

## Endpoints

| Path | Purpose |
|---|---|
| `/health` | startup/overall health |
| `/ready` | readiness (dependencies reachable) |
| `/live` | liveness |
| `/version` | build + contract provenance |
| `/metrics` (:9090) | Prometheus metrics |

## Where to add business logic

This skeleton is infrastructure only. Implement the context's aggregates/handlers under the
`application` and `domain` layers; never edit blueprint-owned wiring. Integrate only via events / OHS
(R6). Money is `int64` poisha; IDs are typed (use the SDK).
''' % (name, svc.context, svc.runtime, svc.sdk, port))
    w.write("docs/architecture.md", '''# %s — Architecture (generated)

Hexagonal: `domain <- application <- adapters`. The domain imports nothing outward. This skeleton
ships only the **adapters/infrastructure** ring; the domain/application rings are where the owning
team adds business logic (none here).

## Capability contract (realised by this skeleton)

%s

## Cross-cutting rules (inherited from frozen canon)

- Integration is events / OHS only — no cross-context DB access (R6).
- Money is `int64` poisha; timestamps `int64` ms UTC; IDs are typed (dkd-platform-libs).
- Effectively-once: transactional outbox + consumer inbox + DLQ (wired in the messaging adapter).
- External REST is `/v1` with the `{success,data,error,meta}` envelope + RFC-7807 problem+json.
''' % (name, caps))
    w.write("docs/developer-guide.md", '''# Developer Guide — %s

- `make run` / `docker compose up` — local stack.
- Health: `/health` `/ready` `/live` `/version`; metrics on `:9090/metrics`.
- Config via environment (see `.env.example`) — 12-factor; secrets via the platform secret manager.
- Tests: unit + integration (testcontainers). CI runs them on every MR.
- Deploy: `helm upgrade --install %s deploy/helm/%s` or `kubectl apply -k deploy/k8s`.

Do not edit blueprint-owned wiring; re-scaffolding overwrites it. Add business logic in the
domain/application layers only.
''' % (name, name, name))
    w.write("CHANGELOG.md", "# Changelog\n\n## [0.1.0] - generated\n### Added\n- Service skeleton from dkd-scaffold (infrastructure only).\n")
