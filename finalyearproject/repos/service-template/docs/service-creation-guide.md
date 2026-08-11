# Service Creation Guide

How to create a new DOKANDAR microservice from the golden template.

## 1. Generate

```bash
cd scaffold
python -m dkdscaffold new-service \
  --name catalog-svc \
  --context catalog \
  --lang go \            # omit to default from the context's frozen runtime
  --out ../../dkd-catalog
```

`--context` must be one of the 13 bounded contexts. `--lang` is one of `go|java|csharp|python|node`;
if omitted it defaults to the context's frozen runtime (e.g. `finance` → `java`, `identity` → `csharp`).

## 2. What you get

A complete, buildable skeleton realising the full [blueprint](../blueprint/blueprint.md): HTTP health
endpoints, observability, security, messaging + persistence abstractions, Docker/Helm/k8s/CI, and
unit + integration tests. It already consumes `dkd-platform-libs` and starts cleanly.

## 3. Add business logic (the only manual step)

- Implement the context's aggregates/use-cases under the **domain** and **application** layers.
- Wire concrete drivers at the documented injection points (Kafka/RabbitMQ publisher+consumer, DB).
- Integrate with other contexts **only via events / OHS** (R6) using the SDK's topic constants — never
  a cross-context DB call.
- Never edit blueprint-owned wiring; re-scaffolding overwrites it.

## 4. Ship

Push to the context's repo (`dkd-<context>[-svc]`), open an MR, and let CI build/test. Deploy with
`helm upgrade --install` or `kubectl apply -k deploy/k8s`.

## Rules

- No business rule is invented in code (P2) — thresholds/tiers/fees come from the BA via the contracts.
- Money is `int64` poisha; IDs are typed; timestamps `int64` ms UTC.
- Conservative-tier contexts (Finance/Custody/Fraud/Gov) require four-eyes + signed commits.
