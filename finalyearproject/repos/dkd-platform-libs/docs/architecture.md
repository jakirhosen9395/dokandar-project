# dkd-platform-libs — Architecture

## Principle: contracts in, SDKs out

```
dkd-contracts-spine@v1.0.0 (10 frozen contracts)
        │  (pinned snapshot under contracts/, SHA-256 verified on load)
        ▼
   dkdgen.contracts.load()  ──►  dkdgen.ir.Contracts   (ONE contract model)
        │
        ▼
   emitters/{python,java,go,typescript}   (one per language; identical semantics)
        │
        ▼
   sdk/{python,java,go,typescript}   (committed; CI proves committed == regenerated)
```

There is exactly **one** contract model (`dkdgen.ir`) and **one** generator. Each language emitter is
a pure function `emit(contracts, build_meta, out_dir)`; it adds no business data — it only renders the
IR into idiomatic source. This is why all four SDKs stay semantically identical and why "nothing is
manually duplicated."

## Freeze integrity = contract compatibility

`dkdgen.contracts.verify_freeze()` recomputes the SHA-256 of every contract file and compares it to
`contracts/spine.lock.yaml`. If any byte differs, generation aborts. The committed snapshot is pinned
to `dkd-contracts-spine@v1.0.0`; bumping it is a deliberate, reviewed sync (`scripts/`), never an edit.

## Generated vs Framework-only vs Blocked

The frozen contracts deliberately defer some data to Phase-2 transcription (`NEEDS-INFO`). The
generator never fabricates it. Three tiers:

| Tier | Meaning | Examples |
|---|---|---|
| **Generated** | Deterministically derived from a populated contract field | IDs, topic constants+metadata, config constants, enums, error taxonomy+builder, DTO envelope, schema-subject registry, role enums, principles |
| **Framework-only** | The structure/extension point is generated; the deferred data is a typed hole | `EventEnvelope<P>` (payload `P` unbound), `schema.get_schema()` throws "NEEDS-INFO", `error_code()` builder with an empty code catalog, security PDP without a matrix |
| **Blocked** | Cannot be generated at all without contract data that does not exist | OpenAPI REST DTOs/clients (no OpenAPI spec), gRPC stubs (no `.proto`), concrete per-event payload classes, field-level JSON-Schemas |

Every framework-only/blocked item is attributable to a specific `NEEDS-INFO` marker in the contracts
(surfaced via `Contracts.needs_info`), so the gap is the frozen architecture's deliberate deferral —
not missing implementation here.

## Determinism

Generation is deterministic: `build_time`/`build_commit` default to fixed values for committed source,
so CI can regenerate and assert a clean `git diff` (the **generator-drift gate**). The publish
pipeline overrides them to stamp live provenance onto distributed artifacts only.

## Layering (hexagonal-friendly)

The SDKs are pure published-language types and helpers — no I/O, no framework coupling, no business
logic. They sit at the edge of each service's hexagon (adapters/ports import them; the domain stays
pure). Money is `int64` poisha, time is `int64` ms UTC, IDs are typed (no raw strings) — the
fleet-wide invariants enforced at the type level.

Trace: R6 (Published Language), R7 (master-data conformance), ADR-016/021, EF §7/§8.
