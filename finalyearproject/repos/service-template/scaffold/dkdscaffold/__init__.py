"""dkd-scaffold — DOKANDAR polyglot service scaffolder.

One canonical blueprint, five runtime emitters (Go/Java/C#/Python/Node). Generates production-ready,
infrastructure-only service skeletons that consume dkd-platform-libs and realise the same capability
contract regardless of runtime. No business logic.
"""
from .blueprint import Service, RUNTIMES, CAPABILITIES

__all__ = ["Service", "RUNTIMES", "CAPABILITIES"]
