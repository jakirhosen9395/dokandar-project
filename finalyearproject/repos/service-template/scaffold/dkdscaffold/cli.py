"""
dkdscaffold CLI — generate a runtime-specific service skeleton from the canonical blueprint.

  python -m dkdscaffold new-service --name catalog-svc --lang go --context catalog --out ./out
  python -m dkdscaffold list-capabilities
  python -m dkdscaffold runtimes

Every generated service realises the same blueprint (health/ready/live, config, DI, logging, metrics,
tracing, correlation, JWT auth/authz, Kafka+RabbitMQ bootstrap, DB abstraction, Docker/Helm/k8s/CI,
unit+integration tests) — differing only where the target runtime requires.
"""
from __future__ import annotations
import argparse
import os
import sys

from .blueprint import Service, RUNTIMES, CAPABILITIES, CONTEXT_RUNTIME, DEFAULT_HTTP_PORT
from .runtimes import EMITTERS


def cmd_new_service(args) -> int:
    runtime = args.lang or CONTEXT_RUNTIME.get(args.context)
    if runtime not in RUNTIMES:
        print("ERROR: --lang must be one of %s (or a known --context)" % ", ".join(RUNTIMES), file=sys.stderr)
        return 2
    emitter = EMITTERS.get(runtime)
    if emitter is None:
        print("ERROR: no emitter installed for runtime %r" % runtime, file=sys.stderr)
        return 2
    svc = Service(name=args.name, context=args.context, runtime=runtime,
                  http_port=args.port, group=args.group)
    out = os.path.abspath(os.path.join(args.out, svc.slug))
    written = emitter.emit(svc, out)
    print("generated %s (%s) -> %s" % (svc.slug, runtime, os.path.relpath(out, os.getcwd())))
    print("  %d files; realises %d blueprint capabilities" % (len(written), len(CAPABILITIES)))
    return 0


def cmd_list_capabilities(args) -> int:
    for c in CAPABILITIES:
        print("  " + c)
    print("total: %d" % len(CAPABILITIES))
    return 0


def cmd_runtimes(args) -> int:
    for r in RUNTIMES:
        print("  %-8s %s" % (r, "available" if r in EMITTERS else "not-installed"))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="dkdscaffold", description="DOKANDAR polyglot service scaffolder")
    sub = ap.add_subparsers(dest="cmd", required=True)
    n = sub.add_parser("new-service")
    n.add_argument("--name", required=True)
    n.add_argument("--context", required=True)
    n.add_argument("--lang", choices=list(RUNTIMES), default=None)
    n.add_argument("--out", default="./out")
    n.add_argument("--port", type=int, default=DEFAULT_HTTP_PORT)
    n.add_argument("--group", default="final-year-project3354127")
    n.set_defaults(func=cmd_new_service)
    sub.add_parser("list-capabilities").set_defaults(func=cmd_list_capabilities)
    sub.add_parser("runtimes").set_defaults(func=cmd_runtimes)
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
