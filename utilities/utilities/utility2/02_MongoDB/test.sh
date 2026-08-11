#!/usr/bin/env bash
# DOKANDAR — MongoDB contract/smoke test. Tests ANY MongoDB server/instance (single node OR replica set).
# It creates a THROWAWAY database `dokandar_mongotest_<ts>` on the target, exercises CRUD, aggregation,
# a UNIQUE index, bilingual UTF-8, and (on a replica set) a multi-document transaction, prints a
# PASS/FAIL report, then DROPS the throwaway database and PROVES zero residue. It never touches a
# pre-existing database.
#
#   Usage:  bash test.sh [TARGET]
#     TARGET may be any ONE of:
#       • a connection URI:           bash test.sh "mongodb://user:pass@host:27017/?authSource=admin"
#       • an install-variant folder:  bash test.sh 03_docker_single   (reads that variant's .env)
#       • an explicit env-file path:  bash test.sh ./03_docker_single/.env
#       • omitted: see the resolution order below.
#     Connection sources (highest priority first):
#       1. a connection URI:   the TARGET arg, or   MONGO_URL='mongodb://…'  bash test.sh
#       2. a `.env` BESIDE this script (02_MongoDB/.env) holding MONGO_URL= or MONGO_* vars
#       3. a per-variant .env: the TARGET folder, or the first NN_*/.env found
#       4. built from parts:   MONGO_HOST/MONGO_PORT/MONGO_ROOT_USER/MONGO_ROOT_PASSWORD (defaults
#                              127.0.0.1:27017, authSource=admin, directConnection=true)
#     The URI's database (if any) is ignored — the test makes its own throwaway DB; the user needs
#     rights to create/drop a database (the built-in `root` role used by the variants suffices).
#
#   Run modes (auto-selected, printed on the first line):
#     • host mode   — `mongosh` is on PATH.
#     • docker mode — no host mongosh, but Docker is present → runs mongosh in a `mongo:<ver>` container
#                     with `--network host` (so 127.0.0.1:<port> reaches a locally published server, and
#                     a remote host:port is reachable just as from the host). Needs zero host packages.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# ---- connection resolution -------------------------------------------------------------------
_URL="${MONGO_URL:-}"                 # explicit URI env always wins
ARG="${1:-}"; CONNURL=""; ENVF=""
case "$ARG" in
  mongodb://*|mongodb+srv://*) CONNURL="$ARG" ;;
  "")        : ;;
  *.env|*/*) ENVF="$ARG" ;;
  *)         ENVF="$HERE/$ARG/.env" ;;
esac
[ -z "$CONNURL" ] && [ -n "$_URL" ] && CONNURL="$_URL"

if [ -z "$CONNURL" ]; then
  if [ -n "$ENVF" ]; then
    if   [ -r "$ENVF" ]; then set -a; . "$ENVF"; set +a
    elif [ -f "$ENVF" ]; then echo "  ! env file exists but is NOT READABLE: $ENVF — run as its owner, or: sudo chown \$(id -un): \"$ENVF\"" >&2
    else echo "  ! env file not found: $ENVF (using MONGO_* env / defaults)" >&2; fi
  elif [ -r "$HERE/.env" ]; then
    set -a; . "$HERE/.env"; set +a
  else
    for f in "$HERE"/0*_*/.env /etc/dokandar/.env; do [ -r "$f" ] || continue; set -a; . "$f"; set +a; break; done
  fi
  [ -n "${MONGO_URL:-}" ] && CONNURL="$MONGO_URL"   # a sourced .env may define MONGO_URL
fi

MONGO_VERSION="${MONGO_VERSION:-7.0}"
# Build a URI from parts if none was given.
if [ -n "$CONNURL" ]; then
  URI="$CONNURL"
else
  H="${MONGO_HOST:-127.0.0.1}"; P="${MONGO_PORT:-27017}"
  U="${MONGO_ROOT_USER:-${MONGO_USER:-}}"; W="${MONGO_ROOT_PASSWORD:-${MONGO_PASSWORD:-}}"
  A="${MONGO_AUTHSOURCE:-admin}"
  if [ -n "$U" ] && [ -n "$W" ]; then URI="mongodb://${U}:${W}@${H}:${P}/?authSource=${A}&directConnection=true"
  else                                URI="mongodb://${H}:${P}/?directConnection=true"; fi
fi
# A redacted URI for display (hide the password between ':' and '@').
URI_SAFE="$(printf '%s' "$URI" | sed -E 's#(mongodb(\+srv)?://[^:/@]+:)[^@]*@#\1****@#')"

# ---- choose how to run mongosh: host client, or a Docker fallback ----------------------------
MONGO_IMG="mongo:${MONGO_VERSION}"
if command -v mongosh >/dev/null 2>&1; then
  RUNMODE=host
  MSH(){ mongosh "$@"; }
elif command -v docker >/dev/null 2>&1; then
  RUNMODE=docker
  docker image inspect "$MONGO_IMG" >/dev/null 2>&1 || { echo "  (pulling ${MONGO_IMG} for the test client...)"; docker pull -q "$MONGO_IMG" >/dev/null 2>&1 || true; }
  MSH(){ docker run --rm --network host --entrypoint mongosh "$MONGO_IMG" "$@"; }
else
  {
    echo "  ✗ no MongoDB client (mongosh) on this host, and Docker is not available."
    echo "    Fix ONE of:"
    echo "      • install mongosh:  https://www.mongodb.com/docs/mongodb-shell/install/"
    echo "      • install Docker (the test will run mongosh in a mongo:${MONGO_VERSION} container)."
  } >&2
  echo "RESULT: FAIL (no mongosh client)"; exit 2
fi
runjs(){ MSH --quiet "$URI" --eval "$1" 2>&1; }

TS="$(date +%Y%m%d_%H%M%S)_$$"
TESTDB="dokandar_mongotest_${TS}"
RESULT_FILE="$HERE/test-result.txt"

cleanup(){ runjs "db.getSiblingDB('${TESTDB}').dropDatabase()" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> MongoDB test   ${URI_SAFE}   testdb=${TESTDB}   [mode=${RUNMODE}${RUNMODE:+ ${MONGO_IMG}}]"

# 0. connectivity + AUTH (fail fast). listDatabases needs auth, so it validates the credentials too —
#    unlike ping, which any unauthenticated client may run. In docker mode this also pulls the image.
PING="$(runjs 'try{print(db.adminCommand({listDatabases:1}).ok)}catch(e){print("ERR:"+e.message)}')"
if ! printf '%s' "$PING" | grep -q '^1$'; then
  printf '  \033[31m✗\033[0m cannot connect / authenticate to %s\n' "$URI_SAFE"
  printf '     %s\n' "$(printf '%s' "$PING" | grep -iE 'err|auth|refus|timed|ECONN' | tail -1)"
  echo "RESULT: FAIL (no server / auth)"; exit 1
fi

# ---- the contract: one mongosh program runs every assertion and prints ✓/✗ + a SUMMARY line --
read -r -d '' JS <<JSEOF || true
const TESTDB = "${TESTDB}";
let pass = 0, fail = 0;
function ok(n){ pass++; print("  ✓ " + n); }
function bad(n,d){ fail++; print("  ✗ " + n + (d ? ("  " + d) : "")); }
function eq(n,exp,act){ (String(exp) === String(act)) ? ok(n + " [" + act + "]") : bad(n, "expected[" + exp + "] got[" + act + "]"); }

const hello = db.hello();
const isRS  = !!hello.setName;
print("  server v" + db.version() + (isRS ? ("  replicaSet=" + hello.setName) : "  (standalone)"));

const T = db.getSiblingDB(TESTDB);

// 1. CRUD insert (bilingual UTF-8) — a DB/collection is created lazily on first write
T.products.insertMany([
  { name_bn: "চাল",  name_en: "rice",   qty: 100, price_minor: 5500 },
  { name_bn: "ডাল",  name_en: "lentil", qty: 50,  price_minor: 12000 },
  { name_bn: "তেল",  name_en: "oil",    qty: 0,   price_minor: 25000 }
]);
eq("insert 3 documents", 3, T.products.countDocuments());

// 2. read + UTF-8 round-trip
eq("utf-8 bangla round-trip", "চাল", T.products.findOne({ name_en: "rice" }).name_bn);

// 3. aggregation pipeline (\$group / \$sum)
eq("aggregate sum(qty)", 150, T.products.aggregate([{ \$group: { _id: null, s: { \$sum: "\$qty" } } }]).toArray()[0].s);

// 4. update
T.products.updateOne({ name_en: "oil" }, { \$set: { qty: 10 } });
eq("update one document", 10, T.products.findOne({ name_en: "oil" }).qty);

// 5. unique index + rejection of a duplicate
T.products.createIndex({ name_en: 1 }, { unique: true });
eq("index created (>=2 incl _id)", true, T.products.getIndexes().length >= 2);
try { T.products.insertOne({ name_en: "rice", qty: 1 }); bad("UNIQUE index rejects duplicate"); }
catch (e) { (e.code === 11000) ? ok("UNIQUE index rejects duplicate") : bad("UNIQUE index rejects duplicate", e.message); }

// 6. multi-document transaction — REQUIRES a replica set; N/A on a standalone
if (isRS) {
  const s = db.getMongo().startSession();
  try {
    s.startTransaction();
    const td = s.getDatabase(TESTDB);
    td.orders.insertOne({ sku: "rice", n: 2 });
    td.orders.insertOne({ sku: "oil",  n: 1 });
    s.commitTransaction();
    eq("multi-doc transaction (replica set)", 2, T.orders.countDocuments());
  } catch (e) { try { s.abortTransaction(); } catch (_) {} bad("multi-doc transaction (replica set)", e.message); }
  finally { s.endSession(); }
} else {
  print("  - multi-doc transaction: N/A (standalone — a transaction needs a replica set)");
}

// 7. cleanup + PROVE zero residue
T.dropDatabase();
const names = db.adminCommand({ listDatabases: 1 }).databases.map(d => d.name);
eq("post-clean: testdb dropped", false, names.includes(TESTDB));
eq("post-clean: 0 leftover test dbs", 0, names.filter(n => /^dokandar_mongotest_/.test(n)).length);

print("SUMMARY " + pass + " " + (pass + fail));
JSEOF

OUT="$(runjs "$JS")"
# colorize ✓/✗ lines for the terminal
printf '%s\n' "$OUT" | while IFS= read -r line; do
  case "$line" in
    *✗*) printf '\033[31m%s\033[0m\n' "$line" ;;
    *✓*) printf '\033[32m%s\033[0m\n' "$line" ;;
    SUMMARY*) : ;;
    *)   printf '%s\n' "$line" ;;
  esac
done

# ---- report ----------------------------------------------------------------------------------
SUM_LINE="$(printf '%s\n' "$OUT" | grep '^SUMMARY ' | tail -1)"
PASS="$(printf '%s' "$SUM_LINE" | awk '{print $2}')"; TOTAL="$(printf '%s' "$SUM_LINE" | awk '{print $3}')"
PASS="${PASS:-0}"; TOTAL="${TOTAL:-0}"; FAIL=$(( TOTAL - PASS ))
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="MongoDB test @ ${STAMP}  ${URI_SAFE}  mode=${RUNMODE}  ->  ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
echo ""
echo "=================================================================="
printf '%s\n' "$SUMMARY"
echo "=================================================================="
printf '%s\n' "$SUMMARY" > "$RESULT_FILE" 2>/dev/null || true
if [ "$TOTAL" -eq 0 ]; then echo "RESULT: FAIL (test body did not run — connection/auth/exception; see output above)"; exit 1
elif [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS — throwaway database dropped, zero residue."; exit 0
else echo "RESULT: FAIL (${FAIL} failing)"; exit 1; fi
