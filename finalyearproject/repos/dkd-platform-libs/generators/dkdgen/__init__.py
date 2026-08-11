"""dkdgen — the single canonical generator for DOKANDAR platform SDKs.

Reads the frozen dkd-contracts-spine v1.0.0 into one IR (dkdgen.ir.Contracts) and emits four SDKs
(Java, Go, TypeScript, Python) with identical semantics. Generates ONLY what the contracts
deterministically contain; deferred contract data is surfaced as framework/extension points, never
fabricated.
"""
from .version import GENERATOR_NAME, GENERATOR_VERSION
from .contracts import load, verify_freeze, ContractError

__all__ = ["load", "verify_freeze", "ContractError", "GENERATOR_NAME", "GENERATOR_VERSION"]
