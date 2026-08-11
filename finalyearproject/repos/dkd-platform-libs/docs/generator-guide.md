# Generator Guide (`dkdgen`)

`dkdgen` is the single canonical generator. It reads the frozen contracts and emits all SDKs.

## Commands

```bash
python3 -m dkdgen verify   --contracts contracts                    # freeze-integrity only
python3 -m dkdgen generate --lang all  --contracts contracts --out sdk
python3 -m dkdgen generate --lang go   --contracts contracts --out sdk
bash scripts/generate.sh all                                        # deterministic wrapper used by CI
```

## How it works

1. **Parse + verify** — `dkdgen.contracts.load(dir)` verifies `spine.lock.yaml` SHA-256s, then builds
   the immutable `dkdgen.ir.Contracts` IR (identifiers, topics, queues, constants, enum families, OHS
   services, schema subjects, principles, roles, error taxonomy, `needs_info`).
2. **Emit** — each `dkdgen.emitters.<lang>_emit.emit(c, meta, out_dir)` renders the IR into idiomatic
   source via the shared `Writer` + naming helpers (`pascal/camel/snake/screaming/const_name`), so
   names derive identically across languages.

## Adding or changing an emitter

- Implement `emit(c, meta, out_dir) -> list[str]`; register it in `emitters/__init__.py`.
- Mirror the **reference** emitter `emitters/python_emit.py` artifact-for-artifact so semantics match.
- Never read anything outside the IR; never fabricate `NEEDS-INFO` data — emit a typed extension point.
- Add a generated test asserting the contract invariants (version, 59 topics, ID prefixes, money type).

## Provenance

`dkdgen.version.build_metadata(spine_version)` returns `{generator, generator_version,
contract_version, build_time, build_commit}`; `Writer.banner()` stamps it into every generated file.
Defaults are deterministic (stable committed source); the publish pipeline overrides
`DKDGEN_BUILD_TIME`/`DKDGEN_BUILD_COMMIT` for distributed artifacts.

## Guarantees enforced in CI

`generator:tests` (unit) · `contracts:compat` (freeze + version) · `generate:drift` (committed ==
regenerated). A drifted commit or a hand-edited SDK fails the pipeline.
