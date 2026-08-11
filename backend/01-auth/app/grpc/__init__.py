"""gRPC server — Auth service over :8001.

Protobuf stubs are generated at import-time from /app/proto/auth.proto.
This avoids checking generated files into the repo and keeps the schema
in one place. The cost is ~30 ms at startup; tolerable.
"""
