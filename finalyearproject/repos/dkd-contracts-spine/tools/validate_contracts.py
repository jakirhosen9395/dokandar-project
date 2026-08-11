#!/usr/bin/env python3
"""
DOKANDAR Contracts-Spine validator (Stage 0.2).

Validates the Published-Language contracts against the invariants ALREADY defined in the frozen
canon — it invents no rule. If a canonical file violates a canonical invariant, this FAILS (exit 1)
and the deviation is reported upstream; it never edits the contracts.

Grounding:
  - Topic grammar `<context>.<aggregate>.<EventName>.v<N>`, one-producer-per-topic, IDs-only ......... R1/R6, S-TOPIC, ADR-016
  - Canonical vocabulary (DM wins; SA errata banned) ................................................. ADR-016
  - Persistence engine-of-record = SYS §8.1; MongoDB/RustFS/DuckDB unreconciled (not adopted) ........ ADR-017
  - Finance(#8)/Custody(#3) dedicated isolation ...................................................... R1/R2/ADR-002/ADR-004
  - Custody is sole writer of custody.* ............................................................. R1
  - Enum/actor registry doc-of-record; values NEEDS-INFO until transcribed ........................... FR-IDN-310/ADR-018

Usage: python3 validate_contracts.py [ROOT]   (ROOT defaults to the repo root = parent of tools/)
"""
import os, sys, re, json

try:
    import yaml
except ImportError:
    sys.exit("FATAL: PyYAML not available (CI installs it). pip install pyyaml")

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Canonical context map (messaging.yaml header lines 20-21; DM).
CTX = {1: "identity", 2: "catalog", 3: "custody", 4: "provenance", 5: "inventory", 6: "b2c",
       7: "b2b", 8: "finance", 9: "logistics", 10: "fraud", 11: "government", 12: "analytics",
       13: "platform"}
# Kafka topic context-prefix -> producing context number (only contexts that own a Kafka prefix).
PREFIX_CTX = {"identity": 1, "catalog": 2, "custody": 3, "b2c": 6, "b2b": 7, "finance": 8,
              "logistics": 9, "fraud": 10, "government": 11, "platform": 13}
# Read-only contexts that, by construction, produce ZERO cross-context topics (DM; reconciliation).
READ_ONLY_NONPRODUCERS = {4, 5, 12}
# Canonical ordering keys (DM "Ordering keys"; CLAUDE.md; messaging.yaml).
VALID_KEYS = {"DID", "GPID", "PPID", "parentPpid", "newPpid", "recallId",
              "ORD", "TRD", "WLT", "TXN", "ESC", "SHP", "directiveId"}
# ADR-016: Service-Architecture errata spellings that must NEVER appear (DM vocabulary wins).
ERRATA = ["PaymentSettled", ".parcel.", "EscrowHeld", "finance.ledger.", "markets.order.",
          "government.subsidy."]
# ADR-017: engines named in other L0 docs but absent from SYS §8.1 — not adopted into `services`.
UNRECONCILED_ENGINES = {"MongoDB", "RustFS", "DuckDB"}
TOPIC_RE = re.compile(r"^[a-z][a-z0-9]*\.[a-z][a-z0-9]*\.[A-Z][A-Za-z0-9]+\.v[1-9][0-9]*$")
DOC_SECTIONS = ["Purpose", "Scope", "References", "Traceability", "Glossary", "Assumptions",
                "Constraints", "ADRs", "Open Questions", "Risks", "Future", "Revision History",
                "Quality Checklist", "Approval", "Version"]

FAILS, WARNS, INFO = [], [], {}


def fail(code, msg):
    FAILS.append((code, msg))


def warn(code, msg):
    WARNS.append((code, msg))


def load_yaml(name):
    p = os.path.join(ROOT, name)
    if not os.path.isfile(p):
        fail("FILE", "missing required contract file: %s" % name); return None
    try:
        return yaml.safe_load(open(p, encoding="utf-8"))
    except Exception as e:
        fail("YAML", "%s does not parse: %s" % (name, e)); return None


SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$")
# ADR-021 machine-artifact Header Profile (required keys for every contract).
HEADER_PROFILE = ("id", "title", "layer", "taxonomy", "doc_class", "owner",
                  "classification", "status", "version", "trace", "last_verified")


def check_header(doc, name, want_trace):
    h = (doc or {}).get("header", {})
    for k in HEADER_PROFILE:                      # full ADR-021 header-profile compliance
        if k not in h:
            fail("HDR", "%s header missing ADR-021 profile key '%s'" % (name, k))
    if h.get("classification") != "Internal":
        fail("CLASS", "%s classification must be Internal (ADR-019), got %r" % (name, h.get("classification")))
    if h.get("doc_class") != "contracts":
        warn("DOCCLASS", "%s doc_class expected 'contracts', got %r" % (name, h.get("doc_class")))
    if not SEMVER.match(str(h.get("version", ""))):
        fail("VER", "%s header version not SemVer: %r" % (name, h.get("version")))
    tr = " ".join(map(str, h.get("trace", [])))
    for a in want_trace:
        if a not in tr:
            warn("TRACE", "%s header trace should cite %s" % (name, a))
    return h


# ---------------- messaging.yaml ----------------
def validate_messaging():
    doc = load_yaml("messaging.yaml")
    if not doc:
        return
    check_header(doc, "messaging.yaml", ["R6", "ADR-016", "R1"])
    kafka = (doc.get("buses") or {}).get("kafka") or {}
    topics = kafka.get("topics") or []
    baseline = kafka.get("topic_count_baseline")
    INFO["kafka_topics"] = len(topics)
    INFO["kafka_baseline"] = baseline

    # count vs baseline (ADR-016: derived, must equal baseline; never silently drop)
    if baseline != len(topics):
        fail("COUNT", "kafka topic_count_baseline=%s but %d topics listed (ADR-016)" % (baseline, len(topics)))
    if baseline != 59:
        fail("COUNT59", "kafka topic_count_baseline must be 59 (DM/messaging.yaml), got %s" % baseline)

    seen = {}
    producers = set()
    by_producer = {}
    for t in topics:
        for k in ("topic", "producer", "key", "consumers"):
            if k not in t:
                fail("ENV", "topic entry missing '%s': %r" % (k, t)); continue
        name = t.get("topic"); prod = t.get("producer"); key = t.get("key"); cons = t.get("consumers")
        # no duplicate event definition
        if name in seen:
            fail("DUP", "duplicate topic definition: %s" % name)
        seen[name] = True
        # grammar
        if not TOPIC_RE.match(str(name)):
            fail("GRAMMAR", "topic violates `<context>.<aggregate>.<EventName>.v<N>`: %s" % name)
            continue
        prefix = name.split(".", 1)[0]
        # event-envelope: producer/key/consumers well-typed and resolvable
        if not isinstance(prod, int) or prod not in CTX:
            fail("PRODUCER", "%s producer not a valid context 1-13: %r" % (name, prod))
        if not isinstance(cons, list) or any((c not in CTX) for c in cons):
            fail("CONSUMER", "%s consumers must be a list of valid contexts: %r" % (name, cons))
        if isinstance(cons, list) and prod in cons:
            fail("SELFCONSUME", "%s lists its own producer #%s as a consumer" % (name, prod))
        if key not in VALID_KEYS:
            fail("KEY", "%s ordering key %r not in canonical set" % (name, key))
        # context-prefix <-> producer consistency
        if prefix in PREFIX_CTX and prod != PREFIX_CTX[prefix]:
            fail("PREFIX", "%s prefix '%s' implies context #%s but producer=%s" % (name, prefix, PREFIX_CTX[prefix], prod))
        producers.add(prod)
        by_producer.setdefault(prod, []).append(name)
        # ADR-016 errata vocabulary
        for e in ERRATA:
            if e in name:
                fail("ADR016", "%s uses ADR-016 errata vocabulary %r (DM spelling wins)" % (name, e))

    # R1: custody (#3) is the SOLE writer of custody.* and produces ONLY custody.*
    for name in seen:
        if name.startswith("custody.") and seen.get(name):
            pass
    custody_topics = [n for n in seen if n.startswith("custody.")]
    for n in custody_topics:
        prod = next(t["producer"] for t in topics if t["topic"] == n)
        if prod != 3:
            fail("R1", "custody topic %s produced by #%s, must be #3 (R1 sole writer)" % (n, prod))
    for n in by_producer.get(3, []):
        if not n.startswith("custody."):
            fail("R1", "custody-svc (#3) produces non-custody topic %s (R1)" % n)

    # read-only contexts produce zero cross-context topics
    for c in READ_ONLY_NONPRODUCERS:
        if c in producers:
            fail("READONLY", "read-only context #%s (%s) appears as a topic producer" % (c, CTX[c]))

    # RabbitMQ: intra-context only, never a Kafka topic, prefix matches its context
    rmq = (doc.get("buses") or {}).get("rabbitmq") or {}
    queues = rmq.get("queues") or []
    INFO["rabbitmq_queues"] = len(queues)
    kafka_event_names = {n.split(".")[-2] + ".v" + n.split(".v")[-1] for n in seen}  # EventName.vN
    for q in queues:
        for k in ("queue", "context", "messages"):
            if k not in q:
                fail("RMQ", "queue missing '%s': %r" % (k, q))
        qn = q.get("queue", ""); ctx = q.get("context")
        if ctx not in CTX:
            fail("RMQCTX", "queue %s context %r invalid" % (qn, ctx))
        elif not qn.startswith(CTX[ctx] + "."):
            fail("RMQPREFIX", "queue %s does not match its context prefix '%s.' (R6 intra-context)" % (qn, CTX[ctx]))
        for m in q.get("messages", []):
            if isinstance(m, str) and m.endswith(".v1") and m in {n.split(".", 2)[-1] for n in seen}:
                fail("RMQKAFKA", "RabbitMQ message %s also appears as a Kafka topic (R6 bus split)" % m)
    INFO["topics_by_context"] = {CTX[p]: len(v) for p, v in sorted(by_producer.items())}


# ---------------- data-stores.yaml ----------------
def validate_data_stores():
    doc = load_yaml("data-stores.yaml")
    if not doc:
        return
    check_header(doc, "data-stores.yaml", ["SYS§8.1", "ADR-017", "R2"])
    services = doc.get("services") or []
    INFO["services"] = len(services)
    ctxs = []
    for s in services:
        for k in ("ctx", "service", "engine", "class"):
            if k not in s:
                fail("DSENV", "service entry missing '%s': %r" % (k, s))
        ctxs.append(s.get("ctx"))
        engs = s.get("engine") or []
        if not engs:
            fail("DSENGINE", "service ctx=%s has empty engine list" % s.get("ctx"))
        for e in engs:
            if e in UNRECONCILED_ENGINES:
                fail("ADR017", "ctx=%s adopts unreconciled engine %s in `services` (ADR-017: must stay in unreconciled_variants)" % (s.get("ctx"), e))
        if s.get("ctx") in (3, 8) and s.get("isolation") != "dedicated":
            fail("ISOLATION", "ctx=%s (%s) must have isolation: dedicated (R1/R2)" % (s.get("ctx"), CTX.get(s.get("ctx"))))
    # 13 contexts, unique
    if sorted(ctxs) != list(range(1, 14)):
        fail("DSCTX", "services must cover contexts 1..13 exactly once; got %s" % sorted(ctxs))
    # unreconciled_variants block present and exactly the 3 known engines
    uv = doc.get("unreconciled_variants") or []
    INFO["unreconciled_variants"] = [u.get("engine") for u in uv]
    names = {u.get("engine") for u in uv}
    if names != UNRECONCILED_ENGINES:
        fail("UV", "unreconciled_variants must be exactly %s (ADR-017), got %s" % (sorted(UNRECONCILED_ENGINES), sorted(names)))
    for u in uv:
        if u.get("status") != "unreconciled":
            fail("UVSTATUS", "unreconciled_variant %s status must be 'unreconciled'" % u.get("engine"))
    if not doc.get("rules"):
        fail("DSRULES", "data-stores.yaml must state the DB-per-service / isolation / spine-only rules")
    return services


# ---------------- enum-registry.md ----------------
def validate_enum_registry():
    p = os.path.join(ROOT, "enum-registry.md")
    if not os.path.isfile(p):
        fail("FILE", "missing enum-registry.md"); return
    txt = open(p, encoding="utf-8").read()
    m = re.match(r"^---\n(.*?)\n---\n", txt, re.S)
    if not m:
        fail("ENUMFM", "enum-registry.md missing YAML front-matter"); return
    fm = yaml.safe_load(m.group(1)) or {}
    for k in ("id", "owner", "classification", "trace"):
        if k not in fm:
            fail("ENUMFM", "enum-registry.md front-matter missing '%s'" % k)
    if fm.get("classification") != "Internal":
        fail("CLASS", "enum-registry.md classification must be Internal")
    tr = " ".join(map(str, fm.get("trace", [])))
    for a in ("FR-IDN-310", "ADR-018", "R7"):
        if a not in tr:
            warn("ENUMTRACE", "enum-registry.md should trace %s" % a)
    # 15-section document contract present
    headers = set(re.findall(r"^#{2,3}\s+([A-Za-z][^\n]*)", txt, re.M))
    headers = {re.sub(r"\s*\(.*", "", h).strip() for h in headers}
    missing = [s for s in DOC_SECTIONS if not any(s in h for h in headers)]
    if missing:
        fail("ENUMSECT", "enum-registry.md missing contract sections: %s" % missing)
    # values are canon-sourced; exhaustive lists must be declared NEEDS-INFO (never fabricated)
    if "NEEDS-INFO" not in txt:
        fail("ENUMINFO", "enum-registry.md must declare NEEDS-INFO for un-transcribed values (no fabrication)")
    # no duplicate enum values inside any inline UPPER_SNAKE/Vn list
    for grp in re.findall(r"\(([^()]*)\)", txt):
        toks = [x.strip() for x in grp.split(",")]
        vals = [x for x in toks if re.fullmatch(r"[A-Z][A-Z0-9_]{2,}|V[0-3]", x)]
        if len(vals) >= 3 and len(set(vals)) != len(vals):
            dup = [v for v in set(vals) if vals.count(v) > 1]
            fail("ENUMDUP", "duplicate enum value(s) %s in list: %s" % (dup, grp[:60]))
    # KYC tier family present
    if not re.search(r"\bV0\b.*\bV3\b", txt):
        warn("ENUMKYC", "KYC tier family V0..V3 not evident")
    INFO["enum_status"] = "doc-of-record present; values NEEDS-INFO (FR-IDN-310 machine artifact = Phase 2)"


# ---------------- ids.yaml ----------------
def validate_ids():
    doc = load_yaml("ids.yaml")
    if not doc:
        warn("OPT", "ids.yaml not present"); return None
    check_header(doc, "ids.yaml", ["DM", "R7"])
    if not doc.get("types"):
        fail("IDS", "ids.yaml missing `types` block")
    ids = doc.get("identifiers") or []
    seen, prefixes, owners = set(), [], {}
    for i in ids:
        for k in ("id", "prefix", "owner_ctx"):
            if k not in i:
                fail("IDS", "identifier missing '%s': %r" % (k, i))
        if i.get("id") in seen:
            fail("IDSDUP", "duplicate identifier id %s" % i.get("id"))
        seen.add(i.get("id"))
        prefixes.append(i.get("prefix"))
        if i.get("owner_ctx") not in CTX:
            fail("IDSOWNER", "identifier %s owner_ctx %r not a context 1-13" % (i.get("id"), i.get("owner_ctx")))
        owners[i.get("id")] = i.get("owner_ctx")
    if len(set(prefixes)) != len(prefixes):
        fail("IDSPREFIX", "duplicate identifier prefix in ids.yaml")
    INFO["identifiers"] = len(ids)
    return owners


# ---------------- schema-registry.yaml ----------------
def validate_schema_registry():
    doc = load_yaml("schema-registry.yaml")
    if not doc:
        warn("OPT", "schema-registry.yaml not present"); return
    check_header(doc, "schema-registry.yaml", ["EF§8.4", "R6"])
    if not doc.get("policy"):
        fail("SCHEMA", "schema-registry.yaml missing `policy` block")
    subs = doc.get("subjects") or []
    names = [s.get("subject") for s in subs]
    INFO["schema_subjects"] = len(subs)
    if len(set(names)) != len(names):
        fail("SUBJDUP", "duplicate schema subject")
    for s in subs:
        if s.get("subject") != s.get("topic"):
            fail("SUBJREF", "subject != topic: %r" % s)
    msg = load_yaml("messaging.yaml")
    topics = {t["topic"] for t in ((msg.get("buses") or {}).get("kafka") or {}).get("topics") or []} if msg else set()
    miss = topics - set(names)
    extra = set(names) - topics
    if miss:
        fail("SUBJMISS", "schema subjects missing for %d topic(s): %s" % (len(miss), sorted(miss)[:4]))
    if extra:
        fail("SUBJEXTRA", "schema subjects with no Kafka topic: %s" % sorted(extra)[:4])


# ---------------- error-codes.yaml ----------------
def validate_error_codes():
    doc = load_yaml("error-codes.yaml")
    if not doc:
        warn("OPT", "error-codes.yaml not present"); return
    check_header(doc, "error-codes.yaml", ["EF§7.7"])
    tax = doc.get("taxonomy") or {}
    if tax.get("format") != "dokandar.<context>.<category>.<reason>":
        fail("ERRFMT", "error taxonomy format must be dokandar.<context>.<category>.<reason>")
    slugs = set(tax.get("context_slugs") or [])
    want = {CTX[i] for i in CTX} | {"edge"}
    if not want <= slugs:
        fail("ERRSLUG", "error context_slugs missing: %s" % sorted(want - slugs))
    codes = doc.get("codes") or []
    seen = set()
    cre = re.compile(r"^dokandar\.([a-z]+)\.([a-z0-9_]+)\.([a-z0-9_]+)$")
    for c in codes:
        code = c.get("code") if isinstance(c, dict) else c
        if code in seen:
            fail("ERRDUP", "duplicate error code %s" % code)
        seen.add(code)
        m = cre.match(code or "")
        if not m:
            fail("ERRCODE", "error code not canonical: %s" % code)
        elif m.group(1) not in slugs:
            fail("ERRCTX", "error code uses non-canonical context: %s" % code)
    INFO["error_codes"] = len(codes)


# ---------------- permissions.yaml ----------------
def validate_permissions():
    doc = load_yaml("permissions.yaml")
    if not doc:
        warn("OPT", "permissions.yaml not present"); return
    check_header(doc, "permissions.yaml", ["R4", "R5", "R7"])
    if not doc.get("principles"):
        fail("PERM", "permissions.yaml missing `principles`")
    kyc = ((doc.get("roles") or {}).get("kyc_tiers") or {}).get("values") or []
    if kyc != ["V0", "V1", "V2", "V3"]:
        fail("PERMKYC", "kyc_tiers must be V0..V3 (FR-IDN-005), got %r" % kyc)
    INFO["permission_principles"] = len(doc.get("principles") or [])


# ---------------- api-registry.yaml ----------------
def validate_api_registry():
    doc = load_yaml("api-registry.yaml")
    if not doc:
        warn("OPT", "api-registry.yaml not present"); return
    check_header(doc, "api-registry.yaml", ["R6", "R7", "ADR-008"])
    planes = doc.get("planes") or {}
    if "external" not in planes or "internal" not in planes:
        fail("API", "api-registry planes must define external + internal")
    ohs = doc.get("ohs_services") or []
    seen = set()
    for s in ohs:
        if s.get("id") in seen:
            fail("APIDUP", "duplicate ohs service id %s" % s.get("id"))
        seen.add(s.get("id"))
        if s.get("owner_ctx") not in CTX:
            fail("APIOWNER", "ohs %s owner_ctx %r invalid" % (s.get("id"), s.get("owner_ctx")))
    INFO["ohs_services"] = len(ohs)


# ---------------- configuration.yaml ----------------
def validate_configuration():
    doc = load_yaml("configuration.yaml")
    if not doc:
        warn("OPT", "configuration.yaml not present"); return
    check_header(doc, "configuration.yaml", ["DM", "R2"])
    cons = doc.get("constants") or []
    seen = set()
    for c in cons:
        if "id" not in c or "trace" not in c:
            fail("CFG", "constant missing id/trace: %r" % c)
        if c.get("id") in seen:
            fail("CFGDUP", "duplicate constant id %s" % c.get("id"))
        seen.add(c.get("id"))
    INFO["config_constants"] = len(cons)


# ---------------- glossary.yaml ----------------
def validate_glossary():
    doc = load_yaml("glossary.yaml")
    if not doc:
        warn("OPT", "glossary.yaml not present"); return
    check_header(doc, "glossary.yaml", ["FR-IDN-310", "R7"])
    fams = doc.get("term_families") or []
    seen = set()
    for f in fams:
        if f.get("family") in seen:
            fail("GLOSDUP", "duplicate glossary family %s" % f.get("family"))
        seen.add(f.get("family"))
        vals = f.get("values")
        if isinstance(vals, list) and len(vals) != len(set(vals)):
            fail("GLOSVAL", "duplicate value in family %s" % f.get("family"))
    INFO["glossary_families"] = len(fams)


# ---------------- spine.lock.yaml — Contract Freeze integrity ----------------
def validate_freeze_lock():
    import hashlib
    p = os.path.join(ROOT, "spine.lock.yaml")
    if not os.path.isfile(p):
        warn("LOCK", "spine.lock.yaml (freeze manifest) not present"); return
    lock = yaml.safe_load(open(p, encoding="utf-8")) or {}
    INFO["spine_version"] = lock.get("version")
    vf = os.path.join(ROOT, "VERSION")
    if os.path.isfile(vf):
        rv = open(vf, encoding="utf-8").read().strip()
        if rv != str(lock.get("version")):
            fail("LOCKVER", "VERSION (%s) != spine.lock version (%s)" % (rv, lock.get("version")))
    for e in lock.get("contracts") or []:
        fp = os.path.join(ROOT, e["file"])
        if not os.path.isfile(fp):
            fail("LOCKMISS", "frozen contract missing: %s" % e["file"]); continue
        h = hashlib.sha256(open(fp, "rb").read()).hexdigest()
        if e.get("sha256") != h:
            fail("LOCKHASH", "FREEZE DRIFT: %s content changed since freeze" % e["file"])


# ---------------- cross-file referential integrity ----------------
def validate_cross(services):
    msg = load_yaml("messaging.yaml")
    if not msg or services is None:
        return
    svc_ctx = {s.get("ctx") for s in services}
    topics = ((msg.get("buses") or {}).get("kafka") or {}).get("topics") or []
    refed = set()
    for t in topics:
        if isinstance(t.get("producer"), int):
            refed.add(t["producer"])
        for c in (t.get("consumers") or []):
            refed.add(c)
    orphans = refed - svc_ctx
    if orphans:
        fail("ORPHAN", "messaging references contexts with no data-stores service entry: %s" % sorted(orphans))


def main():
    print("== DOKANDAR contracts-spine validation ==  ROOT=%s" % ROOT)
    validate_messaging()
    services = validate_data_stores()
    validate_enum_registry()
    validate_ids()
    validate_schema_registry()
    validate_error_codes()
    validate_permissions()
    validate_api_registry()
    validate_configuration()
    validate_glossary()
    validate_freeze_lock()
    validate_cross(services)

    print("\n-- SUMMARY --")
    print(json.dumps(INFO, indent=2, sort_keys=True))
    print("\n-- COUNTS --")
    print("  Kafka topics        : %s (baseline %s)" % (INFO.get("kafka_topics"), INFO.get("kafka_baseline")))
    print("  RabbitMQ queues     : %s" % INFO.get("rabbitmq_queues"))
    print("  Persistence services: %s (contexts 1..13)" % INFO.get("services"))
    print("  Unreconciled engines: %s" % INFO.get("unreconciled_variants"))
    print("  Canonical identifiers: %s" % INFO.get("identifiers"))
    print("  Schema subjects     : %s (1 per Kafka topic)" % INFO.get("schema_subjects"))
    print("  OHS services        : %s" % INFO.get("ohs_services"))
    print("  Config constants    : %s" % INFO.get("config_constants"))
    print("  Error codes         : %s (taxonomy frozen; codes Phase-2)" % INFO.get("error_codes"))
    print("  Permission principles: %s" % INFO.get("permission_principles"))
    print("  Glossary families   : %s" % INFO.get("glossary_families"))
    print("  Enum registry       : %s" % INFO.get("enum_status"))
    print("  SPINE FREEZE version : %s" % INFO.get("spine_version"))

    if WARNS:
        print("\n-- WARNINGS (%d) --" % len(WARNS))
        for c, m in WARNS:
            print("  [%s] %s" % (c, m))
    if FAILS:
        print("\n-- FAILURES (%d) --" % len(FAILS))
        for c, m in FAILS:
            print("  [%s] %s" % (c, m))
        print("\nRESULT: FAIL")
        sys.exit(1)
    print("\nRESULT: PASS — all contract invariants hold.")
    sys.exit(0)


if __name__ == "__main__":
    main()
