"""Generate auth_pb2 / auth_pb2_grpc at runtime from proto/auth.proto.

Why runtime rather than build-time:
  - Keeps generated artifacts out of git (one source of truth: the .proto).
  - Costs ~30 ms once per process at startup.
  - The same wheel/source works without a separate codegen step.

If the .proto file is missing (e.g. someone copied only `app/` without
the sibling `proto/` dir), import raises ImportError with a clear hint.
"""
from __future__ import annotations
import importlib
import importlib.util
import os
import sys
import tempfile
from pathlib import Path
from typing import Tuple

_PROTO_DIR = Path(__file__).resolve().parents[2] / "proto"
# Generated stubs live in a writable per-process tmpdir so the container can
# run as a non-root user without needing chmod on /app. The image still ships
# /app/app/grpc/ owned by root with read-only perms.
_OUT_DIR = Path(os.environ.get(
    "AUTH_GRPC_CODEGEN_DIR",
    tempfile.gettempdir(),
)) / "dokandar_auth_grpc_stubs"


def _ensure_generated() -> Path:
    proto_file = _PROTO_DIR / "auth.proto"
    if not proto_file.exists():
        raise ImportError(
            f"auth.proto not found at {proto_file}. "
            "Ensure the `proto/` sibling of `app/` is shipped with the service."
        )
    _OUT_DIR.mkdir(parents=True, exist_ok=True)
    pb2 = _OUT_DIR / "auth_pb2.py"
    pb2_grpc = _OUT_DIR / "auth_pb2_grpc.py"
    if pb2.exists() and pb2_grpc.exists():
        return _OUT_DIR
    from grpc_tools import protoc  # type: ignore
    rc = protoc.main([
        "grpc_tools.protoc",
        f"--proto_path={_PROTO_DIR}",
        f"--python_out={_OUT_DIR}",
        f"--grpc_python_out={_OUT_DIR}",
        str(proto_file),
    ])
    if rc != 0:
        raise RuntimeError(f"grpc_tools.protoc failed: rc={rc}")
    return _OUT_DIR


def load_stubs() -> Tuple[object, object]:
    out = _ensure_generated()
    # grpc_tools.protoc generates `auth_pb2_grpc.py` that does
    # `import auth_pb2 as ...` — a top-level import. So we just put the
    # generated dir on sys.path and import them as plain top-level modules.
    out_s = str(out)
    if out_s not in sys.path:
        sys.path.insert(0, out_s)
    pb2 = importlib.import_module("auth_pb2")
    pb2_grpc = importlib.import_module("auth_pb2_grpc")
    return pb2, pb2_grpc
