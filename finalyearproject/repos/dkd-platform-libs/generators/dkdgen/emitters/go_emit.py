"""
dkdgen.emitters.go_emit — emits the Go SDK (package dkdplatform) from the IR.

Mirrors the Python reference emitter (identical semantics), idiomatic Go 1.22 (stdlib only, generics).
Framework-only for contract-deferred data (event payloads, schemas, error-code catalog, matrix).
"""
from __future__ import annotations
import json
from ..ir import Contracts, CONTEXTS
from .base import Writer, pascal, screaming

PKG = "dkdplatform"
MODULE = "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"


def _q(s) -> str:
    return json.dumps(s)


def _hdr(body: str) -> str:
    return "package %s\n\n%s" % (PKG, body)


def emit(c: Contracts, meta: dict, out_dir: str) -> list[str]:
    w = Writer(out_dir, "//", meta)

    # provenance
    w.write("provenance.go", _hdr(
        "const (\n"
        "\tGenerator        = %s\n\tGeneratorVersion = %s\n\tContractVersion  = %s\n"
        "\tBuildTime        = %s\n\tBuildCommit      = %s\n)\n" % (
            _q(meta["generator"]), _q(meta["generator_version"]), _q(meta["contract_version"]),
            _q(meta["build_time"]), _q(meta["build_commit"]))))

    # money / time (int64)
    w.write("money.go", _hdr('''// Money is int64 poisha (DM type conventions). Float/decimal money is impossible by type.
const PoishaPerBDT int64 = 100

type Money struct{ Poisha int64 }

func MoneyOfBDT(bdt int64) Money { return Money{Poisha: bdt * PoishaPerBDT} }

// Timestamp is Unix milliseconds, UTC (int64).
type Timestamp struct{ EpochMs int64 }
'''))

    # ids
    id_body = ['import (', '\t"fmt"', '\t"strings"', ')', '',
               '// Strongly-typed identifiers (ids.yaml). No raw-string IDs.', '']
    for i in c.identifiers:
        T = pascal(i.id)
        id_body += [
            "const %sPrefix = %s" % (T, _q(i.prefix)),
            "const %sOwnerContext = %d // %s" % (T, i.owner_ctx, CONTEXTS[i.owner_ctx]),
            "const %sImmutable = %s" % (T, "true" if i.immutable else "false"),
            "",
            "type %s string" % T,
            "",
            "// New%s validates the canonical prefix; the body is a UUIDv7." % T,
            "func New%s(v string) (%s, error) {" % (T, T),
            "\tif len(v) <= len(%sPrefix) || !strings.HasPrefix(v, %sPrefix) {" % (T, T),
            "\t\treturn \"\", fmt.Errorf(\"%s must start with %%q and carry a body\", %sPrefix)" % (T, T),
            "\t}",
            "\treturn %s(v), nil" % T,
            "}",
            "func (id %s) String() string { return string(id) }" % T,
            "",
        ]
    w.write("ids.go", _hdr("\n".join(id_body)))

    # topics / events
    t = ['// Kafka topics + RabbitMQ queues (messaging.yaml). Cross-context = Kafka only (R6).', '',
         'type TopicMeta struct {',
         '\tName       string', '\tProducer   int', '\tKey        string', '\tConsumers  []int',
         '\tContext    string', '\tAggregate  string', '\tEvent      string', '\tVersion    int',
         '}', '', 'const (']
    for tp in c.topics:
        t.append("\tTopic%s = %s" % (pascal(tp.name), _q(tp.name)))
    t += [')', '', 'const (']
    for q in c.queues:
        t.append("\tQueue%s = %s" % (pascal(q.name), _q(q.name)))
    t += [')', '', 'var TopicMetaByName = map[string]TopicMeta{']
    for tp in c.topics:
        t.append("\t%s: {Name: %s, Producer: %d, Key: %s, Consumers: []int{%s}, Context: %s, Aggregate: %s, Event: %s, Version: %d}," % (
            _q(tp.name), _q(tp.name), tp.producer, _q(tp.key), ", ".join(str(x) for x in tp.consumers),
            _q(tp.context), _q(tp.aggregate), _q(tp.event), tp.version))
    t += ['}', '',
          'func TopicMetaFor(name string) (TopicMeta, bool) { m, ok := TopicMetaByName[name]; return m, ok }', '',
          'func AllTopics() []string {',
          '\tout := make([]string, 0, len(TopicMetaByName))',
          '\tfor k := range TopicMetaByName {', '\t\tout = append(out, k)', '\t}',
          '\treturn out', '}']
    w.write("topics.go", _hdr("\n".join(t)))

    # config
    cf = ['// Canon-named operational constants (configuration.yaml). Values verbatim from canon.', '', 'const (']
    for k in c.constants:
        if isinstance(k.value, int) and not isinstance(k.value, bool):
            cf.append("\t%s int64 = %d // %s — %s" % (pascal(k.id), k.value, k.human, k.scope))
        else:
            cf.append("\t%s = %s // %s — %s" % (pascal(k.id), _q(k.value), k.human, k.scope))
    cf.append(")")
    w.write("config.go", _hdr("\n".join(cf)))

    # enums
    en = ['// Canonical enum families (glossary.yaml; FR-IDN-310). Values transcribed verbatim.', '']
    for f in c.enum_families:
        if not f.values:
            continue
        T = pascal(f.family)
        en += ["type %s string" % T, "const ("]
        for v in f.values:
            en.append("\t%s%s %s = %s" % (T, pascal(v), T, _q(v)))
        en.append(")")
        if f.exhaustive is not True:
            en.append("// NOTE: contract marks this family non-exhaustive (illustrative).")
        en.append("")
    w.write("enums.go", _hdr("\n".join(en)))

    # errors
    slugs = list(c.error_taxonomy.context_slugs)
    er = ['import (', '\t"fmt"', '\t"regexp"', ')', '',
          '// Error taxonomy (error-codes.yaml): dokandar.<context>.<category>.<reason> (RFC-7807).',
          '// Concrete codes are NEEDS-INFO in frozen contracts; this provides the builder + slug type',
          '// + ProblemDetails + typed errors — never a fabricated code list.', '',
          'type ContextSlug string', '', 'const (']
    for s in slugs:
        er.append("\tContextSlug%s ContextSlug = %s" % (pascal(s), _q(s)))
    er += [')', '', 'var contextSlugs = map[string]bool{']
    for s in slugs:
        er.append("\t%s: true," % _q(s))
    er += ['}', '',
           r'var codeRe = regexp.MustCompile(`^dokandar\.([a-z]+)\.([a-z0-9_]+)\.([a-z0-9_]+)$`)', '',
           'func ErrorCode(context, category, reason string) (string, error) {',
           '\tcode := fmt.Sprintf("dokandar.%s.%s.%s", context, category, reason)',
           '\tif !contextSlugs[context] {',
           '\t\treturn "", fmt.Errorf("unknown context slug: %s", context)', '\t}',
           '\tif !codeRe.MatchString(code) {',
           '\t\treturn "", fmt.Errorf("error code violates taxonomy: %s", code)', '\t}',
           '\treturn code, nil', '}', '',
           'type ProblemDetails struct {',
           '\tType, Title       string', '\tStatus            int', '\tCode              string',
           '\tDetail, Instance  string', '\tTraceID           string', '}', '',
           'type DokandarError struct {',
           '\tCode       string', '\tMessage    string', '\tDetail     string', '\tHTTPStatus int', '}', '',
           'func (e *DokandarError) Error() string { return e.Message }', '',
           'func NewValidationError(code, message string) *DokandarError {',
           '\treturn &DokandarError{Code: code, Message: message, HTTPStatus: 400}', '}',
           'func NewBusinessError(code, message string) *DokandarError {',
           '\treturn &DokandarError{Code: code, Message: message, HTTPStatus: 409}', '}',
           'func NewInfrastructureError(code, message string) *DokandarError {',
           '\treturn &DokandarError{Code: code, Message: message, HTTPStatus: 503}', '}']
    w.write("errors.go", _hdr("\n".join(er)))

    # dto (generics)
    w.write("dto.go", _hdr('''// Common DTOs: the {success,data,error,meta} envelope, cursor pagination, trace/audit metadata.
type PageMeta struct {
\tNextCursor string
\tHasMore    bool
\tLimit      int
}

type TraceMetadata struct{ TraceID, SpanID, CorrelationID string }
type AuditMetadata struct {
\tActorDID     string
\tOccurredAtMs int64
\tRequestID    string
}

type Meta struct {
\tPage  *PageMeta
\tTrace *TraceMetadata
\tExtra map[string]any
}

// Response is the canonical external REST envelope (EF §7).
type Response[T any] struct {
\tSuccess bool
\tData    *T
\tError   *ProblemDetails
\tMeta    *Meta
}

func Ok[T any](data T, meta *Meta) Response[T] {
\treturn Response[T]{Success: true, Data: &data, Meta: meta}
}

func Fail[T any](err *ProblemDetails, meta *Meta) Response[T] {
\treturn Response[T]{Success: false, Error: err, Meta: meta}
}

type Page[T any] struct {
\tItems []T
\tPage  PageMeta
}
'''))

    # events
    w.write("events.go", _hdr('''// Event envelope/base + headers + metadata + topic binding + serializer interface.
// Per-event PAYLOAD types are FRAMEWORK-ONLY (schema-registry subjects are NEEDS-INFO): EventEnvelope
// is generic over the payload; concrete payloads bind on Phase-2 contract population.
type EventHeaders struct {
\tEventID         string // inbox dedup key
\tOccurredAtMs    int64
\tProducerContext int
\tPartitionKey    string // per-aggregate ordering key
\tCorrelationID   string
\tTraceID         string
\tSchemaVersion   int
}

type EventMetadata struct {
\tTopic string
\tMeta  TopicMeta
}

func EventMetadataFor(topic string) (EventMetadata, bool) {
\tm, ok := TopicMetaFor(topic)
\treturn EventMetadata{Topic: topic, Meta: m}, ok
}

type EventEnvelope[P any] struct {
\tHeaders EventHeaders
\tTopic   string
\tPayload P
}

type PayloadSerializer[P any] interface {
\tSerialize(payload P) ([]byte, error)
\tDeserialize(data []byte) (P, error)
}
'''))

    # schema
    sc = ['import "fmt"', '',
          '// Schema-registry metadata (schema-registry.yaml): subjects + compatibility + version helpers.',
          '// Per-subject JSON-Schema is NEEDS-INFO; GetSchema returns an error until populated.', '',
          'type Compatibility string', '', 'const CompatibilityBackward Compatibility = "BACKWARD"', '',
          'type SubjectInfo struct {',
          '\tSubject       string', '\tTopic         string', '\tCompatibility string', '\tSchemaStatus  string', '}',
          '', 'var Subjects = map[string]SubjectInfo{']
    for s in c.schema_subjects:
        sc.append("\t%s: {Subject: %s, Topic: %s, Compatibility: %s, SchemaStatus: %s}," % (
            _q(s.subject), _q(s.subject), _q(s.topic), _q(s.compatibility), _q(s.schema_status)))
    sc += ['}', '',
           'func SubjectFor(topic string) (string, bool) { s, ok := Subjects[topic]; return s.Subject, ok }', '',
           'func GetSchema(subject string) error {',
           '\treturn fmt.Errorf("schema for %s is NEEDS-INFO in frozen contracts (Phase-2 transcription)", subject)', '}',
           '', 'func IsCompatible(newVersion, oldVersion int) bool { return newVersion >= oldVersion }']
    w.write("schema.go", _hdr("\n".join(sc)))

    # security
    se = ['// Security helpers: access principles, JWT claim names, correlation/trace propagation.',
          '// Role families are the canonical glossary enums (enums.go). The permission MATRIX is',
          '// NEEDS-INFO (permissions.yaml) — principle constants only.', '',
          'var Principles = map[string]string{']
    for p in c.principles:
        se.append("\t%s: %s," % (_q(p.id), _q(p.rule)))
    se += ['}', '', 'const (',
           '\tJwtClaimSubjectDID    = "sub"',
           '\tJwtClaimKycTier       = "kyc_tier"',
           '\tJwtClaimRoles         = "roles"',
           '\tJwtClaimCorrelationID = "cid"', ')', '',
           'type CorrelationContext struct {',
           '\tCorrelationID string', '\tTraceID       string', '\tActorDID      string', '}', '',
           'func (c CorrelationContext) Headers() map[string]string {',
           '\th := map[string]string{}',
           '\tif c.CorrelationID != "" {', '\t\th["x-correlation-id"] = c.CorrelationID', '\t}',
           '\tif c.TraceID != "" {', '\t\th["traceparent"] = c.TraceID', '\t}',
           '\treturn h', '}']
    w.write("security.go", _hdr("\n".join(se)))

    # validation
    w.write("validation.go", _hdr('''// Validation utilities.
func ValidateTopic(name string) bool { _, ok := TopicMetaByName[name]; return ok }

func ValidateMoney(poisha int64) Money { return Money{Poisha: poisha} }
'''))

    # API Documentation Standard helper (stdlib only) — serves Swagger UI at /docs and the OpenAPI
    # JSON at /swagger/v1/swagger.json so Go services inherit identical docs via one Register(...) call.
    w.write("apidocs/apidocs.go", '''package apidocs

import (
\t"net/http"
\t"strings"
)

// DocsCSP is the Content-Security-Policy for the Swagger UI paths (allows the UI assets it loads).
func DocsCSP() string {
\treturn "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; " +
\t\t"style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; img-src 'self' data: https://cdn.jsdelivr.net; " +
\t\t"font-src 'self' https://cdn.jsdelivr.net; connect-src 'self'"
}

// IsDocsPath reports whether the request path targets the Swagger UI or the OpenAPI document.
func IsDocsPath(path string) bool {
\treturn strings.HasPrefix(path, "/docs") || strings.HasPrefix(path, "/swagger")
}

// Register wires /docs (Swagger UI) and /swagger/v1/swagger.json (OpenAPI document) onto the mux.
func Register(mux *http.ServeMux, title string) {
\tspec := strings.ReplaceAll(openapiTemplate, "__TITLE__", title)
\tmux.HandleFunc("/swagger/v1/swagger.json", func(w http.ResponseWriter, r *http.Request) {
\t\tw.Header().Set("Content-Type", "application/json")
\t\t_, _ = w.Write([]byte(spec))
\t})
\tmux.HandleFunc("/docs", func(w http.ResponseWriter, r *http.Request) {
\t\tw.Header().Set("Content-Type", "text/html; charset=utf-8")
\t\t_, _ = w.Write([]byte(swaggerUIHTML))
\t})
}

const swaggerUIHTML = `<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><title>API Documentation</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist/swagger-ui.css"></head>
<body><div id="swagger-ui"></div>
<script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist/swagger-ui-bundle.js"></script>
<script>window.ui = SwaggerUIBundle({url: "/swagger/v1/swagger.json", dom_id: "#swagger-ui"});</script>
</body></html>`

const openapiTemplate = `{
  "openapi": "3.0.3",
  "info": {"title": "__TITLE__", "version": "v1", "description": "__TITLE__ REST API."},
  "paths": {
    "/health": {"get": {"tags": ["HealthEndpoints"], "operationId": "getHealth", "summary": "Health probe", "responses": {"200": {"description": "OK", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Envelope"}}}}}}},
    "/live": {"get": {"tags": ["HealthEndpoints"], "operationId": "getLive", "summary": "Liveness probe", "responses": {"200": {"description": "OK"}}}},
    "/ready": {"get": {"tags": ["HealthEndpoints"], "operationId": "getReady", "summary": "Readiness probe", "responses": {"200": {"description": "OK"}, "503": {"description": "Not ready", "content": {"application/problem+json": {"schema": {"$ref": "#/components/schemas/ProblemDetails"}}}}}}},
    "/version": {"get": {"tags": ["HealthEndpoints"], "operationId": "getVersion", "summary": "Version", "responses": {"200": {"description": "OK", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Envelope"}}}}}}}
  },
  "components": {
    "schemas": {
      "Envelope": {"type": "object", "properties": {"success": {"type": "boolean"}, "data": {"type": "object", "nullable": true}, "error": {"$ref": "#/components/schemas/ProblemDetails"}, "meta": {"type": "object", "nullable": true}}},
      "ProblemDetails": {"type": "object", "description": "RFC-7807 problem+json", "properties": {"type": {"type": "string"}, "title": {"type": "string"}, "status": {"type": "integer"}, "detail": {"type": "string"}, "instance": {"type": "string"}, "code": {"type": "string"}}}
    },
    "securitySchemes": {"Bearer": {"type": "http", "scheme": "bearer", "bearerFormat": "JWT", "description": "JWT bearer token (injected by the API gateway in production)."}}
  }
}`
''')

    # go.mod (no banner)
    w.write("go.mod", "module %s\n\ngo 1.25\n" % MODULE, with_banner=False)

    # test
    w.write("dkdplatform_test.go", _hdr('''import "testing"

func TestProvenance(t *testing.T) {
\tif ContractVersion != %s {
\t\tt.Fatalf("contract version = %%s", ContractVersion)
\t}
}

func TestIDsTypedAndValidated(t *testing.T) {
\td, err := NewDID("did:dokandar:abc")
\tif err != nil || d.String() != "did:dokandar:abc" {
\t\tt.Fatalf("DID: %%v", err)
\t}
\tif !DIDImmutable || DIDOwnerContext != 1 {
\t\tt.Fatal("DID metadata")
\t}
\tif _, err := NewPPID("did:dokandar:x"); err == nil {
\t\tt.Fatal("PPID should reject wrong prefix")
\t}
}

func TestTopics(t *testing.T) {
\tif len(TopicMetaByName) != 59 {
\t\tt.Fatalf("topics = %%d", len(TopicMetaByName))
\t}
\tm, ok := TopicMetaFor("custody.passport.CustodyInitialized.v1")
\tif !ok || m.Producer != 3 || m.Key != "PPID" {
\t\tt.Fatal("custody topic meta")
\t}
}

func TestErrorCode(t *testing.T) {
\tcode, err := ErrorCode("finance", "idempotency", "duplicate_key")
\tif err != nil || code != "dokandar.finance.idempotency.duplicate_key" {
\t\tt.Fatalf("error code: %%v %%s", err, code)
\t}
\tif _, err := ErrorCode("frobnicate", "x", "y"); err == nil {
\t\tt.Fatal("should reject unknown context")
\t}
}
''' % _q(meta["contract_version"])))

    return list(w.written)
