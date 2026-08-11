#!/usr/bin/env python3
"""
CustodyHash Spec v2 — shared cross-language golden vector generator.

This is the REFERENCE ORACLE for the 5-runtime byte-identical gate (DM §2 / §10, PL-01).
It reproduces custody-ledger-svc/internal/custody/canonical.go byte-for-byte (proven: TV-01
digest ac543fec…). It emits custodyhash_vectors.json — the single fixture every SDK
(go/java/csharp/python/typescript) loads and must match on BOTH canonical bytes and digest.

Do not hand-edit the JSON; regenerate with `python3 gen_vectors.py`.
"""
import hashlib
import json
import os


def canonical(v):
    """Serialize per CustodyHash Spec v2 rules R1–R9."""
    if v is None:
        raise ValueError("null forbidden outside omitted object members (R2)")
    if isinstance(v, bool):
        return "true" if v else "false"  # R7 — MUST precede int (bool is a subclass of int)
    if isinstance(v, dict):
        keys = sorted(k for k, val in v.items() if val is not None)  # R2 omit null, R3 sort
        return "{" + ",".join(enc_str(k) + ":" + canonical(v[k]) for k in keys) + "}"  # R4
    if isinstance(v, list):
        return "[" + ",".join(canonical(e) for e in v) + "]"  # R8 order preserved, R9 recurse
    if isinstance(v, int):
        return str(v)  # R6 plain decimal
    if isinstance(v, float):
        if v.is_integer() and abs(v) <= 2 ** 53:
            return str(int(v))  # integral floats re-encode as R6 integers
        raise ValueError("non-integral float has no canonical encoding (R6)")
    if isinstance(v, str):
        return enc_str(v)
    raise TypeError(f"no canonical encoding for {type(v)}")


def enc_str(s):
    """R5: UTF-8, no \\uXXXX for code points < U+0080; only mandatory escapes; no HTML escaping."""
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == '\\':
            out.append('\\\\')
        elif o == 0x08:
            out.append('\\b')
        elif o == 0x09:
            out.append('\\t')
        elif o == 0x0A:
            out.append('\\n')
        elif o == 0x0C:
            out.append('\\f')
        elif o == 0x0D:
            out.append('\\r')
        elif o < 0x20:
            out.append('\\u%04x' % o)
        else:
            out.append(ch)  # literal UTF-8: <, >, &, Bangla, emoji — all pass through (R5)
    out.append('"')
    return "".join(out)


def event_hash(fields):
    canon = {k: val for k, val in fields.items() if k != "eventHash"}  # eventHash always excluded
    s = canonical(canon)
    digest = hashlib.sha256(s.encode("utf-8")).hexdigest()
    return s, digest


# ---- Golden vectors: every R1–R9 edge case that historically diverges across runtimes ----
VECTORS = [
    {
        "name": "TV-01-genesis",
        "note": "DM §5 worked example — CustodyInitialized genesis, previousHash='' included",
        "fields": {
            "ppid": "PP-01JABCDEF", "gpid": "GP-rice-01JABCDEF",
            "holder": "did:dokandar:01JABCDEF", "holderRole": "PRODUCER",
            "quantity": 5000, "unit": "kg",
            "producedAt": 1750000000000, "initializedAt": 1750000001000,
            "previousHash": "",
        },
    },
    {
        "name": "TV-02-eventHash-excluded",
        "note": "eventHash present in input is UNCONDITIONALLY excluded — same digest as TV-01",
        "fields": {
            "ppid": "PP-01JABCDEF", "gpid": "GP-rice-01JABCDEF",
            "holder": "did:dokandar:01JABCDEF", "holderRole": "PRODUCER",
            "quantity": 5000, "unit": "kg",
            "producedAt": 1750000000000, "initializedAt": 1750000001000,
            "previousHash": "",
            "eventHash": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        },
    },
    {
        "name": "TV-03-null-omission",
        "note": "R2 — null members omitted; identical to a payload without them",
        "fields": {
            "ppid": "PP-XYZ", "quantity": 10, "previousHash": "abc",
            "optionalNote": None, "anotherNull": None,
        },
    },
    {
        "name": "TV-04-string-R5-unicode",
        "note": "R5 — Bangla, <, >, &, quote, backslash, control chars; no \\uXXXX for >=U+0080",
        "fields": {
            "ppid": "PP-বাংলা", "label": "a<b>c&d\"e\\f", "ctrl": "line1\nline2\ttab",
            "emoji": "\U0001F33E", "previousHash": "",
        },
    },
    {
        "name": "TV-05-nested-sorting-R3-R9",
        "note": "R3/R9 — keys sorted at every depth; R8 arrays NOT sorted",
        "fields": {
            "zeta": 1, "alpha": {"z": 3, "a": 2, "m": {"y": 1, "b": 2}},
            "list": [3, 1, 2, {"k": "v", "a": "z"}],
            "previousHash": "",
        },
    },
    {
        "name": "TV-06-int-bool-R6-R7",
        "note": "R6 bare int64 (incl. large + negative + zero), R7 lowercase bool",
        "fields": {
            "big": 9007199254740992, "neg": -42, "zero": 0,
            "flagT": True, "flagF": False, "previousHash": "",
        },
    },
    {
        "name": "TV-07-transfer",
        "note": "CustodyTransferred with a non-empty previousHash (chain continuation)",
        "fields": {
            "ppid": "PP-01JABCDEF", "fromHolder": "did:dokandar:AAA",
            "toHolder": "did:dokandar:BBB", "quantity": 5000, "unit": "kg",
            "transferredAt": 1750000002000,
            "previousHash": "ac543fecee75695fb2b1922ea9e0830f4bddb6ef1ad17e80f278d6171cbe0597",
        },
    },
    {
        "name": "TV-08-recalled-no-previousHash",
        "note": "§6 — ProductRecalled keyed by recallId, NOT chained, has NO previousHash field",
        "fields": {
            "recallId": "RECALL-01JXYZ", "gpid": "GP-rice-01JABCDEF",
            "reason": "contamination", "issuedBy": "did:dokandar:REGULATOR",
            "affectedPpids": ["PP-01JABCDEF", "PP-01JABCDEG"],
            "recalledAt": 1750000003000,
        },
    },
]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = []
    for v in VECTORS:
        s, digest = event_hash(v["fields"])
        assert len(digest) == 64 and digest == digest.lower()
        out.append({"name": v["name"], "note": v["note"], "fields": v["fields"],
                    "canonical": s, "digest": digest})
    doc = {
        "spec": "CustodyHash Specification v2 (DM §2, RFC-8785 subset R1-R9)",
        "oracle": "sdk/testvectors/gen_vectors.py == custody-ledger canonical.go",
        "note": "Every SDK MUST reproduce canonical (UTF-8 bytes) AND digest for each vector.",
        "vectors": out,
    }
    path = os.path.join(here, "custodyhash_vectors.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
        f.write("\n")
    for v in out:
        print(f"{v['name']:32} {v['digest']}")
    print(f"\nwrote {path} ({len(out)} vectors)")


if __name__ == "__main__":
    main()
