# Migration Guide

How consumers move between platform-libs versions. Because every SDK is generated from a versioned
contract baseline, migrations are predictable.

## When the contracts release a new version

1. Read the `dkd-contracts-spine` CHANGELOG for the target version.
2. Bump your platform-libs dependency to the matching SemVer.
3. Recompile against the new SDK; the type system surfaces breaking changes:
   - **New `.vN` topic** (breaking event change) → a new topic constant appears; the old `.v(N-1)`
     remains (dual-publish window). Migrate consumers, then drop the old.
   - **Populated `NEEDS-INFO`** (MINOR) → previously framework-only surfaces gain concrete types
     (event payloads, JSON-Schemas, error codes). These are **additive** — existing code keeps working;
     opt in to the new types.

## Framework-only → populated (Phase-2 contract fill)

Today these are extension points; when the contracts populate them they become real types **without
breaking** existing usage:

| Surface | Today | After contract population |
|---|---|---|
| `EventEnvelope<P>` | generic payload | concrete payload classes per topic |
| `schema.get_schema()` | throws NEEDS-INFO | returns the JSON-Schema |
| error code catalog | builder only | enumerated codes |
| OpenAPI/gRPC clients | absent | generated clients |

## Stability guarantees

- Published topic/ID/error-code **names never change** (EF immutable-names rule). Renames = new major.
- Money stays `int64` poisha, time `int64` ms — these are frozen invariants and will not change.
