"""Generate risk_pb2 / risk_pb2_grpc at RUNTIME from proto/risk.proto (mirrors
01-auth/16-recommendation). Stubs are written to a writable per-process tmpdir so the
container runs as the non-root uid 10001."""
from __future__ import annotations
import importlib
import os
import sys
import tempfile
from pathlib import Path
from typing import Tuple

_PROTO_DIR = Path(__file__).resolve().parents[2] / "proto"
_OUT_DIR = Path(os.environ.get("RISK_GRPC_CODEGEN_DIR", tempfile.gettempdir())) / "dokandar_risk_grpc_stubs"


def _ensure_generated() -> Path:
    proto_file = _PROTO_DIR / "risk.proto"
    if not proto_file.exists():
        raise ImportError(f"risk.proto not found at {proto_file}.")
    _OUT_DIR.mkdir(parents=True, exist_ok=True)
    pb2, pb2_grpc = _OUT_DIR / "risk_pb2.py", _OUT_DIR / "risk_pb2_grpc.py"
    if pb2.exists() and pb2_grpc.exists():
        return _OUT_DIR
    from grpc_tools import protoc
    rc = protoc.main([
        "grpc_tools.protoc", f"--proto_path={_PROTO_DIR}",
        f"--python_out={_OUT_DIR}", f"--grpc_python_out={_OUT_DIR}", str(proto_file),
    ])
    if rc != 0:
        raise RuntimeError(f"grpc_tools.protoc failed: rc={rc}")
    return _OUT_DIR


def load_stubs() -> Tuple[object, object]:
    out = _ensure_generated()
    if str(out) not in sys.path:
        sys.path.insert(0, str(out))
    return importlib.import_module("risk_pb2"), importlib.import_module("risk_pb2_grpc")
