---
id: enum-registry-doc-of-record
title: DOKANDAR Enum & Actor-Code Registry — FR-IDN-310 doc-of-record
layer: L2
taxonomy: T7            # contracts (Published Language)
doc_class: contracts
owner: identity-kyc      # FR-IDN-310 master-data steward (R7); governed with the spine board
classification: Internal
status: In-Review
version: 0.1.0
trace:
  - FR-IDN-310   # the machine-readable, semver-tagged glossary & enum registry all services import
  - NFR-MNT-040  # enum/actor-code change is breaking → registry version bump + migration note
  - R7           # Identity/Catalog master-data backbone; no local forks
  - R6           # Published Language; consumed as a versioned artifact
  - ADR-018      # FR-IDN-310 glossary/enum registry authority (per std-document-contract)
  - ADR-021      # this prose doc-of-record governs the (Phase-2) machine artifact
last_verified:
  date: 2026-06-28
  source_commit: PENDING
supersedes: None
superseded_by: None
references:
  - DOKANDAR-Architecture.md §12 glossary intro (FR-IDN-310, NFR-MNT-040)
  - DOKANDAR-Domain-Model.md (type conventions; ID prefixes; status enums)
  - dkd-platform-docs/standards/document-contract.md (domain terms owned by FR-IDN-310)
---

## Purpose

The **doc-of-record for the FR-IDN-310 enum & actor-code registry**: the single, semver-tagged,
machine-readable source from which **every service imports actor codes, status enums, and unit
definitions** (and the Bangla↔English domain bridge), so no service hardcodes a divergent value
(R7). This prose doc governs the registry's purpose, governance, and lifecycle; the **machine
artifact carrying the actual values** is produced under it (Phase 2). It **transcribes no values
that are not verbatim in canon** — unconfirmed values are **NEEDS-INFO**.

## Scope

**Covers (canonical for):**

1. The registry's **role** as the single source for enums, actor codes, and units.
2. The **Bangla↔English domain bridge** requirement.
3. The **semver + enum-change-is-breaking** governance (NFR-MNT-040).
4. **Where the values come from** (canon-sourced) and what is NEEDS-INFO.

**Does NOT cover (owned elsewhere — referenced by ID, never restated):**

- The **verbatim enum/actor/unit values** → BA canon (actor table, FR-* sections) + DM type
  conventions; transcribed into the machine artifact **only verbatim** (Phase 2; NEEDS-INFO here).
- The **money/timestamp/ID type rules** → DM type conventions (`int64` poisha, UUIDv7, ms-UTC).
- The **document-contract glossary mechanics** → `std-document-contract`.

### S-1. Role — the single source (R7)

FR-IDN-310 is the **normative registry** that all 13 contexts conform to: actor codes, status
enums, and unit definitions live here and are **imported, never forked** (R7; no local divergent
value). It is consumed as a **versioned Published-Language artifact** (R6), never as shared source.

### S-2. Bangla↔English domain bridge

The registry carries the **bilingual domain bridge** — canonical English keys mapped to Bangla
display terms (and synonym normalization, e.g. Catalog's versioned lexicon, FR-PRD-007) — so one
canonical key drives Bangla-first UX (R8) without forking identifiers. Exact bridge entries are
canon-sourced (BA/DM) and **NEEDS-INFO** until transcribed verbatim.

### S-3. Versioning & change discipline (NFR-MNT-040)

- The registry is **semver-tagged**.
- **Any enum or actor-code change is a BREAKING change** requiring a **registry version bump + a
  migration note** (NFR-MNT-040). Additive, backward-compatible value additions still bump the
  registry version and ship a migration note.
- Consumers pin a registry version; a major bump is coordinated through the spine board (R6).

### S-4. Value provenance — canon-sourced, not invented

The machine artifact's values are **transcribed verbatim from BA/DM**, never authored here. Enum
**families evidenced in BA** (names confirmed verbatim in canon; **values are illustrative of the
families, not the exhaustive set**) include: **KYC tiers** `V0/V1/V2/V3` (FR-IDN-005, BA §KYC tiers);
**actor/principal codes** (BA actor table — e.g. FARIA, WHOLESALER, RETAIL, GOV, plus PERSON/ORG
principals); **fraud detectors** (BA §fraud dashboard — HOARDING, PASSPORT_FORGERY, GHOST_SPLIT,
MFS_STRUCTURING, SUBSIDY_DUP, CIRCULAR_TRADE, VELOCITY_ANOMALY, GEO_IMPOSSIBLE, COLLUSION_RING);
**FraudCase states** (OPEN→INVESTIGATING→{SUBSTANTIATED→ENFORCED|DISMISSED}); **enforcement actions**
(WARN, RESTRICT_LISTING, SUSPEND, BLACKLIST, LICENSE_REVOKE); **oversight roles** (ANALYST,
INVESTIGATOR, ENFORCEMENT_OFFICER, APPROVER, SUPER_ADMIN); and **commodity units** (e.g. seer/maund/
bosta). The **complete, authoritative value lists, codes, and Bangla bridge entries are NEEDS-INFO**
and must be transcribed verbatim from BA/DM into the Phase-2 machine artifact — never fabricated.

## References

BA §12 (FR-IDN-310, NFR-MNT-040), BA actor table + FR-IDN-005 + fraud/oversight FR sections; DM type
conventions; `std-document-contract`; ADR-018; ADR-021.

## Traceability

Realizes **FR-IDN-310** (the machine-readable semver registry) and **NFR-MNT-040** (enum-change =
breaking + version bump + migration note); upholds **R7** (no local forks of master-data
identifiers) and **R6** (consumed as a versioned artifact). Governed as a machine artifact under
**ADR-021** with this prose doc-of-record.

## Glossary

- **enum registry** — the FR-IDN-310 single source for enums/actor-codes/units (gloss; canonical = BA §12).
- **actor code** — a canonical principal/role identifier (e.g. FARIA, GOV) imported, never forked (R7).
- **domain bridge** — the Bangla↔English canonical-key mapping (gloss; S-2).
- **breaking change** — an enum/actor-code change forcing a registry version bump (gloss; NFR-MNT-040).

Domain terms (poisha, custody, escrow, KYC tier, seer/maund/bosta) are defined ONLY in this registry
and the DM type conventions — referenced by key, never redefined elsewhere.

## Assumptions

- The Phase-2 machine artifact (`enum-registry.yaml`/`.json`) is generated under this doc-of-record.
- BA/DM contain the authoritative verbatim values to transcribe (they do; not all are in scope here).
- ADR-018 establishes FR-IDN-310 as the glossary/enum authority (per `std-document-contract`).

## Constraints

- **No value fabricated** — values are transcribed verbatim from BA/DM; otherwise NEEDS-INFO.
- **No local forks** of any actor code, enum, or unit (R7).
- **Enum change ⇒ version bump + migration note** (NFR-MNT-040); consumers pin a version.
- **Bangla-first bridge** for every display term (R8) without forking the canonical key.

## ADRs

Bound by **ADR-018** (FR-IDN-310 authority), **ADR-021** (machine-artifact + owning doc), and the
**R6/R7** Published-Language rules. A change to the registry's governance is an ADR event.

## Open Questions

- **OQ-enum-1:** the **exhaustive enum/actor/unit value lists, codes, and Bangla bridge entries** are
  **NEEDS-INFO** — to be transcribed verbatim from BA/DM into the machine artifact (Phase 2), never
  authored here.
- **OQ-enum-2:** the canonical unit set (seer/maund/bosta and SI base units) and their conversion
  factors must be confirmed verbatim against DM before encoding — **NEEDS-INFO**.

## Risks

- **R-enum-1:** transcribing a wrong value would corrupt every consumer (R7). Mitigation:
  verbatim-only + NEEDS-INFO; cross-language test-vector parity in CI (Phase 2).
- **R-enum-2:** a silent local fork of an actor code. Mitigation: import-only (R7) + the
  no-duplicate-convention canary.

## Future

- The Phase-2 `enum-registry` machine artifact (semver-tagged) generated under this doc.
- A cross-language import-conformance gate proving no service hardcodes a divergent value.

## Revision History

| Version | Date | Author | Change |
|---|---|---|---|
| 0.1.0 | 2026-06-28 | identity-kyc | Initial FR-IDN-310 doc-of-record; purpose/governance/semver; values left NEEDS-INFO (verbatim transcription pending). |

## Quality Checklist

- [x] All 15 §15.2.1 sections present and ordered.
- [x] Purpose/governance/semver + enum-change-is-breaking stated by reference (FR-IDN-310/NFR-MNT-040).
- [x] No enum value fabricated; exhaustive lists marked NEEDS-INFO.
- [ ] Trace anchors resolve in `id-map.yaml` — **deferred** (Wave B).
- [ ] Two distinct cross-team approvers (identity-kyc + spine board/ARB) — **pending**.

## Approval

Pending. Contracts/Published-Language doc; requires two named approvers from different teams
(identity-kyc steward + event-spine board or ARB delegate) per EF §15.2.3 / §17.4. Author may not
self-approve.

## Version

0.1.0 (In-Review).
