"""
dkdgen CLI — the single entrypoint that turns frozen contracts into SDKs.

  python -m dkdgen generate --lang all   --contracts <dir> --out <sdk-dir>
  python -m dkdgen generate --lang java  ...
  python -m dkdgen verify   --contracts <dir>      # freeze-integrity only

Every emitter consumes the same IR, so all SDKs have identical semantics.
"""
from __future__ import annotations
import argparse
import os
import sys

from .contracts import load, verify_freeze, ContractError
from .version import build_metadata, GENERATOR_VERSION
from .emitters import EMITTERS

DEFAULT_LANGS = ["java", "go", "typescript", "python", "csharp", "openapi"]


def _resolve(p: str) -> str:
    return os.path.abspath(os.path.expanduser(p))


def cmd_generate(args) -> int:
    contracts_dir = _resolve(args.contracts)
    out_root = _resolve(args.out)
    try:
        c = load(contracts_dir)
    except ContractError as e:
        print("CONTRACT ERROR: %s" % e, file=sys.stderr)
        return 2
    meta = build_metadata(c.spine_version, build_time=args.build_time)
    langs = DEFAULT_LANGS if args.lang == "all" else [args.lang]
    rc = 0
    for lang in langs:
        emitter = EMITTERS.get(lang)
        if emitter is None:
            print("  %-10s SKIP (emitter not installed)" % lang)
            rc = max(rc, 1)
            continue
        out = os.path.join(out_root, lang)
        written = emitter.emit(c, meta, out)
        print("  %-10s OK  %3d files -> %s" % (lang, len(written), os.path.relpath(out, os.getcwd())))
    print("generated from contracts v%s with dkdgen v%s" % (c.spine_version, GENERATOR_VERSION))
    return rc


def cmd_verify(args) -> int:
    try:
        v = verify_freeze(_resolve(args.contracts))
    except ContractError as e:
        print("FREEZE CHECK FAILED: %s" % e, file=sys.stderr)
        return 2
    print("freeze-integrity OK — contracts v%s" % v)
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="dkdgen", description="DOKANDAR platform SDK generator")
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate")
    g.add_argument("--lang", default="all", choices=DEFAULT_LANGS + ["all"])
    g.add_argument("--contracts", required=True)
    g.add_argument("--out", required=True)
    g.add_argument("--build-time", default=None)
    g.set_defaults(func=cmd_generate)
    v = sub.add_parser("verify")
    v.add_argument("--contracts", required=True)
    v.set_defaults(func=cmd_verify)
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
