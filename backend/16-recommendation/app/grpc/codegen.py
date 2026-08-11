"""Generate recommendation_pb2 / recommendation_pb2_grpc at RUNTIME from
proto/recommendation.proto (mirrors 01-auth/app/grpc/codegen.py).

Runtime codegen keeps the generated artifacts out of git (one source of truth: the
.proto) and costs ~30 ms once per process at startup. Stubs are written to a writable
per-process tmpdir so the container runs as the non-root uid 10001 without chmod.
"""
from __future__ import annotations
import importlib
import os
import sys
import tempfile
from pathlib import Path
from typing import Tuple

_PROTO_DIR = Path(__file__).resolve().parents[2] / "proto"
_OUT_DIR = Path(os.environ.get("RECO_GRPC_CODEGEN_DIR", tempfile.gettempdir())) / "dokandar_reco_grpc_stubs"


def _ensure_generated() -> Path:
    proto_file = _PROTO_DIR / "recommendation.proto"
    if not proto_file.exists():
        raise ImportError(
            f"recommendation.proto not found at {proto_file}. "
            "Ensure the `proto/` sibling of `app/` is shipped with the service."
        )
    _OUT_DIR.mkdir(parents=True, exist_ok=True)
    pb2 = _OUT_DIR / "recommendation_pb2.py"
    pb2_grpc = _OUT_DIR / "recommendation_pb2_grpc.py"
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
    out_s = str(out)
    if out_s not in sys.path:
        sys.path.insert(0, out_s)
    pb2 = importlib.import_module("recommendation_pb2")
    pb2_grpc = importlib.import_module("recommendation_pb2_grpc")
    return pb2, pb2_grpc
