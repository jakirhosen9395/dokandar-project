# SDK Guide

All four SDKs expose the same modules with idiomatic names. Money is `int64` poisha; time is `int64`
ms UTC; IDs are typed (no raw strings).

## Install / consume

| Language | Consume |
|---|---|
| Python | `pip install ./sdk/python` → `import dkd_platform` |
| Go | `import "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"` (module in `sdk/go`) |
| TypeScript | `npm install ./sdk/typescript` → `import { ... } from "@dokandar/platform-sdk"` |
| Java | `mvn -f sdk/java install` → `com.dokandar.platform.*` |

## Modules

- **ids** — `DID`, `PPID`, `GPID`, `ORD`, `TRD`, `WLT`, `ESC`, `TXN`, `SHP`, `NTF`, `MFSA` (prefix-validated), `Money`, `Timestamp`.
- **topics** — `KafkaTopics.*` constants (59) + `TOPIC_META` (producer, ordering key, consumers) + `RabbitQueues.*` (10).
- **config** — `COOLING_OFF_WINDOW`, `ESCROW_ABANDON_TTL`, `NIL_ROLLUP_MAX_LAG`, `B2B_DELIVERY_MIN_LEAD`, `MONEY_CUSTODY_RPO`.
- **enums** — `KycTiers (V0–V3)`, `OversightRoles`, `EnforcementActions`, fraud detectors/states, party actor codes, units.
- **errors** — `error_code(context, category, reason)` builder, `ContextSlug`, `ProblemDetails`, `DokandarError`/`ValidationError`/`BusinessError`/`InfrastructureError`.
- **dto** — `Response{success,data,error,meta}`, `Page`, `Meta`, `TraceMetadata`, `AuditMetadata`.
- **events** — `EventHeaders`, `EventMetadata`, `EventEnvelope<P>`, `PayloadSerializer` (payload `P` is contract-populated in Phase 2).
- **schema** — `SUBJECTS` (59), `Compatibility.BACKWARD`, `subject_for(topic)`, `is_compatible(new, old)`; `get_schema()` throws until schemas are populated.
- **security** — role enums, `PRINCIPLES`, `JwtClaims`, `CorrelationContext`.
- **validation** — id / money / topic / envelope validators.

## Example (Python)

```python
from dkd_platform.ids import DID
from dkd_platform.money import Money
from dkd_platform.topics import KafkaTopics, TOPIC_META
from dkd_platform.errors import error_code

did = DID("did:dokandar:0190a8f2-...")          # typed, prefix-validated
price = Money.of_bdt(250)                        # 25000 poisha
topic = KafkaTopics.CUSTODY_PASSPORT_CUSTODY_INITIALIZED_V1
key = TOPIC_META[topic].key                      # "PPID" (ordering key)
code = error_code("finance", "idempotency", "duplicate_key")
```

## Framework-only surfaces (by frozen-contract design)

`EventEnvelope` is generic over its payload, `schema.get_schema()` raises until JSON-Schemas are
published, and the error **code catalog** is empty (the *builder* is provided). These are extension
points for the Phase-2 contract population — they are intentionally unpopulated, not missing.
