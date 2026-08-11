# service-template — DOKANDAR Golden Service Template

> The **canonical blueprint** every DOKANDAR microservice is generated from. One blueprint, **five
> runtime emitters** (Go, Java/Spring, C#/.NET 8, Python, Node/TS). Generated services are
> **production-ready, infrastructure-only — no business logic.** They consume `dkd-platform-libs`
> and realise the same capability contract regardless of runtime.

## Why a scaffolder, not one template

The platform is polyglot (ADR-011's five-language cap); each bounded context has a fixed runtime.
A single-language template cannot serve Identity (C#) *and* Finance (Java) *and* Catalog (Go)
unchanged. So this repo is a **scaffolding engine**: one canonical blueprint + a per-runtime emitter.
`new-service --lang <rt> --context <ctx>` produces a complete skeleton in that runtime.

## Generate a service

```bash
cd scaffold
python -m dkdscaffold new-service --name catalog-svc --context catalog --lang go --out ./out
python -m dkdscaffold list-capabilities      # the blueprint capability contract
python -m dkdscaffold runtimes               # installed runtime emitters
```

Every generated service automatically includes (no manual coding): standard hexagonal structure ·
config loading · dependency injection · graceful shutdown · startup validation · `/health` `/ready`
`/live` `/version` · structured logging · metrics · distributed tracing · correlation IDs · request
logging · JWT authentication · authorization · security headers · input validation · exception
handling · Kafka bootstrap · RabbitMQ bootstrap · event publisher/consumer abstractions · DB
abstraction · migrations · repository base · transaction helpers · unit + integration tests ·
testcontainers · Dockerfile · docker-compose · Helm chart · Kubernetes manifests · GitLab CI ·
**Swagger UI at `/docs`** (per the mandatory [API Documentation Standard](docs/api-documentation-standard.md)).

## API Documentation Standard

Every service exposes Swagger identically — Swagger UI at **`/docs`**, OpenAPI JSON at
**`/swagger/v1/swagger.json`** — with no per-service variation. The C# emitter generates this by
default; teams add per-endpoint metadata (WithName/Summary/Description/Tags, Accepts/Produces/
ProducesProblem) per the standard. See **[docs/api-documentation-standard.md](docs/api-documentation-standard.md)**.

See [`blueprint/blueprint.md`](blueprint/blueprint.md) for the full contract.

## Repository layout

```
scaffold/
  dkdscaffold/
    blueprint.py            # the canonical capability contract + Service model
    render.py               # Writer + naming helpers
    cli.py / __main__.py    # new-service / list-capabilities / runtimes
    runtimes/
      common.py             # shared ops files (Helm, k8s, compose, README, docs)
      go.py java.py csharp.py python.py node.py   # one emitter per runtime
  tests/                    # blueprint-conformance tests (run per runtime)
blueprint/                  # the canonical blueprint documentation
docs/                       # service-creation, coding-standards, developer, contribution guides
examples/                   # a generated sample per runtime
.gitlab-ci.yml              # scaffold tests -> generate samples -> build samples (with the real SDK)
```

## Guarantees (CI-enforced)

`scaffold:tests` proves every runtime's output realises the blueprint (all ops files present, all
four health endpoints wired, `/version` consumes the SDK, Helm probes present, **no
TODO/FIXME/placeholder**). `generate:samples` + `sample:*` build the generated services against the
real `dkd-platform-libs` v1.0.0.

Trace: ADR-011 (five-language cap), R6/R7 (events/OHS + SDK consumption), EF service-skeleton standard.
