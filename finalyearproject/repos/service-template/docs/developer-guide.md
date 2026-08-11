# Developer Guide (service-template)

## Local
```bash
cd scaffold
python -m dkdscaffold runtimes                 # installed emitters
python -m dkdscaffold new-service --name x-svc --context catalog --lang go --out /tmp/x
python -m pytest tests/ -q                     # blueprint conformance (all runtimes)
```

## How it works
`blueprint.py` defines the capability contract + Service model. `cli.py` resolves the runtime and
calls `runtimes/<rt>.emit(svc, out_dir)`. Each emitter calls `common.emit_common` (Helm/k8s/compose/
docs) then writes the runtime-specific source/Dockerfile/CI/dependency-manifest. One blueprint, five
emitters, identical capabilities.

## CI parity
`scaffold:tests` is exactly what runs in CI. If it's green locally, the template conforms. The
`sample:*` jobs additionally compile a generated service per runtime against `dkd-platform-libs`.

## Where to change what
| Want to change | Edit |
|---|---|
| A capability across all runtimes | `blueprint.py` + every `runtimes/*` + tests + docs |
| One runtime's output | `runtimes/<rt>.py` |
| Shared ops (Helm/k8s/compose/docs) | `runtimes/common.py` |
