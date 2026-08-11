# DOKANDAR — Engineering Foundation
### The Engineering Constitution for Implementation (Phase EF)

| Field | Value |
|-------|-------|
| Document | Engineering Foundation — standards & engineering governance (planning only) |
| System | DOKANDAR — National Digital Commerce Infrastructure (Bangladesh) |
| Governs | Implementation of DOKANDAR-Service-Architecture.md (ARB-PASS) on DOKANDAR-Architecture.md v1.0 (FROZEN), per Engineering-Execution-Roadmap.md |
| Scope | 60 engineering standards in 21 chapters. No code, IaC, manifests, Dockerfiles, OpenAPI, protobuf, SQL, or infra diagrams. |
| Status | **v1.0 (FROZEN)** — read-only; changes require a formal ADR |
| Version | 1.0 | Date | 2026-06-26 |

> Phase EF precedes System Architecture. This is a new governing artifact; it realizes the frozen architecture and never amends it. Every standard is justified and traces to BA/SA/ADR/R/Roadmap.

## Table of Contents

1. Introduction, Scope, Traceability & Engineering Principles
2. Repository Strategy & Structure
3. Git Branching & Collaboration Workflow
4. Release, Versioning & Artifacts
5. Coding & Language Standards
6. Shared Library & Internal SDK Strategy
7. API Design Standards (REST & gRPC)
8. Event Design Standards
9. Logging, Observability, Metrics & Tracing Standards
10. Configuration, Secrets & Feature Flags
11. Environment & Local Development Standards
12. Testing Strategy
13. Static Analysis & Dependency Management
14. CI/CD Standards
15. ADR Process & Documentation Standards
16. Review Process, Architecture Governance & Quality Gates
17. Definition of Ready, Definition of Done & Engineering Checklists
18. Team Responsibilities & Ownership Rules
19. Migration, Backward Compatibility & Deprecation
20. Technical Debt, Incident Response & Operational Readiness
21. Recommended Build Order

---

## 1. Introduction, Scope, Traceability & Engineering Principles

> **Document:** DOKANDAR Engineering-Foundation.md — the engineering constitution that implementation teams build against.
> **Status:** Binding. Chapter 1 is the governing front-matter for all subsequent chapters.

### 1.0 Front-Matter

| Field | Statement |
|---|---|
| **Purpose** | Translate the four frozen architecture documents into binding, enforceable engineering standards so that 13 context teams across five languages build one coherent, correct, sovereign commerce OS. |
| **Scope (IN)** | Cross-cutting engineering standards: principles, repository/runtime conventions, API/event contracts discipline, idempotency, observability, security posture, testing/release/incident gates, build order. Applies to every context (#1–#13), EDGE, and SPINE. |
| **Scope (OUT)** | Business rules (owned by BA), service decomposition (owned by SA), and any modification to ADR-001..012 or R1–R8. This document **realizes**; it never **amends**. |
| **References** | DOKANDAR-Architecture.md v1.0 (BA: 13 contexts, ADR-001..012, R1–R8, FR-*, BR-001..040); DOKANDAR-Service-Architecture.md (SA: 27 chapters incl. Ch.27 remediations, ARB-PASS); Engineering Execution Roadmap (12 phases). |
| **Glossary** | Canonical terms (custody, escrow saga, OHS, Published Language, poisha, park-and-freeze, fencing, RPO) are defined once in the BA/SA. This document points to those definitions and does not redefine them; a consolidated engineering glossary appears as an appendix and never overrides source definitions. |
| **Assumptions** | Sovereign landing zone exists before any service (Roadmap Phase 1); polyglot is capped at five governed languages (ADR-011); event-spine is the sole inter-context transport (R6). |
| **Constraints** | Standards-only — no business-rule invention; money is integer poisha; five-language cap; never-same-team separations (§17.4) are inviolable. |
| **Revision history** | v1.0 — initial constitution baseline, aligned to ARB-PASS and Ch.27 remediations. Changes require Architecture Review Board (ARB) approval and a traceability delta. |

### 1.1 Purpose & Scope — the Engineering Constitution

**Rule.** Every implementation decision MUST be reducible to a clause in this document, and every clause MUST trace upward to the BA/SA/ADR/R/FR/Roadmap. Where this document is silent, teams escalate to the ARB rather than improvising a local convention.

**WHY.** A nation-scale system spanning custody ledgers, escrow, KYC, and government read models cannot tolerate per-team interpretation of cross-cutting concerns. Drift in idempotency, event naming, or money representation is not a style issue — it corrupts financial and custody invariants (R1, R2) irreversibly. A single binding constitution converts 13 independent teams into one system with predictable seams.

**Alternatives compared and rejected.**

| Option | Description | Verdict |
|---|---|---|
| Per-team READMEs only | Each context documents its own conventions | **Rejected** — guarantees divergence at OHS/spine boundaries (R6/R7); no enforceable cross-team contract. |
| Tooling-enforced lint only, no prose constitution | Encode rules purely in CI checks | **Rejected** — checks can verify shape but cannot carry *intent/WHY*; new edge cases have no adjudication authority. |
| **Constitution + traceability + enforcement (chosen)** | Binding prose standards, each traced and each backed by an enforcement mechanism | **Chosen** — combines human-adjudicable intent with machine-enforceable gates; survives team turnover. |

### 1.2 Relationship to the Four Frozen Documents

**Rule.** The four documents form a strict authority hierarchy. This Foundation sits *below* and *realizes* them.

```text
DOKANDAR-Architecture.md (BA)        ─ WHAT the business is; never modified here
   └─ Service-Architecture.md (SA)   ─ HOW it decomposes into services; frozen, ARB-PASS
        └─ Execution Roadmap         ─ WHEN/ORDER it is built; 12 phases
             └─ Engineering-Foundation.md  ─ THE STANDARDS by which it is built (this doc)
                  └─ Implementation  ─ code/config/infra (governed by this doc)
```

**WHY.** Direction of dependency must be one-way. If engineering standards could amend the BA, the business contract would be defined by implementation convenience — exactly the failure mode ADR governance exists to prevent. Freezing BA/SA and forcing this document to *cite rather than create* keeps business intent stable while engineering evolves beneath it.

**Conflict resolution rule.** On any contradiction, precedence is **BA > SA > Roadmap > Foundation**. A Foundation clause that conflicts with a higher document is void on discovery and raised to the ARB as a defect in this document, never as a deviation in the higher one.

### 1.3 Core Engineering Principles

These six principles are the lens for every later chapter. Each is binding, each carries a WHY, and each names how it is enforced (mechanism detailed in later chapters).

#### P1 — Correctness > Speed

**Rule.** When delivery speed conflicts with correctness of custody, money, or audit state, correctness wins; the feature ships later, never wrong.
**WHY.** Custody (R1) is event-sourced and the sole writer; Finance (R2) demands exactly-once. A fast-but-wrong write to these stores is unrecoverable and legally consequential. Velocity is recoverable; a corrupted ledger is not.
**Rejected alternative:** "ship-then-reconcile" for money paths — rejected because reconciliation cannot reconstruct intent lost to a non-idempotent double-write; it only detects damage after the fact.

#### P2 — Governance > Convenience

**Rule.** Governed constraints — five-language cap (ADR-011), never-same-team separations (§17.4), four-eyes (R4), gov read-mostly (R5) — override any local "easier if we just…" shortcut.
**WHY.** A sixth language or a Finance/operational team merge optimizes one team's week at the cost of system-wide auditability and segregation of duties. Convenience is local; governance protects the whole.
**Rejected alternative:** case-by-case exceptions granted by individual teams — rejected; exceptions are an ARB power only, recorded as ADR deltas.

#### P3 — Database-per-Service (no shared store)

**Rule.** Each context owns its data store exclusively; no cross-store reads/writes (R6); cross-context data flows only via gRPC OHS calls (R7) or the event-spine Published Language.
**WHY.** Shared databases couple deployment, schema evolution, and failure domains — fatal for Finance isolation (R2) and Catalog⟂Custody separation. Db-per-service makes the team boundary the data boundary.
**Rejected alternative:** shared read replicas "for reporting" — rejected; Analytics (#12) consumes the audit-sink/Published Language, never another context's tables, preserving Fraud⟂Analytics and isolation guarantees.

#### P4 — Event-Driven Integration

**Rule.** Inter-context state propagation uses the event-spine with the canonical topic grammar `<context>.<aggregate>.<Event>.vN`, schema-registry backward-compatibility within a major version, per-aggregate ordering keys (PPID/WLT/TXN), transactional OUTBOX → consumer INBOX, per-topic DLQ, and retry-with-backoff.
**WHY.** Synchronous cross-context coupling would make 13 teams' availability multiplicative; event-driven integration decouples liveness and gives an append-only audit spine (R6) for free.
**Rejected alternatives:** synchronous orchestration across contexts (rejected — cascading failure, tight coupling); dual-write without outbox (rejected — split-brain between DB and broker). The OUTBOX+INBOX pattern is the only one that keeps the local commit and the event atomic.

#### P5 — Idempotency by Default

**Rule.** Every unsafe, money, or custody write carries an `idempotency-key`; consumers deduplicate via the INBOX; poison messages are handled by per-key park-and-freeze (Ch.27.5), never silent drop.
**WHY.** At-least-once delivery is the only realistic broker guarantee at scale; without idempotency, retries become double-spends. Defaulting to idempotent makes the safe path the easy path.
**Rejected alternative:** exactly-once transport "solving" the problem — rejected as a distributed-systems myth across heterogeneous stores; we engineer exactly-once *effects* (R2) via idempotent consumers, not exactly-once *delivery*.

#### P6 — Trace Everything

**Rule.** Every request and event carries OpenTelemetry context end-to-end; money and custody paths have the strictest SLOs and full-fidelity tracing; no service ships without traces, structured logs, and SLO instrumentation.
**WHY.** With offline-first/USSD/SMS/IVR parity (R8) and 13-team event chains, a failure may surface three contexts away from its cause. Without correlation, incident response (Ch.27.7) is guesswork. Observability is a release gate, not an afterthought.
**Rejected alternative:** log-only observability — rejected; logs without trace correlation cannot reconstruct a cross-context saga (R3) timeline.

### 1.4 Traceability Principle

**Rule.** Every standard in this document MUST carry a *trace anchor* to its source authority, and every implementation artifact (service, contract, pipeline) MUST cite the Foundation clause it satisfies. Traceability is bidirectional and auditable.

```text
BR-### / FR-### / ADR-0##/ R# / Ch.## / Roadmap-Phase-#
        ↓ realized by
Foundation §clause  ──cited by──→  service / contract / test / runbook
```

**WHY.** Sovereign and regulated operation (Identity/KYC #1, Government #11, Finance #8) requires demonstrating *why* every control exists, to auditors who do not read code. An untraceable standard is unenforceable and unjustifiable; an uncited implementation is unverifiable. Traceability turns "we think we comply" into "here is the chain."

**Rejected alternative:** documentation-by-convention without explicit anchors — rejected because it cannot survive audit, team turnover, or the ARB change process; anchors are mandatory, not decorative.

### 1.5 Reading Guide

| If you are… | Read first | Then |
|---|---|---|
| A context-team engineer (#1–#13) | §1.3 principles, repo/runtime & API/event chapters | Your context's language standard + OHS contract chapters |
| Platform / SRE | §1.3 (P3, P4, P6), observability, release, incident chapters | Build-order & ORR chapters |
| Security / Risk | §1.3 (P1, P2), security posture, four-eyes (R4), KMS/HSM chapters | Ch.27 remediation mappings |
| Finance / Provenance Core | P1, P3, P5 + isolation (R2) and custody (R1) chapters | Saga (R3), exactly-once, reconciliation chapters |
| ARB / VP Eng | This chapter end-to-end | Traceability appendix and conflict-resolution rule (§1.2) |

**Convention for the remainder of this document.** Each chapter states the **Rule**, the **WHY**, **alternatives compared and rejected** where genuine choices exist, and a **trace anchor**. Folder-structure trees and commit/branch naming patterns appear as illustrative `text` only; no executable code, configuration, or infrastructure artifacts appear anywhere — this is a standards-and-planning document by hard constraint, and that constraint is itself Principle P2 in action.

---

## 2. Repository Strategy & Structure

This chapter sets the binding standard for how DOKANDAR source code is partitioned into repositories, how each service tree is laid out, and how repositories are named. Every rule traces to the Service Architecture ownership model (§17), the binding rules (R1, R2, R6, R7), ADR-011 (polyglot cap), and the Roadmap build order. Repository strategy is not a cosmetic choice: it is the first physical enforcement layer for context isolation, team autonomy, and the "never-same-team" separation-of-duties constraints in §17.4. Get this wrong and no downstream control (CI gating, secret scoping, blast-radius containment) can fully recover.

### 2.1 Repository Strategy (Roadmap-item 1)

**Rule R-REPO-1 — One repository owns exactly one bounded context's deployable code; ownership is single and team-aligned.** No repository may contain code owned by two different teams. The repository is the unit of ownership, the unit of CI policy, the unit of secret scope, and the unit of CODEOWNERS authority.

**WHY.** §17 assigns each of the 13 contexts to exactly one team, and §17.4 declares hard separation pairs (Finance ⟂ all; Fraud ⟂ Analytics; Catalog ⟂ Custody; Government ⟂ operational/Platform; B2C ⟂ B2B). A repository is the strongest, cheapest, most auditable boundary we have: it scopes merge rights, branch protection, deploy keys, and signing identities. If two separated contexts share a repo, a single compromised CI token or an over-broad CODEOWNERS rule silently re-couples them. Aligning the repository boundary to the team/context boundary makes the separation physical rather than aspirational.

**Rule R-REPO-2 — Repository granularity is per-context, not per-microservice and not per-team-monolith.** A context that decomposes into several deployables (e.g., Finance command service + reconciler) keeps them in its context repository unless a binding rule forces a split (see R-REPO-5).

**WHY.** Per-microservice repos (one repo per deployable) would multiply DOKANDAR's ~20+ services into a sprawl of tiny repos with duplicated CI, fractured history, and cross-repo refactors for a single context change — high coordination cost for the Provenance Core team that owns three tightly-coupled contexts (#3/#4/#5). Per-team-monolith repos would re-couple separated contexts inside one team and erase the context boundary the BA froze. Per-context is the altitude that matches the BA's own unit of design.

### 2.2 Monorepo vs Polyrepo (Roadmap-item 2)

We evaluated three estate models against the 5-language, 13-context, never-same-team reality.

| Model | Description | Verdict |
|-------|-------------|---------|
| **Single monorepo** | All 13 contexts + edge + spine in one repo, one history, one CI graph | **Rejected** |
| **Pure polyrepo (per-microservice)** | Every deployable its own repo, no shared platform repo | **Rejected** |
| **Governed multi-repo-by-context + shared platform repo, Finance isolated (R2)** | One repo per context, owned by its team; cross-cutting platform code in a dedicated `dkd-platform-*` repo published as versioned libraries; Finance in its own hard-isolated repo | **CHOSEN** |

**Why single monorepo is rejected.** A monorepo offers atomic cross-context refactors and one dependency graph, but it directly contradicts §17.4. Branch protection and CODEOWNERS can *approximate* in-repo separation, but they are advisory and bypassable by repo admins and CI service accounts; a monorepo gives every CI pipeline ambient read access to *all* source, including Finance and Government code. R2 demands Finance have no shared substrate; R5 makes Government read-mostly and organizationally separated; a shared repo gives a Commerce engineer's leaked token line-of-sight to Finance ledgers. The polyglot estate (ADR-011: Go/Java/C#/Python/Node-TS) also defeats monorepo tooling economics — no single build tool (Bazel notwithstanding) spans all five cleanly without heavy investment that the Roadmap does not budget. Blast radius of a bad merge spans the nation-scale platform.

**Why pure polyrepo is rejected.** Per-microservice polyrepo maximizes isolation but pays for it with rampant duplication of the envelope (`{success,data,error,meta}`), problem+json error mapping, idempotency-key handling, outbox/inbox plumbing (SA conventions), and OpenTelemetry/SLO instrumentation across 20+ repos. That violates DRY at the worst possible layer — the money/custody correctness layer — and guarantees implementation drift where R1/R2/R6 demand uniformity. It also fragments the Published Language (R6) into copy-pasted schema clients.

**Why governed multi-repo-by-context + shared platform repo is chosen.** It places the repository boundary exactly on the context/team boundary (satisfying §17 and §17.4 physically), while a small set of `dkd-platform-*` repositories owned by Platform/Substrate publish the cross-cutting concerns as **versioned, consumed libraries** — never as shared source pulled into other repos. Contexts depend on *published artifacts* with semantic versions, not on each other's trees, preserving DRY without re-coupling. This mirrors the runtime architecture: independent deployables, shared Published Language, no shared store (R6).

**Rule R-REPO-3 — Finance (#8) lives in a hard-isolated repository with its own CODEOWNERS, deploy identity, secret scope, and CI runners; it consumes platform libraries only as pinned, signed artifacts.** It may not share build infrastructure with any operational context.

**WHY.** R2 mandates Finance no-shared-DB and exactly-once with a separate repo/reconciler; §17.4 makes Finance ⟂ all. The repository is where "separate repo" becomes literal. Pinned, signed artifact consumption (not source sharing) keeps Finance dependent on platform contracts without granting platform CI write-reach into Finance.

**Rule R-REPO-4 — The event-spine Published Language (schemas/contracts) lives in its own contract repository owned by the Event-Spine Enabling team; it is the single OHS upstream for event and gRPC contracts.** Consumers depend on its versioned releases only.

**WHY.** R6 (Published Language, append-only audit OHS, no cross-store) and R7 (Identity+Catalog master-data OHS) require one authoritative, backward-compatible-within-major source of truth for contracts. Co-locating schemas in each consumer repo would fork the language. A dedicated contract repo with schema-registry-backed compatibility checks enforces the "backward-compatible within major version" SA rule at PR time.

**Rule R-REPO-5 — A context repository may split into multiple repos ONLY when a binding rule forces a separation of duties, never for convenience.** Forced splits: Finance command vs reconciler (R2 exactly-once independence); Fraud's enforcement plane kept apart from any Analytics tooling (§17.4 Fraud ⟂ Analytics, even though both touch #10/#12 boundaries).

**WHY.** Splitting for convenience multiplies cross-repo change cost; splitting for a binding rule converts a compliance constraint into an un-bypassable structural fact.

### 2.3 Repository Map (traceable to §17)

| Repository | Context(s) | Team | Runtime | Trace |
|------------|-----------|------|---------|-------|
| `dkd-identity-kyc` | #1 | Substrate | C#/.NET | R7, build order |
| `dkd-catalog` | #2 | Substrate | Go | R7, Catalog⟂Custody |
| `dkd-custody-ledger` | #3 | Provenance Core | Go | R1 sole writer |
| `dkd-provenance-graph` | #4 | Provenance Core | Go | recall |
| `dkd-inventory-nil` | #5 | Provenance Core | Go | — |
| `dkd-b2c` | #6 | Commerce | Node/TS | B2C⟂B2B |
| `dkd-b2b` | #7 | Exchange | Java/Spring | B2C⟂B2B |
| `dkd-finance` (isolated) | #8 | Finance | Java/Spring | **R2, §17.4 Finance⟂all** |
| `dkd-logistics` | #9 | Logistics | Go | — |
| `dkd-fraud` | #10 | Risk&Enforcement | Python+Go | Fraud⟂Analytics |
| `dkd-government` | #11 | Government | C#/.NET | R5, Gov⟂Platform |
| `dkd-analytics` | #12 | Substrate | Python | Fraud⟂Analytics |
| `dkd-platform-*` (set) | #13 + shared libs | Substrate/Platform | Go + per-lang SDKs | shared platform repo |
| `dkd-contracts-spine` | spine PL | Event-Spine Enabling | schema | R6 |
| `dkd-edge-gateway`, `dkd-bff-*` | EDGE | Platform / owning channel team | Go, Node/TS | gateway+BFFs |

### 2.4 Standard Folder Structure (Roadmap-item 3)

**Rule R-REPO-6 — Every service repository follows the same top-level skeleton, regardless of language, with language-idiomatic internals beneath.** The shape is fixed; the implementation layout inside `src`/module roots follows each language's convention.

**WHY.** A uniform top level lets any engineer, auditor, or platform tool locate contracts, deployment descriptors, runbooks, and tests in seconds across all five languages — essential for SRE on-call spanning unfamiliar contexts and for ORR/ARB audits (Ch.27.6/27.7). Forcing internal layout to be identical across Go and Java would fight each ecosystem's tooling and is rejected; standardizing only the boundary captures the value without the friction.

Illustrative top-level tree (text, not code):

```text
dkd-<context>-<service>/
  README.md                # purpose, owning team, on-call, build order pos
  CODEOWNERS               # team-scoped, §17 alignment
  /contracts               # consumed PL refs (pinned), service's own API spec refs
  /src (or module root)    # domain / app / adapters — hexagonal layering
    /domain                # aggregates, invariants (R1 custody, money=poisha)
    /application           # use-cases, sagas (R3 escrow), idempotency handling
    /adapters
      /inbound             # api, event-consumer (INBOX), USSD/SMS/IVR (R8)
      /outbound            # persistence, event-producer (OUTBOX), gRPC clients
  /platform                # thin wiring over dkd-platform-* libs (no forks)
  /deploy                  # deployment descriptors (declarative, env-agnostic)
  /test
    /unit  /integration  /contract  /chaos   # Ch.27.6
  /ops
    /runbooks              # incident + backup/restore (Ch.27.7)
    /slo                   # SLO definitions (money/custody strictest)
  /docs/adr                # service-local decisions tracing to global ADRs
```

**WHY the `/contracts`, `/ops`, and `/test/contract` placement.** Contracts are first-class because R6/R7 make the Published Language the integration substrate; surfacing it at top level makes cross-context coupling reviewable. `/ops/runbooks` and `/ops/slo` are in-repo (not a separate wiki) so they version with the code and are enforceable ORR gates (Ch.27.7). `/test/contract` and `/test/chaos` are mandatory directories so CI can assert their presence (Ch.27.6 chaos, schema-registry contract tests).

### 2.5 Repository Naming Convention (Roadmap-item 4)

**Rule R-REPO-7 — Repository names follow `dkd-<context>-<service>` in lowercase kebab-case; single-service contexts may collapse to `dkd-<context>`.** Reserved prefixes: `dkd-platform-*` (shared libraries), `dkd-bff-*` (channel BFFs), `dkd-contracts-*` (Published Language), `dkd-infra-*` (landing-zone/SRE, Platform team only).

| Element | Rule | Example |
|---------|------|---------|
| Org prefix | always `dkd-` | `dkd-` |
| Context | BA context slug | `finance`, `custody`, `catalog` |
| Service | role within context (optional if single) | `reconciler`, `command` |
| Case | lowercase kebab-case only | `dkd-finance-reconciler` |

**WHY a mandatory prefix and fixed order.** `dkd-` namespaces DOKANDAR repos against vendor/fork clutter and makes org-wide tooling globs deterministic (e.g., `dkd-platform-*` for library publishers, `dkd-bff-*` for edge). Context-before-service ordering groups a context's repos lexicographically, so `dkd-finance` and `dkd-finance-reconciler` sort adjacently — aiding the R2 audit that Finance's split is intact. Kebab-case is chosen over snake_case or camelCase because it is the cross-platform-safe, URL-clean convention every Git host and CI system handles identically across our five languages; mixed case invites case-sensitivity bugs on differing filesystems and is rejected. Embedding team names in repo names is rejected: teams can be reorganized, but the BA contexts are frozen — naming to the stable axis (context) keeps names durable while CODEOWNERS carries the mutable team mapping.

**Rule R-REPO-8 — The repository name is immutable once the context enters the build order; renames require an ADR.** This protects the dependency, CI, and artifact-coordinate references that accrue across the 12-phase Roadmap.

**WHY.** Renames break artifact coordinates, pinned platform-library references, and audit trails. Given the sovereign-landing-zone → spine → Identity/Catalog → … build order, every later phase pins earlier repos by name; treating names as immutable infrastructure preserves that chain.

---

## 3. Git Branching & Collaboration Workflow

This chapter sets the binding source-control law for all 13 contexts, the EDGE tier, and the event-spine. It realizes the Service Architecture's CD posture (SA §25.6 conservative tier for Finance/Custody), the polyglot cap (ADR-011), the four-eyes mandate (R4), Finance isolation (R2), Custody sole-writer integrity (R1), and the Roadmap build order. Version control is the first enforcement surface for these invariants: a rule that is not gated in Git is a rule that will eventually be violated.

### 3.1 Repository Topology (precondition for branching)

Branching policy is meaningless without the repo boundaries it operates on. We mandate **polyrepo, one repository per deployable service**, not a monorepo.

| Option | Verdict | WHY |
|---|---|---|
| Monorepo (all 13 contexts) | **Rejected** | Violates NEVER-SAME-TEAM (§17.4) at the access-control layer — a single repo cannot grant Finance⟂all or Government⟂Platform separation without brittle path-based ACLs. Defeats R2 (Finance separate repo/reconciler). Couples CI blast radius across teams. |
| Polyrepo, one repo per service | **Chosen** | Maps cleanly to team ownership, per-service pipelines (SA §25.6), and the conservative-tier carve-out. CODEOWNERS and branch protection become per-context, not per-path. Finance and Custody repos get their own signing and review law without leaking it onto Commerce. |

Finance owns two physically separate repos (ledger-of-record and the independent reconciler) to honor R2's no-shared-fate and exactly-once separation. Custody (#3) is a single repo whose sole-writer guarantee (R1) is reinforced by the strictest protection profile below.

### 3.2 Item 5 — Branch Strategy

**Rule:** **Trunk-based development** is the standard for all repos, with a two-tier release discipline: a **Standard tier** (short-lived branches, continuous delivery) and a **Conservative tier** (Finance #8, Custody #3, Fraud #10, Government #11) layering release branches and stronger gates on top of the same trunk model.

**WHY trunk-based:** It minimizes integration latency, keeps branches measured in hours-to-days, and is the only model that natively supports per-service continuous delivery (SA §25.6). Long-lived divergent branches are the primary source of merge-conflict defects and "works on my branch" integration failures at nation scale.

**Alternatives compared and rejected:**

| Model | Verdict | WHY |
|---|---|---|
| GitFlow (`develop`+`release`+`feature`+`hotfix`+`master`) | **Rejected** | Five long-lived branch classes create chronic merge debt and delay integration feedback. Designed for shrink-wrapped, infrequent releases — the opposite of our CD goal. The `develop`/`master` split duplicates truth and routinely drifts. |
| GitHub-flow (branch off `main`, PR, deploy) | **Partially adopted** | Excellent for the Standard tier, but lacks a release-branch concept. Finance and Custody require a pinned, auditable release line that can receive cherry-picked fixes without absorbing unreviewed trunk progress. Adopted as the Standard-tier baseline; insufficient alone. |
| Trunk-based + release branches | **Chosen** | Keeps a single source of truth (`main`) and short-lived branches for fast integration, while giving the conservative tier an immutable, regulator-defensible release line. Satisfies both CD and the Finance/Custody caution mandate. |

**Branch taxonomy (all tiers):**

| Branch | Lifetime | Purpose |
|---|---|---|
| `main` | permanent, protected | Single integration trunk; always releasable. |
| `feat/<ticket>-<slug>` | < 3 days | Feature work; rebased on `main` before merge. |
| `fix/<ticket>-<slug>` | < 2 days | Bug fix. |
| `release/v<major>.<minor>` | Conservative tier only | Pinned release line; receives only cherry-picked, re-reviewed fixes. |
| `hotfix/<ticket>` | hours | Emergency fix; merges to `main` and active release branch. |

**Standard:** feature/fix branches that exceed their lifetime ceiling are flagged stale by automation and must be rebased or closed. **WHY:** the ceiling is the enforcement mechanism for trunk-based discipline — without it the model silently degrades into GitFlow.

### 3.3 Item 6 — Platform & Workflow (Protected Branches, Signed Commits)

**Rule:** `main` (and any `release/*`) is a **protected branch** in every repo. Direct pushes are forbidden; all change arrives by reviewed, green PR. Linear history is enforced (see §3.5).

**Protected-branch profile (two tiers):**

| Control | Standard tier | Conservative tier (Finance/Custody/Fraud/Gov) |
|---|---|---|
| Direct push to `main` | Blocked | Blocked |
| Force-push / branch deletion | Blocked | Blocked |
| Required approvals | ≥ 1 CODEOWNER | ≥ 2, spanning four-eyes separation (R4) |
| Required status checks | Build, unit, lint, SAST | + integration, contract, SBOM, exactly-once/replay suite |
| Signed commits (GPG/Sigstore) | Recommended | **Mandatory, every commit** |
| Admin bypass | Disabled | Disabled (no exceptions, including org admins) |
| Stale-approval dismissal on new push | On | On |

**WHY signed commits for the conservative tier:** Finance (money, R2), Custody (sole-writer ledger, R1), Fraud (four-eyes, R4), and Government (regulator-facing, R5) produce changes whose authorship must be cryptographically attributable for audit and incident reconstruction (Ch.27.7). An unsigned commit on the ledger-of-record repo is unprovable provenance — unacceptable for the system of record that backs poisha-denominated balances.

**Signing mechanism — compared:**

| Option | Verdict | WHY |
|---|---|---|
| No signing (trust the platform identity) | **Rejected** | Platform account compromise yields untraceable, forgeable authorship. Fails Ch.27.7 incident-attribution needs. |
| GPG per-developer keys | **Accepted (baseline)** | Mature, widely tooled, verifiable offline. Key custody overhead is acceptable for the bounded conservative-tier teams. |
| Sigstore/keyless (OIDC-backed) | **Accepted (preferred where available)** | Removes long-lived key custody by binding signatures to short-lived OIDC identities — aligns with our OAuth2/OIDC posture and KMS-managed secret philosophy (Ch.27.8). |

Signing keys are governed under the same KMS/HSM rotation cadences as runtime secrets (Ch.27.8); an expired or revoked key invalidates the commit at the gate.

### 3.4 Item 7 — Pull Request Rules

**Rule:** Every change merges via PR that is **small, owned, reviewed, and green**. CODEOWNERS encodes team ownership; required checks encode the SA conventions; four-eyes is structurally enforced for money/custody/fraud repos.

**PR size standard:**

| Metric | Target | Hard ceiling |
|---|---|---|
| Changed lines (net) | ≤ 400 | 800 (requires written justification + extra reviewer) |
| Files touched | ≤ 20 | — |
| Logical concern | exactly one | — |

**WHY size limits:** Review defect-detection rate collapses past ~400 changed lines; large PRs receive rubber-stamp approvals, which is intolerable on a system carrying custody and money invariants. The ceiling mirrors the 800-line file rule from the coding-style canon so the same cohesion discipline governs both files and changesets.

**CODEOWNERS — by team, honoring NEVER-SAME-TEAM (§17.4):**

- Each repo's CODEOWNERS maps directories to the **owning team only** (e.g. Finance repo → Finance team).
- Cross-context contract/schema directories (Published Language under R6, master-data OHS under R7) require **co-ownership by both producer and the spine/Substrate steward**, so no single team can unilaterally break a backward-compatibility guarantee.
- A reviewer may **never** satisfy a required-approval slot for a context their team is forbidden to co-own (Finance⟂all; Fraud⟂Analytics; Catalog⟂Custody; Government⟂operational/Platform; B2C⟂B2B). This is enforced by CODEOWNERS team membership, not by convention.

**Four-eyes for money/custody/fraud (R4):** PRs in Finance, Custody, and Fraud repos require **two distinct human approvers** where author ≠ reviewer ≠ second reviewer, all CODEOWNERS. **WHY:** R4 mandates four-eyes for fraud actions and money movement; the same control must guard the *code* that implements those flows, because a single actor who can both write and approve ledger logic defeats the runtime four-eyes control entirely.

**Required status checks (gate to merge):**

| Check | Applies | Traces to |
|---|---|---|
| Build + unit (≥ 80% coverage) | all | testing canon |
| Lint / format | all | Ch.27.8 lint |
| SAST + secret scan | all | security canon |
| Dependency/SBOM + license | all | Ch.27.8 cost+supply-chain |
| Contract/schema backward-compat | event-producing & OHS repos | R6, R7, SA schema-registry |
| Idempotency/exactly-once/replay suite | Finance, Custody | R1, R2, Ch.27.1 fencing |
| Migration safety (expand-contract) | repos with state stores | SA, no cross-store (R6) |

A red required check is a **hard block** — no override, including for hotfixes; an emergency path uses a pre-approved break-glass PR that still runs the full gate and is reviewed retroactively within the incident runbook (Ch.27.7).

### 3.5 Item 8 — Commit Convention

**Rule:** **Conventional Commits** are mandatory on every commit, enforced by a commit-message lint in the PR gate. History is **linear** via squash-merge on the Standard tier; the Conservative tier uses **rebase-merge** to preserve individually signed, individually auditable commits.

**WHY Conventional Commits:** A machine-parseable `type(scope): subject` grammar lets automation derive semantic-version bumps, generate changelogs/release notes, and route changes by scope — directly feeding the per-service CD pipelines (SA §25.6) and the schema-registry major-version discipline. The alternative — free-form messages — makes automated versioning and audit-trail reconstruction impossible, which is disqualifying for regulator-facing Government and Finance histories.

**Grammar and patterns:**

```text
<type>(<scope>): <imperative subject ≤ 72 chars>

<body: WHY, not WHAT>
Refs: <ticket>  Trace: <BR-### | FR-### | ADR-### | R#>
BREAKING CHANGE: <consumer impact>   # mandatory on contract changes
```

- `type` ∈ `feat, fix, refactor, docs, test, chore, perf, ci, build, revert`.
- `scope` = bounded-context or aggregate (`custody`, `wallet`, `txn`, `catalog`), aligning commits to the PPID/WLT/TXN ordering keys.
- A `feat!` or `BREAKING CHANGE:` footer is **required** whenever a Published Language event schema or OHS contract changes (R6/R7), and triggers the major-version review path.

**Merge strategy — compared:**

| Strategy | Tier | WHY |
|---|---|---|
| Squash-merge | Standard | One clean, conventional commit per PR; trivial revert; linear `main`. |
| Rebase-merge | Conservative | Preserves every **signed** commit individually so audit can attribute each ledger/finance change to a verified author (Ch.27.7); squashing would collapse signatures. |
| Plain merge commits | **Rejected (both)** | Non-linear history obstructs `bisect`-based incident forensics and pollutes auto-generated changelogs. |

Branch names mirror the commit grammar (`feat/<ticket>-<slug>`) so tooling can correlate branch, PR, commits, and the originating BA/FR trace end-to-end — closing the loop from requirement to merged, signed, releasable change.

---

## 4. Release, Versioning & Artifacts

This chapter binds how DOKANDAR cuts releases, numbers everything it ships, and manufactures the artifacts that flow to the sovereign landing zone. It realizes SA conventions (schema-registry compatibility, idempotency, event topic `vN`), ADR-011 (five-language cap, centrally governed), R6 (Published Language stability), R7 (Identity+Catalog master-data OHS), and Ch.27 remediations (27.6 chaos/test gates, 27.8 cost/rotation/lint, 27.1 fencing). Every rule below traces to a binding source and states its WHY.

### 4.1 Release Strategy (Roadmap item 9)

**RULE R-REL-1 — Per-service independent releases.** Each of the 13 contexts plus EDGE/SPINE components releases on its own cadence from its own pipeline. There is no platform-wide "release train" version, no shared deployment unit.

*WHY.* The BA mandates strict context isolation (R1 custody sole writer, R2 Finance no-shared-DB/separate repo, NEVER-SAME-TEAM §17.4). A monolithic release train would couple Finance to B2C and Catalog to Custody, violating those isolation invariants and forcing the slowest/riskiest service to gate the fastest. Independent releases let Finance (gated, change-controlled) move slowly while B2C (Commerce) ships daily, each respecting its own SLO tier.

**Alternatives compared & rejected.**

| Model | Verdict | Reason |
|---|---|---|
| Mono-release train (all services, one version, fixed window) | **Reject** | Couples isolated contexts; slowest service gates all; contradicts R2/§17.4 ownership. |
| Release per team (3–4 services together) | **Reject** | Substrate owns #1,2,12,13 with different runtimes/SLOs; bundling re-introduces hidden coupling and shared blast radius. |
| **Per-service independent (chosen)** | **Accept** | Matches one-context-one-pipeline ownership; blast radius = one deployable; honors per-context SLO tiers. |

**RULE R-REL-2 — Progressive delivery tiers (from §25.6).** Every release advances through a tier ladder gated by SLO burn and health signals before reaching 100% of traffic. The tier and minimum bake time are a function of the context's criticality class.

| Criticality class | Contexts | Delivery technique | Min bake / gate |
|---|---|---|---|
| **CRITICAL — money/custody** | #3 Custody, #5 Inventory/NIL, #8 Finance | Canary → progressive, with **fencing (27.1)** + co-sign (27.3) on first cohort; manual four-eyes promotion (R4-style control) | Longest bake; zero SLO-error budget burn; RPO=0 quorum verified (27.2) |
| **HIGH — commerce/exchange/logistics** | #6 B2C, #7 B2B, #9 Logistics | Canary → automated progressive rollout on SLO health | Medium bake; auto-rollback on burn-rate alert |
| **GOVERNED — read-mostly/regulatory** | #11 Government (R5), #12 Analytics | Blue/green (instant cutover, instant revert) | Read-mostly tolerates atomic swap; no in-flight write migration |
| **EDGE** | api-gateway, BFFs, offline-sync-gateway | Canary at PoP/region granularity | Per-region bake; USSD/SMS/IVR parity smoke (R8) before promote |

*WHY tier-by-criticality.* A uniform rollout strategy would either over-protect cheap stateless BFFs (slowing them needlessly) or under-protect money flows. Money and custody mutations are irreversible in the ledger (R1 event-sourced, append-only); they earn the strictest, fencing-protected, co-signed canary. Government is read-mostly (R5), so an atomic blue/green swap is safe and simpler than progressive write-path canarying.

**Rejected:** *Big-bang deploy* for any tier — irreversible custody/finance writes make an un-baked 100% cutover an unbounded-blast-radius event; rejected outright for CRITICAL and as default everywhere. *Always-canary even for Government* — adds rollout complexity with no benefit on a read-mostly store; blue/green is the simpler correct choice (KISS).

**RULE R-REL-3 — Build order honored at first-release.** A context may not cut its first production release until its upstream dependencies (per Roadmap order: landing zone → spine → Identity/Catalog → Custody/Inventory → Finance → B2C → B2B → Logistics → Fraud/Gov → Analytics) have a released, compatible Published Language. *WHY:* R6/R7 make Identity, Catalog, and the event-spine schemas the contracts everyone binds to; releasing a consumer before its OHS contract is stable guarantees integration churn.

### 4.2 Semantic Versioning (Roadmap item 10)

**RULE R-VER-1 — SemVer `MAJOR.MINOR.PATCH` is the universal scheme** for services, shared libraries, and event/API schemas. MAJOR = incompatible contract change; MINOR = backward-compatible addition; PATCH = backward-compatible fix.

**Calendar vs Semantic — compared & rejected.**

| Scheme | Encodes compatibility? | Verdict |
|---|---|---|
| CalVer (`YYYY.MM`) | No — a date says *when*, not *whether a consumer breaks* | **Reject** as primary |
| **SemVer (chosen)** | Yes — MAJOR bump is a machine- and human-readable break signal | **Accept** |

*WHY.* The entire integration fabric is contract-driven: gRPC OHS internally, REST `/v1` externally, and Kafka-class events with schema-registry backward-compatibility *within a major version*. The single most important fact a consumer needs is "will this break me?" SemVer encodes exactly that in MAJOR; CalVer encodes only release timing, forcing humans to read changelogs to assess risk. CalVer is *permitted as a non-authoritative release-date tag in metadata* (e.g. build label) but never as the compatibility contract. Date-driven coupling would also re-introduce the train model R-REL-1 rejects.

**RULE R-VER-2 — Compatibility windows by artifact kind.**

| Artifact | Compatibility rule | Window / WHY |
|---|---|---|
| **Event schema** (`<context>.<aggregate>.<Event>.vN`) | Registry enforces **backward-compatible** evolution *within* major `vN`; a breaking change = new topic suffix `v(N+1)`, old topic retained | Old + new majors run **in parallel ≥ 2 release cycles** so async consumers (and offline/USSD R8 clients that sync late) drain. Per-aggregate ordering (PPID/WLT/TXN) must hold across the window. |
| **External REST** | URI-versioned `/v1`; additive within v1; breaking = `/v2` | `/v(N)` supported **min 12 months** after `/v(N+1)` GA — third-party + offline-first (R8) clients update slowly. |
| **Internal gRPC OHS** | Additive proto evolution; never renumber/reuse fields; break = new service major | Two majors served during consumer migration; coordinated via OHS owner (Identity/Catalog R7). |
| **Shared library** | Consumer pins MAJOR; MINOR/PATCH auto-eligible | See §4.4. |

*WHY parallel-running majors.* DOKANDAR is offline-first with USSD/SMS/IVR parity (R8); a feature phone may replay an event or call an API days after the producer upgraded. Hard-cutting a schema would silently drop or corrupt those late messages — unacceptable for custody/finance. The registry's backward-compatibility-within-major gate (a PreToolUse-style CI check) makes accidental breaks un-mergeable.

**RULE R-VER-3 — `0.x` is pre-production only.** No context may serve external traffic or write to custody/finance on a `0.x` line. *WHY:* `0.x` grants no SemVer stability guarantee; money (integer poisha) and the sole-writer ledger demand a committed contract.

**RULE R-VER-4 — Money/contract changes force MAJOR.** Any change to a money field's units (always integer poisha), an idempotency-key contract, or an event's ordering key (PPID/WLT/TXN) is by definition breaking → MAJOR. *WHY:* exactly-once (R2) and per-aggregate ordering are correctness invariants; silently altering them under a MINOR would corrupt reconciliation.

### 4.3 Artifact Management (Roadmap item 42)

**RULE R-ART-1 — Every artifact is immutable, content-addressed, signed, and SBOM-bearing.** A built image/package is tagged with its SemVer **and** its digest; tags are never moved or overwritten; promotion across environments copies the *same digest*, never rebuilds.

| Control | Standard | WHY |
|---|---|---|
| **Signing** | Sigstore-class keyless/HSM signatures (27.8 rotation cadence); admission policy in the landing zone refuses unsigned digests | Supply-chain integrity for a national commerce OS; provenance of what runs in production is non-repudiable. |
| **SBOM** | SBOM generated and attached per build; stored with the artifact | License + CVE auditability; gov/regulatory posture (#11). |
| **Immutability** | Digest-pinned, no tag mutation, no `latest` in any environment | Reproducible incident forensics (27.7) and deterministic rollback to R-REL-2 prior tier. |
| **Provenance attestation** | Build provenance (source commit → artifact) attested | Ties a running binary to a reviewed, four-eyes-approved commit. |
| **Registry** | Single sovereign registry inside the landing zone; per-team write scopes; immutable repos | Data sovereignty (Bangladesh); §17.4 separation enforced at registry-ACL level (Finance write-isolated). |

**RULE R-ART-2 — Promote-the-binary, never rebuild-per-environment.** The exact digest that passed dev/staging gates is what reaches production. *WHY:* rebuilding per environment defeats signing/SBOM guarantees and admits "works in staging, differs in prod" drift; the canary in R-REL-2 must bake the *identical* bytes that go to 100%.

**Rejected:** *mutable tags / `latest`* — destroys rollback determinism and forensic chain (27.7); *per-environment rebuild* — breaks attestation linkage; *unsigned internal artifacts* ("it's internal, skip signing") — lateral movement is the dominant supply-chain threat; admission stays signature-gated everywhere.

### 4.4 Package Versioning for the Five-Language Shared Libs (Roadmap item 52)

ADR-011 caps runtimes at five (Go, Java, C#, Python, Node/TS), centrally governed. Shared libraries (e.g. the envelope `{success,data,error,meta}`, problem+json mapping, idempotency-key helpers, OTel bootstrap, outbox/inbox/DLQ client) exist per-language and **must stay behaviorally equivalent**.

**RULE R-PKG-1 — One SemVer line per logical library, mirrored across languages.** The Go and Java implementations of, say, the event-envelope library share the **same MAJOR.MINOR** when they expose the same contract; PATCH may diverge for language-local fixes. *WHY:* a Node BFF and a Go gateway must agree byte-for-byte on the Published Language (R6); divergent majors across languages would fork the contract silently.

**RULE R-PKG-2 — Consumers pin MAJOR, float MINOR/PATCH within it.** Each context locks the major and accepts compatible minor/patch via its native lockfile (go.mod, Maven, NuGet, Poetry/uv, npm). *WHY:* gets security patches automatically (27.8 lint/cost governance) while a MAJOR bump remains a deliberate, reviewed migration — never a transitive surprise.

**RULE R-PKG-3 — Central governance gate.** A shared-lib MAJOR release requires platform sign-off (ADR-011 central governance) and a published migration note; per-language CI publishes to the sovereign package registries only after signing + SBOM (R-ART-1). *WHY:* shared libraries are the one place a single change touches all 13 contexts — exactly where uncontrolled drift would break cross-context contracts and §17.4 isolation assumptions.

**Rejected:** *independent per-language version numbers with no cross-language coupling* — lets the Go and Java envelope drift into incompatible shapes, breaking R6; *vendoring/copy-paste of shared logic* — violates DRY and guarantees implementation drift across runtimes; *CalVer for libraries* — hides the break/no-break signal consumers pin on (see §4.2).

**Trace summary.** R-REL-1/2/3 ⇐ §25.6, §17.4, R1/R2/R4/R5/R8, 27.1/27.2/27.3, Roadmap build order. R-VER-1..4 ⇐ SA schema-registry/`vN`/`/v1`/idempotency/ordering, R6/R7, money=poisha. R-ART-1/2 ⇐ 27.7/27.8, sovereignty, §17.4. R-PKG-1..3 ⇐ ADR-011, R6, 27.8.

---

## 5. Coding & Language Standards

These standards bind every repository in the DOKANDAR estate. They exist to make 13 bounded contexts in 5 languages (ADR-011) behave as one disciplined platform: predictable to read, safe to change, and impossible to corrupt across team boundaries (NEVER-SAME-TEAM §17.4). Each rule is enforced in CI as a merge gate, not a guideline — advisory standards decay, gated standards hold.

### 5.1 Cross-Cutting Coding Standards (Roadmap 11)

These apply to all languages. Per-language sections (§5.2) translate them into idioms and tools.

| # | Standard | Rule | WHY (trace) |
|---|----------|------|-------------|
| C1 | **Immutability by default** | Domain objects and value types are constructed valid and never mutated; state transitions return new instances. Mutation is confined to explicit, named adapters at the persistence edge. | Custody Ledger is event-sourced and sole-writer (R1); a mutated aggregate-in-memory diverges from its event log. Immutable values eliminate the most common class of concurrency bug and make per-aggregate ordering (PPID/WLT/TXN) reasoning sound. Aligns with the CANON coding-style mandate. |
| C2 | **No shared mutable state** | No global mutable singletons, no cross-request caches holding domain state, no package-level vars except constants and stateless clients. Concurrency communicates via messages/channels or immutable snapshots. | A nation-scale platform runs thousands of concurrent flows; shared mutable state turns into heisenbugs and silent money/custody corruption. R6 forbids cross-store coupling; shared in-process state is the same anti-pattern one layer down. |
| C3 | **Errors are values, handled explicitly** | Every error is inspected at the boundary that can act on it. No silent swallowing, no blanket catch-and-continue. Money/custody paths fail closed. | Finance isolation (R2) and exactly-once depend on never treating a failed write as success. A swallowed error in escrow saga (R3) produces orphaned funds. Explicit handling is the precondition for OUTBOX/INBOX/DLQ correctness. |
| C4 | **Small functions, small files** | Functions <50 lines, files <800 lines, nesting ≤4 (early returns). | Cohesion and reviewability; four-eyes review (R4) is only effective if a reviewer can hold the unit in their head. Smaller units localize the blast radius of change. |
| C5 | **Idempotency is structural** | Every unsafe / money / custody handler consumes `idempotency-key`, dedupes via INBOX, and is safe to replay. | SA convention: idempotency-key on all unsafe/money/custody writes; DLQ retry-with-backoff (Ch.27.5) replays messages — non-idempotent handlers double-spend on replay. |
| C6 | **Money = integer poisha** | Currency is a dedicated integer value type (poisha). Floating-point money is a build-failing offense; linters ban `float`/`double`/`decimal` in money contexts. | CANON: Money=integer poisha. Float rounding is non-associative and reconciliation-breaking (R2 reconciler). A named type prevents unit confusion (taka vs poisha). |
| C7 | **Boundary validation** | All inbound data (gateway, BFF, event consumer, gRPC) is validated against a schema before entering the domain. Invalid input is rejected with problem+json, never coerced. | R6 Published Language + schema-registry backward-compatibility; R8 offline payloads arrive late and untrusted. Fail-fast at the edge keeps the domain pure. |
| C8 | **Structured, contextual logging + tracing** | No ad-hoc print/console logging. Logs are structured; every request/event carries an OpenTelemetry trace context and correlation/idempotency keys. No secrets/PII in logs. | OpenTelemetry tracing + SLOs are SA-mandated (money/custody strictest); security.md forbids leaking sensitive data. Debugging cross-context sagas (R3) is impossible without propagated trace IDs. |
| C9 | **Time, IDs, money via platform libraries** | UTC-only internally; IDs and clocks come from the Platform Services (#13) shared kernel, never re-implemented per service. | DRY across 13 contexts; consistent ordering keys and audit timestamps for the append-only OHS sink (R6). |

**Rejected alternative — exceptions-for-control-flow as the universal model.** Convenient, but it hides failure paths and tempts blanket handlers, violating C3 and undermining exactly-once. We standardize on explicit error values where the language supports them (Go) and **checked, typed, boundary-mapped** exceptions where it does not (Java/C#/Python/TS), rather than letting unchecked exceptions flow freely.

**Rejected alternative — “immutability only where convenient.”** Permissive mutation lowers ceremony but reintroduces C1/C2 hazards precisely in the highest-stakes contexts. Rejected: the cost of disciplined construction is paid once; the cost of a custody corruption is paid by the nation.

### 5.2 Language-Specific Standards (Roadmap 12)

ADR-011 caps the platform at **five languages, centrally governed**. Each serves a distinct capability class; introducing a sixth (e.g., Rust, Kotlin) requires an ADR superseding 011. The Platform/Infra team owns the shared toolchain config so a rule cannot drift per repo.

| Language | Contexts (capability class per ADR-011) | Formatter / Linter (gated) | Null-safety & types | Concurrency model |
|----------|------------------------------------------|----------------------------|---------------------|-------------------|
| **Go** | #2 Catalog, #3 Custody, #4 Provenance, #5 Inventory, #9 Logistics, #13 Platform, #10 (perf path), api-gateway — *high-throughput, event-sourced, latency-critical cores* | `gofmt`/`gofumpt` + `golangci-lint` (vet, errcheck, staticcheck) | No nullable types; explicit zero-value discipline; `errcheck` forbids ignored errors | Goroutines + channels; context propagation mandatory; `-race` in CI |
| **Java/Spring** | #7 B2B, #8 Finance — *transactional, integration-heavy domains* | Spotless (google-java-format) + Checkstyle + Error Prone + SpotBugs | `Optional` for absent returns; `@NonNull` by default via NullAway; no raw `null` returns | Virtual-thread / structured concurrency or reactor; no shared mutable singletons |
| **C#/.NET** | #1 Identity/KYC, #11 Government — *regulatory, identity, read-mostly* | `dotnet format` + Roslyn analyzers + StyleCop, `TreatWarningsAsErrors` | Nullable reference types **enabled and enforced**; `#nullable` cannot be disabled | `async`/`await` + immutable records; no `async void` outside handlers |
| **Python** | #10 Fraud (ML), #12 Analytics — *data/ML, scoring* | `ruff` (lint+format) + `mypy --strict` | `mypy --strict`, no untyped defs, no implicit `Optional` | `asyncio` for IO; process pools for CPU; never threads for shared mutable state |
| **Node/TypeScript** | #6 B2C, BFFs, offline-sync-gateway — *experience edge, channel adapters* | ESLint (typescript-eslint) + Prettier | `strict` + `noUncheckedIndexedAccess`; `any` is build-failing; runtime schema validation at edges (C7) | Single-thread event loop; worker threads for CPU; no blocking IO |

**Language-to-capability rationale (WHY each, with rejected alternatives):**

- **Go for the Provenance/Custody/Inventory/Logistics cores.** Custody is event-sourced sole-writer (R1) with strict ordering and SLOs; Go gives predictable latency (no GC stop-the-world surprises at scale comparable to JVM tail latency), first-class concurrency for high-fan-in consumers, and a tiny readable surface that suits four-eyes review. *Rejected: Java for these cores* — heavier runtime and richer language surface invite mutable-state patterns the custody invariant cannot tolerate.
- **Java/Spring for Finance and B2B.** Finance (#8) is isolated (R2) with exactly-once and a separate reconciler; the JVM ecosystem has the most mature transactional, outbox, and saga (R3) libraries and the strongest decimal/precision and audit tooling. B2B exchange logic is integration-heavy and benefits from the same stack — but **B2C⟂B2B and Finance⟂all** (§17.4) keep them in separate teams/repos. *Rejected: Node for Finance* — single-threaded event loop and dynamic typing are a poor fit for money correctness and CPU-bound reconciliation.
- **C#/.NET for Identity and Government.** Both are regulatory, identity-centric, read-mostly (R5) with strong tooling for KYC, document/credential handling, and enterprise auth. Nullable-reference enforcement removes the null-deref class that plagues identity code. *Rejected: putting Government on the Go/operational stack* — violates Government⟂operational/Platform (§17.4); the language split reinforces the team split.
- **Python for Fraud-ML and Analytics.** The ML/data ecosystem is unmatched; Fraud (#10) pairs Python (scoring/models) with Go (latency-critical enforcement path) deliberately. *Rejected: doing fraud scoring in Go* — would forfeit the ML ecosystem; hence the documented polyglot pairing, still within the five-language cap.
- **Node/TypeScript for B2C and BFFs/offline-sync.** The experience edge needs rapid UI iteration, shared types with web/mobile clients, and channel adapters for USSD/SMS/IVR parity (R8). *Rejected: a single BFF language mismatched to each client* — TS unifies edge typing end-to-end. TS is confined to the edge; it never owns custody or money state.

**Rejected platform-wide alternative — “let each team choose freely.”** Maximizes local autonomy but explodes the operational surface (security patching, observability agents, hiring, shared kernels) and breaks DRY across 13 contexts. ADR-011’s five-language cap is the deliberate, central-governed middle path between monoglot rigidity and unbounded polyglot sprawl.

### 5.3 Package / Module Structure — Hexagonal (Roadmap 13)

Every service uses **ports-and-adapters (hexagonal)** so the domain never depends on infrastructure. The dependency rule is absolute and lint-enforced: **`domain` imports nothing outward; `application` imports only `domain`; `adapters` import inward only.** An adapter touching another adapter, or a domain importing a framework, fails the build.

Illustrative structure (language-neutral; names adapt to each idiom):

```text
<service>/
  domain/            # entities, value objects (money=poisha), invariants — pure, no I/O
  application/       # use-cases, saga orchestration, port interfaces
  ports/
    inbound/         # driving ports: REST handler, gRPC, event-consumer contracts
    outbound/        # driven ports: repository, event-publisher, PDP, KMS interfaces
  adapters/
    inbound/         # api-gateway/BFF handlers, Kafka consumers (INBOX)
    outbound/        # persistence, OUTBOX publisher, gRPC clients, secret/KMS access
  config/            # composition root: wires adapters to ports (the only place infra meets domain)
  contracts/         # generated from schema-registry; never hand-edited
```

**WHY hexagonal over the alternatives.**

- **Rejected: layered/N-tier (controller→service→DAO).** Permits the domain to depend transitively on persistence and frameworks; over time business rules leak into ORM entities and HTTP types. That directly threatens R1 (custody domain purity), R2 (Finance isolation), and R6 (no cross-store coupling). Hexagonal makes “the domain knows nothing about Kafka/SQL/HTTP” a structural, testable fact.
- **Rejected: framework-default “package-by-type” (all controllers, all services, all repos).** Low cohesion, high coupling; contradicts the file-organization rule (package by feature/domain). Hexagonal is package-by-capability with an enforced dependency direction.
- **Why a single composition root.** Centralizing wiring in `config/` keeps secret/KMS and PDP access (OAuth2/OIDC, RBAC/ABAC, four-eyes R4) at one auditable seam, satisfying security and rotation cadences (Ch.27.8). `contracts/` is generated from the schema-registry to guarantee backward-compatibility (R6) — hand-editing it is forbidden.

This structure makes the CANON enforceable at compile time: custody stays sole-writer, Finance stays isolated, money stays poisha, and no team can reach across a boundary §17.4 forbids — because the package graph itself will not allow it.

---

## 6. Shared Library & Internal SDK Strategy

> Realizes Roadmap Item 14 (Shared Library Strategy). Traces to ADR-011 (polyglot capped at five), R1–R8, R6 (Published Language), SA conventions (envelope, problem+json, idempotency-key, outbox/inbox/DLQ, OAuth2/OIDC + mTLS + PDP, OpenTelemetry), and §17.4 NEVER-SAME-TEAM ownership boundaries.

### 6.0 Mandate & Scope

The Platform/Enabling team (Substrate + Event-Spine Enabling) owns a curated set of **cross-cutting platform libraries** delivered in all five governed languages — **Go, Java, C#, Python, Node/TS** — and nothing beyond those five (ADR-011). These libraries encode *how DOKANDAR talks to itself and to its operators*: authentication, authorization (PDP client), structured logging, the event spine (outbox/inbox/DLQ), data access, gRPC/REST scaffolding, configuration, telemetry, retry, idempotency, caching, error handling, and validation. They exist so that every one of the 13 contexts implements the binding SA conventions **identically**, not approximately.

**WHY a platform library tier at all.** The SA conventions are non-negotiable and security-critical: idempotency-key on all money/custody writes, per-aggregate ordering, problem+json errors, mTLS, short-JWT validation, OpenTelemetry trace propagation. If each of 13 teams re-implements JWT validation or outbox semantics from a prose spec, drift is guaranteed and drift here means a custody double-write (R1 violation) or an exactly-once breach in Finance (R2). Centralizing the *mechanism* makes conformance the path of least resistance.

### 6.1 The Foundational Rule: Shared Libraries Never Embed Business Rules

| Allowed in shared libs | Forbidden in shared libs |
|---|---|
| Envelope `{success,data,error,meta}` shaping | Escrow saga steps (R3), four-eyes flow (R4) |
| Idempotency-key plumbing & dedup storage adapter | What constitutes a duplicate *order* or *payout* |
| Outbox writer / inbox dedup / DLQ routing | Topic ownership, which events an aggregate emits |
| JWT/mTLS validation, PDP request/response | RBAC/ABAC *policy content*, role grants |
| Money type = integer poisha, currency-safe arithmetic | Pricing, fee, escrow-release, settlement logic |
| problem+json formatting | Domain error *taxonomy* per context |

**WHY (binding).** Business rules live in BR-001..040 and the bounded contexts that own them; they are the Business Architecture, which this document **never modifies**. If a saga step or a fraud threshold were compiled into a shared library, a Platform-team release would silently change Finance or Risk behaviour — violating both §17.4 (Finance ⟂ all; Fraud ⟂ Analytics) and the autonomy of context teams. The library provides the *typed money primitive*; the *fee* is the context's. **Enforcement:** shared-lib repositories carry an automated "no-domain-vocabulary" lint (deny-list of business nouns: escrow, payout, recall, KYC-decision, fraud-score) plus mandatory cross-team review where any PR touching a shared lib requires a Platform reviewer **and** cannot be authored solely by a single consuming context team. A library that needs a business concept is the wrong abstraction — the concept belongs behind a context's gRPC OHS interface.

### 6.2 Distribution Model — Shared Libraries vs Sidecar vs Copy-Paste

| Approach | Conformance guarantee | Polyglot cost | Upgrade blast radius | Latency / failure surface | Verdict |
|---|---|---|---|---|---|
| **Copy-paste / snippet wiki** | None — drifts immediately | Zero upfront, infinite long-term | Unbounded, untracked | None added | **Rejected** |
| **Sidecar-for-everything** (mesh proxy owns all cross-cutting) | Strong for network concerns | One sidecar, language-agnostic | Per-deploy, operational | Extra hop + proc per call | **Partially adopted (selective)** |
| **Governed shared libraries** (5 languages, versioned) | Strong, compile-time + tested | 5× authoring, centrally funded | Versioned, opt-in, tracked | In-process, none added | **Chosen (primary)** |

**Rejected — Copy-paste.** It is the cheapest first commit and the most expensive everything-after. There is no version, no CVE recall path, no way to roll a JWT-validation fix across 13 contexts. For security-critical mechanics (mTLS, idempotency, exactly-once) an unrecallable fix is disqualifying. Rejected outright.

**Rejected as the sole model — Sidecar-for-everything.** A sidecar (mesh data-plane) is language-agnostic and upgrades operationally, which is attractive against the 5× cost of polyglot libraries. But it can only own concerns expressible at the network boundary. It **cannot** type money as poisha inside the process, cannot give a Java developer a compile-time `IdempotencyKey`, cannot shape the in-process `{success,data,error,meta}` envelope, and cannot validate domain payloads. Pushing idempotency dedup or outbox semantics into a sidecar also forces transactional concerns across a process boundary — incompatible with the **transactional outbox** convention (the outbox row must commit in the *same* local transaction as the state change). So a sidecar cannot deliver R2 exactly-once or R1 sole-writer guarantees.

**Chosen — Governed shared libraries + selective sidecars.** Libraries own *in-process correctness* (envelope, money, idempotency, outbox/inbox, validation, error taxonomy plumbing, retry, telemetry SDK). The **service mesh sidecar** owns *pure network plane* concerns where it is genuinely superior and language-independent: mTLS termination/rotation, L7 retries/timeouts at the edge, traffic shifting, and connection-level policy. We pay the 5× authoring cost deliberately because DOKANDAR's correctness lives inside the transaction, not on the wire — and ADR-011 already funds exactly five language toolchains, bounding that cost.

### 6.3 The Library Catalogue

Each library is a thin, independently versioned module per language under a single Platform namespace (illustrative: `dokandar.platform.<concern>`).

| Library | Encodes (SA convention) | Hard boundary |
|---|---|---|
| `auth` | OAuth2/OIDC token acquisition, short-JWT validation, mTLS client identity | No role/permission *content* |
| `authz` (PDP client) | RBAC/ABAC PDP request/response, four-eyes *protocol* hook | No policies; PDP is the source of truth |
| `logging` | Structured JSON logs, correlation/trace-id injection, PII redaction primitives | No log-retention policy |
| `events` | Topic naming `<context>.<aggregate>.<Event>.vN`, outbox writer, inbox dedup, DLQ + retry-with-backoff, park-and-freeze (Ch.27.5) | No event *schemas* (those live in schema registry / Published Language, R6) |
| `db` | Connection lifecycle, transaction helpers, outbox co-commit hook | No queries; **must not** enable cross-store (R6) or shared-DB (R2) |
| `transport` | gRPC (internal OHS) + REST `/v1` scaffolding, envelope, problem+json, idempotency-key middleware | No endpoints |
| `config` | Typed config load, secret references via KMS (never values) | No secret values in code |
| `telemetry` | OpenTelemetry tracing/metrics, SLO instrumentation hooks | No SLO *targets* (per context) |
| `resilience` | Retry-with-backoff, circuit breaking, fencing (Ch.27.1) | No business retry policy |
| `idempotency` | Idempotency-key generation/storage adapter, dedup | No "what is a duplicate order" |
| `cache` | Cache-aside helpers, TTL/key conventions | No cache invalidation rules |
| `money` | Integer poisha type, currency-safe arithmetic, no float | No fees, no pricing |

**WHY one library per concern (not a mega-SDK).** Per coding-style "many small files / low coupling," a context that needs only `money` + `transport` should not pull `cache` or `events`. Fine-grained modules shrink the upgrade blast radius (§6.5) and let a CVE in one concern be patched without forcing unrelated teams to re-qualify.

### 6.4 Versioning & Breaking-Change Policy

All platform libraries follow **strict SemVer** with a published support window.

| Change class | Version bump | Consumer action | Notice |
|---|---|---|---|
| Backward-compatible additive | MINOR | Optional adopt | Changelog |
| Bug/security fix, no API change | PATCH | Adopt promptly; security = mandated | Advisory |
| Breaking API change | MAJOR | Migrate within window | ≥1 quarter + migration guide |

**Rules.** (1) Two consecutive MAJOR lines run **in parallel** for a minimum migration window so no context is forced into a same-sprint rewrite. (2) Event-schema evolution within a major version stays **backward-compatible** (mirrors the schema-registry convention; R6). (3) Security PATCHes are **mandatory** with an enforced adopt-by date; the dependency dashboard flags any service past it. (4) No "flag day" upgrades across all 13 contexts.

**WHY SemVer + parallel majors over a single rolling latest.** A monorepo-style "everyone on HEAD" minimizes version sprawl but couples release cadence across teams that §17.4 mandates be independent (Finance ⟂ all). Independent SemVer lets Finance qualify a money-library MAJOR on its own gated timeline (Roadmap: Finance is gated) while B2C moves faster — **rejected** the forced-latest model because it manufactures exactly the cross-team coupling the ownership rules forbid.

### 6.5 Consumer Onboarding & Governance

```text
platform-libs/
  go/    java/    dotnet/    python/    node-ts/
    auth/  authz/  events/  transport/  money/ ...
  CONTRACT.md          (cross-language behavioural parity spec)
  conformance-suite/   (same scenarios, all 5 languages)
```

**Behavioural parity is contract-tested, not assumed.** A single language-agnostic conformance suite (idempotency dedup, outbox co-commit, envelope shape, problem+json, JWT rejection cases, poisha arithmetic) runs against **all five** implementations in CI. **WHY:** five hand-written ports of "exactly-once" will diverge in edge cases unless a shared executable contract pins them; for R2/R1 a divergence is a financial-integrity defect.

**Onboarding path (binding):**

1. Service declares dependencies via the standard manifest; only Platform-published, signed artifacts from the internal registry are resolvable (no public-registry direct pulls for platform concerns).
2. A golden-path service template wires `auth`, `transport`, `telemetry`, `logging`, `config` by default — secure-by-default, opt-out requires Platform sign-off.
3. Build order honoured: spine + Identity/Catalog libraries stabilize first (Roadmap), since R7 master-data OHS and R6 Published Language are foundational dependencies for every later context.

**Contribution & ownership.** Platform owns the libraries; context teams contribute via PR but **cannot self-merge** platform changes (§17.4 separation). A Government-team need landing in a shared lib is reviewed by Platform — never the reverse — preserving Government ⟂ operational/Platform. Requests that smell of business logic are bounced to the requesting context's own service per §6.1.

**Enforcement summary:** no-domain-vocabulary lint; signed-artifact-only resolution; conformance suite gate in CI; security adopt-by dashboard; mandatory cross-team review on every shared-lib PR. Together these make the SA conventions the default and any deviation a visible, blocked CI event rather than a silent drift.

---

## 7. API Design Standards (REST & gRPC)

This chapter binds every DOKANDAR interface — the externally exposed REST surface fronted by the api-gateway and BFFs, and the internal gRPC mesh that realizes the Open-Host Service (OHS) contracts of R6, R7. It realizes SA Ch.19 (API conventions) and the envelope/idempotency/problem+json rules in the CANON. No standard here invents business behavior; each one constrains *how* the 13 contexts speak, never *what* they decide.

### 7.1 API Design Philosophy & Layering (Roadmap Item 15)

DOKANDAR runs two API planes with different consumers, trust levels, and evolution speeds. Conflating them is the root cause of most interface debt, so the boundary is a binding rule.

| Plane | Protocol | Consumers | Boundary | Trace |
|---|---|---|---|---|
| External | REST `/v1` | Apps, web, USSD/SMS/IVR (via offline-sync-gateway), partners | api-gateway → BFFs | SA Ch.19, R8 |
| Internal | gRPC | Context-to-context, OHS contracts | service mesh, mTLS | R6, R7, ADR-011 |

**Rule 7.1.1 — REST is external-only; gRPC is internal-only.** WHY: the two planes optimize for opposing forces. External clients need broad reach, human-debuggable payloads, CDN/proxy compatibility, and tolerance for flaky mobile/2G links (R8); internal callers need low-latency, strongly-typed, schema-governed contracts. **Alternatives rejected:** (a) *gRPC end-to-end including external* — rejected because gRPC-web degrades on Bangladesh edge networks, breaks USSD/IVR gateways, and forces proto toolchains onto every partner, violating R8 parity. (b) *REST end-to-end including internal* — rejected because JSON-over-REST loses the schema-registry guarantees, costs serialization CPU at custody/ledger volumes, and lacks first-class deadline propagation. The split lets each plane evolve independently and keeps the gateway as the single translation seam.

**Rule 7.1.2 — No context exposes its internal gRPC surface directly to clients.** The gateway+BFF is the only translator (gRPC→REST, problem+json mapping §7.6). WHY: enforces the OHS/Published-Language discipline of R6/R7, keeps cross-store access impossible from the edge, and gives one place to apply auth, rate-limiting, and localization.

### 7.2 REST `/v1` Standards (Roadmap Item 18)

**Resource naming.** Plural, lowercase, kebab-case nouns; hierarchy reflects ownership, not implementation. Verbs never appear in paths.

```text
/v1/catalog/products/{productId}
/v1/custody/wallets/{walletId}/holdings
/v1/b2c/orders/{orderId}
/v1/logistics/shipments/{shipmentId}/events
```

**Rule 7.2.1 — Nouns + HTTP verbs, never verbs-in-path.** WHY: uniform-interface predictability lets the gateway, caches, and SDK generators reason about safety/idempotency from the method alone. **Rejected:** RPC-style REST (`/getOrder`, `/cancelOrder`) — it hides idempotency, defeats HTTP caching, and forces per-endpoint documentation of semantics that the verb already conveys.

**Verb→semantics contract:**

| Verb | Semantics | Idempotent | Body |
|---|---|---|---|
| GET | Read, cacheable | Yes | None |
| POST | Create / non-idempotent action | No (needs Idempotency-Key) | Yes |
| PUT | Full replace | Yes | Yes |
| PATCH | Partial update (merge semantics) | Yes | Yes |
| DELETE | Remove / soft-cancel | Yes | Optional |

**Status codes** are a fixed vocabulary; teams may not improvise.

| Code | Use | Notes |
|---|---|---|
| 200 / 201 / 202 | OK / Created / Accepted (saga in flight, e.g. escrow R3) | 202 for async escrow/payout |
| 400 / 422 | Malformed syntax / valid syntax-failed business validation | §7.7 |
| 401 / 403 | Unauthenticated / unauthorized (RBAC/ABAC PDP) | four-eyes denials → 403 + code |
| 404 / 409 | Not found / state conflict (optimistic concurrency, duplicate idempotency-key mismatch) | |
| 423 | Locked — park-and-freeze / fencing (Ch.27.1, 27.5) | distinct from 409 |
| 429 | Rate-limited | `Retry-After` mandatory |
| 5xx | Server fault — never leak internals | problem+json only |

**Rule 7.2.2 — 422 is reserved for business-validation failures; 400 for malformed requests.** WHY: clients and the localized-error layer (§7.7) must distinguish "your JSON is broken" from "your input violated a rule," because only the latter carries field-level Bangla messages worth surfacing to a shopkeeper.

### 7.3 Response Envelope & Pagination

**Rule 7.3.1 — Every REST response uses the envelope `{success, data, error, meta}`.** Exactly one of `data` or `error` is populated; `success` is the boolean discriminant; `meta` carries pagination, trace id, and deprecation hints. WHY: a single shape lets SDKs, BFFs, and offline clients parse uniformly without content-type sniffing, and gives the deprecation channel (§7.8) a guaranteed home. **Rejected:** bare-payload responses (data at the root) — they leave no room for pagination metadata or warnings without overloading HTTP headers, which USSD/SMS transcoders strip.

**Rule 7.3.2 — Cursor pagination only; offset pagination is prohibited.** Requests use `pageSize` + opaque `cursor`; responses return `meta.nextCursor` (null at end). WHY: at nation-scale catalog/order volumes, offset/`LIMIT n OFFSET m` degrades linearly and yields duplicate/missing rows under concurrent writes. Opaque cursors encode sort-key position, are stable under inserts, and hide storage internals. **Rejected:** offset pagination (unscalable, inconsistent under write load) and page-number pagination (same defects plus client-cacheable deep links that rot).

```text
GET /v1/catalog/products?pageSize=50&cursor=eyJrIjoi...   → meta.nextCursor
```

**Rule 7.3.3 — HATEOAS is NOT adopted; clients use documented URI templates and capability flags.** WHY: full hypermedia adds payload weight and runtime link-parsing that hurt 2G/USSD clients (R8) and buy little when BFFs are versioned and SDK-generated. We instead expose coarse `meta.actions` capability booleans (e.g. `canCancel`) so clients render affordances without hard-coding business rules. **Rejected:** strict HAL/HATEOAS — operationally heavy for marginal decoupling given our typed BFFs; bare static docs only — loses the per-resource capability signal four-eyes and saga states need.

### 7.4 Idempotency

**Rule 7.4.1 — `Idempotency-Key` header is mandatory on every unsafe, money, or custody write** (POST/PATCH/DELETE touching contexts #3 Custody, #5 Inventory, #7 B2B, #8 Finance, #9 Logistics state-changes). The gateway rejects such requests lacking the key with 400. WHY: mobile retries over lossy links are routine (R8); without client-supplied keys, retried payment/custody writes double-spend. This pairs with the transactional OUTBOX/INBOX (Ch.6) — the key is the dedup anchor across the whole write path. **Rejected:** server-generated request hashes — they cannot distinguish a deliberate retry from a distinct identical request (e.g. two legitimate equal-amount top-ups). Client-owned keys make intent explicit.

**Rule 7.4.2 — Same key + same payload returns the original result (replay); same key + different payload returns 409.** WHY: protects exactly-once money semantics (R2) and gives a deterministic, auditable contract. Keys are retained per the money/custody SLO window.

### 7.5 gRPC Internal-OHS Standards (Roadmap Item 17)

gRPC is the wire for every OHS/Published-Language contract (R6, R7). Service and method names mirror the bounded-context aggregate vocabulary.

```text
service CustodyLedger { rpc RecordHolding(...) ; rpc GetWallet(...) }
package dokandar.custody.v1
```

**Rule 7.5.1 — One major version per package (`...v1`); breaking changes mint `...v2`.** WHY: aligns gRPC contracts with the same backward-compatibility-within-major-version rule the event schema-registry enforces, giving one mental model across sync and async planes.

**Rule 7.5.2 — Every internal call sets a deadline; servers reject deadline-less calls.** Defaults by tier: money/custody reads tight, writes tighter; cross-context fan-out budgets are explicit. WHY: deadlines are the backbone of cascade-failure prevention and propagate the caller's SLO downstream; an unbounded call is a latent outage. **Rejected:** relying on transport timeouts only — they don't propagate across hops and let a slow custody write exhaust upstream B2C threads.

**Rule 7.5.3 — Streaming is restricted.** Unary is the default. Server-streaming is permitted only for bounded result feeds (e.g. provenance-graph traversal, logistics event tails). Client- and bidi-streaming are prohibited without architecture sign-off. WHY: streams complicate retries, deadlines, idempotency, and observability; most needs are better served by cursor-paginated unary calls or the event-spine. **Rejected:** liberal bidi-streaming — turns simple request/response auditing into stateful session management, fighting R6's append-only audit model.

**Rule 7.5.4 — Internal calls carry propagated identity, trace context, and idempotency key in metadata; mTLS is mandatory** (CANON security). The OHS server re-validates authorization at its own PDP — never trusts the caller's claim of having checked (four-eyes R4, Finance isolation R2).

### 7.6 gRPC→problem+json Error Mapping at the Edge

**Rule 7.6.1 — gRPC status codes map to problem+json at the gateway/BFF via a fixed table; internal status codes never leak raw to clients.** WHY: clients get one error grammar (§7.7) regardless of which protocol served them, and internal taxonomy stays private.

| gRPC status | HTTP / problem+json | DOKANDAR code class |
|---|---|---|
| INVALID_ARGUMENT | 422 | `validation.*` |
| FAILED_PRECONDITION | 409 / 423 | `state.*`, `frozen.*` |
| PERMISSION_DENIED | 403 | `authz.*` (incl. four-eyes) |
| NOT_FOUND | 404 | `resource.*` |
| RESOURCE_EXHAUSTED | 429 | `rate.*` |
| DEADLINE_EXCEEDED / UNAVAILABLE | 503 | `dependency.*` |

### 7.7 Unified Error Handling & Code Taxonomy (Roadmap Item 19)

**Rule 7.7.1 — All errors are RFC 7807 problem+json, wrapped in the envelope's `error` field.** Required members: `type` (stable DOKANDAR code URI), `title`, `status`, `detail`, plus `traceId` and `errors[]` for field-level validation. WHY: a single machine-readable contract lets every client, SDK, and the deprecation/observability pipeline branch on `type` rather than parse prose.

**Rule 7.7.2 — Error codes are a hierarchical, stable, namespaced taxonomy** — `dokandar.<context>.<category>.<reason>` (e.g. `dokandar.finance.validation.amount_not_poisha`, `dokandar.custody.state.holding_frozen`). Codes are append-only; meaning never changes once shipped. WHY: stability is what makes errors integratable and localizable; mutable codes silently break clients. **Rejected:** raw HTTP status as the sole signal (too coarse for dozens of distinct business failures) and free-text messages as the contract (unstable, untranslatable, leak internals).

**Rule 7.7.3 — Error responses never leak stack traces, SQL, internal hostnames, or secrets**; `detail` is safe, `traceId` correlates to server logs. WHY: CANON security — error messages must not leak sensitive data.

### 7.8 Validation Standards (Roadmap Item 20)

**Rule 7.8.1 — Validate at every boundary, fail-fast, schema-based.** The gateway/BFF performs syntactic and shape validation; each context independently re-validates business invariants — never trusting upstream (R6 no-cross-store, R2 Finance isolation). WHY: boundary validation contains malformed/hostile input early; re-validation per context preserves bounded-context autonomy and defense-in-depth. **Rejected:** validate-once-at-edge — a compromised or buggy BFF would let invalid writes reach the custody ledger; single sole-writer (R1) integrity demands the writer re-check.

**Rule 7.8.2 — Money is validated as integer poisha; fractional or float amounts are rejected with `*.validation.amount_not_poisha`.** WHY: CANON — money = integer poisha; floats introduce rounding error unacceptable to Finance/Custody reconciliation (R2).

**Rule 7.8.3 — Validation errors return 422 with localized Bangla `detail` and field `errors[]`; codes stay English/stable, human text is localized.** The BFF selects locale (Bangla default, English fallback) via request locale; USSD/SMS/IVR receive the same code mapped to a short Bangla template (R8 parity). WHY: separating stable code from localized message lets shopkeepers read actionable Bangla while integrators branch on invariant codes — serving both audiences without forking the contract.

**Rule 7.8.4 — Reject unknown fields (strict schemas) on writes.** WHY: silent field-dropping hides client bugs and version drift; fail-fast surfaces them. **Rejected:** lenient/ignore-unknown parsing — convenient short-term, but masks contract mismatches that later corrupt state.

### 7.9 Compatibility & Deprecation Pointers

**Rule 7.9.1 — Backward-compatible changes only within `/v1` and gRPC `v1`; breaking changes require a new major version running in parallel.** Deprecations surface via `meta.deprecation` (sunset date, successor link) and standard `Sunset`/`Deprecation` headers. WHY: mirrors the schema-registry backward-compatibility-within-major-version rule, giving REST, gRPC, and events one evolution policy. Full lifecycle and version-retirement governance are defined in the API Versioning & Lifecycle chapter; this chapter binds the in-band signals that make those transitions observable to clients.

---

## 8. Event Design Standards

This chapter sets the binding standard for every event published, consumed, retained, or replayed on the DOKANDAR event-spine. It realizes **R6** (event-spine Published Language, append-only audit OHS sink, NO cross-store), **ADR-010** (event-spine as the integration backbone), **R7** (Identity+Catalog master-data OHS), and **SA Ch.17** conventions. Events are the only sanctioned cross-context integration channel; therefore their design is a platform-wide contract, not a per-team preference. Every rule below traces to a binding source and is enforced at the schema-registry, CI-lint, and ARB-review gates.

### 8.1 Topic Naming: `<context>.<aggregate>.<Event>.vN`

**Rule.** Every topic name is exactly four dot-segments: bounded-context slug, aggregate name, PastTense event name, and a major-version suffix `vN`. Context and aggregate are `lower-kebab` drawn from the BA's 13-context register; the event is `PascalCase`; `N` is a positive integer. Example patterns: `custody.wallet.FundsCommitted.v1`, `finance.payout.PayoutReleased.v2`, `catalog.product.ProductPublished.v1`.

| Segment | Source of truth | WHY |
|---|---|---|
| `<context>` | BA 13-context register | Makes ownership unambiguous; routes governance to the owning team (§17.4 NEVER-SAME-TEAM is enforceable only if topic ownership is legible). |
| `<aggregate>` | SA aggregate model | Aligns topic with the per-aggregate ordering key (PPID/WLT/TXN), so partitioning is derivable from the name. |
| `<Event>` | Published Language | PastTense names express settled facts, not commands (see 8.2). |
| `vN` | Schema major version | Encodes the only break boundary consumers must watch (8.4). |

**Alternatives rejected.** A flat `events.all` firehose with a `type` field was rejected: it destroys per-topic ACLs, per-topic DLQ (Ch.27.5), and per-topic retention, and forces every consumer to deserialize everything. A free-form team-chosen naming was rejected: it breaks automated lineage, ABAC topic-scoping, and the schema-registry subject convention. The four-part scheme is the minimum structure that makes ownership, ordering, and versioning all derivable from the name alone.

### 8.2 Past-Tense, Immutable Events

**Rule.** Events name things that **have already happened** (`OrderPlaced`, `RecallInitiated`, `FundsCommitted`). An event, once published, is immutable: no in-place edit, no deletion, no republish of the same `(topic, key, eventId)` with altered payload. Corrections are expressed as **new compensating events** (`PayoutReversed`), never as mutation. This directly encodes the coding-style immutability rule and the event-sourced nature of Custody (R1).

**WHY.** Consumers, the append-only audit sink (R6), and the Custody event store treat the log as the system of record. If a producer could mutate a past event, every downstream projection and every audit reconstruction would be non-deterministic, and Custody's sole-writer guarantee (R1) would be meaningless. Past-tense naming also prevents the anti-pattern of command-shaped events (`CreateOrder`) that smuggle imperative coupling across contexts and re-introduce the synchronous dependencies the spine exists to remove.

**Alternative rejected.** "Mutable last-state" topics (compacted to a single editable record) were rejected as the *primary* event model because they erase history needed for recall provenance (Context #4) and financial reconciliation (R2). Compaction is permitted only for snapshot/state topics under 8.9, never for fact streams.

### 8.3 Canonical-IDs-Only, No PII in Payloads

**Rule.** Event payloads carry **canonical identifiers only** — `partyId`, `walletId`, `productId`, `orderId`, `txnId` — never names, NID numbers, phone numbers, addresses, biometric data, or KYC artifacts. Consumers needing personal data resolve it on demand from the owning OHS context (Identity for parties per R7; Catalog for product master-data per R7) under their own ABAC authorization.

| Concern | Standard | WHY |
|---|---|---|
| Privacy | IDs-only | The spine fans out widely; embedding PII would replicate regulated data into every consumer store, violating data-minimization and creating uncontrolled copies. |
| Authorization | Resolve-on-read at OHS | Keeps the PDP/ABAC decision (Ch.27.8) at the data owner, not at every subscriber. |
| Right-to-erasure | IDs-only | Erasure handled at the Identity master; the immutable log never has to be rewritten to comply. |

**Alternative rejected.** Event-carried *personal* state (denormalizing names/addresses into events to save a lookup) was rejected: it trades a cheap, cached OHS read for permanent regulatory liability and cross-store PII sprawl, which R6's "NO cross-store" and Government read-mostly (R5) constraints forbid.

### 8.4 Schema Registry and Backward Compatibility Within a Major Version

**Rule.** Every event has a registered schema keyed by topic subject. Within a major version `vN`, only **backward-compatible** changes are allowed: add optional fields, widen enums via documented defaults, never remove or retype a field, never tighten a constraint. Breaking changes require a new topic `v(N+1)` and a dual-publish migration window; consumers cut over before the old topic is retired by ARB sign-off.

**WHY.** A nation-scale, polyglot estate (five languages, ADR-011) cannot coordinate lock-step deploys. Registry-enforced backward compatibility lets producers and consumers evolve independently — the core promise of ADR-010. CI fails any merge whose schema diff violates the compatibility rule, so the guarantee is mechanical, not aspirational.

**Alternatives compared.** *Forward* compatibility (new consumers reading old events) is necessary too and is satisfied by the same additive-only discipline plus required-field stability; we therefore mandate **full** compatibility within a major. *No registry / schema-in-payload* was rejected: it pushes validation to runtime and hides breakage until production. *Breaking changes by field-reuse* was rejected because silent retypes corrupt replay of historical events.

### 8.5 Per-Aggregate Ordering Keys

**Rule.** The partition/message key is the **aggregate instance ID** — `PPID` (party), `WLT` (wallet), `TXN` (transaction), and the equivalent per context. This guarantees total order **per aggregate**, which is the only ordering the domain requires.

**WHY.** Custody (R1) and Finance (R2) are correct only if all events for one wallet or one transaction are observed in production order; cross-wallet ordering is irrelevant and would needlessly serialize the whole system. Keying by aggregate ID gives exactly the ordering guarantee the invariants need while preserving horizontal scale across keys.

**Alternative rejected.** A single global-order partition was rejected: it caps throughput at one partition and cannot serve nation-scale volume. Random/round-robin keying was rejected because it breaks per-aggregate causality and makes event-sourced rebuilds (Custody) non-deterministic.

### 8.6 Transactional Outbox and Inbox Idempotency

**Rule.** Producers write domain state and the outgoing event in **one local transaction** (transactional OUTBOX); a relay publishes from the outbox. Consumers maintain an **INBOX** keyed by `eventId`/idempotency-key and process each event at-most-once *effectively*, discarding duplicates. Every unsafe/money/custody write also carries an `idempotency-key` (SA convention).

**WHY.** Dual-writes (DB then broker, non-atomic) are the classic source of lost or phantom events. The outbox makes "state changed ⇔ event emitted" atomic; the inbox makes redelivery harmless. Together they deliver **exactly-once-effective** semantics on top of an at-least-once transport (see 8.10), which is mandatory for Finance exactly-once (R2) and Custody integrity (R1).

**Alternative rejected.** Distributed two-phase commit across DB and broker was rejected: it couples availability of two systems, performs poorly at scale, and is unsupported by the Kafka-class spine. Best-effort fire-and-forget was rejected outright for any money/custody path.

### 8.7 DLQ and Per-Key Park-and-Freeze

**Rule.** Each topic has a dedicated **DLQ**; consumers use **retry-with-backoff** for transient faults. A **poison** message (deterministically failing) triggers **per-key park-and-freeze** (Ch.27.5): the offending aggregate key is parked and its ordered stream frozen, while other keys on the same topic continue.

**WHY.** Global pause-on-poison would halt an entire context for one bad record — unacceptable at nation scale. Skip-and-continue would silently violate per-aggregate ordering (8.5) and risk financial corruption. Park-and-freeze contains the blast radius to a single aggregate, preserves ordering for that aggregate, and surfaces an operator action — the explicit Ch.27.5 remediation.

### 8.8 Correlation, Causation, and Offline-Boundary Token

**Rule.** Every event header carries `correlationId` (constant across a business flow), `causationId` (the immediate triggering message), and — for events originating from offline/USSD/SMS/IVR paths (R8) — an **offline-boundary token** marking the sync boundary and original capture time.

**WHY.** Correlation/causation give end-to-end lineage across the polyglot estate and feed OpenTelemetry tracing and SLO attribution (money/custody strictest). The offline-boundary token lets consumers distinguish real-time from reconciled-after-the-fact events and apply the right conflict-resolution and freshness rules, satisfying the offline-first parity mandate (R8) without ambiguous timestamps.

### 8.9 Retention and Compaction Policy

| Stream type | Policy | WHY / Trace |
|---|---|---|
| Fact/event streams (custody, finance, orders) | Long-retention, append-only, no compaction | Replay and audit reconstruction (R6 audit sink, R1 event sourcing). |
| State/snapshot topics (master-data projections) | Log-compacted, keep latest per key | R7 OHS master-data needs current state, not full history. |
| Audit OHS sink | Immutable, regulatory-horizon retention | R6 append-only audit; Government read-mostly (R5). |
| DLQ | Bounded retention + alerting | Operational, not a system of record. |

**WHY.** One-size retention either bankrupts storage (infinite everything) or destroys auditability (aggressive deletion). Differentiating fact streams from state topics matches each topic's purpose and keeps cost governance (Ch.27.8) honest.

### 8.10 Exactly-Once-Effective vs At-Least-Once

**Rule.** The transport delivers **at-least-once**. The platform achieves **exactly-once-effective** application semantics via outbox + inbox idempotency (8.6) plus per-aggregate ordering (8.5). Money and custody paths MUST be exactly-once-effective (R1, R2); analytics/notification consumers MAY operate at at-least-once if idempotent.

**Alternatives compared.** Broker-native exactly-once (transactional producer/consumer) is used as a *defense-in-depth* layer but is **not** trusted as the sole guarantee, because it does not span the producer's own database write — only the outbox does. At-most-once delivery was rejected everywhere: dropping a custody or payout event is unrecoverable. The chosen model gives the strongest guarantee the domain needs while staying within the Kafka-class spine's real capabilities.

### 8.11 Event Style Per Context (Compared and Justified)

| Context | Dominant style | WHY |
|---|---|---|
| #3 Custody, #5 Inventory/NIL | **Event-sourcing** | R1 sole-writer event-sourced store; state *is* the event log. |
| #4 Provenance/Recall | **Event-carried state transfer** | Recall consumers must trace lineage offline without round-trips to source. |
| #8 Finance | **Event-notification** (thin) + reconciler | R2 isolation forbids leaking financial state; consumers pull authoritative figures from Finance. |
| #1 Identity, #2 Catalog | **Notification + compacted state** | R7 OHS master-data: thin change events plus compacted current-state topic. |
| #6 B2C, #7 B2B, #9 Logistics | **Event-carried state transfer** | Cross-context choreography (escrow saga R3) needs enough payload to act without synchronous coupling. |
| #10 Fraud, #12 Analytics | **Event-carried state transfer** (consume-only) | Need rich features; must stay decoupled (Fraud⟂Analytics §17.4). |

**Trade-off stated.** Event-carried state transfer increases payload size and duplication but removes synchronous coupling; event-notification minimizes payload and coupling-surface but adds a read-back round-trip. We assign each style where its trade-off matches the context's invariants — never a single global choice — because Custody's correctness, Finance's isolation, and choreography's autonomy have genuinely different needs. All three styles still obey 8.1–8.10 uniformly.

---

## 9. Logging, Observability, Metrics & Tracing Standards

This chapter is binding on every service, BFF, gateway, worker, and offline node across all 13 contexts. Observability is not a post-incident afterthought; it is the evidentiary substrate that proves custody integrity (R1), settlement exactly-once (R2), four-eyes enforcement (R4), and offline/USSD parity (R8). At nation scale, a blind service is an unrecoverable service. We therefore standardize signal shape, naming, retention, and SLO governance, and we reject team-local conventions. Traceability: SA OpenTelemetry + SLO conventions, R6 (no-PII OHS audit sink, no cross-store), Ch.27.8 (tracing across offline boundary, cost+lint), Roadmap ORR gating.

### 9.1 Why Standardize (and Why Ad-Hoc Is Rejected)

DOKANDAR spans five languages and ten teams (ADR-011). A money saga (R3 escrow) hops Commerce → Finance → Custody → Logistics; a recall hops Provenance Graph → Inventory → B2C. If each team picks its own field names, log levels, and trace propagation, no operator can follow a single transaction across the seam where incidents actually occur.

| Option | Description | Verdict |
|---|---|---|
| **A. Ad-hoc per team** | Each team logs/metrics as it sees fit | **Rejected** — cross-context correlation impossible; PII leakage uncontrolled; ORR un-auditable |
| **B. Shared library, per-team schema** | Common SDK, free-form fields | **Rejected** — divergent field names defeat fleet-wide queries and alerting; partial gain only |
| **C. Mandated contract + per-language adapters** | One signal contract, OTel semantic conventions, thin per-language emitters | **CHOSEN** — uniform query surface, single PII policy, ORR-gateable, polyglot-tolerant |

We choose C: a **single observability contract** with five conformant emitter libraries (one per language), centrally governed like the polyglot cap itself. The contract is versioned and backward-compatible; emitters are owned by Platform/SRE, consumed by all.

### 9.2 Roadmap Item 21 — Structured Logging Standard

**Rule L-1 — Structured JSON only.** Every log line is a single structured JSON object emitted to stdout; the platform collector ships it. No free-text, no multi-line stack-as-text. **WHY:** machine-parseable logs are queryable fleet-wide; multi-line text breaks ingestion and correlation. **Rejected:** plaintext/syslog formats (un-queryable at scale); per-service log files (lost on ephemeral compute).

**Rule L-2 — Mandatory envelope fields.** Every line carries: `timestamp` (RFC3339, UTC), `level`, `service`, `context` (1–13), `version`, `trace_id`, `span_id`, `correlation_id`, `tenant_scope`, `message`, `event_code`. Money/custody lines additionally carry `idempotency_key`, `aggregate_id` (PPID/WLT/TXN), and `saga_id` where applicable. **WHY:** these are the join keys that stitch a request across contexts and to its trace; `event_code` enables stable alerting independent of message wording.

**Rule L-3 — Level discipline.** Levels are fixed and meaningful:

| Level | Meaning | Example trigger |
|---|---|---|
| ERROR | Action failed, needs attention/SLO impact | outbox publish failed, saga compensation triggered |
| WARN | Degraded but handled | retry-with-backoff invoked, DLQ park-and-freeze |
| INFO | Business-significant state change | escrow opened, custody event appended, payout cooling-off started |
| DEBUG | Engineering diagnostics | off by default in prod, sampled on demand |

**WHY:** consistent levels let SRE alert on ERROR rate uniformly. **Rejected:** TRACE/FATAL/custom levels — fragment alerting thresholds.

**Rule L-4 — Correlation propagation.** `correlation_id` is minted at the edge (gateway/BFF) or at the offline node, and propagated unchanged through every gRPC OHS hop, every event (in headers), and every saga step. Events additionally carry `causation_id` (the message that caused this one). **WHY:** R3 sagas and R6 event flows are multi-hop and async; without an immutable correlation key, an operator cannot reconstruct a settlement or recall. Trace IDs alone are insufficient because async event consumption starts new traces (see §9.5).

**Rule L-5 — NO PII in logs (R6, non-negotiable).** Logs MUST NOT contain NID numbers, full names, phone numbers, addresses, KYC document content, raw pan/account identifiers, or geolocation. Use opaque surrogate keys (hashed/tokenized identifiers issued by Identity OHS). A PII-detection linter runs in CI (Ch.27.8 lint mandate) and at the collector as defense-in-depth; a positive match **fails the build** and quarantines the line at ingest.

| Approach | Verdict |
|---|---|
| Log PII then redact downstream | **Rejected** — PII already at rest in transit/buffers; violates R6 and BD data-residency |
| Allow PII at DEBUG only | **Rejected** — DEBUG can be enabled in prod; no safe tier exists |
| **Surrogate keys + CI/collector lint** | **CHOSEN** — PII never enters the log plane |

**WHY:** R6 mandates the audit sink be append-only and PII-clean, and Bangladesh data-protection posture forbids dispersing citizen identifiers across operational stores. Surrogate keys preserve debuggability without exposure.

**Rule L-6 — In-country retention & residency.** All logs, metrics, and traces are stored within the sovereign landing zone (Roadmap item 0). Hot retention 30 days (operational), warm 90 days, the R6 append-only **audit sink** retained per regulatory minimum (multi-year, immutable, WORM-class). **WHY:** sovereignty and audit obligations (Government context #11, Finance #8) require evidence to survive long after operational logs expire; separating operational from audit retention controls cost (Ch.27.8) while preserving compliance.

### 9.3 Roadmap Item 22 — Observability Golden Signals (ORR Gate)

**Rule O-1 — Every service emits the golden-signal set before ORR.** No service is admitted to production (Operational Readiness Review) until it emits, conformantly: structured logs (§9.2), RED metrics, USE metrics, distributed traces, health/readiness signals, and its declared business SLIs (§9.4). **WHY:** ORR is the enforcement point; a service that cannot be observed cannot be operated, paged on, or safely promoted in the Roadmap build order. This makes observability a **release gate**, not a courtesy.

**Rule O-2 — Golden signals defined.**

| Signal class | Metrics | Applies to |
|---|---|---|
| **RED** (request-driven) | Rate, Errors, Duration (latency histogram) | All sync services, gateway, BFFs, gRPC OHS |
| **USE** (resource) | Utilization, Saturation, Errors | CPU, memory, connection pools, Kafka consumer lag |
| **Stream health** | consumer lag, DLQ depth, park-and-freeze count, outbox backlog, inbox dedupe rate | All event consumers/producers (R6) |
| **Saga health** | open/compensating/stuck counts, step latency | R3 escrow, recall, payout sagas |

**WHY RED+USE together:** RED captures user-facing symptom (is the service serving?); USE captures cause (is it resourced?). One without the other forces guesswork during incidents. **Rejected:** RED-only — blind to saturation that precedes outage; USE-only — blind to user pain.

### 9.4 Roadmap Item 23 — Metrics & Business SLIs

**Rule M-1 — One metrics convention, labeled by context/aggregate.** Metric names follow `dokandar_<context>_<subject>_<unit>` with bounded label sets (`context`, `service`, `outcome`, `aggregate_type`). **WHY:** uniform naming enables one dashboard template per concern across all teams; bounded labels prevent cardinality explosion (a leading cost driver — Ch.27.8). **Rejected:** unbounded labels (e.g., raw IDs as labels) — cardinality blowup, cost and query collapse.

**Rule M-2 — Mandatory business SLIs.** Beyond RED/USE, these business-truth SLIs are required and feed SLOs:

| Business SLI | Definition | Owning context | Why it exists |
|---|---|---|---|
| **Settlement correctness** | reconciled-exactly-once txns ÷ total; target 100% | Finance #8 (R2) | Exactly-once + reconciler is the financial guarantee; any drift is a sev-1 |
| **Custody append integrity** | rejected/duplicate custody writes; target 0 | Custody #3 (R1) | Sole-writer event-sourcing must never double-append |
| **Projection lag** | event-time → read-model-visible latency | All CQRS read models | Stale projections mislead operators and customers; bounds eventual consistency |
| **QR-resolve-2G** | p95 catalog/provenance QR resolution over 2G | Catalog #2 / Provenance #4 | R8 field reality — resolution must be usable on degraded networks |
| **Offline-sync convergence** | queued-offline-op → reconciled latency & conflict rate | offline-sync-gateway (R8) | Parity guarantee depends on bounded, observable convergence |
| **USSD/SMS/IVR parity** | success rate of channel-equivalent flows | EDGE (R8) | Non-smartphone users are first-class; parity must be measured, not assumed |

**WHY business SLIs at all:** RED tells us a request returned 200; it does not tell us money settled correctly or that a 2G shopper could read a QR. Technical green with business red is the failure mode we most fear at nation scale. **Rejected:** infra-only SLIs — they would let a correctly-shaped-but-wrong settlement pass unobserved.

### 9.5 Roadmap Item 24 — Distributed Tracing (OpenTelemetry)

**Rule T-1 — OpenTelemetry is the single tracing standard.** All five languages instrument via OTel SDKs exporting through the OTel Collector in-country. **WHY:** OTel is the only vendor-neutral, polyglot-complete standard; it lets us swap backends without re-instrumenting and is mandated by SA. **Rejected:** vendor-proprietary agents (lock-in, incomplete language coverage); bespoke trace headers (would not interoperate across our five runtimes).

**Rule T-2 — W3C Trace Context propagation everywhere.** `traceparent`/`tracestate` propagate across gateway → BFF → gRPC OHS hops, and `trace_id` is recorded in **every event header**. **WHY:** uniform propagation is what makes a cross-context saga visible as one trace; W3C is the interoperable wire format across SDKs.

**Rule T-3 — Async/saga continuity via span links.** When a service consumes an event (async, R6), it starts a new trace but attaches a **span link** to the producing span using the carried `trace_id`/`causation_id`. **WHY:** a single synchronous trace cannot span Kafka-class async boundaries without becoming unbounded; span links preserve the causal chain across the outbox→topic→inbox seam while keeping each consumer trace bounded. **Rejected:** forcing one giant trace across all hops (unbounded, sampling-hostile); relying on logs alone for async causality (loses span timing).

**Rule T-4 — Offline-boundary tracing (Ch.27.8).** Operations created offline mint a **provisional trace/correlation id** on-device. On sync, the offline-sync-gateway opens a server span **linked** to the provisional id, recording `offline_origin=true` and the client-side queue time. **WHY:** R8 offline-first means causally-significant work happens before the server ever sees it; without explicit linkage, sync-time anomalies (conflicts, replays) are un-diagnosable. Ch.27.8 specifically requires tracing to survive the offline boundary.

**Rule T-5 — Sampling policy.** Tail-based sampling at the Collector: **100% retention** for money (#8), custody (#3), four-eyes (R4), and all error/saga-compensation traces; head/probabilistic sampling (low rate) for high-volume read paths (e.g., catalog browse). **WHY:** financial and custody traces are evidence and must never be sampled away; read-path volume would otherwise dominate cost (Ch.27.8). **Rejected:** uniform sampling (drops critical money traces) and 100%-everything (cost-prohibitive at nation scale).

### 9.6 SLO & Error-Budget Framework — What Gates Release Velocity

**Rule S-1 — Tiered SLOs, money/custody strictest.** Every service declares SLOs in a versioned, reviewed manifest; tiers set minimum targets:

| Tier | Contexts | Availability / Latency floor | Correctness |
|---|---|---|---|
| **Tier-0 Critical** | Custody #3, Finance #8, Identity #1 | Highest availability, strict p99 latency, RPO=0 (Ch.27.2) | 100% — zero tolerance for settlement/custody error |
| **Tier-1 Core** | Catalog #2, Inventory #5, B2C #6, B2B #7, Logistics #9 | High availability, p95 bounded incl. QR-2G SLI | High |
| **Tier-2 Supporting** | Fraud #10, Government #11 (read-mostly R5), Analytics #12, Platform #13 | Standard | Standard |

**WHY tiering:** uniform SLOs would either over-spend on analytics or under-protect money. Strictest budgets follow the strictest guarantees (R1, R2). **Rejected:** flat SLO for all (mis-allocates reliability investment).

**Rule S-2 — Error budgets gate velocity.** Each SLO implies an error budget. Policy:

```text
budget healthy   → normal release cadence
budget < 50% left → heightened review; risky changes deferred
budget exhausted  → release FREEZE on that service (reliability work only)
                    until budget recovers; exception requires VP Eng sign-off
Tier-0 breach     → automatic incident (Ch.27.7 runbook) + four-eyes change control
```

**WHY:** the error budget is the objective arbiter between feature velocity and reliability; it removes argument by tying the right to ship to demonstrated stability. **Rejected:** velocity-at-all-costs (erodes the custody/settlement guarantees the platform exists to protect); reliability-at-all-costs (stalls the Roadmap). The budget is the negotiated middle, enforced automatically.

**Rule S-3 — Alerting on symptoms, burn-rate based.** Page on **SLO burn rate** (fast-burn → page now; slow-burn → ticket) and on business-SLI breach (settlement correctness, custody integrity), not on raw CPU. **WHY:** symptom-based, multi-window burn alerts cut false pages while catching real degradation early; resource alerts belong on dashboards, not pagers. **Rejected:** threshold-on-everything (alert fatigue, the leading cause of missed real incidents).

**Closing standard:** observability artifacts — log conformance, golden signals, business SLIs, trace propagation, and the SLO manifest with its error-budget policy — are **ORR entry criteria**. A service missing any one is not production-eligible, regardless of feature completeness. This is how DOKANDAR keeps a nation-scale, polyglot, event-driven, offline-first platform operable, auditable, and honest about the difference between "served a response" and "did the right thing."

---

## 10. Configuration, Secrets & Feature Flags

This chapter binds how DOKANDAR externalizes configuration, custodies secrets, and gates behaviour with flags. The governing premise: **the binary is immutable and identical across every environment; behaviour is determined by inputs supplied at runtime**. This is non-negotiable because nation-scale operation (13 contexts, 5 languages, 12 phases) cannot tolerate per-environment rebuilds, secret leakage, or un-killable autonomous actions. Every rule below traces to a CANON rule, SA convention, or Ch.27 remediation.

### 10.1 Configuration Management (Roadmap Item 25)

#### 10.1.1 The Config-over-Code Standard

**Rule C-1 — No business-affecting constant is compiled in.** All thresholds, limits, TTLs, timeouts, retry/backoff parameters, cooling-off windows (Ch.27.4), fencing tokens scope (Ch.27.1), pagination caps, and SLO targets are externalized as named configuration keys resolved at runtime.

**WHY.** BR-001..040 and FR-* will be tuned operationally (e.g., escrow R3 hold durations, fraud R4 score cut-offs, payout cooling-off). A compiled constant forces a full build → review → ORR → deploy cycle for a number change — unacceptable when a fraud wave or liquidity event demands a minute-scale response. Externalization makes the change a governed config edit, not a code release.

**Boundary rule C-2 — Config tunes; it never encodes business rules.** Configuration may set *the value of* a threshold the BA already mandates; it may **never** introduce a rule the BA does not define, nor switch a context's invariant (R1 sole-writer, R2 isolation, money=integer poisha). Those are structural and live in code under ARB control. This preserves the CANON prohibition on inventing business rules: a misconfigured value is a bad number, never a new behaviour.

#### 10.1.2 Configuration Taxonomy

| Tier | Example keys | Mutability | Change path |
|------|--------------|------------|-------------|
| **Build constants** | language runtime, framework major version | Immutable post-build | Code + ADR-011 review |
| **Environment binding** | endpoint hostnames, topic prefixes, partition counts | Per-env, deploy-time | GitOps PR + ORR |
| **Operational tunables** | TTLs, retry/backoff, rate limits, cooling-off windows | Runtime, no redeploy | Config-service change + four-eyes |
| **Feature flags** | release/ops toggles, kill-switches | Runtime, fast | §10.3 governance |
| **Secrets** | keys, tokens, signing material | Runtime, brokered | §10.2, never in config store |

**WHY the split:** different change velocities demand different control planes. Conflating deploy-time bindings with second-scale operational tuning either makes safe changes slow or makes dangerous changes too easy. Secrets are carved out entirely because their threat model (confidentiality, rotation) differs categorically from configuration (correctness, auditability).

#### 10.1.3 Distribution Mechanism — Compared and Decided

| Approach | Strength | Why rejected (as sole mechanism) |
|----------|----------|----------------------------------|
| **Env vars / baked files only** | Simple, zero runtime dependency | Change requires pod restart/redeploy → violates C-1 "change-without-redeploy"; no live audit of who changed what; drift between replicas during rollout |
| **Dynamic config service only** | Live updates, central audit, targeting | A runtime dependency in the request path; an outage could destabilize all 13 contexts; weaker peer-review than Git |
| **GitOps-declared config (chosen baseline) + config service for live tunables** | Git = reviewable, versioned, four-eyes-native source of truth; service = low-latency live delivery | Two planes to operate — accepted cost |

**Decision (Rule C-3): GitOps is the system of record; a config service is the delivery cache.** Every operational tunable and environment binding is declared in a Git repository, peer-reviewed, and reconciled outward. A read-optimized config service (or equivalent dynamic store) delivers values to services with a bounded refresh and push-on-change, so tunables update **without redeploy** while every change remains a reviewed, attributable Git commit.

**WHY this hybrid:** it satisfies C-1 (live change) *and* the CANON audit/governance posture (R6 append-only audit ethos, R4 four-eyes for sensitive change) without putting an un-reviewed mutable store on the critical path. GitOps gives us rollback-by-revert and a tamper-evident history; the service gives us latency. Pure env-vars fails velocity; pure config-service fails governance and adds a fragile dependency.

**Rule C-4 — Fail-safe resolution.** Each service ships a **last-known-good** cached snapshot and a compiled **safe-default** for every key. If the config service is unreachable, the service runs on cache, then defaults, and emits a health-degraded signal — it never fails startup or requests on config-fetch error. **WHY:** R8 offline-first and R5 government read-mostly mean availability cannot hinge on a config control plane; an SLO-strict context (money/custody) must keep serving with the last validated values.

**Rule C-5 — Schema-validated, typed, per-env.** Every config key has a registered schema (type, range, unit — poisha for money, milliseconds for durations) validated at PR time and again at service load. Out-of-range or unparseable values are rejected, not coerced. **WHY:** CANON input-validation at boundaries; a fat-fingered cooling-off window of `0` must be caught by schema, not discovered in production. Per-env declaration prevents a sandbox value leaking to production.

**Rule C-6 — Finance config isolation (R2).** Finance (#8) configuration lives in its **own repository and its own config-service partition**, written and reviewed only by Finance team members, never co-resident with operational config. **WHY:** R2 mandates no shared infrastructure and the NEVER-SAME-TEAM rule isolates Finance from all; a shared config plane would be a shared blast-radius and a segregation-of-duties breach.

### 10.2 Secret Management (Roadmap Item 26, Ch.27.8)

#### 10.2.1 Core Prohibitions

**Rule S-1 — Zero secrets in repositories, images, logs, or config stores.** No credential, key, token, connection string, or signing material appears in source, container images, GitOps config, environment manifests, or telemetry. Enforced by CI secret-scanning (pre-commit + pipeline gate, Ch.27.8 lint) that **blocks** merge on detection, and by log-redaction filters at the logging boundary.

**WHY:** a secret in a repo is permanently compromised (history is forever) and a secret in an image ships to every node. The CANON security mandate ("NEVER hardcode secrets") and Ch.27.8 rotation discipline are meaningless if secrets are statically embedded. Scanning must block, not warn — a warned-past leak is still a leak.

#### 10.2.2 Brokered Delivery & Per-Service Identity

**Rule S-2 — KMS-brokered, identity-scoped delivery.** Secrets are stored in a managed KMS/secret broker and delivered at runtime to a workload authenticated by its **own service identity** (mTLS workload identity, per SA conventions). Each service receives **only** the secrets its role grants — least privilege, no shared "platform" credential.

| Alternative | Why rejected |
|-------------|--------------|
| Secrets as env vars injected at deploy | Visible in process inspection/orchestrator metadata; rotation needs redeploy; broad blast radius |
| Shared secret bundle per cluster | Violates least privilege; one compromised pod exposes all contexts |
| **Per-service KMS broker lease (chosen)** | Scoped, rotatable in place, audited per-access — accepted operational complexity |

**WHY chosen:** brokered short-lived leases mean a secret can be rotated centrally and revoked per-identity, and every access is logged — aligning with OAuth2/OIDC + mTLS + RBAC/ABAC PDP conventions and the audit ethos of R6.

**Rule S-3 — HSM-resident signing keys, never exported.** Cryptographic signing material (custodial co-sign Ch.27.3, government attestation #11, event/audit signing) is generated and used **inside an HSM**; private keys never leave the boundary — services request signatures, not keys. **WHY:** custody (R1) and the RPO=0 / co-sign remediations (27.2, 27.3) make signing keys the crown jewels; an exportable key defeats four-eyes and non-repudiation.

#### 10.2.3 Rotation Cadence (Ch.27.8)

| Secret class | Max lifetime | Trigger-based rotation |
|--------------|--------------|------------------------|
| Service credentials / API tokens | 90 days | On role change, on suspected compromise |
| mTLS workload certs | Short-lived (hours–days), auto-renewed | On identity revocation |
| JWT signing keys | Overlapping rotation, dual-active window | On compromise (immediate) |
| HSM signing keys (custody/gov) | Defined cadence + overlap | Co-sign quorum change, incident |
| Database/Finance partition creds | 90 days, R2-isolated | Finance team only |

**Rule S-4 — Rotation is overlap-based and automated.** New material is activated alongside old (dual-active window) before the old is retired, so no request fails mid-rotation. **WHY:** big-bang rotation causes outages on SLO-strict money/custody paths; overlap honours both Ch.27.8 cadence and availability. **Rule S-5 — Finance secrets rotate on a separate schedule, owned solely by Finance (R2).**

### 10.3 Feature Flag Strategy (Roadmap Item 27)

#### 10.3.1 Flag Taxonomy

| Flag type | Purpose | Lifetime | Owner |
|-----------|---------|----------|-------|
| **Release flag** | Decouple deploy from release; progressive rollout per phase/region | Temporary — removed after full rollout | Owning context team |
| **Ops flag** | Operational dial: degrade gracefully, shed load, toggle non-critical paths | Long-lived | Owning team + SRE |
| **Kill-switch** | Hard stop of an autonomous/sensitive capability | Permanent | Owning team + Risk/Finance, four-eyes |
| **Permission/entitlement flag** | Gate access by KYC tier, region, channel (R8 USSD/SMS/IVR parity) | Long-lived | Identity/owning team |

**Rule F-1 — Flags are evaluated server-side, default-off, and audited.** Every flag defaults to its **safe state** (off / least-capable) and every change is recorded as an attributable, append-only event (R6 audit sink). **WHY:** a flag whose default is "on" fails open during a config outage; default-off means a missing flag never silently enables an untested or dangerous path. Client-side evaluation would leak unreleased behaviour and bypass governance — rejected.

**Rule F-2 — Flags decouple deploy from release.** New code ships dark behind a release flag, enabling trunk-based flow and per-phase Roadmap rollout (spine → Identity/Catalog → Custody → Finance(gated) → …). **WHY:** the gated build order demands that Finance and downstream contexts deploy code before they are switched live; flags make "deployed" and "active" independent and reversible.

**Rule F-3 — Flags never carry business rules; release flags are debt.** A flag chooses *between existing, reviewed behaviours*; it never encodes a new rule (preserves CANON). Every release flag has a removal ticket and an expiry; stale flags are a governed cleanup obligation. **WHY:** long-lived release flags create combinatorial untested states and hidden logic — the antithesis of KISS.

#### 10.3.2 Kill-Switches for the Autonomous Set

**Rule F-4 — Every autonomous Finance (#8) and Fraud (#10) capability has a mandatory, independently-governed kill-switch.** Autonomous payouts, escrow saga progression (R3), and automated fraud enforcement actions (R4) must each be haltable by a flag whose flip requires **four-eyes** (R4) and is owned by the respective team plus Risk — never by Platform alone (NEVER-SAME-TEAM, §17.4).

**WHY:** autonomous money movement and automated enforcement are the highest-blast-radius actions in the platform. Ch.27.4 (payout cooling-off) and R4 (four-eyes) establish that these flows must be *stoppable by humans under control*. A kill-switch is the last line of defence against a runaway automated loop or a fraud-model failure mass-actioning legitimate users.

**Rule F-5 — Kill-switch flip is fail-safe and instant.** Flip propagates on the push channel with the tightest bound; if propagation is uncertain, the capability **self-disables** on stale-config detection. **Rule F-6 — Finance kill-switches live in the R2-isolated config partition** and are governed solely by Finance + Risk, never co-located with operational ops flags. **WHY:** R2 isolation and segregation of duties extend to the control surface, not just the data.

#### 10.3.3 Governance Summary

| Concern | Standard | Trace |
|---------|----------|-------|
| Source of truth | GitOps PR, peer-reviewed | C-3, R6 |
| Sensitive flag change | Four-eyes approval | F-4, R4 |
| Default behaviour | Safe / off | F-1 |
| Auditability | Append-only change events | R6 |
| Finance/Risk separation | Isolated partition, team-owned | F-6, R2, §17.4 |
| Lifecycle | Expiry + removal for release flags | F-3 |

These standards make DOKANDAR's behaviour tunable at operational speed, its secrets unleakable by construction, and its most dangerous automated actions reversible by governed human action — without ever rebuilding a binary or inventing a business rule.

---

## 11. Environment & Local Development Standards

This chapter binds how DOKANDAR engineers provision environments, run services on a laptop, and build container images. It realizes Roadmap items 28–30 and SA Ch.27 remediations without prescribing artifacts: it states the **standard** and **how it is enforced**, never the Dockerfile, manifest, or Terraform. Every rule traces to the Business Architecture (BA), Service Architecture (SA), ADRs, or design rules R1–R8. Sovereignty (national hosting of all citizen/commerce/money/custody data) is the non-negotiable axis that shapes every decision below.

### 11.1 Environment Strategy (Roadmap Item 28)

#### 11.1.1 The tier ladder

DOKANDAR runs a **fixed four-tier ladder**. No team may invent a fifth standing tier; ephemeral previews (11.1.3) are the only sanctioned addition, and they are constrained.

| Tier | Purpose | Data class | Sovereignty | Lifetime |
|------|---------|-----------|-------------|----------|
| `dev` | Inner loop, integration of a single team's changes | Synthetic only | National landing zone or local | Continuous |
| `staging` | **Sovereign prod-like** pre-production; ORR rehearsal, chaos, restore drills | Synthetic + masked-shape, never real money/custody | National, prod-identical topology | Continuous |
| `prod` | Live citizen/commerce/money/custody traffic | Real, classified | National sovereign region | Permanent |
| `pr-preview` | Ephemeral per-PR validation of **edge/commerce only** | Synthetic only | National | Hours, auto-destroyed |

**WHY a fixed ladder.** The Roadmap build order (landing zone → spine → Identity/Catalog → Custody/Inventory → Finance gated → …) presumes every context promotes through identical gates. Divergent per-team tiers would make the gates non-comparable and break the ORR (Ch.27.6/27.7) evidence chain. A small, named set keeps cost (Ch.27.8) bounded and audit (R6 append-only) coherent.

#### 11.1.2 Staging must be sovereign and prod-like — and why we reject the alternatives

**Standard.** `staging` runs in the **same national sovereign region** as `prod`, with the same network segmentation, the same Finance isolation boundary (R2: separate repo, no shared DB), the same custody sole-writer topology (R1), the same spine (R6), the same PDP/mTLS/OIDC posture, and the same KMS/HSM rotation cadences (Ch.27.8). It differs from `prod` only in scale and in carrying **no real data**.

**WHY.** The strictest SLOs (money/custody) and the hardest remediations — fencing (27.1), RPO=0 quorum (27.2), custodial co-sign (27.3), payout cooling-off (27.4) — are failure-mode behaviours that only surface under prod-identical topology. A staging tier that is cheaper-shaped would "pass" while masking the exact quorum, fencing, and saga-timeout defects ORR exists to catch. Prod-parity is what makes a staging green a credible prod prediction.

| Alternative for staging | Verdict | Why rejected |
|---|---|---|
| **Foreign-region / hyperscaler test env** | **REJECTED** | Violates sovereignty: even synthetic-seeded envs accrete masked-shape data, schemas, and topology that reveal citizen-scale design; cross-border egress of any DOKANDAR data shape is disallowed. Latency/topology also diverge from the national landing zone, invalidating SLO rehearsal. |
| **Scaled-down "staging-lite" (shared DB, no Finance isolation)** | **REJECTED** | Breaks R2 and R1; cannot rehearse exactly-once reconciliation or custody fencing; ORR evidence would not transfer to prod. |
| **No staging; promote dev→prod with flags** | **REJECTED** | Removes the chaos/restore/ORR rehearsal surface (Ch.27.6/27.7) for money and custody — unacceptable for a financial system of record. |
| **Sovereign + prod-like staging** | **CHOSEN** | Only option that lets ORR gates predict prod behaviour while honouring sovereignty and R1/R2. |

#### 11.1.3 Ephemeral PR previews — edge/commerce ONLY

**Standard.** Per-PR ephemeral previews are permitted **only** for edge and commerce surfaces — api-gateway, BFFs, and B2C (#6) — and are seeded with **synthetic data only**. They are **forbidden** from instantiating, connecting to, or seeding Finance (#8), Custody Ledger (#3), Provenance/Recall (#4), Inventory/NIL (#5), or Identity/KYC (#1) real data stores, per §25.6. Previews auto-destroy on PR close/merge and have a hard TTL.

**WHY.** B2C and the edge are the high-churn, UX-iterative surfaces where a disposable, shareable environment yields the most reviewer value, and they hold no money/custody/citizen records of record. Finance and Custody are isolated (R2) and sole-writer/event-sourced (R1); spinning ephemeral copies would (a) risk real-data leakage into short-lived, weakly-governed namespaces, (b) duplicate ledgers that violate the single-writer invariant, and (c) explode cost (Ch.27.8). Previews for those contexts add no UX value that staging does not already provide.

| Preview policy alternative | Verdict | Why |
|---|---|---|
| Previews for **all** contexts | REJECTED | §25.6 breach; R1/R2 violation risk; cost blow-up; real-data exposure surface. |
| **No** previews at all | REJECTED | Loses fast edge/B2C review loop; pushes UI validation onto scarce staging slots. |
| **Edge/commerce-only, synthetic, auto-destroyed** | CHOSEN | Maximal review value where it is safe; zero exposure of regulated data classes. |

**Enforcement.** Preview provisioning is gated by a context-allow-list check in CI; any preview spec referencing a forbidden context's datastore or a real-data secret scope fails the pipeline. NEVER-SAME-TEAM (§17.4) ownership of the gate (Platform owns the allow-list, not the requesting team) prevents self-exemption.

#### 11.1.4 Data classification across tiers (binding)

| Data class | dev | staging | pr-preview | prod |
|---|---|---|---|---|
| Real money / poisha ledgers | Never | Never | Never | Only |
| Custody/provenance records | Never | Never | Never | Only |
| Real KYC / citizen PII | Never | Never (masked-shape ok) | Never | Only |
| Synthetic catalog/orders | Yes | Yes | Yes | n/a |

**WHY.** Real money is integer poisha and custody is event-sourced and append-only (R1, R6); a stray non-prod write against a real ledger is unrecoverable by design. The simplest safe rule is therefore categorical: **real money/custody data exists in prod and nowhere else.**

### 11.2 Local Development Standard (Roadmap Item 29)

#### 11.2.1 Run-a-service-locally contract

**Standard.** Every service MUST be runnable on an engineer's machine through one documented, idempotent bootstrap, satisfying:

- **Infra is emulated/containerized, never shared-remote.** Datastores, the event-spine, and object storage run as **local containers or in-memory fakes**. No laptop connects to a shared `dev`/`staging` datastore.
- **Spine emulation is mandatory.** Because the spine is the Published Language and append-only audit OHS sink (R6), local runs use a containerized Kafka-class broker (or an in-memory test double honouring the same envelope `{success,data,error,meta}`, topic naming `<context>.<aggregate>.<Event>.vN`, and per-aggregate ordering keys PPID/WLT/TXN).
- **DB emulation is mandatory.** Each context uses its own local store matching its prod engine family; no cross-context store sharing locally (R6 "no cross-store" holds even on a laptop).
- **No real money/custody/KYC data, ever.** Local seeds are synthetic fixtures only. Idempotency-key, outbox/inbox, and DLQ behaviours are exercised against fakes, not prod ledgers.
- **Contract-first parity.** Local stubs are generated from the same schema-registry contracts and gRPC OHS definitions as prod, so a service tested locally honours backward-compatibility-within-major rules before it reaches CI.

**WHY.** The architecture is polyglot (ADR-011, five languages) and event-driven; an engineer on Commerce (Node/TS) must exercise B2C against a faithful spine without standing up Finance (Java/Spring) or Custody (Go). Emulated infra gives deterministic, offline-capable, sovereignty-safe inner loops and keeps the laptop incapable of touching regulated data by construction. R8 (offline-first, USSD/SMS/IVR parity) further demands that services run and degrade correctly without live upstreams — local emulation is the first place that is proven.

| Local-infra alternative | Verdict | Why |
|---|---|---|
| **Shared remote dev datastore/spine** | REJECTED | Cross-engineer interference, non-determinism, and a path for real-shaped data onto laptops; breaks R6 no-cross-store discipline; unusable offline. |
| **Cloud dev sandbox per engineer** | REJECTED for default | Cost (Ch.27.8) and sovereignty exposure; slow loop; still no real-data justification. Permitted only as opt-in for heavyweight integration, synthetic-only. |
| **Containerized/in-memory local infra** | CHOSEN | Deterministic, offline, free, sovereignty-safe, contract-faithful. |

#### 11.2.2 Cross-context local integration

**Standard.** A service depends locally on **contract stubs and the emulated spine**, not on neighbouring teams' running services. To integrate two real contexts locally, engineers compose only the minimal set, each in its own emulated store, wired through the local broker. Finance and Custody are **never** auto-started by another context's bootstrap (R1/R2; §17.4 NEVER-SAME-TEAM ownership keeps boundaries honest).

**WHY.** Coupling local startup to live neighbours reintroduces the distributed-monolith failure the bounded-context design forbids; stubs keep the inner loop fast and each team independently buildable in Roadmap order.

### 11.3 Docker Development Standards (Roadmap Item 30)

These are **standards**, not Dockerfiles. They govern how images are built, named, and trusted.

#### 11.3.1 Base-image policy

| Rule | Standard | WHY |
|---|---|---|
| **Approved base set** | Images derive only from a centrally curated, per-language approved base list (one canonical base per ADR-011 language: Go, Java/Spring, C#/.NET, Python, Node/TS). | Polyglot is capped at five and centrally governed (ADR-011); an unbounded base set defeats that governance and inflates the patch surface. |
| **Provenance & signing** | Bases are pulled from the sovereign internal registry, signed, and verified at build; no direct public-registry pulls in CI/prod builds. | Supply-chain integrity; sovereignty (no build-time dependency on foreign registries); aligns with HSM/KMS trust posture (Ch.27.8). |
| **Minimal surface** | Runtime images are minimal/distroless-class, non-root, no shells/package managers in the final stage. | Smaller attack surface and image size; supports money/custody strict security posture and cost control (Ch.27.8). |
| **Pinned, digest-addressed** | Bases and dependencies are pinned by immutable digest, never floating tags. | Reproducibility; eliminates "works-on-my-build" drift across the four tiers. |

#### 11.3.2 Reproducibility & build hygiene

| Rule | Standard | WHY |
|---|---|---|
| **Deterministic builds** | Multi-stage, dependency-locked, hermetic builds; identical inputs produce identical image digests. | A money/custody system needs build-to-artifact traceability for incident forensics (Ch.27.7). |
| **No secrets in images** | Secrets are injected at runtime from KMS; never baked into layers or build args. | Mirrors §11.1.4 and the secrets standard; a leaked layer is an unrotatable exposure. |
| **SBOM + scan gate** | Every image emits an SBOM and passes vulnerability and lint gates (Ch.27.8) before promotion. | Continuous supply-chain assurance; blocks known-vuln promotion to prod. |
| **One process, parity across tiers** | The same image digest promotes dev→staging→prod; tiers differ by config/secret injection only. | Guarantees staging actually predicts prod (11.1.2); prevents rebuild-induced drift. |

**Rejected alternative — per-team free-choice base images.** REJECTED: it breaks the five-language cap (ADR-011), multiplies CVE exposure and patch toil, and makes the signed-provenance and SBOM gates inconsistent. **Chosen — centrally curated, signed, pinned, minimal bases** because it is the only policy that keeps a 13-context polyglot estate auditable, reproducible, and sovereignty-clean.

#### 11.3.3 Image naming and tier promotion pattern (illustrative text)

```text
registry.sovereign.internal/<team>/<context>-<service>@sha256:<digest>
promotion:  dev(digest D) → staging(digest D) → prod(digest D)   # same D, config differs
```

**WHY a digest-carried promotion.** Re-tagging or rebuilding between tiers would silently allow a different artifact into prod than the one ORR-rehearsed in staging — exactly the gap the prod-parity standard (11.1.2) and Ch.27 remediations exist to close.

### 11.4 Traceability

| Standard | Traces to |
|---|---|
| Four-tier ladder; ORR/chaos/restore on staging | Roadmap 28; Ch.27.6/27.7 |
| Sovereign prod-like staging; reject foreign envs | BA sovereignty; SLO posture; R1/R2 |
| Edge/commerce-only ephemeral previews | §25.6; R1/R2; Ch.27.8 |
| No real money/custody/KYC outside prod | R1, R2, R6; money=integer poisha |
| Local emulated spine + per-context store | R6, R8; ADR-011 polyglot |
| Curated/signed/pinned/minimal base images; digest promotion | ADR-011; Ch.27.8; KMS/HSM posture |

---

## 12. Testing Strategy

This chapter realizes Service-Architecture Ch.27.6 (test & chaos) as the binding verification doctrine for all 13 contexts. It governs **how we prove correctness before money moves, custody is written, or a recall fires**. Testing is not a phase; it is a CI/CD gate (§25.6) and an ORR (Operational Readiness Review) precondition. Every standard below traces to a CANON rule and is enforced mechanically — an un-enforced standard is a suggestion, and DOKANDAR does not ship on suggestions.

**Governing principle.** Test intensity scales with blast radius. Custody (R1), Finance (R2), escrow saga (R3), and recall (#4) carry the strictest gates; read-mostly Government (R5) and Analytics (#12) carry lighter ones. Uniform coverage targets across such asymmetric risk would either under-protect money or bankrupt velocity on dashboards — so we tier.

---

### 12.31 Testing Strategy (the doctrine)

| Rule | Standard | WHY | Trace |
|------|----------|-----|-------|
| T-1 | Tests are owned by the **producing team**, never a central QA silo. | A central QA team becomes a bottleneck and an accountability sink — producers stop owning quality. NEVER-SAME-TEAM (§17.4) still applies to *certification sign-off*, not authoring. | §17.4 |
| T-2 | A test suite is a **release artifact**, versioned with the service, run on every PR and every deploy. | Tests that drift from code are worse than none; coupling them to the artifact forces co-evolution. | Roadmap, §25.6 |
| T-3 | **No production money/custody/PII data** ever enters a test or ephemeral environment. Synthetic fixtures + masked generators only. | R2 isolation and KYC duty forbid leaking real ledger or identity data into lower trust tiers. | R1, R2, R6 |
| T-4 | Risk-tiered gates: **Tier-0** (Custody, Finance, Fraud co-sign) block merge on any failure; **Tier-1** (B2C, B2B, Logistics) block on contract/integration failure; **Tier-2** (Analytics, Gov read paths) block on unit/contract only. | Differentiated rigor matches blast radius; treating a dashboard like the ledger wastes the budget that should harden the ledger. | ADR-001, R5 |

**Rejected alternative — single global coverage %:** A flat "80% line coverage everywhere" optimizes a vanity metric, rewards trivial getter tests, and ignores that custody invariants need *behavioural* not *line* coverage. We reject pure line-coverage gating in favour of **mutation-score gates on Tier-0** plus journey/contract gates elsewhere (see §12.32).

---

### 12.32 Test Pyramid

We mandate a five-layer pyramid: **unit → component → contract → integration → e2e**, widest at the base.

```text
              /\         e2e (few, key journeys, §12.35)
             /  \        integration (ephemeral env, §12.34)
            /----\       contract (CDC gate, §12.33)
           /      \      component (service-in-isolation, mocked deps)
          /--------\     unit (pure logic, money math, state machines)
```

| Layer | Scope | Gate |
|-------|-------|------|
| Unit | Pure functions, poisha integer math, saga/state-machine transitions, projection reducers | Tier-0 **mutation score ≥ 80%**; others line ≥ 80% |
| Component | One service + in-memory/mocked adapters | Required all tiers |
| Contract | Spine events + gRPC OHS pacts | CI gate (§12.33) |
| Integration | Real datastore + real broker, ephemeral | §12.34 |
| E2E | Cross-context user journey | §12.35 |

**WHY a pyramid, not an ice-cream cone.** Inverting toward e2e-heavy suites yields slow, flaky pipelines that teams learn to ignore — the worst outcome for a money platform. Fast unit/component feedback (seconds) catches most defects cheaply; expensive e2e is reserved for journeys that *only* emerge across contexts.

**WHY mutation testing on Tier-0.** Line coverage proves a line *executed*, not that a wrong result would be *caught*. For poisha arithmetic and custody invariants, an undetected off-by-one is catastrophic. Mutation testing injects faults and demands the suite kill them — directly measuring fault-detection power. **Rejected:** coverage-only (cheap to game); manual review-only (non-repeatable, doesn't gate CI).

---

### 12.33 Contract Testing

**Standard:** All inter-context coupling — **spine events (R6 Published Language)** and **internal gRPC OHS (R7)** — is verified by **consumer-driven contract (CDC)** tests, enforced as a CI gate per §25.6. A producer may not merge a change that breaks a registered consumer contract.

| Rule | Standard | WHY |
|------|----------|-----|
| C-1 | Each consumer publishes a pact describing the fields/semantics it relies on. | Producers learn *actual* usage, not guessed usage; enables safe evolution. |
| C-2 | Producer CI verifies **every** consumer pact before merge; broker stores verification results. | Backward-compatibility within a major version (SA convention) becomes mechanically provable, not aspirational. |
| C-3 | Schema-registry backward-compat check runs **alongside** CDC; both must pass. | Registry catches structural breaks; CDC catches *semantic* breaks the schema permits (e.g., a field repurposed). |
| C-4 | Event contracts assert topic naming `<context>.<aggregate>.<Event>.vN` and per-aggregate ordering keys (PPID/WLT/TXN). | Ordering guarantees are part of the contract; a consumer relying on per-key order must be protected from a producer that reorders. |

**WHY CDC over provider-driven or shared integration suites.** A shared end-to-end integration suite to catch every breakage is slow, owned-by-no-one, and couples release cadences across 13 teams — violating context autonomy (ADR-001). Provider-driven contracts test what the producer *imagines* consumers need. **CDC** inverts this: real consumer expectations gate the producer, giving independent deployability with safety. We **reject** "just version everything and never coordinate" because backward-compat must be *proven*, not assumed.

---

### 12.34 Integration Testing

**Standard:** Integration tests run in **ephemeral, per-PR environments** wired to *real* infrastructure classes (real broker, real datastore engine, real cache) but **never** production money/custody/PII data (T-3). Environments are created on demand and destroyed on merge.

| Rule | Standard | WHY |
|------|----------|-----|
| I-1 | Outbox→broker→inbox flow tested end-to-end including **DLQ routing** and **retry-with-backoff**. | The transactional outbox/inbox pattern is only safe if its failure paths are exercised; untested DLQ is a silent data-loss hole. |
| I-2 | **Idempotency-key** replay test: the same unsafe/money/custody write submitted twice yields one effect. | Exactly-once (R2) and idempotency conventions are correctness-critical; duplicate payment = real loss. |
| I-3 | **Projection-rebuild** test: rebuild a read model from the event log and assert byte-equivalence with the live projection. | Event-sourced custody (R1) depends on deterministic replay; a non-replayable projection means unrecoverable divergence. |
| I-4 | Finance integration runs in its **own isolated repo/pipeline** with its own ephemeral env; no shared DB with any context. | R2 forbids shared DB; the test topology must mirror the production isolation or it tests a fiction. |
| I-5 | **Park-and-freeze (Ch.27.5)** poison-message test: a poison event freezes its key, not the partition. | Validates that one bad message cannot stall an entire aggregate stream. |

**WHY ephemeral over a shared staging environment.** A long-lived shared staging accumulates drift, hidden state, and cross-team contention — "works in staging" stops meaning anything. Ephemeral envs are reproducible, isolated, and disposable. **Rejected:** mocking all infra (misses broker/datastore semantics — the very things integration must catch); shared staging (flaky, contended, non-deterministic).

---

### 12.35 End-to-End Testing

**Standard:** E2E covers a **curated, minimal set of key user journeys** spanning contexts — not exhaustive UI permutations. Each journey is owned, named, and traced to an FR.

| Journey (illustrative) | Spans | Validates |
|------------------------|-------|-----------|
| B2C purchase + escrow release | #6→#8→#3→#9 | Escrow saga (R3), custody write (R1), delivery |
| B2B exchange order settlement | #7→#8→#3 | Exchange isolation from B2C (§17.4), settlement |
| Product recall propagation | #4→#5→#6/#7 | Provenance graph traversal, NIL update |
| **Offline order via USSD/SMS/IVR** | edge→#6→#8 | R8 channel **parity** with app path |

**WHY thin E2E.** E2E is the slowest, flakiest layer; over-investing here collapses pipeline trust. We keep it thin and **mandate R8 parity journeys** — an offline USSD order must produce the same custody/finance outcome as an app order, and only a cross-channel e2e proves it. **Rejected:** record-and-replay UI mega-suites (brittle, high-maintenance, low signal).

---

### 12.36 Performance & Load Testing

**Standard:** Every Tier-0/Tier-1 service has SLO-anchored load tests; **peak scenarios model Eid and recall at 100× baseline** (Ch.27.6).

| Rule | Standard | WHY |
|------|----------|-----|
| P-1 | Load profiles: steady, **Eid surge (100×)**, **recall fan-out (100×)**, soak (24h). | These are the real tail events; capacity proven only at average load fails when it matters most. |
| P-2 | Pass/fail bound to **published SLOs**; money/custody carry the strictest latency/error budgets. | An SLO without a load test that exercises it is undefended. |
| P-3 | Tests assert **graceful degradation** (load-shed, queue depth, backpressure), not just throughput. | At 100× the question is *how* we fail, not *whether* — uncontrolled failure cascades. |

**Rejected:** production-only observation (waiting for Eid to learn we're undersized is negligence); single-shot benchmarks (miss soak-induced leaks and queue growth).

---

### 12.37 Security Testing

**Standard:** Layered, automated, and gated — **SAST + dependency/secret scan on every PR; DAST on every deploy to integration; periodic external penetration tests** before Finance/Government go-live and on a fixed cadence thereafter.

| Layer | Trigger | Blocks |
|-------|---------|--------|
| SAST + lint (Ch.27.8) | Every PR | Tier-0 on any high finding |
| Secret/dependency scan | Every PR | All tiers on exposed secret |
| DAST | Deploy to ephemeral integration | Auth/authz, injection, OWASP Top-10 |
| Pen test (external) | Pre-go-live + cadence | Finance, Identity/KYC, Government |
| **Four-eyes & co-sign tests** | Per PR (Fraud, Custody) | Tier-0 |

Security tests must assert the **PDP (RBAC/ABAC) deny-by-default**, **four-eyes (R4)** cannot be bypassed by a single actor, **custodial co-sign (Ch.27.3)** requires two parties, and **payout cooling-off (Ch.27.4)** delays cannot be skipped. **WHY automate + pen-test both:** automation gives breadth and repeatability every PR; human pen-testers find logic and chained flaws scanners miss. Neither alone suffices. **Rejected:** annual-audit-only (too slow for continuous delivery); scanner-only (misses business-logic abuse like four-eyes circumvention).

---

### 12.x Chaos & Resilience Testing

**Standard:** Game-day chaos validates the Ch.27 remediations as *tested behaviours*, not design claims.

| Scenario | Validates | Trace |
|----------|-----------|-------|
| Stale node fencing | Old writer cannot write after failover | 27.1 |
| Quorum loss / forced failover | **RPO=0** preserved | 27.2 |
| Spine-down (broker partition) | Outbox buffers, no money lost, recovery drains | R6 |
| MFS provider failover | Payment retries idempotently, no double-charge | R2, 27.4 |

**WHY chaos is mandatory, not optional.** Fencing, RPO=0, and exactly-once are claims until an injected failure proves them; the only acceptable place to discover they don't hold is a game day, never production. **Rejected:** trusting design review alone — distributed-failure behaviour is emergent and must be observed.

---

### Certification & Coverage Gates (summary)

A service may not pass ORR or deploy to production until: unit/component green; **Tier-0 mutation ≥ 80%** (others line ≥ 80%); **all consumer contracts verified**; integration (incl. idempotency, projection-rebuild, outbox/DLQ) green; mandated e2e journeys (incl. R8 parity) green; load at 100× within SLO; SAST/DAST clean of high findings; and chaos scenarios for its tier passed. Sign-off follows §17.4 separation — Finance, Custody, and Fraud certifications are counter-signed by a team that does **not** own the service under test.

---

## 13. Static Analysis & Dependency Management

This chapter binds two CI gates for all 13 contexts: **static analysis** (Roadmap item 38) and **dependency management** (item 39). Both are **blocking** — a violation fails the pipeline before merge. They exist because DOKANDAR is a sovereign, money-and-custody-bearing platform where the architectural invariants (R1–R8) and the polyglot cap (ADR-011, five languages) cannot be defended by human vigilance alone at nation scale. Code review catches what reviewers happen to look at; a fitness function catches it every time, on every commit, in every one of the five languages.

### 13.1 Static Analysis (item 38)

#### 13.1.1 The standard

Every repository runs a **three-layer** static-analysis gate on every pull request and every merge to a release branch:

| Layer | Purpose | Scope | Gate |
|-------|---------|-------|------|
| L1 Lint/format | Style, idiom, dead code, complexity, file size | Per-language, per-file | Block on error severity |
| L2 SAST | Security defects (injection, secrets, unsafe crypto, taint) | Per-language + cross-cutting | Block on HIGH/CRITICAL |
| L3 Architecture-fitness | R1–R8 / SA-convention conformance | Whole-repo, import graph, config | Block on any violation |

**Per-language L1/L2 mapping** (one canonical toolchain per ADR-011 language — no per-team divergence):

| Language | Contexts | L1 lint | L2 SAST |
|----------|----------|---------|---------|
| Go | 2,3,4,5,9,13, gateway | Vet + staticcheck-class + import-linter | Go security analyzer + secret scan |
| Java/Spring | 7,8 | Checkstyle + PMD-class + ArchUnit-class | Spotbugs-security-class + secret scan |
| C#/.NET | 1,11 | Roslyn analyzers + format | Security analyzers + secret scan |
| Python | 10,12 | Ruff-class + type-check (strict) | Bandit-class + secret scan |
| Node/TS | 6, BFFs | ESLint (strict) + type-check (no-`any`) | TS security plugin + secret scan |

**Why one toolchain per language, centrally governed:** ADR-011 caps the polyglot at five *precisely so* the platform org can master each. Allowing teams to pick their own linters re-creates the sprawl ADR-011 forbids, makes the gate non-comparable across contexts, and means a rule disabled in one repo silently weakens the fleet. The toolchain config lives in a shared, versioned "engineering-baseline" that repos consume read-only; local overrides are limited to an allow-list reviewed by the Platform team.

**Complexity and size limits** (enforced by L1, traceable to the coding-style canon):

| Metric | Limit | Action |
|--------|-------|--------|
| Cyclomatic complexity / function | ≤ 15 | Block |
| Function length | ≤ 50 lines | Warn → block at 80 |
| File length | ≤ 800 lines | Block |
| Nesting depth | ≤ 4 | Block |
| Public-API undocumented | 0 tolerated | Block |

**Why hard numeric limits rather than reviewer judgment:** thresholds make "too complex" objective and unarguable, so the discussion at review time is about design, not about whether a 600-line file is acceptable. The limits are deliberately generous (block, not warn, only at the outer bound) to avoid gaming via artificial function-splitting.

#### 13.1.2 Architecture-fitness functions (L3) — the DOKANDAR-specific core

L3 is what makes this chapter more than a generic lint policy. Each function is a deterministic check over the import graph, dependency manifest, config surface, and event/topic declarations. **Each maps to a binding rule:**

| Fitness function | Enforces | Detection signal | WHY |
|------------------|----------|------------------|-----|
| **No-cross-store** | R6 | Custody/Finance/other context source must not import another context's data-access package, ORM model, or migration namespace; no DB driver pointed at a foreign schema | R6 forbids cross-store reads; a shared table is invisible coupling that breaks event-sourcing and audit |
| **Ban shared-DB DSN** | R2, R6 | Config/secret references scanned for a connection string whose host/database name belongs to another context's datastore | R2 isolates Finance with no-shared-DB; a stray DSN is the single most dangerous regression |
| **Custody sole-writer** | R1 | Only context #3's write-side package may emit custody-ledger append commands; any other module importing the custody write API fails | R1 makes custody the *sole* event-sourced writer; a second writer corrupts the ledger irrecoverably |
| **Outbox-required** | SA outbox | Any module publishing to the event-spine must route through the transactional-outbox adapter, never a direct producer client | Direct publish loses the atomic DB-commit-plus-emit guarantee, causing ghost or lost events |
| **Inbox/idempotency-present** | SA inbox + idempotency-key | Consumers must register an inbox dedup handler; HTTP handlers for unsafe/money/custody routes must declare the idempotency-key middleware | At-least-once delivery + retries means non-idempotent handlers double-charge or double-move custody |
| **Topic-name conformance** | R6 Published Language | Event topics must match `<context>.<aggregate>.<Event>.vN`; schema must be registry-registered and backward-compatible within major | Off-convention or unregistered topics break the Published Language contract and consumer routing |
| **Money-type** | Money=integer poisha | Monetary fields/params typed as integer poisha; float/decimal-for-money usage flagged | Floating money creates rounding loss; the canon mandates integer poisha |
| **Team-separation** | §17.4 | Repo's declared owning-team vs imported context must not violate NEVER-SAME-TEAM (Finance⟂all, Catalog⟂Custody, etc.) | Code-level coupling can smuggle a forbidden team dependency past org charts |

**Why fitness functions over manual architecture review (alternative compared and rejected):**

- *Manual review only* — relies on a reviewer recognizing, e.g., a Finance repo importing a B2C model. Rejected: invariants like R1/R2/R6 are catastrophic and silent when breached; human recall is probabilistic, the breach is permanent. At 13 contexts and thousands of PRs, miss rate is effectively certain.
- *Runtime guardrails only* (e.g., network policy blocking cross-store) — necessary defense-in-depth but rejected as the *primary* gate: it catches the violation in production, after the bad code shipped and possibly wrote bad data. Fitness functions shift detection left to commit time, where the cost is a red CI run, not an incident.
- *Chosen: fitness functions as blocking CI + runtime guardrails as backstop.* Cheap, deterministic, every-commit, and they document the rule executably. Runtime policy remains as the second wall.

**Why CI-blocking, not advisory:** an advisory check that "warns" is noise within a week; teams under delivery pressure merge through warnings. Money, custody, and sovereignty invariants have no acceptable violation rate, so the gate must be a hard stop. Exceptions require a time-boxed, signed waiver (see §13.3) — never a silent override.

### 13.2 Dependency Management (item 39)

#### 13.2.1 The standard

| Control | Rule | Gate |
|---------|------|------|
| **Lockfiles** | Every repo commits a fully-resolved, hash-pinned lockfile; builds use frozen/CI-install (no resolution) | Block if lockfile missing, stale, or unpinned |
| **License policy** | Only allow-listed licenses; copyleft and unknown licenses blocked | Block on disallowed/unknown |
| **CVE/SCA** | Software-composition scan on every dependency, direct and transitive | Block on threshold breach |
| **Supply-chain integrity** | SBOM generated per build artifact; artifacts signed; signatures verified at admission | Block if SBOM/signature absent or invalid |
| **Update cadence** | Automated dependency-update PRs on a fixed cadence; security patches expedited | Stale-dependency check blocks beyond max age |

**License allow-list (governance, not legalism):**

| Tier | Examples class | Decision |
|------|----------------|----------|
| Allowed | Permissive (MIT/BSD/Apache-2.0-class) | Auto-pass |
| Conditional | Weak-copyleft (file-level) | Pass only with Legal-approved exception record |
| Blocked | Strong copyleft / network-copyleft / unknown / no-license | Block |

**Why an allow-list (not a block-list):** a block-list assumes you can enumerate every dangerous license; new and exotic licenses appear constantly, and "unknown" is the most common real case. An allow-list is *default-deny* — anything not explicitly cleared is blocked — which matches the security-canon principle of never trusting external inputs. For a state-critical commerce OS, an accidental network-copyleft obligation on the Finance or Government context is an unacceptable legal-sovereignty risk.

**CVE/SCA admission threshold:**

| Severity | Internet-facing (gateway/BFF/B2C/B2B) | Money/Custody/Identity/Gov (1,3,8,11) | Other |
|----------|----------------------------------------|----------------------------------------|-------|
| CRITICAL | Block | Block | Block |
| HIGH | Block | Block | Block, 7-day waiver max |
| MEDIUM | Block, 30-day grace | Block, 14-day grace | Warn → block at 90d |
| LOW | Warn | Warn | Warn |

Stricter thresholds for money/custody/identity/government trace to the SLO canon ("money/custody strictest") and R5 (government read-mostly, high-assurance).

**Supply-chain integrity — SBOM + signing:** every build emits an SBOM and a cryptographic signature; the deployment admission controller **verifies signature provenance and SBOM presence before an artifact may run** in the sovereign landing zone. Unsigned or SBOM-less artifacts are rejected at admission, not merely at build.

**Why SBOM + signing is mandatory (alternatives compared):**

- *Trust the registry / pin by version tag only* — rejected: tags are mutable and registries are compromisable; a version pin without a hash or signature does not prove the bytes you tested are the bytes you run. Recent ecosystem supply-chain attacks (typosquats, maintainer-account takeovers, build-system tampering) target exactly this gap.
- *Hash-pinned lockfiles alone* — necessary but insufficient: lockfiles protect *dependency* integrity but not the integrity of *our own* build artifacts as they flow to production. SBOM + signing closes that second gap and gives Government/audit a verifiable bill of materials per release — directly serving the audit and provenance posture of the platform.
- *Chosen: lockfile hashes (inputs) + SBOM and signature verification at admission (outputs).* Defense at both ends of the build.

**Update cadence — why automated, not on-demand:**

- *Manual, ad-hoc updates* — rejected: dependencies rot silently; the gap between a CVE disclosure and a hand-driven update is where breaches live, and big-bang catch-up upgrades are high-risk and rarely prioritized.
- *Chosen: scheduled automated update PRs* (routine cadence for normal, expedited lane for security advisories), each gated by the full test + static-analysis + SCA pipeline. Small, continuous, test-verified increments keep the fleet patchable and the blast radius of any single bump tiny.

#### 13.2.2 Why dependency gates are CI-blocking — reject review-only

A reviewer cannot read a transitive dependency tree of thousands of packages, cannot recall every CVE, cannot eyeball a license deep in the graph, and cannot verify a signature by inspection. These are machine tasks with zero acceptable miss rate on a money-and-sovereignty platform. Therefore SCA, license, SBOM, and signature checks are **blocking automation**; human review governs *exceptions and waivers*, not routine enforcement.

### 13.3 Governance, waivers, and traceability

- **Waivers** are explicit, time-boxed, signed records (severity-scoped, expiry-dated) committed to the repo and surfaced in the gate output. An expired waiver re-blocks automatically. **No silent suppression** of any L1/L2/L3 or dependency finding — suppression comments without a linked waiver fail the gate.
- **Four-eyes (R4) on rule changes:** modifying the shared engineering-baseline (loosening a fitness function, adding an allowed license, raising a CVE threshold) requires two-person approval from Platform + the owning security authority, mirroring the four-eyes control the platform enforces on fraud and custody.
- **Build-order alignment (Roadmap):** the fitness functions for spine/custody/Finance must exist *before* those contexts are built (sovereign landing zone → spine → Identity/Catalog → Custody/Inventory → Finance-gated …), so each context is born under its invariant gate rather than retrofitted.

Every rule above traces to a CANON source — R1, R2, R4, R5, R6, ADR-011, the SA conventions (outbox/inbox/idempotency/topic/money), §17.4 team separation, the SLO "money/custody strictest" mandate, and the Roadmap build order — and is enforced as a blocking CI gate precisely because the consequences of a single missed violation, at nation scale, are irreversible.

---

## 14. CI/CD Standards

The DOKANDAR delivery system spans 13 contexts, five governed languages (ADR-011), and a roadmap build order that gates Finance and Custody behind ARB remediations (Ch.27). CI and CD are therefore not team conveniences — they are the enforcement surface where binding rules R1–R8 and SA conventions become non-negotiable, machine-checked gates. This chapter sets the uniform pipeline shape every service obeys and the deployment doctrine the platform enforces.

### 14.1 CI Standards (Roadmap Item 40)

**Rule CI-1 — One pipeline shape, five language adapters.** Every service, regardless of context or language, executes the identical seven-stage pipeline in identical order: `lint → build → unit-test → contract-test → security-scan → package → publish-provenance`. Language toolchains differ; the stage contract does not.

| Stage | Purpose | Uniform gate (all 5 languages) |
|-------|---------|-------------------------------|
| lint | Style + static analysis | Zero new violations vs. baseline; format enforced by the centrally governed linter set (Ch.27.8) |
| build | Compile / type-check | Reproducible, hermetic, pinned toolchain version |
| unit-test | Logic correctness | ≥80% coverage (testing.md); money/custody paths ≥90% |
| contract-test | OHS/PL conformance | **Hard gate, see CI-3** |
| security-scan | SCA + SAST + secrets | Zero CRITICAL/HIGH; zero detected secrets |
| package | Build artifact | OCI image, SBOM attached, digest-pinned |
| publish-provenance | Sign + attest | Cosign signature + SLSA provenance to registry |

**WHY uniformity.** With five languages and ten-plus teams, divergent pipelines metastasize into per-team snowflakes that hide regressions and make the NEVER-SAME-TEAM separation (§17.4) unauditable. A single shape lets Platform/SRE reason about *every* service identically, lets ORR (Operational Readiness Review) checklists be language-agnostic, and lets the spine team trust that any producer joining `event-spine` has already passed schema-compat checks. The cost — building five conformant language adapters once — is paid a single time and amortized across the fleet.

**Alternative rejected — per-team freedom over pipeline.** Maximizes local velocity but destroys fleet-wide guarantees; a Finance pipeline that skips contract-tests could silently break R6 Published Language consumers. Rejected: in a money-moving, recall-capable system the blast radius of one weak pipeline is national. Uniformity is a safety property, not bureaucracy.

**Alternative rejected — monorepo single pipeline.** A monolithic build graph couples build cadence across contexts that must stay independent (R2 Finance isolation, R1 custody sole-writer). Rejected in favor of **per-service pipelines in per-context repositories**, with Finance and its reconciler in a *separate repo* (R2). This preserves blast-radius isolation and lets the gated roadmap order (Finance after Custody) be enforced at the repo/access boundary, not merely by convention.

**Rule CI-2 — Hermetic, reproducible builds with pinned toolchains.** No build may reach the network for undeclared dependencies; all dependencies are version-pinned and checksum-verified, all base images digest-pinned. **WHY:** reproducibility is the precondition for signed provenance (CD-2) to mean anything — an irreproducible build cannot be attested. It also defends the supply chain feeding a sovereign landing zone.

**Rule CI-3 — The Published-Language / gRPC contract test is the non-negotiable gate.** A pipeline FAILS, with no override path, if:

- a produced or consumed **event schema** (`<context>.<aggregate>.<Event>.vN`) is not backward-compatible within its major version against the schema registry, or
- a gRPC **OHS interface** (internal) or REST `/v1` surface (external) breaks its consumer-driven contract, or
- a change touches the Published Language without a registered, reviewed schema evolution.

**WHY this is the keystone.** R6 (event-spine Published Language), R7 (Identity+Catalog master-data OHS), and the entire envelope/event convention set are the *only* coupling allowed between independent teams. If a producer ships a breaking schema, it silently corrupts the append-only audit sink, the custody event stream (R1), and every downstream consumer's INBOX — across team boundaries that are deliberately staffed to be adversarial (§17.4). Unit tests cannot catch this because the break is *between* services. The contract test is therefore the single gate that protects inter-context integrity, and it is enforced by consumer-driven contracts (consumers publish expectations; producers must satisfy all registered consumers before merge) plus a schema-registry compatibility check run in CI against the live registry state.

**Alternative rejected — contract validation only at deploy/runtime.** Catches breaks too late (after merge, possibly after promotion), turning a compile-time-class error into a production incident on money or custody flows. Rejected: shift-left to CI where the cost of failure is a red build, not a recall.

**Rule CI-4 — Trunk-based development, short-lived branches.** Branch pattern `feat/<context>-<ticket>-<slug>`, `fix/<context>-<ticket>-<slug>`; merge to trunk within ~2 days behind feature flags. **WHY:** long-lived branches accumulate undetected contract drift and defeat CI-3's value (the registry only knows trunk). Trunk-based keeps the integration surface continuously green. **Rejected — GitFlow:** its release/develop branches institutionalize divergence and slow security patching of a national system. Commit format follows git-workflow.md (`<type>: <description>`).

### 14.2 CD Standards (Roadmap Item 41)

**Rule CD-1 — GitOps pull-based deployment is mandatory.** Desired state lives in a versioned, signed config repository; in-cluster reconcilers continuously pull and converge actual state toward it. No human and no CI job pushes directly to any runtime.

**Compare: push vs. pull.**

| Dimension | Push (CI deploys) | Pull / GitOps (chosen) |
|-----------|-------------------|------------------------|
| Cluster credentials | CI holds prod write creds (broad blast radius) | Cluster pulls; no external system holds prod creds |
| Source of truth | Imperative pipeline state | Declarative git, fully audited |
| Drift handling | Undetected until next deploy | Continuously reconciled + alerted |
| Audit / four-eyes | Scattered across CI logs | Every change is a reviewed, signed commit |
| Rollback | Re-run prior pipeline (may not be reproducible) | Revert commit; reconciler converges |

**WHY GitOps.** A sovereign, money-moving platform cannot let a CI runner hold standing production credentials — that single compromised runner would breach Finance, Custody, and Government simultaneously. Pull-based deployment inverts trust: the cluster authenticates *outward* to git, so no external system carries the keys to the kingdom. It also makes the git history the audit ledger, which is exactly the evidence ORR, four-eyes (R4), and incident review (Ch.27.7) require. **Push is rejected** because credential centralization, drift blindness, and weak auditability are unacceptable at nation scale.

**Rule CD-2 — Only signed, attested images deploy; admission is enforced.** Reconcilers and the admission controller reject any image lacking a valid Cosign signature and SLSA provenance traceable to a CI-2 hermetic build. **WHY:** this closes the loop from CI-2 → CD-1; declarative desired state is only as trustworthy as the artifacts it references. Unsigned or unprovenanced images cannot enter a sovereign landing zone.

**Rule CD-3 — Strict environment promotion, no skipping.** Promotion order is `dev → staging → pre-prod → prod`, each gated. Promotion = a signed commit to the next environment's config path; an artifact is promoted by digest (never rebuilt). **WHY:** rebuilding per environment breaks reproducibility and provenance; promoting the *same* digest guarantees what was tested is what ships. The fixed ladder enforces the roadmap's gated order — Finance cannot reach prod before Custody exists upstream.

**Rule CD-4 — Progressive delivery in three tiers (§25.6), assigned by risk.** Every rollout uses a tier; the tier is a property of the context, not the deployer's preference.

| Tier | Rollout shape | Bake / soak | Assigned contexts | WHY |
|------|---------------|-------------|-------------------|-----|
| **Conservative** | Small canary → long soak → staged steps; manual + four-eyes hold | Longest | Finance (8), Custody (3), Fraud (10), Government (11) | Money exactly-once (R2), sole-writer integrity (R1), four-eyes (R4), payout cooling-off (27.4) tolerate zero silent regression |
| **Standard** | Canary → automated step-up on healthy SLOs | Moderate | Catalog (2), Inventory (5), Provenance (4), B2C (6), B2B (7), Logistics (9), Identity (1) | Customer-facing but recoverable; balance speed and safety |
| **Fast** | Rapid linear with auto-rollback | Short | Analytics (12), most Platform Services (13), BFFs/edge | Read-mostly / stateless; low blast radius favors velocity |

**WHY tiering.** A single rollout speed either throttles harmless edge changes or dangerously rushes money flows. Tiers let risk dictate caution. **Rejected — uniform blue/green for all:** doubles cost fleet-wide (Ch.27.8 cost discipline) and still lacks the gradual SLO observation that canaries give for strict tiers.

**Rule CD-5 — Automated rollback on SLO / error-budget regression.** Each rollout is bound to its service's SLOs (OpenTelemetry-sourced; money/custody strictest). Breaching an SLO or burning the error budget past threshold during bake triggers automatic revert (GitOps reconciles to the prior signed commit). **WHY:** human reaction time is too slow for a national payment incident; automation bounds blast radius to the canary cohort. The strict-tier SLOs make this trip earliest exactly where stakes are highest.

**Rule CD-6 — Four-eyes promotion for Finance, Custody, and Fraud.** Promotion commits into these contexts' prod paths require two distinct approvers from different individuals, enforced by branch protection on the config repo. **WHY:** R4 (fraud four-eyes), R1/R2 integrity, and 27.3 custodial co-sign demand that no single actor can move state-critical code to production — the deploy gate mirrors the runtime control.

**Rule CD-7 — Finance reconciler deploys via its own isolated pipeline (R2).** The separate Finance repo carries a separate CD pipeline, separate config path, separate signing identity, and separate reconciler. **WHY:** R2 mandates no-shared-DB and exactly-once with an independent reconciler; sharing a deploy pipeline would reintroduce the coupling R2 exists to forbid, and would violate the Finance⟂all team separation (§17.4). Isolation in delivery is the operational expression of isolation in architecture.

**Traceability.** CI-1/CI-2 → ADR-011, Ch.27.8; CI-3 → R6, R7, SA event/contract conventions; CD-1 → SA security posture + Ch.27.7; CD-2 → Ch.27.8; CD-4 → §25.6; CD-5 → SLO conventions; CD-6 → R4, 27.3; CD-7 → R2. Together they make every binding rule a gate no team can merge or ship past.

---

## 15. ADR Process & Documentation Standards

> **Mandate.** This chapter governs how engineering knowledge is *decided* and *recorded* across DOKANDAR. The Business Architecture (BA v1.0), the Service Architecture (SA, ARB-PASS), ADR-001..012, design rules R1–R8, and the 12-phase Roadmap are **frozen canon**. They are not frozen because they are perfect; they are frozen because nation-scale commerce cannot be built on shifting ground. This chapter exists to answer one question with discipline: *when reality demands change to a frozen decision, by what governed path does that change happen?* The answer is a single, narrow gate — a **new ADR** — and the supporting discipline is a uniform documentation standard so that every decision is traceable, reviewable, and reversible-by-record. Traces: ADR-011 (central governance precedent), R6/R7 (Published Language and master-data ownership require stable contracts), Roadmap (build order depends on stable upstream decisions), SA Ch.27 (remediations were themselves change-of-decision events that an ADR process formalizes).

### 15.1 ADR Process

#### 15.1.1 The single binding rule: change-by-ADR, never edit-in-place

**Rule.** Any change to a frozen decision — a bounded-context boundary, an ADR, a design rule (R1–R8), a Published-Language contract, an ownership assignment (§17.4 NEVER-SAME-TEAM), a language allocation (ADR-011), or a Roadmap build-order dependency — is made by authoring a **new ADR that supersedes the prior one**. The prior ADR is **never edited in place** except to flip its status field and add a back-reference. Frozen documents (BA, SA chapters) are amended only by an Accepted ADR that the document then *cites*; the document’s prose is not silently rewritten to erase the prior position.

**WHY.** A frozen architecture’s value is that downstream teams can build against it without re-verifying it daily. Custody (R1, sole-writer event-sourced), Finance (R2, isolated, exactly-once), and the event-spine Published Language (R6) are *load-bearing for correctness and money*. If these decisions could be mutated in place, three failures follow: (1) **silent divergence** — a team that read the contract last quarter is now wrong and has no signal; (2) **lost rationale** — the *why* behind a rejected alternative evaporates, so the same mistake is re-litigated; (3) **un-auditable governance** — for a sovereign, regulated platform (Government context #11, R5 read-mostly; gov/operational separation §17.4), regulators and incident reviewers must reconstruct *who decided what, when, and why*. Change-by-ADR makes every architectural change an **append-only, attributable, reviewable artifact** — the same discipline R6 mandates for the audit sink, applied to governance itself.

#### 15.1.2 Alternatives considered and rejected

| Change-management approach | What it offers | Why rejected for DOKANDAR |
|---|---|---|
| **Edit-in-place on frozen docs** (wiki-style) | Lowest friction, single current copy | Destroys rationale and history; no supersession trail; un-auditable; breaks downstream contract stability (R6/R7). **Rejected.** |
| **Inline “Decision Log” bullets** appended to each doc | Cheap, co-located | No uniform template, no lifecycle states, no numbering, no review gate; cannot enforce four-eyes or traceability; degrades into unsearchable prose. **Rejected.** |
| **Tickets/issues as the decision record** | Integrates with delivery tooling | Issues are mutable, closeable, and ephemeral; they capture *tasks*, not *durable rationale*; status semantics are wrong (Closed ≠ Superseded). **Rejected as the record of truth** (issues *link* to ADRs, never replace them). |
| **New-ADR-supersedes (CHOSEN)** | Immutable history, explicit lifecycle, numbered, reviewable, traceable | Higher authoring friction — accepted deliberately as a *governance speed bump* proportional to blast radius. **Chosen.** |

The friction is the feature: changing a frozen money/custody decision *should* cost a documented, reviewed ADR, not a quiet keystroke.

#### 15.1.3 When an ADR is required (and when it is not)

**An ADR is REQUIRED when** a change touches: a bounded-context boundary or its OHS contract; any R1–R8 rule realization; a Published-Language event schema’s *major* semantics (additive backward-compatible evolution within a major version is governed by the schema registry, **not** a new ADR — see §15.1.7); cross-context integration patterns (saga R3, four-eyes R4, OUTBOX/INBOX/DLQ); language allocation under ADR-011’s five-language cap; security posture (auth, KMS/HSM rotation cadence, PDP policy shape); SLO targets for money/custody; or Roadmap build-order dependencies.

**An ADR is NOT required for** reversible, context-local implementation choices that do not cross a published contract: internal library selection within one service, local refactors, log formats, non-contract test structure. These are recorded in the owning team’s service docs (§15.2), not the global ADR log.

**WHY the split.** ADRs are reserved for **architecturally significant, hard-to-reverse, cross-team** decisions. Diluting the log with reversible local choices would bury the decisions that actually constrain other teams. Significance test: *does reversing this later force another team to change code, or touch money/custody/audit?* If yes → ADR.

#### 15.1.4 ADR template (mandatory sections)

Every ADR carries, in order: **ID & Title**; **Status** (see lifecycle); **Date**; **Authors & Approvers** (four-eyes — never single-author-approves; R4’s separation-of-duties ethos applied to governance); **Context** (forces, constraints, the BA/SA/R/FR trace); **Decision** (the binding standard, stated imperatively); **Alternatives Considered** (each with explicit rejection rationale — *mandatory*, mirroring this chapter’s own discipline); **Consequences** (positive, negative, and newly-accepted risk); **Affected Contexts/Teams** (with §17.4 ownership check); **Supersedes / Superseded-By**; **Compliance & Security impact** (KMS/HSM, audit, gov/regulatory); **Revision History**. An ADR with an empty *Alternatives* section is **rejected at review** — a decision with no considered alternatives is an assertion, not an architecture decision.

#### 15.1.5 Numbering

**Rule.** ADRs are globally, monotonically numbered (`ADR-NNN`), zero-padded, **never reused, never renumbered**, allocated from a single central registry continuing the existing ADR-001..012 sequence. Numbers are *identity*, not *ordering of importance*.

**WHY central + global, not per-context.** Considered per-context numbering (e.g., `CUSTODY-ADR-007`). Rejected: cross-cutting decisions (R6 spine, ADR-011 polyglot) belong to no single context, and per-context schemes collide and obscure global supersession chains. A single registrar (the ADR log owner, §15.1.6) prevents number collisions — the same single-writer discipline R1 applies to custody, applied to ADR identity.

#### 15.1.6 Lifecycle: Proposed → Accepted → Superseded (and terminal states)

```text
Proposed ──review(four-eyes)──> Accepted ──new ADR──> Superseded
   │                                │
   └──> Rejected (terminal)         └──> Deprecated (no longer recommended, not yet replaced)
```

| Status | Meaning | Who may set |
|---|---|---|
| **Proposed** | Drafted, under review; not yet binding | Author |
| **Accepted** | Binding standard; downstream must conform | Architecture Review (two approvers, cross-team) |
| **Rejected** | Considered and declined; kept for rationale | Architecture Review |
| **Deprecated** | Still factually true but discouraged; replacement pending | Architecture Review |
| **Superseded** | Replaced by a named later ADR | Set automatically when the superseding ADR is Accepted |

**WHY explicit states with a Superseded terminal.** A binary draft/final model cannot express “this was true, now it is not, and *here is its replacement*.” The Superseded state with a mandatory **Superseded-By** pointer (and reciprocal **Supersedes** on the new ADR) preserves the **causal chain of decisions** — the same append-only, follow-the-links property R6 requires of the audit sink. Nothing is deleted; history is navigable.

#### 15.1.7 ADR vs schema-registry: the boundary

Backward-compatible event evolution **within a major version** (additive fields, per the SA schema-registry rule) is *not* an ADR event — it is routine governed evolution. A **new major version** of a Published-Language topic (`<context>.<aggregate>.<Event>.vN`), a break in per-aggregate ordering guarantees (PPID/WLT/TXN), or a change to exactly-once/idempotency posture **is** an ADR event. **WHY.** ADRs govern *irreversible contract semantics*; the registry governs *safe forward-compatible growth*. Conflating them would either throttle routine evolution or hide breaking changes from governance.

#### 15.1.8 The ADR log (index of record)

**Rule.** A single, central, append-only **ADR Log** lists every ADR: ID, title, status, date, supersedes/superseded-by, affected contexts. It is the **canonical index**; the Roadmap, BA, and SA reference ADRs by ID through it. CI verifies referential integrity: no dangling Superseded-By, no orphan Accepted ADR contradicting a frozen doc, no duplicate numbers. **WHY enforced in CI.** Governance that relies on human diligence drifts; mechanizing the integrity check (broken-link, status-consistency, number-collision) makes the log self-policing — the documentation analogue of the lint/cost gates in SA Ch.27.8.

### 15.2 Documentation Standards

#### 15.2.1 The universal document contract

**Rule.** *Every* engineering document — ADR, service README, runbook, design note, ORR record, API contract doc — carries the **standard front-matter and back-matter** below. No document is considered complete (or mergeable) without all sections; sections that are genuinely empty state `None` explicitly, never blank.

| Section | Purpose / WHY it is mandatory |
|---|---|
| **Purpose** | One-paragraph reason the doc exists — defends against scope drift |
| **Scope** | What is and is *not* covered — prevents over-claiming authority |
| **References** | Upstream BA/SA/ADR/Roadmap links — anchors to canon |
| **Traceability** | Explicit map to FR-*/BR-*/R*/ADR/Roadmap-phase — proves the doc realizes canon, invents nothing |
| **Glossary** | Defines domain terms — Bangladesh-context, custody, escrow, poisha unambiguous across 10 teams |
| **Assumptions** | What is taken as true — surfaces hidden coupling |
| **Constraints** | Hard limits (ADR-011 five-language cap, money=integer poisha, R2 isolation) |
| **ADRs** | Which Accepted ADRs bind this doc — single source of decision authority |
| **Open Questions** | Known unknowns — prevents false certainty |
| **Risks** | Identified risks + mitigation — feeds ORR/incident readiness (Ch.27.7) |
| **Future** | Deferred work (YAGNI boundary) — records intent without committing |
| **Revision History** | Dated, attributed changes — append-only audit of the doc itself |
| **Quality Checklist** | Self-verification gate before review |
| **Approval** | Named approvers (four-eyes for cross-team/security/money docs) |
| **Version** | Semantic doc version — enables stable external reference |

**WHY a uniform contract.** Ten teams across five languages and 13 contexts cannot share knowledge if every document has a different shape. **Traceability** is the keystone: it operationalizes the canon rule *“trace every standard to BA/SA/ADR/R/FR/Roadmap”* and makes “did we invent a business rule?” a **mechanically checkable** question. **Revision History** + **Version** give documents the same append-only, attributable history that ADRs and the R6 audit sink enjoy — consistency of governance from code to contract to prose.

#### 15.2.2 Why not lighter-weight docs

| Alternative | Why rejected |
|---|---|
| **Freeform docs, no template** | No traceability → cannot prove conformance to frozen canon; un-reviewable at scale. **Rejected.** |
| **Template but optional sections** | Optionality collapses to omission; the missing section is always the one that mattered (Risks, Traceability). **Rejected** — sections are mandatory, `None` is explicit. |
| **Auto-generated docs only** | Captures *what* exists, never *why* — the rationale that ADRs and Context sections exist to preserve. **Rejected as sole source.** |

#### 15.2.3 Enforcement

Documentation conformance is a **merge gate**: CI checks presence of all mandatory sections, non-empty Traceability with resolvable references, valid status/version fields, and ADR-log referential integrity (§15.1.8). Security/money/custody/government documents additionally require **two named approvers from different teams** (§17.4 separation; R4 four-eyes ethos). **WHY mechanized.** Standards that are only *aspirational* are not standards. Gating at merge makes the document contract as binding as the code contract — which, for a nation-scale commerce OS under regulatory scrutiny, is exactly the bar this engineering office sets.

---

## 16. Review Process, Architecture Governance & Quality Gates

This chapter is the constitution's enforcement layer. It binds the standards in Chapters 1–15 to merge gates, board authority, and phase-entry criteria so that nothing reaches `main`, and no Roadmap phase begins, without measurable proof of conformance. It realizes SA Ch.27 ARB remediations and the Roadmap §18 quality-gate matrix. It governs *how we decide*; it never re-opens *what was decided* — the Business Architecture (DOKANDAR-Architecture.md v1.0) is frozen.

---

### 16.45 Review Process

#### 16.45.1 Ownership: CODEOWNERS as machine-enforced accountability

Every path in every repository **MUST** map to exactly one owning team via a version-controlled `CODEOWNERS` manifest. Ownership follows the frozen 13-context / team map, not convenience.

| Rule | Standard | WHY |
|------|----------|-----|
| RV-1 | Each directory has ≥1 owning team; no orphan paths | An unowned file is an unreviewed file; accountability gaps become security gaps (security.md) |
| RV-2 | Cross-context contract paths (proto/OHS schemas, event schemas) require **two** owning teams: producer + consumer | R6/R7 Published Language is a shared liability; unilateral change breaks downstream contexts |
| RV-3 | NEVER-SAME-TEAM (§17.4) pairs **MUST NOT** appear as co-owners or cross-approve each other's sensitive merges | Segregation of duties: Finance⟂all, Fraud⟂Analytics, Catalog⟂Custody, Government⟂operational, B2C⟂B2B. Co-ownership would collapse the very separation the BA mandates |

**Alternatives compared.** *Wildcard fallback owner* (a single platform team owns `*`) — **REJECTED**: it manufactures a bottleneck and dilutes domain accountability; the platform team cannot meaningfully review Finance saga logic. *Voluntary reviewer tagging* — **REJECTED**: relies on author memory, fails silently, and is unauditable. Machine-enforced `CODEOWNERS` is chosen because it makes the required reviewer set a *merge precondition* the forge enforces, not a courtesy.

#### 16.45.2 The two-stage review: multi-lens self-review, then independent review

No merge to a protected branch occurs without **both** stages passing, in order.

**Stage 1 — Multi-lens self-review (author).** Before requesting review, the author certifies a checklist covering distinct lenses, mirroring the split-role discipline:

```text
[ ] Correctness   — behaviour matches FR/BR trace; tests prove it
[ ] Contract      — envelope {success,data,error,meta}, problem+json, /v1, idempotency-key on unsafe/money/custody writes
[ ] Boundary      — no cross-store reads (R6); no Finance shared-DB (R2); custody sole-writer respected (R1)
[ ] Security      — no secrets, input validated, RBAC/ABAC PDP path, four-eyes where required (R4)
[ ] Observability — OTel spans, SLO-relevant metrics, DLQ/retry wired
[ ] Reversibility — migration is backward-compatible; rollback path stated
```

**Stage 2 — Independent review.** At least one approver from the owning team who is **not** the author. Contract-, money-, or custody-touching changes require a domain reviewer **plus** an architecture-board delegate (16.46).

**WHY two stages.** Self-review removes the cheap, high-volume defects so the human reviewer spends scarce attention on design and risk, not formatting. Independent review enforces the four-eyes principle (R4) structurally — an author can never be the sole gate on money or custody code. 

**Alternatives compared.** *Single-reviewer, no self-review* — **REJECTED**: pushes trivial defects onto the reviewer, lengthening SLAs and lowering signal. *Mandatory pair-programming in lieu of review* — **REJECTED**: valuable but non-auditable; it leaves no durable artifact, and regulators of a nation-scale commerce OS require an evidence trail. The two-stage model yields both a self-certification record and an independent approval record.

#### 16.45.3 Review SLAs and risk-tiered rigor

Review effort is proportional to blast radius, not uniform.

| Risk tier | Examples | Min approvers | Review SLA (first response) |
|-----------|----------|---------------|------------------------------|
| T0 Critical | Finance, Custody ledger, Identity/KYC, escrow saga, key rotation | 2 + ARB delegate | 4 business hours |
| T1 High | Cross-context contracts, event schema changes, Gateway/BFF auth | 2 | 1 business day |
| T2 Standard | Single-context feature, internal refactor | 1 | 1 business day |
| T3 Low | Docs, comments, test-only | 1 | 2 business days |

**WHY tiering.** Uniform SLAs either over-burden low-risk flow or under-protect T0 money/custody paths whose SLOs are strictest. Tiering concentrates rigor where the BA assigns the highest stakes. SLAs are *first-response* commitments, not merge deadlines — a slow approval never justifies skipping a gate.

---

### 16.46 Architecture Governance

#### 16.46.1 The Architecture Review Board (ARB) and the never-redesign-BA rule

The ARB is the standing authority that protects architectural integrity. Its **first and inviolable mandate**: the Business Architecture, its 13 bounded contexts, ADR-001..012, design rules R1–R8, FR-*, and BR-001..040 are **frozen inputs**. The ARB may decide *how* to realize them; it has **no authority to alter them**. Any proposal that requires changing a BR or context boundary is **out of scope** and escalates to business architecture ownership, never resolved inside engineering.

| ARB rule | Standard | WHY |
|----------|----------|-----|
| AG-1 | ARB membership spans contexts but **excludes** self-review of one's own context for NEVER-SAME-TEAM concerns | Independence; prevents a team ratifying its own boundary violation |
| AG-2 | ARB owns the polyglot cap (ADR-011: Go/Java/C#/Python/Node-TS only); a sixth language is a **rejected default** requiring unanimous ARB + VP Eng sign-off | Each language is a hiring, security-patching, and toolchain liability; uncapped polyglot fragments the platform |
| AG-3 | ARB ratifies all ADRs and runs the API and Event governance boards (16.46.3) | Single accountable authority prevents contract drift across 13 contexts |

**WHY a board, not an individual.** A single chief architect is a bus-factor and a bottleneck for a 13-team platform. **Alternatives compared.** *Fully decentralized (each team self-governs)* — **REJECTED**: guarantees divergent envelopes, incompatible event schemas, and erosion of R6/R7 master-data discipline. *Central architecture team owning all design* — **REJECTED**: bottlenecks delivery and de-skills domain teams. The ARB is a **federated** body — domain teams design within guardrails; the ARB ratifies cross-cutting contracts and enforces the frozen rules.

#### 16.46.2 Change control via ADR

Every decision that crosses a context boundary, changes a contract, adds a dependency or technology, or alters an SLO **MUST** be recorded as an ADR before implementation.

```text
ADR-NNN: <title>
Status: Proposed | Accepted | Superseded-by-ADR-NNN | Rejected
Context · Decision · Consequences · Trace(BA/SA/R/FR/Roadmap) · Alternatives-rejected
```

**WHY.** ADRs make architecture *append-only and auditable* — the same property R1/R6 demand of the ledger and audit sink, applied to decisions. A decision with no recorded WHY is indistinguishable from an accident and cannot be safely revisited. ADRs are **superseded, never deleted**, preserving the reasoning chain. **Alternatives compared.** *Wiki pages / tribal knowledge* — **REJECTED**: mutable, unversioned, lost on attrition. *Decisions embedded only in PR descriptions* — **REJECTED**: not discoverable as a corpus and buried in merge history.

#### 16.46.3 API and Event governance boards

Two specialized ARB sub-boards enforce the Published Language (R6) and master-data OHS (R7).

| Board | Enforces | Binding checks |
|-------|----------|----------------|
| API Governance | REST `/v1` external via gateway+BFF; gRPC internal OHS; `{success,data,error,meta}`; problem+json; idempotency-key on unsafe/money/custody | No breaking change within a major version; deprecation requires successor + migration window |
| Event Governance | Topic `<context>.<aggregate>.<Event>.vN`; schema-registry **backward-compatible within major version**; per-aggregate ordering (PPID/WLT/TXN); OUTBOX/INBOX/DLQ | Registry rejects incompatible schemas at CI; new major version requires dual-publish plan |

**WHY separate boards.** API and event contracts have different compatibility models (request/response vs. append-only streams) and different blast radii. A combined board blurs these. **Alternatives compared.** *Trust producers to version responsibly* — **REJECTED**: a single uncoordinated breaking change can cascade across consuming contexts (recall, finance reconciliation), violating R6. Registry-enforced compatibility makes the safe path the only mergeable path.

#### 16.46.4 Fitness functions: governance as executable tests

Architectural rules that *can* be checked by a machine **MUST** be, and run in CI as blocking checks.

| Fitness function | Detects violation of |
|------------------|----------------------|
| Boundary-dependency scan | R1 custody sole-writer; R2 Finance no-shared-DB; R6 no cross-store reads |
| Contract-lint | Envelope, problem+json, `/v1`, idempotency-key presence |
| Schema-compat gate | Event/registry backward-compat within major version |
| Polyglot-guard | Language outside the ADR-011 five |
| Secret-scan / dependency-CVE | security.md; Ch.27.8 |
| Trace-coverage | Every new endpoint/event carries OTel context |

**WHY automate.** Human reviewers cannot reliably catch every boundary leak across 13 contexts at merge velocity; **fitness functions make conformance continuous and non-negotiable**, freeing human review for judgment. **Alternatives compared.** *Periodic manual architecture audits* — **REJECTED**: detect drift weeks late, after it has spread. *Documentation-only rules* — **REJECTED**: unenforced rules decay. Executable fitness functions convert the constitution into a gate.

---

### 16.47 Engineering Quality Gates

#### 16.47.1 The gate principle

Every Roadmap phase and wave terminates in a **measurable quality gate**. **No phase begins until the prior gate passes** — gates are sequential and non-overridable except by a formally recorded, time-boxed VP Eng + ARB waiver with a remediation ADR. This realizes the Roadmap §18 quality-gate matrix and the dependency-ordered build sequence.

| Gate | Phase boundary (Roadmap order) | Exit criteria (must all pass) |
|------|-------------------------------|-------------------------------|
| G0 Landing zone | Sovereign landing zone → spine | RPO=0 quorum (27.2), backup/restore drill (27.7), KMS/HSM rotation proven (27.8) |
| G1 Spine | Spine → Identity/Catalog | OUTBOX/INBOX/DLQ + park-and-freeze (27.5) chaos-tested (27.6); schema registry live |
| G2 Master data | Identity/Catalog → Custody/Inventory | R7 OHS contracts published; four-eyes (R4) PDP enforced |
| G3 Custody | Custody/Inventory → Finance | R1 sole-writer fitness green; fencing (27.1); custodial co-sign (27.3) |
| G4 Finance (gated) | Finance → B2C | R2 exactly-once reconciler; escrow saga (R3); payout cooling-off (27.4); SLOs strictest-tier met |
| G5+ Commerce→Analytics | Each subsequent context | Context SLOs, 80% coverage, ORR sign-off, offline/USSD parity (R8) where applicable |

#### 16.47.2 Universal gate criteria

Independent of phase, every gate requires: **≥80% test coverage** (unit + integration + E2E per testing.md); all fitness functions green; T0/T1 reviews closed; an **Operational Readiness Review (ORR)** with runbooks, DLQ/rollback, and incident playbooks (27.7); zero open CRITICAL security findings.

**WHY hard sequential gates.** The build order is dependency-driven: Custody cannot be trusted before the spine is durable; Finance cannot settle before Custody is the proven sole writer. **Allowing a phase to start on an unpassed gate imports unverified risk into a money-or-custody-critical layer** — precisely where the BA tolerates least. **Alternatives compared.** *Soft gates (advisory, ship-anyway)* — **REJECTED**: under delivery pressure advisory gates are always skipped, defeating their purpose. *Big-bang final gate* — **REJECTED**: defers discovery of integration defects to the most expensive moment. Per-phase blocking gates, with auditable waivers as the only escape hatch, keep risk bounded and traceable to Roadmap §18.

---

## 17. Definition of Ready, Definition of Done & Engineering Checklists

This chapter sets the binding gates that decide when DOKANDAR work may **start** (Definition of Ready, DoR), when it may be declared **complete** (Definition of Done, DoD), and the **checklists** that operationalize both at PR, service, security, and release boundaries. These gates are not bureaucracy: at nation scale, with a custody ledger that is the sole writer (R1), an isolated Finance context with exactly-once semantics (R2), and offline/USSD parity obligations (R8), half-done work is not a local inconvenience — it is a systemic, irreversible liability (a mis-posted poisha balance, a broken provenance chain, a recall that cannot be traced). DoR and DoD convert the frozen Business Architecture (BA), Service Architecture (SA), ADRs, and Roadmap into **enforceable preconditions and postconditions** for every unit of work.

### Why gates at all — the failure mode we are designing against

| Without gates | With DoR/DoD |
|---|---|
| Work starts on ambiguous scope; contracts invented mid-flight, diverging from SA Published Language (R6) | No start until contract + AC exist; divergence impossible by construction |
| "Done" means "compiles on my machine"; observability, idempotency, security bolted on later or never | "Done" is multi-dimensional and machine-checked; money/custody paths cannot merge without idempotency proof |
| Defects surface in Finance/Custody where they are unrecoverable | Defects caught at the cheapest boundary (PR) before they reach irreversible contexts |
| Cross-team coupling discovered at integration | Dependency satisfaction proven *before* a card is pulled |

**WHY:** DOKANDAR's strictest invariants (R1 sole writer, R2 exactly-once, R3 escrow saga, R4 four-eyes) are append-only and money-bearing — the cost of detection rises by orders of magnitude the later it occurs. DoR/DoD push detection left to the point where rollback is still free.

---

### 17.1 Definition of Ready (Roadmap item 48)

A work item (story, task, or spike) **MUST NOT be pulled into a sprint/iteration** until *every* DoR condition holds. The DoR is a checklist enforced by the product/tech lead at backlog refinement and re-verified at pull time.

| # | DoR Condition | Enforcement | WHY / Trace |
|---|---|---|---|
| DoR-1 | **Traced** to a BA/SA artifact (FR-*, BR-0xx, ADR, R-rule, SA chapter, or Roadmap phase) recorded in the item | Item template has a mandatory `Traces:` field; refinement rejects empty | We never invent business rules; every line of work justifies itself against the frozen canon |
| DoR-2 | **Contracts available** — the gRPC OHS interface (internal) and/or `/v1` REST + event schema (`<context>.<aggregate>.<Event>.vN`) the item consumes/produces are published in the schema registry or contract repo | Contract-first review; registry entry linked | Prevents the "invented contract" drift; honors R6 Published Language and R7 master-data OHS |
| DoR-3 | **Dependencies satisfied** — upstream services/topics exist per Roadmap build order; no item may depend on an un-built context | Dependency graph check against build order (spine→Identity/Catalog→Custody/Inventory→Finance→…) | A B2C item cannot start before Custody/Inventory exist; respects gated sequencing |
| DoR-4 | **Acceptance Criteria (AC)** defined, testable, in Given/When/Then form, including the negative and offline/USSD-parity path where R8 applies | AC section mandatory; QA signs off on testability | Untestable AC = untestable DoD; parity is a first-class requirement, not an afterthought |
| DoR-5 | **No open blocker** — no unresolved ADR question, no pending security/architecture exception, no NEVER-SAME-TEAM (§17.4 BA) ownership conflict | Blocker register checked; ARB ticket linked if architectural | Starting blocked work creates WIP that rots and hides true progress |
| DoR-6 | **Sizing & owner** — single owning team (per the 13-context ownership map), estimate present, fits one iteration or is split | Lead assigns single team; oversized items split | Single-team ownership preserves bounded-context integrity (Conway alignment) |

**Alternatives considered & rejected:**
- *No DoR (pull anything ready-ish).* Rejected: maximizes mid-flight contract invention — the exact failure R6/R7 forbid.
- *Heavyweight DoR with full design doc per story.* Rejected: violates KISS/YAGNI; design belongs in SA/ADR which are already frozen. DoR only *verifies traceability to* them, it does not re-litigate them.
- *Soft DoR (advisory checklist).* Rejected: advisory gates are skipped under deadline pressure precisely when discipline matters most (Finance/Custody). DoR is **blocking**.

---

### 17.2 Definition of Done (Roadmap item 49)

A work item is **Done** only when *all* applicable conditions are satisfied and evidenced in the PR/CI record. "Applicable" is determined by the item's context: money/custody conditions are mandatory for contexts #3, #5, #8 and any saga touching them (R3).

| # | DoD Condition | Evidence / Gate | WHY / Trace |
|---|---|---|---|
| DoD-1 | **Built** — green CI on the governed toolchain for the owning language (Go/Java/C#/Python/Node-TS only) | CI status; no out-of-cap language (ADR-011) | Polyglot is capped at five and centrally governed |
| DoD-2 | **Tested to coverage gate** — ≥80% line/branch on changed units; unit + integration; AAA structure | Coverage report blocks merge below threshold | Per testing standard; Finance/Custody may carry a higher local gate (Ch.27.6) |
| DoD-3 | **Contract-tested** — consumer-driven contract tests pass against published gRPC/REST/event schemas; schema-registry backward-compatibility check green within major version | CDC suite + registry compat check in CI | Backward-compatible evolution is a hard SA rule; breaking it breaks consumers silently |
| DoD-4 | **Observable** — OpenTelemetry spans on entry/exit, correlation/trace-id propagated, RED/USE metrics emitted, SLO alert wired (money/custody strictest) | Trace appears in staging; dashboard + alert linked | You cannot operate at nation scale what you cannot see; SLOs are contractual |
| DoD-5 | **Documented** — runbook delta, API/event changelog, and ADR reference updated | Docs diff in same PR | Undocumented behavior is unsupportable; ties to Ch.27.7 runbooks |
| DoD-6 | **Reviewed** — ≥1 peer + CODEOWNERS approval; four-eyes for fraud-enforcement actions (R4) | Branch protection; required reviewers | Review is mandatory; R4 four-eyes is non-negotiable on enforcement paths |
| DoD-7 | **Security-scanned** — SAST, dependency/SCA, secret scan, IaC/lint clean; no hardcoded secrets (KMS/HSM only) | Security gate green; findings triaged | Ch.27.8 lint/rotation; security.md secret-management |
| DoD-8 | **Idempotent where money/custody** — idempotency-key honored, transactional OUTBOX + consumer INBOX present, per-aggregate ordering (PPID/WLT/TXN) preserved, DLQ+retry+park-and-freeze wired | Idempotency replay test + outbox/inbox test green | R1, R2 exactly-once, Ch.27.5 poison handling — duplicate money movement is unrecoverable |
| DoD-9 | **ORR items where applicable** — Operational Readiness Review checklist (backup/restore drill, fencing, quorum RPO=0, cooling-off) satisfied for new/changed services touching custody, Finance, or first-of-context go-live | ORR sign-off attached | Ch.27.1/27.2/27.4/27.7 — production readiness is gated, not assumed |

**Alternatives considered & rejected:**
- *Single-axis DoD ("tests pass = done").* Rejected: leaves observability, idempotency, and security as optional — the very dimensions whose absence causes nation-scale incidents.
- *DoD enforced only at release.* Rejected: batches risk and makes attribution impossible; we enforce per-PR so every increment is independently shippable.
- *Uniform DoD for all contexts.* Rejected: a Government read-mostly (R5) query view and a Custody write path have different risk; DoD is **tiered by context** so we neither under-protect money nor over-burden read views.

---

### 17.3 Engineering Checklists (Roadmap item 59)

Checklists are the *executable surface* of DoR/DoD — concrete, binary items wired into PR templates, CI gates, and release runbooks. Four canonical checklists are binding. Each item maps to a DoR/DoD clause so there is no orphan ceremony.

**17.3.1 PR Checklist** (author self-certifies; reviewer verifies; partly CI-enforced)

```text
[ ] Traces: BA/SA/ADR/R/FR linked            (DoR-1)
[ ] Contract change → registry compat green  (DoD-3)
[ ] Coverage ≥ 80% on changed units          (DoD-2)
[ ] OTel spans + metrics + SLO alert present (DoD-4)
[ ] No secrets; SAST/SCA/secret-scan clean   (DoD-7)
[ ] Idempotency-key + outbox/inbox if $/custody (DoD-8)
[ ] Runbook/changelog/ADR updated            (DoD-5)
[ ] Four-eyes reviewer if enforcement path   (DoD-6/R4)
```

**17.3.2 Service-Readiness Checklist** (per service, at first go-live and on material change)

```text
[ ] Owning team is single & correct per 13-context map
[ ] NEVER-SAME-TEAM separations honored (Finance⟂all, Fraud⟂Analytics,
    Catalog⟂Custody, Government⟂Platform, B2C⟂B2B)   (§17.4 BA)
[ ] DLQ + retry-with-backoff + park-and-freeze wired (Ch.27.5)
[ ] SLOs defined; money/custody strictest; alerts paged
[ ] mTLS + OAuth2/OIDC + RBAC/ABAC PDP enforced at edge & internal
[ ] Backup/restore drill executed; RPO=0 quorum verified (Ch.27.2/27.7)
```

**17.3.3 Security Checklist** (blocking; expands DoD-7 — see security.md)

```text
[ ] Secrets in KMS; signing keys in HSM; rotation cadence set (Ch.27.8)
[ ] Input validated at every boundary (problem+json on reject)
[ ] AuthN/AuthZ verified; four-eyes on fraud/enforcement (R4)
[ ] Rate limiting on all external endpoints
[ ] Error responses leak no sensitive data
[ ] Custody/Finance writes use idempotency-key (R1/R2)
```

**17.3.4 Release Checklist** (Release Manager; gate to production)

```text
[ ] All CI gates green; no waived CRITICAL/HIGH review findings
[ ] Build-order dependencies deployed & healthy (Roadmap)
[ ] ORR sign-off for custody/Finance/first-of-context (DoD-9)
[ ] Rollback/runbook rehearsed; fencing tokens active (Ch.27.1)
[ ] Payout cooling-off honored where applicable (Ch.27.4)
[ ] Offline/USSD/SMS/IVR parity verified for user-facing change (R8)
```

**WHY four separate checklists, not one master list:** different actors act at different moments (author, service owner, security engineer, release manager). Collapsing them into one list (rejected) produces a list everyone skims and no one owns; splitting by responsibility moment (chosen) gives each checklist a clear owner, a clear trigger, and a clear blocking gate. **WHY checklists in addition to DoD (rejected: DoD prose alone):** prose is interpreted; binary checklist items wired to CI are *enforced*. The checklist is the contract between intention (DoD) and machine reality (CI/branch-protection).

**Traceability close-out:** DoR-1 guarantees every item points back to the canon; DoD-1..9 guarantee every increment is independently shippable and reversible-before-money; the four checklists guarantee the gates are enforced by the right owner at the right boundary. Together they are the mechanism that makes "half-done work" structurally impossible in the contexts where DOKANDAR cannot afford it.

---

## 18. Team Responsibilities & Ownership Rules

This chapter binds the frozen organizational map of DOKANDAR to its code, data, and contracts. It realizes Service Architecture §17 (team topology) and §17.4 (never-same-team constraints), encodes design rules R1, R2, R6, R7, and aligns repository structure to team boundaries per Conway's Law. It changes no business rule; it makes the *ownership* of every business rule unambiguous and enforceable.

### 18.1 Why Ownership Is Conway-Aligned (Governing Principle)

Conway's Law states that system interfaces mirror the communication structure of the organizations that build them. We treat this not as an observation but as a **design lever**: the 13 bounded contexts of the Business Architecture were drawn as autonomy boundaries, and SA §17 assigned each to exactly one team. Therefore the *socio-technical* unit of ownership is **(team → context → repository → store → event contracts → SLA)**, traced one-to-one.

**WHY:** When team boundaries and architectural boundaries disagree, the disagreement leaks into the code as accidental coupling — shared tables, cross-context imports, and "temporary" reach-arounds that calcify. By making the team the *sole* owner of a context's full vertical stack, every change has one accountable owner and one review path. This directly protects R1 (custody sole writer), R2 (Finance isolation), and R6 (no cross-store) from organizational erosion.

**Alternatives compared and rejected:**

| Model | Description | Why rejected |
|-------|-------------|--------------|
| **Layered teams** (frontend team, backend team, DBA team) | Ownership by technology layer across all contexts | A single business change (e.g., escrow saga R3) crosses three teams → coordination tax, diffused accountability, violates context autonomy. Makes R2 Finance isolation impossible to enforce socially. |
| **Component teams per microservice** | One team per deployable service | Fragments a bounded context across many micro-owners; aggregate invariants (custody event-sourcing R1) lose a single guardian. Over-fragments the polyglot cap (ADR-011). |
| **Shared ownership / collective code** | Anyone may edit anything | No accountable owner for money/custody invariants; four-eyes (R4) and never-same-team (§17.4) become unenforceable. **Rejected outright.** |
| **Stream-aligned + platform (chosen)** | Each business stream owns its full vertical; a Platform/Enabling team owns shared substrate | Matches §17 exactly; preserves autonomy; concentrates accountability; lets Platform reduce cognitive load without owning business logic. |

We adopt **stream-aligned teams with a thin platform/enabling spine** (Team Topologies model) because it is the only option that keeps the BA's context boundaries intact at the human layer.

### 18.2 Team-to-Context Ownership Map (Item 50)

The following is the binding ownership ledger. It is frozen from SA §17 and is the single source of truth for CODEOWNERS, on-call rotation, and ARB escalation routing.

| Team | Owns Contexts (#) | Runtime(s) | Primary Binding Rules |
|------|-------------------|-----------|----------------------|
| **Substrate** | Identity/KYC (1, C#), Catalog (2, Go), Analytics (12, Python), Platform Services (13, Go) | C#/.NET, Go, Python | R7 master-data OHS (Identity+Catalog), R6 audit sink |
| **Provenance Core** | Custody Ledger (3, Go), Provenance Graph/Recall (4, Go), Inventory/NIL (5, Go) | Go | R1 sole writer + event-sourced, Ch.27.1 fencing, Ch.27.2 RPO=0 |
| **Commerce** | B2C (6) | Node/TS | R8 offline-first parity, R3 escrow (buyer side) |
| **Exchange** | B2B (7) | Java/Spring | R3 escrow (trade side) |
| **Finance** | Finance (8) | Java/Spring | R2 no-shared-DB + exactly-once, R3 escrow saga, Ch.27.3/27.4 |
| **Logistics** | Logistics (9) | Go | R8 parity, custody hand-off events |
| **Risk & Enforcement** | Fraud (10) | Python + Go | R4 four-eyes |
| **Government** | Government (11) | C#/.NET | R5 read-mostly |
| **Event-Spine Enabling** | event-spine (Kafka-class) | — | R6 Published Language, append-only audit, no cross-store |
| **Platform / Infra / SRE** | api-gateway (Go), BFFs (Node/TS), offline-sync-gateway, shared libs, landing zone | Go, Node/TS | ADR-011 polyglot governance, Ch.27.7/27.8 |

**Rule O-1 — One Context, One Team.** Every context has exactly one owning team; no context is co-owned. **WHY:** dual ownership reintroduces the diffused-accountability failure mode and breaks ARB escalation routing.

**Rule O-2 — A Team May Own Multiple Contexts, Never Multiple Teams One Context.** Substrate owns four; that is permitted because those contexts share the "substrate" cognitive domain and runtimes. **WHY:** consolidation reduces team count and on-call surface where contexts are genuinely cohesive, while still keeping a single owner per context.

### 18.3 The Ownership Surface — What "Owning a Context" Means (Item 51)

A team that owns a context owns its **entire vertical slice** and is solely accountable for it. The ownership surface is fixed:

| Surface | Owned artifact | Enforcement |
|---------|---------------|-------------|
| **Domain model** | Aggregates, invariants, the ubiquitous language of the context | Code review by owning team only |
| **Code** | Service implementation in the assigned runtime | CODEOWNERS path-match |
| **Data store** | The context's private store; no other team reads or writes it (R6) | Network policy + schema-credential isolation |
| **Event contracts** | Published topics `<context>.<aggregate>.<Event>.vN`, schema-registry compatibility | Schema-registry gate, owning team approves all schema PRs |
| **API contracts** | gRPC OHS internal surface; REST `/v1` exposed via gateway/BFF | Contract test suite owned by producer |
| **SLA / SLO** | Latency, availability, RPO/RTO for the context; on-call rotation | OpenTelemetry SLO dashboards, error-budget policy |

**Rule O-3 — Own Your Store, Expose Only Contracts.** A context's store is private; integration happens *only* through its published events (R6) or its OHS gRPC interface, never by another team touching the store. **WHY:** R6 forbids cross-store access precisely so that stores can evolve independently; a peeking consumer freezes the producer's schema and reintroduces the shared-database anti-pattern that R2 exists to kill.

**Rule O-4 — The Producer Owns Backward Compatibility.** Within a major event version, the owning team must keep schemas backward-compatible (schema registry enforced); breaking changes require a new `.vN` topic and a published deprecation window. **WHY:** consumers across team boundaries cannot be coordinated synchronously at nation scale; compatibility is the contract that lets producer and consumer deploy independently.

**Rule O-5 — Own Your SLA.** The owning team carries the pager for its context. Money and custody contexts (Finance #8, Custody #3) carry the strictest SLOs and an RPO=0 commitment (Ch.27.2). **WHY:** accountability without operational consequence is theater; the team that can fix the invariant must feel the outage.

### 18.4 Codifying Never-Same-Team Constraints (§17.4)

The §17.4 segregations are **structural controls**, not guidelines. They are enforced so that no single team can both perform and unilaterally approve a sensitive action.

| Constraint | Meaning | WHY (control intent) |
|-----------|---------|----------------------|
| **Finance ⟂ all** | Finance team shares no context, repo, or store with any other team (R2) | Exactly-once money handling and reconciliation must be auditable in isolation; shared ownership would let a money bug hide behind another team's change. |
| **Fraud ⟂ Analytics** | The team detecting fraud is not the team modeling behavioral data | Prevents the scorer from grading its own training pipeline; preserves four-eyes (R4) at the org layer. |
| **Catalog ⟂ Custody** | Master-data authorship is separated from ledger authorship | Catalog (R7 OHS) defines *what* a thing is; Custody (R1) defines *who holds* it — conflating them would let a catalog edit silently rewrite provenance. |
| **Government ⟂ operational/Platform** | Gov context owned apart from operational and platform teams | R5 read-mostly + regulatory separation; prevents operational expediency from mutating sovereign records. |
| **B2C ⟂ B2B** | Commerce and Exchange are distinct teams | Different trust models and parity obligations (R8 consumer vs B2B); prevents one channel's incident from owning the other's release. |

**Rule O-6 — Segregation Is Enforced in CODEOWNERS and CI.** A pull request that would place a §17.4-conflicting pair under a common owner, or import across a forbidden boundary, is blocked by the dependency-direction lint (see 18.6) and the CODEOWNERS topology check. **WHY:** social conventions decay; the constraint must fail a build, not a memo.

**Alternative rejected:** *Trust-based segregation* (policy in a wiki, audited quarterly). Rejected because nation-scale money and custody risk (R1/R2/R4) cannot tolerate a quarter of undetected drift; controls must be synchronous with the commit.

### 18.5 The Platform / Enabling Team — Owns Substrate, Never Business Logic

The Platform/Infra/SRE team and the Event-Spine Enabling team exist to *reduce cognitive load* for stream-aligned teams, per Team Topologies.

**Rule O-7 — Platform Owns Shared Libraries, Gateway, BFF Shells, and the Landing Zone; It Owns Zero Business Invariants.** Platform owns the api-gateway, the BFF runtime shells, the offline-sync-gateway transport, shared client libraries (envelope `{success,data,error,meta}`, idempotency-key middleware, OTel instrumentation), and the sovereign landing zone. It does **not** own any aggregate, any business rule, or any context store.

**WHY:** if the platform team owned business logic, every stream team would depend on the platform team's backlog to ship features — recreating the layered-team bottleneck §18.1 rejected. The platform is a *thinnest viable* enabling layer: it provides paved roads (the envelope, idempotency, tracing, the spine) that every team consumes, and it stops there.

**Rule O-8 — The Event-Spine Team Owns the Pipe, Not the Payload Semantics.** The Enabling team owns Kafka-class transport, the schema registry mechanism, DLQ/retry/park-and-freeze machinery (Ch.27.5), and the append-only audit OHS sink (R6). The *meaning* of each event belongs to the producing context's team. **WHY:** R6 designates the spine as a Published Language carrier; carriers must be neutral, or the spine team becomes a hidden co-author of every domain.

**Alternative rejected:** *Platform owns the canonical domain library* (shared business types across contexts). Rejected because it would make the platform a write-path dependency for Custody (R1 sole writer) and Finance (R2 isolation), directly violating both rules and the polyglot cap (ADR-011) by forcing one shared type system across five runtimes.

### 18.6 Repository Mapping and Enforcement

Ownership maps to repositories one context per repository (Finance physically separate per R2), with `CODEOWNERS` as the machine-readable expression of §17.

```text
dokandar/
  identity-kyc/            owner: @substrate     runtime: dotnet
  catalog/                 owner: @substrate     runtime: go
  custody-ledger/          owner: @provenance    runtime: go   (R1 sole writer)
  provenance-graph/        owner: @provenance    runtime: go
  inventory-nil/           owner: @provenance    runtime: go
  b2c/                     owner: @commerce      runtime: node-ts
  b2b/                     owner: @exchange      runtime: java
  finance/   (SEPARATE)    owner: @finance       runtime: java  (R2 isolated repo+store)
  logistics/               owner: @logistics     runtime: go
  fraud/                   owner: @risk          runtime: python,go
  government/              owner: @government     runtime: dotnet
  analytics/               owner: @substrate     runtime: python
  platform-services/       owner: @substrate     runtime: go
  edge/ (gateway,bff)      owner: @platform      runtime: go,node-ts
  event-spine/             owner: @enabling      runtime: spine
```

| Enforcement gate | Mechanism | Rule served |
|------------------|-----------|-------------|
| Path ownership | `CODEOWNERS` requires owning-team approval on every path | O-1, O-6 |
| Cross-context import ban | Dependency-direction lint fails on forbidden imports | O-3, R6 |
| Finance isolation | Separate repo, separate store credentials, no shared module | R2, O-6 |
| Schema compatibility | Schema-registry CI gate on event PRs | O-4 |
| Polyglot cap | Runtime allow-list per repo; new language requires ARB | ADR-011 |
| Build order | Roadmap dependency graph gates dependent-context CI | Roadmap |

**Rule O-9 — Build Order Follows Ownership Dependencies.** Repositories are stood up in the Roadmap order (landing zone → spine → Identity/Catalog → Custody/Inventory → Finance gated → B2C → B2B → Logistics → Fraud/Gov → Analytics); a downstream team's context cannot pass integration CI until its upstream OHS contracts (R7 master data, R1 custody events) are published. **WHY:** ownership is only real once the contract a team depends on exists; sequencing the repos to the Roadmap prevents teams from stubbing invariants they do not own and then forgetting to remove the stub.

---

*Traceability:* SA §17 / §17.4 (topology, segregation); R1, R2, R6, R7 (sole-writer, isolation, no-cross-store, master-data OHS); R3/R4/R5/R8 (escrow, four-eyes, read-mostly, parity ownership); ADR-011 (polyglot cap); Ch.27.1/27.2/27.5/27.7/27.8 (fencing, RPO=0, park-and-freeze, runbooks, lint/cost); Engineering Execution Roadmap (build order).

---

## 19. Migration, Backward Compatibility & Deprecation

This chapter governs how DOKANDAR evolves persistent schemas, API contracts, and event contracts **without breaking** the actors that depend on them — citizens on USSD/SMS/IVR (R8), merchants on BFFs, partner ministries (R5), and the 12 downstream contexts coupled through the event-spine Published Language (R6). Change is continuous; correctness is not negotiable. The binding principle: **every change is reversible at every intermediate step, and no consumer is ever forced to upgrade in lockstep with a producer.** This realizes ADR-006 (loose coupling via OHS/Published Language), R2 (Finance isolation), and the Roadmap's gated build order.

### 19.53 Database Migration Strategy

**Rule M1 — Expand-Contract (Parallel-Change) is the only sanctioned schema-change pattern.** Every structural change to a persistent store proceeds through three independently deployable phases:

| Phase | What happens | Invariant held |
|-------|-------------|----------------|
| **Expand** | Add new columns/tables/topics, nullable or defaulted; backfill asynchronously. Old and new shapes coexist. | Old code still reads/writes the old shape. |
| **Migrate** | Dual-write to old+new; switch reads to new behind a flag; reconcile and verify parity. | Either shape can serve a read. |
| **Contract** | Once no code path references the old shape, drop it in a later, separate release. | Old shape unreferenced before removal. |

**WHY.** A nation-scale OS cannot take a maintenance window; citizens transact at 03:00 over IVR. Expand-contract makes each step a small, online, reversible deployment — a failed phase rolls back to the previous green state without data loss. It also decouples the schema change from the code change: the migration ships before the code that needs it, eliminating the deploy-ordering race that causes the classic "column not found" outage during rolling restarts.

**Alternatives compared and rejected:**

| Approach | Why rejected |
|----------|-------------|
| **Big-bang / stop-the-world migration** | Requires downtime — violates R8 offline-first availability and the money/custody SLOs (Ch.27). Irreversible mid-flight: a failure halfway leaves the store in an unknown state with no clean rollback. Unacceptable for the Custody Ledger (R1) and Finance (R2). |
| **Schema-on-read / no migration (versioned rows only)** | Pushes interpretation complexity into every reader forever; defeats the strong-consistency guarantees the ledger and Finance reconciler depend on. Accumulates unbounded shape-drift. |
| **Blue-green at the database level (clone + cut over)** | Doubles state for petabyte ledgers, and the cut-over of an event-sourced, sole-writer store (R1) cannot be made atomic with in-flight outbox/inbox traffic. Reserve blue-green for *stateless* service rollout (Ch. on deployment), not for stores. |

**Rule M2 — Migrations are per-service and never cross-service.** A migration touches exactly one store owned by exactly one context. No migration may read or write another context's database. This is the schema-level enforcement of R6 ("NO cross-store"), R2 (Finance no-shared-DB), and R7 (master data flows only via Identity/Catalog OHS, never via direct table access). Cross-context data movement happens **only** through published events or OHS gRPC — never through a shared migration script.

**WHY.** A cross-service migration would re-introduce the database-coupling that the bounded-context architecture exists to forbid, and would silently bypass the §17.4 NEVER-SAME-TEAM separations (e.g., a script touching both Catalog and Custody tables violates Catalog⟂Custody). Per-service migrations keep blast radius inside one team's ownership and one ARB-approved store.

**Rule M3 — Online, non-locking, idempotent, backward-recoverable.** Migrations must: avoid long-held locks (use additive DDL + background backfill in bounded batches); be re-runnable to completion if interrupted (each step checks "already applied"); and ship with a tested **down/compensation path** verified in staging against production-shaped data (ties to Ch.27.7 backup/restore drills). Backfills are throttled to protect live SLOs and never block the request path.

**Rule M4 — Event-sourced stores migrate by projection, not by rewrite.** For Custody Ledger and other event-sourced contexts (R1), the append-only event log is immutable: migrations create **new read-model projections** alongside old ones and cut reads over once rebuilt. The log itself is never mutated. **WHY.** The ledger's auditability and RPO=0 quorum guarantee (Ch.27.2) depend on append-only immutability; rewriting history would destroy the provenance chain that Recall (#4) and Government (#11) attest against.

### 19.54 Backward-Compatibility Rules (APIs & Events)

**Rule BC1 — Compatible-within-a-major-version is mandatory.** Within a stable major version (`/v1` REST, internal gRPC OHS, or an event topic at `.vN`), only **backward-compatible** changes are permitted. A breaking change requires a **new major version**, not an in-place edit.

| Change | Compatible? | Where it goes |
|--------|-------------|---------------|
| Add optional field / new enum-tolerant value | Yes | Same major version |
| Add new endpoint / new event type | Yes | Same major version |
| Widen an input acceptance | Yes | Same major version |
| Remove/rename a field; tighten a type; change semantics of an existing field; make an optional field required | **No — breaking** | New major version + dual-read window |

**Rule BC2 — Events are schema-registry-governed and backward-compatible within a major version.** Every event (`<context>.<aggregate>.<Event>.vN`) is registered in the schema registry under a **backward-compatibility** rule enforced at CI and at publish time: a new schema revision must be readable by consumers built against any prior revision of the same major version. Producers may add optional fields; they may never remove or repurpose one. **WHY.** The event-spine is the Published Language (R6) binding all 13 contexts; per-aggregate ordering (PPID/WLT/TXN) and exactly-once Finance consumption (R2) assume a stable contract. A silently incompatible schema would poison consumer inboxes and route otherwise-valid events to the DLQ (Ch.27.5), manifesting as a data-integrity incident, not a clean error.

*Compatibility-mode choice, compared:* **BACKWARD** (new schema reads old data) is chosen over **FORWARD** (old schema reads new data) and **FULL** because producers in this architecture deploy ahead of, and faster than, the long tail of consumers (offline gateways, government batch readers under R5). Optimizing for "new producer, old consumer survives" matches reality. FULL is too restrictive — it forbids even additive-with-default evolution that we routinely need; we reject it as needlessly blocking. Where a producer and a known-lagging consumer invert (rare), the registry rule is raised to FULL for that subject only, by ARB exception.

**Rule BC3 — Breaking change ⇒ new major + dual-read/dual-publish window.** A breaking event change publishes to a **new major topic** (`.vN+1`) while the producer continues emitting `.vN` for the full deprecation window; consumers migrate at their own pace and the old topic is retired only after zero-consumer is proven. A breaking API change exposes `/v2` alongside `/v1`; BFFs and gateway route both until `/v1` sunsets. **WHY.** Dual-running is the only way to honor "no lockstep upgrade" at nation scale where some consumers (USSD aggregators, ministry integrators) move on quarterly cycles.

**Rule BC4 — Tolerant Reader + envelope stability.** All consumers ignore unknown fields and never fail on additive change; the response envelope `{success,data,error,meta}` and `problem+json` error shape are themselves frozen contracts — their top-level structure never changes within a major version. Idempotency-key semantics on unsafe/money/custody writes are contract-stable: a key's meaning never changes mid-version. **WHY.** Tolerant reading lets producers ship additive changes without a consumer census; a moving envelope would break every client simultaneously.

### 19.55 Deprecation Policy

**Rule DEP1 — Minimum notice ≥ 2 release cycles.** No public contract (REST major version, gRPC OHS method, event major topic) is removed in fewer than **two full release cycles** after deprecation is announced. The clock starts at the *announcement*, not the *replacement ship date*.

**WHY.** Two cycles guarantees every consumer team sees the deprecation in at least one planning cycle and ships in the next — even teams on the slowest cadence. One cycle would force same-cycle migration on dependents, recreating lockstep coupling; "until someone complains" provides no planning signal and strands offline/IVR clients (R8) that cannot hot-update.

**Rule DEP2 — Deprecation is machine-announced and tracked.** A deprecation must carry: a `Deprecation` + `Sunset` signal on the contract (HTTP deprecation headers for REST; a `deprecated` marker + sunset timestamp in the schema-registry subject for events), an entry in the central API/event catalog, and a named replacement. **WHY.** Humans miss changelog lines; machine signals let gateways, BFFs, and consumer CI surface "you are calling a deprecated contract" automatically.

**Rule DEP3 — Consumer-migration tracking gates sunset.** Sunset is **evidence-gated, not date-gated alone.** A contract is removed only when **both** (a) the ≥2-cycle notice has elapsed **and** (b) observed traffic/consumer telemetry shows zero active dependents. Per-consumer migration status is tracked in the catalog; the producing team and ARB review it before retirement.

| Sunset gate | Source of truth |
|-------------|----------------|
| Notice elapsed | Catalog announcement date + cycle calendar |
| Zero `/v1` traffic | Gateway/BFF + OpenTelemetry usage metrics |
| Zero `.vN` consumers | Schema-registry consumer registration + topic consumer-group lag/activity |
| Sign-off | Producing team + ARB (per-key for custody/finance) |

**WHY.** A pure date-based sunset can sever a slow but critical consumer — e.g., a Government read-mostly integration (R5) or a Finance reconciler (R2) whose silent breakage is a financial-integrity incident. Requiring observed zero-traffic plus elapsed notice makes sunset safe *and* timely, and prevents zombie contracts from lingering forever (the failure mode of telemetry-only with no deadline).

**Rule DEP4 — Strictest contracts get the longest courtesy.** Money, custody, and government contracts default to the **upper** bound of the notice window and require explicit ARB + four-eyes (R4) sign-off to retire; experimental/internal-only contracts may use the minimum. **WHY.** Blast radius and reversibility differ by domain — the policy scales notice to consequence, consistent with the money/custody SLO strictness mandated across the SA and Ch.27.

---

## 20. Technical Debt, Incident Response & Operational Readiness

This chapter governs how DOKANDAR carries, retires, and is forbidden from accruing engineering debt; how it detects, contains, and learns from incidents; and the binding gate every service crosses before it touches production traffic. It realizes SA Ch.27 remediations — particularly Ch.27.6 (test/chaos), Ch.27.7 (backup/restore + runbooks + incident), and Ch.27.8 (cost/rotation/lint) — and enforces the invariants R1–R8. Nothing here changes the Business Architecture; it operationalizes it.

The governing principle: **debt, incidents, and readiness are not symmetric across contexts.** A latency regression in Catalog search is a managed trade-off; the same posture applied to Custody (R1), Finance (R2), or escrow (R3) is a constitutional violation. The standards below encode that asymmetry.

---

### 20.1 Technical Debt Policy (Roadmap item 56)

**Rule 56.1 — Every piece of debt is registered or it does not exist.** No team may carry undocumented shortcuts. Each deliberate compromise is recorded in a **Debt Register** entry owned by the context team, carrying: `debt-id`, owning context, classification (below), the invariant/SLO at risk, blast radius, remediation plan, and a hard **expiry sprint**. The register is a tracked artifact reviewed at every sprint boundary by the owning team and audited quarterly by the Architecture Review Board.

**WHY:** Undocumented debt is indistinguishable from a latent defect until it detonates. A nation-scale commerce OS cannot absorb surprise. Forcing registration converts hidden risk into a governed, schedulable liability and gives the ARB the cross-context visibility ADR-011 (capped polyglot, central governance) requires.

**Rule 56.2 — Classification drives the budget.** Every entry is one of:

| Class | Definition | Allowed? | Max life |
|-------|-----------|----------|----------|
| **Forbidden** | Touches a money/custody/provenance invariant (R1 sole-writer, R2 no-shared-DB + exactly-once, R3 escrow saga, R6 no cross-store, integer-poisha correctness, R4 four-eyes) | **NEVER** | n/a |
| **Structural** | Architectural seams, missing abstraction, OHS contract drift | Yes, gated | 3 sprints |
| **Quality** | Test gaps, lint debt, weak observability, doc lag | Yes | 2 sprints |
| **Cosmetic** | Naming, formatting, minor duplication | Yes | Backlog |

**Rule 56.3 — Zero-debt invariant on money and custody.** No Forbidden-class debt may ever be opened against Contexts #3 (Custody Ledger), #8 (Finance), or the integer-poisha money type. A pull request that weakens exactly-once, the outbox/inbox guarantee, per-aggregate ordering (PPID/WLT/TXN), or four-eyes is blocked at review and cannot be "registered for later."

**WHY / alternatives compared:** Three postures were considered.

- *Uniform debt budget across all contexts (rejected).* Simple to administer, but it implies a money-correctness bug can be parked like a CSS bug. R2's exactly-once and BR-driven financial integrity have **no acceptable failure budget**; a single mis-ledgered poisha is a regulatory and trust event, not a backlog item.
- *No debt anywhere, ever (rejected).* Intellectually pure but operationally false — it drives debt underground (violating 56.1) and stalls the Roadmap's phased delivery, where Catalog/B2C iterate fast while Finance is gated.
- *Tiered budget keyed to invariant criticality (chosen).* Matches the BA's own asymmetry: R1/R2 are absolute; Catalog (G1) and B2C are evolutionary. It lets fast contexts move while making the protected core un-compromisable.

**Rule 56.4 — Per-sprint debt budget.** Each context team allocates **≤20% of sprint capacity** to remediation and **may not** start a sprint with more than its class-weighted debt ceiling open. Exceeding the ceiling freezes new feature work for that context until the register is drained. The budget is a floor for paydown and a ceiling for accrual — never a license to accrue.

**WHY:** A fixed paydown allotment prevents the classic failure where debt compounds because "there's never time." Capping open debt prevents teams from gaming the allotment by accruing faster than they pay. The 20% figure is governance, not optimization — it keeps remediation continuously funded without starving Roadmap delivery.

**Rule 56.5 — Cross-team debt is escalated, never absorbed.** Debt that spans an OHS contract (R7 Identity/Catalog master data, R6 event-spine Published Language) cannot be unilaterally accepted by a downstream consumer; it is escalated to the ARB because the NEVER-SAME-TEAM separations (§17.4) mean no single team owns both sides. This prevents Finance from silently absorbing a Custody contract compromise — a separation R2 exists to protect.

---

### 20.2 Incident Response (Roadmap item 57)

**Rule 57.1 — Severity is defined by what is at risk, not by symptom volume.** The severity matrix is binding and drives paging, freeze, and four-eyes posture.

| Sev | Trigger | Response | Freeze posture |
|-----|---------|----------|----------------|
| **SEV1** | Money loss/corruption, Custody invariant breach (R1), crown-jewel compromise (HSM signing keys, KMS roots, Identity master data), exactly-once violation (R2) | Immediate **page**; Incident Commander engaged ≤5 min; **four-eyes freeze** of the affected aggregate (per-key park-and-freeze, Ch.27.5) | Affected money/custody writes frozen; co-sign required to thaw (Ch.27.3) |
| **SEV2** | Customer-facing outage of a core flow (checkout, escrow settlement, B2B order), SLO breach on a money/custody path with no confirmed loss | Page on-call; IC optional; degrade-not-fail (offline-first R8 fallbacks engaged) | Targeted; no global freeze |
| **SEV3** | Degraded non-critical path (Catalog search latency, Analytics lag), single-AZ noise | Ticket; next-business-hour | None |

**WHY / alternative rejected:** A symptom-severity scheme (rejected) — ranking by error-rate or user count — would rank a viral Catalog search outage above a silent single-transaction ledger corruption. That inverts the BA's value hierarchy. **Asset-at-risk severity (chosen)** guarantees that any money/custody/crown-jewel signal is SEV1 by definition, however small the blast radius, because R1/R2 integrity is non-negotiable.

**Rule 57.2 — SEV1 invokes four-eyes freeze automatically.** A SEV1 on a money or custody path triggers the per-key park-and-freeze (Ch.27.5) and requires **two-person authorization** (R4) to resume processing. The freeze is the default; thaw is the exception requiring custodial co-sign (Ch.27.3) and, for payouts, respect of the cooling-off window (Ch.27.4). This makes "stop the bleeding" the automatic posture for the protected core, not a judgment call under pressure.

**Rule 57.3 — On-call is per-team and follows ownership.** Each context team (§17 ownership) runs its own on-call rotation; there is no central pager that owns everyone's services, because the NEVER-SAME-TEAM rule means no one team understands Finance, Custody, and Catalog simultaneously. Cross-context SEV1s convene a virtual bridge under a single Incident Commander drawn from Platform/SRE, who coordinates but does not override domain authority.

**Rule 57.4 — Every incident produces a blameless postmortem, audit-logged.** Within 5 business days, a postmortem is filed: timeline, contributing factors (systemic, not personal), customer/financial impact, and dated remediation actions that feed the Debt Register (56.1). Postmortems and all incident actions are written to the **append-only audit OHS sink (R6, Ch.27.7)** — the same immutable substrate used for custody events — so the incident record is tamper-evident and regulator-presentable.

**WHY:** Blameless culture is the only proven way to surface true root causes; blame drives concealment, which is fatal at nation scale. Audit-logging to the append-only sink (rejected alternative: ordinary ticketing) is mandatory because Government (R5) and financial regulators must be able to verify what happened to money and custody without trusting a mutable internal tool.

**Rule 57.5 — Remediations are tracked to closure.** Postmortem actions are debt entries with expiry sprints; a SEV1 cannot be considered "closed" until its top contributing factor has a funded remediation. This closes the loop between 57 and 56.

---

### 20.3 Operational Readiness Review (Roadmap item 58)

**Rule 58.1 — No service reaches production without passing the ORR gate.** The ORR is a hard, signed gate owned jointly by the context team and Platform/SRE. It is checklist-driven, evidence-based (links to drills and dashboards, not assertions), and re-run on any change to a money/custody path.

**Universal ORR checklist (all contexts):**

| # | Requirement | Trace |
|---|-------------|-------|
| 1 | SLOs defined, instrumented, alerting (OpenTelemetry tracing live) | SA observability |
| 2 | Runbooks for top failure modes published and rehearsed | Ch.27.7 |
| 3 | Backup taken **and a restore drill passed** | Ch.27.7 |
| 4 | DLQ + retry-with-backoff + park-and-freeze wired and tested | Ch.27.5 |
| 5 | Idempotency-key enforced on all unsafe writes | SA conventions |
| 6 | Secrets in KMS, rotation cadence configured; lint/cost gates green | Ch.27.8 |
| 7 | OHS/event contracts schema-registry backward-compatible | R6/R7 |
| 8 | On-call rotation staffed; severity matrix wired to paging | 57.1 |

**Rule 58.2 — Finance and Custody carry an elevated ORR.** Contexts #3 and #8 additionally require, **live and demonstrated**, not merely designed:

| # | Elevated requirement | Trace |
|---|----------------------|-------|
| F1 | Fencing tokens active (no split-brain writes) | Ch.27.1 |
| F2 | RPO=0 quorum replication proven (zero-loss failover drill) | Ch.27.2 |
| F3 | Custodial co-sign enforced on thaw/release | Ch.27.3 |
| F4 | Payout cooling-off window enforced | Ch.27.4 |
| F5 | Separate repo + independent reconciler operating (no shared DB) | R2 |
| F6 | Exactly-once verified end-to-end under chaos injection | Ch.27.6 |

**WHY / alternative rejected:** A *single uniform ORR* (rejected) would either over-burden Catalog/B2C with Finance-grade drills or, fatally, let Finance ship without proving RPO=0 and fencing. A *self-attestation gate* (rejected) fails the audit and four-eyes requirements — readiness for money cannot be self-certified. The **two-tier, evidence-based ORR (chosen)** matches the Roadmap build order (Finance is gated after Custody/Inventory, before B2C) and ensures the protected core proves its Ch.27.1–27.4 remediations are *running in production conditions*, validated by chaos and restore drills, before a single poisha flows.

**Rule 58.3 — ORR sign-off requires cross-team independence.** Per §17.4, the ORR for Finance is co-signed by a reviewer outside the Finance team, Custody is co-signed outside Provenance Core's writer, and Government readiness is signed off independently of operational/Platform teams. **WHY:** the same separations that protect the architecture must protect the gate that admits it to production; a team cannot be the sole judge of its own readiness on a protected invariant.

**Trace:** 56→Ch.27.8/ADR-011; 57→Ch.27.5/27.7, R4; 58→Ch.27.1–27.4/27.6/27.7, R1/R2, Roadmap build order.

---

## 21. Recommended Build Order

This chapter fixes the **engineering build sequence** for DOKANDAR — the order in which contexts, edges, and the spine are constructed, gated, and promoted to production. It is the operational projection of the **Roadmap's 12 phases (§10/§16/§19)** onto the Engineering Foundation's own prerequisites: a context may not begin until the EF artifacts it depends on are *live and proven*, not merely *designed*. The build order is **dependency-optimal**, meaning every wave consumes only capabilities produced by an earlier wave, and never forward-references a not-yet-built one. We encode this as eight waves (0–7).

### Governing principle: dependency-optimal, not value-optimal

> **Rule 21.0** — Build order is determined by **technical dependency and risk-gating**, not by perceived business value. A context that delivers revenue (e.g., B2C) is still built *after* the substrate it stands on (Custody, Finance), regardless of commercial pressure.

**WHY.** Nation-scale commerce with a sole-writer custody ledger (R1), an isolated Finance domain (R2), and append-only audit (R6) is a layered system: the integrity guarantees of upper layers are *defined in terms of* lower layers. Building B2C before Custody exists would force teams to stub the ledger, then retrofit exactly-once and event-sourcing semantics — the single most expensive class of rework in this architecture.

**Alternatives compared and rejected.**

| Strategy | Description | Verdict |
|---|---|---|
| **Value-first / vertical-slice** | Ship a thin B2C purchase path end-to-end first, fill in rigor later | **Rejected** — money/custody correctness cannot be "filled in later"; R1/R2/27.2 are foundational invariants, not features |
| **Big-bang parallel** | All 13 contexts built concurrently | **Rejected** — Identity/Catalog master-data OHS (R7) and the spine (R6) are upstream of everything; parallel start creates contract churn and integration deadlock |
| **Dependency-optimal layered (chosen)** | Platform → spine → master-data → custody → finance → demand-side → risk/gov → analytics | **Chosen** — each wave's contracts are frozen before consumers build against them |

The chosen strategy aligns one-to-one with the Roadmap's stated order: *sovereign landing zone → spine → Identity/Catalog → Custody/Inventory → Finance (gated) → B2C → B2B → Logistics → Fraud/Gov → Analytics.*

---

### 21.1 Wave 0 — Platform foundation (shared libs, CI/CD, repos, standards live)

> **Rule 21.1** — No context team writes business code until: (a) per-language shared libraries (envelope, problem+json, idempotency-key, OTel context propagation, outbox/inbox helpers) exist for all five governed languages (ADR-011); (b) CI/CD with the polyglot lint/SAST/coverage gates (Ch.27.8) is enforcing; (c) the repo topology and branch/commit conventions are published; (d) the sovereign landing zone is provisioned.

**Prerequisite EF artifacts.** Repository standards (Ch.19), CI/CD pipeline gates (Ch.18), observability SDK conventions (Ch.15), secrets/KMS bootstrap (Ch.16).

**WHY this is first.** Every downstream guarantee — the `{success,data,error,meta}` envelope, idempotency on money/custody writes, per-aggregate ordering, mandatory tracing — is enforced *through shared libraries and pipeline gates*. If teams hand-roll these per context, drift is guaranteed and the ARB conventions become aspirational. Building the paved road before the first car is the cheapest possible point to standardize. Building it after even one context ships means retrofitting N services.

**Dependency-optimality.** Wave 0 has *no* business dependencies and is a hard prerequisite for *all* other waves; it therefore must be first and must be complete (not partial) before Wave 1.

---

### 21.2 Wave 1 — Event-spine + append-only audit sink

> **Rule 21.2** — The Kafka-class event-spine, schema registry (backward-compatible within major version), topic naming `<context>.<aggregate>.<Event>.vN`, DLQ/retry/park-and-freeze machinery (Ch.27.5), and the append-only audit OHS sink (R6) go live *before any context emits a domain event*.

**Prerequisite EF artifacts.** Eventing standards (Ch.10), schema-registry governance (Ch.11), DLQ/poison-handling (Ch.12), Published Language registry (R6).

**WHY second.** R6 mandates the spine as the *only* cross-context integration substrate and forbids cross-store reads. Therefore the spine is the universal upstream: Identity, Catalog, Custody, Finance — all publish/consume through it. The audit sink must exist simultaneously because R6 requires *every* state transition to be auditable from the first event; standing it up later leaves an un-auditable gap in the historical record, unacceptable for a system answering to Government (#11) and recall (#4).

**Alternative rejected.** *Point-to-point gRPC first, spine later.* Rejected: it would normalize synchronous cross-context coupling, directly violating R6 and forcing a later, painful migration of established call graphs to async events.

---

### 21.3 Wave 2 — Identity + Catalog (master-data OHS, R7)

> **Rule 21.3** — Identity/KYC (#1) and Catalog (#2) are built together as the **master-data Open-Host Services (R7)**, exposing stable Published Language that all downstream contexts conform to.

**Prerequisite EF artifacts.** Wave 0 + Wave 1 live; OHS/PL contract standards (Ch.7), API versioning (Ch.8), RBAC/ABAC PDP scaffolding (Ch.16) — Identity is the issuer of the identities the PDP evaluates.

**WHY third.** R7 designates Identity and Catalog as upstream master data. *Every* transactional context references a party (buyer/seller/agent) and a product. If Custody or B2C built first, they would invent local identity/product notions and later reconcile — the classic distributed master-data anti-pattern. Identity also bootstraps authn/authz (OAuth2/OIDC, short JWT, mTLS), which every later service needs to even be callable. Note the **NEVER-SAME-TEAM** constraint (§17.4): Catalog ⟂ Custody — both Provenance-adjacent yet owned by different teams (Substrate vs Provenance Core), so building Catalog in Wave 2 keeps the team boundary clean before Custody arrives in Wave 3.

---

### 21.4 Wave 3 — Custody + Inventory + Provenance (R1, prod-gated by 27.1/27.2)

> **Rule 21.4** — Custody Ledger (#3, sole writer, event-sourced, R1), Inventory/NIL (#5), and Provenance Graph/Recall (#4) are built as one wave by the Provenance Core team. **Production promotion is gated** by fencing (27.1) and RPO=0 quorum replication (27.2); lower environments may run ungated for development.

**Prerequisite EF artifacts.** Event-sourcing standards (Ch.13), sole-writer enforcement pattern (R1), per-aggregate ordering by PPID/WLT (Ch.10), fencing-token design (27.1), quorum/RPO=0 runbook (27.2, Ch.27.7).

**WHY fourth.** Custody is the integrity heart of the system: it is the authoritative record of who holds what. It depends on Identity (party) and Catalog (product) from Wave 2 and on the spine (Wave 1) to publish custody events. It must precede Finance and all demand-side contexts because escrow (R3) and the money path settle *against* custody state. The **27.1/27.2 production gate** exists because a sole-writer ledger with split-brain or data loss is catastrophic and irreversible — so we permit development to proceed un-gated but **forbid production traffic** until fencing and zero-RPO quorum are proven via the Ch.27.7 restore drills.

**Alternative rejected.** *Build Inventory before Custody.* Rejected: NIL inventory positions are derived from custody movements; inverting the order forces inventory to fabricate provenance it cannot own.

---

### 21.5 Wave 4 — Finance (gated 27.2/27.3/27.4)

> **Rule 21.5** — Finance (#8, Java/Spring) is built next, in its **own repository with no shared database (R2)** and a separate reconciler delivering exactly-once. Production promotion is gated by RPO=0 (27.2), custodial co-sign (27.3), and payout cooling-off (27.4).

**Prerequisite EF artifacts.** Finance isolation standard (R2), exactly-once/outbox-reconciler pattern (Ch.14), escrow saga design (R3), four-eyes PDP (R4), co-sign and cooling-off controls (27.3/27.4), money = integer poisha invariant.

**WHY fifth.** Finance settles against Custody (Wave 3) and identifies parties via Identity (Wave 2); it cannot be correct before either exists. R2 mandates strict isolation — separate repo, no shared store — so Finance is *deliberately sequenced as its own wave* rather than folded into Custody, reinforcing the **Finance ⟂ all** team rule (§17.4). The triple production gate reflects that financial errors are legally and reputationally unrecoverable at nation scale.

---

### 21.6 Wave 5 — B2C + Logistics + money path

> **Rule 21.6** — B2C (#6, Node/TS) and Logistics (#9, Go) are built together to complete the first end-to-end consumer money path, exercising escrow (R3) across Custody and Finance, with **offline-first + USSD/SMS/IVR parity (R8)** mandatory from day one.

**Prerequisite EF artifacts.** BFF standards (Ch.9), saga orchestration (R3), offline-sync-gateway and channel-parity standard (R8), idempotency on all unsafe writes.

**WHY sixth.** B2C is the first *demand-side* consumer of everything below: Identity, Catalog, Custody, Finance, spine. Pairing Logistics here closes the physical-fulfilment loop the money path depends on for release-from-escrow. R8 parity is built *in*, not bolted on, because Bangladesh-scale reach requires USSD/SMS/IVR equivalence — retrofitting parity onto a web-first design is a known failure mode. **B2C ⟂ B2B** (§17.4) keeps the two demand-side contexts on separate teams; B2C goes first as it has fewer counterparty/credit dependencies.

---

### 21.7 Wave 6 — B2B + Fraud

> **Rule 21.7** — B2B (#7, Java/Spring) and Fraud (#10, Python+Go) are built together: B2B extends the exchange to multi-party trade; Fraud applies **four-eyes enforcement (R4)** across the now-live money and custody flows.

**Prerequisite EF artifacts.** Exchange contract standards (Ch.7/8), four-eyes workflow (R4), risk decisioning + park-and-freeze integration (Ch.27.5).

**WHY seventh.** Fraud requires *real* event streams from Custody, Finance, B2C, and Logistics to train and act on; building it earlier would mean modelling against synthetic data. B2B reuses the escrow/money patterns proven in Wave 5. **Fraud ⟂ Analytics** (§17.4) is respected by keeping Fraud (Risk & Enforcement) distinct from the Analytics team in Wave 7.

---

### 21.8 Wave 7 — Government + Analytics

> **Rule 21.8** — Government (#11, C#/.NET, read-mostly R5) and Analytics (#12, Python) are built last, as **downstream read consumers** of the audit sink and event-spine.

**Prerequisite EF artifacts.** Read-mostly access standard (R5), audit-sink consumption contracts (R6), data-governance/PII standards (Ch.16), reporting SLAs.

**WHY last.** Both are terminal consumers: they observe the system rather than drive it, so they depend on the *complete* upstream event corpus. **Government ⟂ operational/Platform** (§17.4) keeps regulatory read access organizationally separate from the systems it oversees. Building these last guarantees they report on a stable, fully-instrumented platform rather than a moving target.

---

### Build-order summary

```text
W0 Platform libs + CI/CD + repos        → enables all
W1 Event-spine + audit sink (R6)        → enables all eventing
W2 Identity + Catalog (R7 OHS)          → master data for all
W3 Custody + Inventory + Provenance     → [PROD GATE 27.1/27.2]
W4 Finance (R2 isolated)                → [PROD GATE 27.2/27.3/27.4]
W5 B2C + Logistics + money path (R3/R8)
W6 B2B + Fraud (R4)
W7 Government (R5) + Analytics
```

Each arrow is a *hard* dependency: no wave may begin business implementation until its predecessors' EF contracts are frozen and live, and no gated wave may enter production until its Ch.27 remediations pass the Ch.27.7 verification drills.

---

## Appendix A — Open Questions, Quality Checklist, Approval & Revision

*This appendix closes the internal-ARB editorial findings MIN-1 (glossary authority) and MIN-2 (document self-compliance with the Ch.15 documentation standard), completing the document for freeze.*

### A.1 Glossary References (MIN-1 closed)

Canonical term definitions are owned by the frozen documents and are **not** redefined here. Authority order on any term conflict: **BA > SA > Roadmap > Foundation**.

| Term class | Source of truth |
|---|---|
| Business & local terms (Faria, arot, maund, MFS, NID, BIN, TIN, TCB, poisha) | **BA §32 Glossary** |
| System identifiers (DID, GPID, PPID, ORD, SHP, WLT, TXN, CON, FWD) | BA §IDs / SA |
| Architecture terms (custody, escrow saga, OHS, Published Language, CQRS, projection, RPO/RTO, fencing, park-and-freeze) | SA (Ch.17–27) |
| Engineering-process terms (DoR, DoD, ORR, CODEOWNERS, expand-contract, consumer-driven contract, architecture-fitness function, transactional outbox/inbox) | Defined inline in this Foundation at first use |

### A.2 Open Questions (tracked; none block the freeze)

| ID | Open question | Owner | Disposition |
|---|---|---|---|
| OQ-EF-1 | Final build-system tooling for the chosen repository topology | Platform | Decided in principle (Ch.2); tooling pinned at repo bootstrap (Roadmap Phase 5) |
| OQ-EF-2 | CI/CD platform confirmation (GitHub Actions per Roadmap Phase 7) | DevOps | Standards in Ch.14 are platform-neutral; selection ratified in System Architecture |
| OQ-EF-3 | Exact per-language formatter/linter/SAST toolset | Each team | Policy fixed (Ch.5/Ch.13); concrete tools pinned at repo bootstrap |
| OQ-EF-4 | Sovereign deployment substrate (BLK-001) | EO/Architecture | Resolved via the Infrastructure Feasibility Study; ratified by ADR-S001 before System Architecture |

These are implementation-tooling and downstream-phase choices, **not** constitutional gaps.

### A.3 Document Quality Checklist (MIN-2 closed — self-compliance with Ch.15)

| Documentation-standard requirement | Status |
|---|---|
| Purpose / Scope / References | ✅ Ch.1 front-matter |
| Traceability to BA/SA/ADR/R/Roadmap | ✅ 621 references |
| Glossary references | ✅ §A.1 |
| Assumptions / Constraints | ✅ Ch.1 |
| Architecture decisions justified (WHY) | ✅ 213 WHY statements |
| Alternatives compared & explicitly rejected | ✅ 202 rejections |
| Open questions | ✅ §A.2 |
| Risks / Future considerations | ✅ per-chapter + Roadmap §17 |
| Revision history | ✅ §A.4 |
| Quality checklist | ✅ this section |
| Approval status | ✅ §A.5 |
| Document version | ✅ v1.0 |

### A.4 Revision History

| Version | Date | Change | Authority |
|---|---|---|---|
| 1.0 | 2026-06-26 | Initial constitution baseline — 21 chapters / 60 standards; internal ARB PASS (0 Critical, 0 Major); editorial findings MIN-1/MIN-2 closed via this appendix | Engineering Office |

### A.5 Approval Status

- **Internal ARB verdict:** PASS — 0 Critical, 0 Major.
- **Editorial findings:** MIN-1, MIN-2 — CLOSED (this appendix). MIN-3 (repo-decision singularity) — confirmed unambiguous in Ch.2.
- **Cross-reference verification:** chapter cross-references validated; no dangling reference remains (the glossary appendix promised in Ch.1 is §A.1).
- **Status:** **Engineering Foundation v1.0 (FROZEN)** — read-only. No modification is permitted except through a formal ADR that explicitly authorizes a constitutional change.
