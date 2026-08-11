# identity-svc — Architecture (generated)

Hexagonal: `domain <- application <- adapters`. The domain imports nothing outward. This skeleton
ships only the **adapters/infrastructure** ring; the domain/application rings are where the owning
team adds business logic (none here).

## Capability contract (realised by this skeleton)

- standard-structure
- config-loading
- dependency-injection
- graceful-shutdown
- startup-validation
- http-health
- http-readiness
- http-liveness
- http-version
- structured-logging
- metrics
- distributed-tracing
- correlation-ids
- request-logging
- jwt-authentication
- authorization
- security-headers
- input-validation
- exception-handling
- kafka-bootstrap
- rabbitmq-bootstrap
- event-publisher
- event-consumer
- db-abstraction
- migrations
- repository-base
- transaction-helpers
- unit-tests
- integration-tests
- testcontainers
- dockerfile
- docker-compose
- helm-chart
- k8s-manifests
- gitlab-ci

## Cross-cutting rules (inherited from frozen canon)

- Integration is events / OHS only — no cross-context DB access (R6).
- Money is `int64` poisha; timestamps `int64` ms UTC; IDs are typed (dkd-platform-libs).
- Effectively-once: transactional outbox + consumer inbox + DLQ (wired in the messaging adapter).
- External REST is `/v1` with the `{success,data,error,meta}` envelope + RFC-7807 problem+json.
