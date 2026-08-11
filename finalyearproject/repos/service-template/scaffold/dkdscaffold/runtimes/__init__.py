"""Runtime emitters. Each exposes emit(service, out_dir) -> list[str] and realises the blueprint."""
EMITTERS = {}

for _name in ("go", "java", "csharp", "python", "node"):
    try:
        _mod = __import__("dkdscaffold.runtimes.%s" % _name, fromlist=["emit"])
        EMITTERS[_name] = _mod
    except Exception:  # pragma: no cover - emitter optional until installed
        pass
