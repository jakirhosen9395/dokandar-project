"""Language emitters. Each exposes emit(contracts, meta, out_dir) -> list[str] and consumes the same IR."""
from . import python_emit

# Registered lazily so a missing optional emitter never breaks the others.
EMITTERS = {"python": python_emit}

try:
    from . import java_emit
    EMITTERS["java"] = java_emit
except Exception:  # pragma: no cover
    pass
try:
    from . import go_emit
    EMITTERS["go"] = go_emit
except Exception:  # pragma: no cover
    pass
try:
    from . import typescript_emit
    EMITTERS["typescript"] = typescript_emit
except Exception:  # pragma: no cover
    pass
try:
    from . import csharp_emit
    EMITTERS["csharp"] = csharp_emit
except Exception:  # pragma: no cover
    pass
try:
    from . import openapi_emit
    EMITTERS["openapi"] = openapi_emit
except Exception:  # pragma: no cover
    pass
