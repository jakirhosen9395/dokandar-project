# Contribution Guide (service-template)

This repo is the **golden template**: changes here affect every future service.

## Workflow
- Trunk-based; `main` protected, MR-only. Conventional Commits with a `Trace:` footer.
- Changing a runtime emitter (`scaffold/dkdscaffold/runtimes/*`) or the blueprint requires:
  1. `scaffold:tests` green (blueprint conformance for every runtime),
  2. `generate:samples` + `sample:*` build green (generated services still compile against the SDK),
  3. a doc update if the capability contract changed.
- Adding a capability = update `blueprint.py` CAPABILITIES + every runtime emitter + the tests + docs.

## Golden rules
- The template emits **infrastructure only** — never business logic, never an invented business rule.
- Abstractions (messaging/persistence) are real; concrete drivers are injection points, not placeholders.
- Frozen Architecture (Phase 0) and Contracts (Phase 1) are never modified — consume only.
- Generated services consume `dkd-platform-libs` as a versioned dependency, never copied source.

## Adding a runtime
Implement `runtimes/<rt>.py` with `emit(svc, out_dir)`, call `emit_common`, mirror `go.py` capability
-for-capability, add a `sample:<rt>` CI build job, and register the runtime in `blueprint.RUNTIMES`.
