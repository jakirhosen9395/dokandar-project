# The Canonical Service Blueprint

This is the single architecture every generated DOKANDAR service realises, regardless of runtime.
Runtime emitters differ only where the target language/framework requires. **Infrastructure only —
no business logic, ever, in the template or its output.**

## Architecture

- **Hexagonal**: `domain ← application ← adapters`. The skeleton ships only the adapters/infra ring;
  the owning team adds domain/application logic (none here).
- **Consumes `dkd-platform-libs`** for IDs, topics, the `{success,data,error,meta}` envelope, error
  taxonomy, config constants, and provenance — never hand-rolled.
- **Integration via events/OHS only** (R6); money is `int64` poisha; IDs are typed.

## Capability contract

| Group | Capabilities |
|---|---|
| **Project** | standard hexagonal structure · config loading · dependency injection · version management |
| **Runtime** | application bootstrap · startup validation · graceful shutdown |
| **HTTP** | `/health` · `/ready` · `/live` · `/version` |
| **Observability** | structured logging · metrics (Prometheus `/metrics`) · distributed tracing (OTel/W3C traceparent) · correlation IDs · request logging |
| **Security** | JWT authentication · authorization (RBAC + PDP seam) · security headers · input validation · exception handling → RFC-7807 |
| **Messaging** | Kafka bootstrap · RabbitMQ bootstrap · event publisher abstraction · event consumer abstraction *(no business events)* |
| **Persistence** | DB abstraction · migrations · repository base · transaction helpers *(no business repositories)* |
| **Testing** | unit tests · integration tests · testcontainers |
| **Deployment** | Dockerfile · docker-compose · Helm chart · Kubernetes manifests · GitLab CI |

## Runtime mapping (frozen contexts)

| Context | Runtime | Context | Runtime |
|---|---|---|---|
| Identity | C#/.NET | Catalog/Custody/Provenance/Inventory/Logistics/Platform | Go |
| Finance/B2B | Java/Spring | B2C + BFFs | Node/TS |
| Government | C#/.NET | Fraud/Analytics | Python |

## Non-negotiables

- No business logic, no invented business rules (P2) anywhere in the template or generated output.
- Abstractions for messaging/persistence are real infrastructure; the concrete driver is an
  explicit injection point — not a placeholder.
- Re-scaffolding overwrites only blueprint-owned files; business code in domain/application is safe.
