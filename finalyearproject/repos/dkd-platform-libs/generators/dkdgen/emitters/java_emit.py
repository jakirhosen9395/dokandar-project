"""
dkdgen.emitters.java_emit — emits the Java SDK from the IR (package com.dokandar.platform).

Mirrors the Python reference emitter (identical semantics), idiomatic Java 17 (records, sealed-free,
no third-party deps except JUnit for tests). Nested types keep one public class per file.
Framework-only for contract-deferred data.
"""
from __future__ import annotations
import json
from ..ir import Contracts, CONTEXTS
from .base import Writer, pascal, screaming, const_name

PKG = "com.dokandar.platform"
SRC = "src/main/java/com/dokandar/platform"
TST = "src/test/java/com/dokandar/platform"


def _q(s) -> str:
    return json.dumps(s)


def _cls(body: str) -> str:
    return "package %s;\n\n%s" % (PKG, body)


def emit(c: Contracts, meta: dict, out_dir: str) -> list[str]:
    w = Writer(out_dir, "//", meta)

    # provenance
    w.write("%s/Provenance.java" % SRC, _cls(
        "public final class Provenance {\n"
        "    private Provenance() {}\n"
        "    public static final String GENERATOR = %s;\n"
        "    public static final String GENERATOR_VERSION = %s;\n"
        "    public static final String CONTRACT_VERSION = %s;\n"
        "    public static final String BUILD_TIME = %s;\n"
        "    public static final String BUILD_COMMIT = %s;\n}\n" % (
            _q(meta["generator"]), _q(meta["generator_version"]), _q(meta["contract_version"]),
            _q(meta["build_time"]), _q(meta["build_commit"]))))

    # money / time
    w.write("%s/Money.java" % SRC, _cls('''public final class Money {
    public static final long POISHA_PER_BDT = 100L;
    public final long poisha;
    public Money(long poisha) { this.poisha = poisha; }
    public static Money ofBdt(long bdt) { return new Money(bdt * POISHA_PER_BDT); }
    @Override public boolean equals(Object o) { return o instanceof Money m && m.poisha == poisha; }
    @Override public int hashCode() { return Long.hashCode(poisha); }
    @Override public String toString() { return "Money(" + poisha + " poisha)"; }
}
'''))
    w.write("%s/Timestamp.java" % SRC, _cls('''public final class Timestamp {
    public final long epochMs;
    public Timestamp(long epochMs) { this.epochMs = epochMs; }
    @Override public boolean equals(Object o) { return o instanceof Timestamp t && t.epochMs == epochMs; }
    @Override public int hashCode() { return Long.hashCode(epochMs); }
}
'''))

    # ids (base + nested per-id)
    ids = ["public final class Ids {", "    private Ids() {}", "",
           "    public abstract static class PrefixedId {",
           "        public final String value;",
           "        protected PrefixedId(String value, String prefix) {",
           "            if (value == null || !value.startsWith(prefix) || value.length() <= prefix.length())",
           "                throw new IllegalArgumentException(getClass().getSimpleName() + \" must start with '\" + prefix + \"' and carry a body\");",
           "            this.value = value;",
           "        }",
           "        @Override public String toString() { return value; }",
           "        @Override public boolean equals(Object o) { return o != null && o.getClass() == getClass() && ((PrefixedId) o).value.equals(value); }",
           "        @Override public int hashCode() { return java.util.Objects.hash(getClass(), value); }",
           "    }", ""]
    for i in c.identifiers:
        T = pascal(i.id)
        ids += [
            "    public static final class %s extends PrefixedId {" % T,
            "        public static final String PREFIX = %s;" % _q(i.prefix),
            "        public static final int OWNER_CONTEXT = %d; // %s" % (i.owner_ctx, CONTEXTS[i.owner_ctx]),
            "        public static final boolean IMMUTABLE = %s;" % ("true" if i.immutable else "false"),
            "        public %s(String v) { super(v, PREFIX); }" % T,
            "    }", ""]
    ids.append("}")
    w.write("%s/Ids.java" % SRC, _cls("\n".join(ids)))

    # topics / events
    tp = ["import java.util.List;", "import java.util.Map;", "",
          "/** Kafka topics + RabbitMQ queues (messaging.yaml). Cross-context = Kafka only (R6). */",
          "public final class Topics {", "    private Topics() {}",
          "    public record TopicMeta(String name, int producer, String key, List<Integer> consumers,",
          "                            String context, String aggregate, String event, int version) {}", ""]
    for t in c.topics:
        tp.append("    public static final String %s = %s;" % (const_name(t.name), _q(t.name)))
    tp.append("")
    for q in c.queues:
        tp.append("    public static final String QUEUE_%s = %s;" % (screaming(q.name), _q(q.name)))
    tp += ["", "    public static final Map<String, TopicMeta> META = Map.ofEntries("]
    entries = []
    for t in c.topics:
        cons = ", ".join(str(x) for x in t.consumers)
        entries.append("        Map.entry(%s, new TopicMeta(%s, %d, %s, List.of(%s), %s, %s, %s, %d))" % (
            _q(t.name), _q(t.name), t.producer, _q(t.key), cons, _q(t.context), _q(t.aggregate), _q(t.event), t.version))
    tp.append(",\n".join(entries))
    tp += ["    );", "",
           "    public static TopicMeta topicMeta(String name) {",
           "        TopicMeta m = META.get(name);",
           "        if (m == null) throw new IllegalArgumentException(\"unknown topic: \" + name);",
           "        return m;",
           "    }", "}"]
    w.write("%s/Topics.java" % SRC, _cls("\n".join(tp)))

    # config
    cf = ["/** Canon-named operational constants (configuration.yaml). Values verbatim from canon. */",
          "public final class Config {", "    private Config() {}"]
    for k in c.constants:
        if isinstance(k.value, int) and not isinstance(k.value, bool):
            cf.append("    public static final long %s = %dL; // %s — %s" % (screaming(k.id), k.value, k.human, k.scope))
        else:
            cf.append("    public static final String %s = %s; // %s" % (screaming(k.id), _q(k.value), k.human))
    cf.append("}")
    w.write("%s/Config.java" % SRC, _cls("\n".join(cf)))

    # enums
    en = ["/** Canonical enum families (glossary.yaml; FR-IDN-310). Values transcribed verbatim. */",
          "public final class Enums {", "    private Enums() {}"]
    for f in c.enum_families:
        if not f.values:
            continue
        T = pascal(f.family)
        consts = ", ".join("%s(%s)" % (screaming(v), _q(v)) for v in f.values)
        en += ["    public enum %s {" % T,
               "        %s;" % consts,
               "        public final String value;",
               "        %s(String value) { this.value = value; }" % T,
               "    }"]
        if f.exhaustive is not True:
            en.append("    // NOTE: contract marks the above family non-exhaustive (illustrative).")
    en.append("}")
    w.write("%s/Enums.java" % SRC, _cls("\n".join(en)))

    # errors
    slugs = list(c.error_taxonomy.context_slugs)
    er = ["import java.util.Set;", "import java.util.regex.Pattern;", "",
          "/** Error taxonomy (error-codes.yaml): dokandar.<context>.<category>.<reason> (RFC-7807).",
          "  * Concrete codes are NEEDS-INFO in frozen contracts; builder + slug enum + ProblemDetails +",
          "  * typed exceptions only — never a fabricated code list. */",
          "public final class Errors {", "    private Errors() {}", "",
          "    public enum ContextSlug {",
          "        %s;" % ", ".join("%s(%s)" % (screaming(s), _q(s)) for s in slugs),
          "        public final String value;",
          "        ContextSlug(String value) { this.value = value; }",
          "    }", "",
          "    private static final Set<String> SLUGS = Set.of(%s);" % ", ".join(_q(s) for s in slugs),
          "    private static final Pattern CODE = Pattern.compile(\"^dokandar\\\\.([a-z]+)\\\\.([a-z0-9_]+)\\\\.([a-z0-9_]+)$\");", "",
          "    public static String errorCode(String context, String category, String reason) {",
          "        String code = \"dokandar.\" + context + \".\" + category + \".\" + reason;",
          "        if (!SLUGS.contains(context)) throw new IllegalArgumentException(\"unknown context slug: \" + context);",
          "        if (!CODE.matcher(code).matches()) throw new IllegalArgumentException(\"error code violates taxonomy: \" + code);",
          "        return code;",
          "    }", "",
          "    public record ProblemDetails(String type, String title, int status, String code,",
          "                                 String detail, String instance, String traceId) {}", "",
          "    public static class DokandarException extends RuntimeException {",
          "        public final String code; public final int httpStatus; public final String detail;",
          "        public DokandarException(String code, String message, int httpStatus, String detail) {",
          "            super(message); this.code = code; this.httpStatus = httpStatus; this.detail = detail;",
          "        }",
          "    }",
          "    public static final class ValidationException extends DokandarException {",
          "        public ValidationException(String code, String message) { super(code, message, 400, null); } }",
          "    public static final class BusinessException extends DokandarException {",
          "        public BusinessException(String code, String message) { super(code, message, 409, null); } }",
          "    public static final class InfrastructureException extends DokandarException {",
          "        public InfrastructureException(String code, String message) { super(code, message, 503, null); } }",
          "}"]
    w.write("%s/Errors.java" % SRC, _cls("\n".join(er)))

    # dto
    w.write("%s/Dto.java" % SRC, _cls('''import java.util.List;
import java.util.Map;

/** Common DTOs: the {success,data,error,meta} envelope, cursor pagination, trace/audit metadata. */
public final class Dto {
    private Dto() {}
    public record PageMeta(String nextCursor, boolean hasMore, int limit) {}
    public record TraceMetadata(String traceId, String spanId, String correlationId) {}
    public record AuditMetadata(String actorDid, long occurredAtMs, String requestId) {}
    public record Meta(PageMeta page, TraceMetadata trace, Map<String, Object> extra) {}

    public record Response<T>(boolean success, T data, Errors.ProblemDetails error, Meta meta) {
        public static <T> Response<T> ok(T data, Meta meta) { return new Response<>(true, data, null, meta); }
        public static <T> Response<T> fail(Errors.ProblemDetails error, Meta meta) { return new Response<>(false, null, error, meta); }
    }
    public record Page<T>(List<T> items, PageMeta page) {}
}
'''))

    # events
    w.write("%s/Events.java" % SRC, _cls('''/** Event envelope/base + headers + metadata + topic binding + serializer interface.
  * Per-event PAYLOAD types are FRAMEWORK-ONLY (schema-registry subjects are NEEDS-INFO): EventEnvelope
  * is generic over the payload; concrete payloads bind on Phase-2 contract population. */
public final class Events {
    private Events() {}
    public record EventHeaders(String eventId, long occurredAtMs, int producerContext, String partitionKey,
                               String correlationId, String traceId, int schemaVersion) {}
    public record EventMetadata(String topic, Topics.TopicMeta meta) {}
    public record EventEnvelope<P>(EventHeaders headers, String topic, P payload) {}
    public interface PayloadSerializer<P> { byte[] serialize(P payload); P deserialize(byte[] data); }
    public static EventMetadata eventMetadataFor(String topic) { return new EventMetadata(topic, Topics.topicMeta(topic)); }
}
'''))

    # schema
    sc = ["import java.util.Map;", "",
          "/** Schema-registry metadata (schema-registry.yaml): subjects + compatibility + version helpers.",
          "  * Per-subject JSON-Schema is NEEDS-INFO; getSchema throws until populated. */",
          "public final class Schema {", "    private Schema() {}",
          "    public enum Compatibility { BACKWARD }",
          "    public record SubjectInfo(String subject, String topic, String compatibility, String schemaStatus) {}", "",
          "    public static final Map<String, SubjectInfo> SUBJECTS = Map.ofEntries("]
    sentries = []
    for s in c.schema_subjects:
        sentries.append("        Map.entry(%s, new SubjectInfo(%s, %s, %s, %s))" % (
            _q(s.subject), _q(s.subject), _q(s.topic), _q(s.compatibility), _q(s.schema_status)))
    sc.append(",\n".join(sentries))
    sc += ["    );", "",
           "    public static String subjectFor(String topic) {",
           "        SubjectInfo s = SUBJECTS.get(topic);",
           "        if (s == null) throw new IllegalArgumentException(\"no subject for topic: \" + topic);",
           "        return s.subject();",
           "    }",
           "    public static void getSchema(String subject) {",
           "        throw new UnsupportedOperationException(\"schema for \" + subject + \" is NEEDS-INFO in frozen contracts (Phase-2 transcription)\");",
           "    }",
           "    public static boolean isCompatible(int newVersion, int oldVersion) { return newVersion >= oldVersion; }",
           "}"]
    w.write("%s/Schema.java" % SRC, _cls("\n".join(sc)))

    # security
    se = ["import java.util.HashMap;", "import java.util.Map;", "",
          "/** Security helpers: access principles, JWT claim names, correlation/trace propagation.",
          "  * Role families are the canonical glossary enums (Enums). Permission MATRIX is NEEDS-INFO. */",
          "public final class Security {", "    private Security() {}", "",
          "    public static final Map<String, String> PRINCIPLES = Map.ofEntries("]
    se.append(",\n".join("        Map.entry(%s, %s)" % (_q(p.id), _q(p.rule)) for p in c.principles))
    se += ["    );", "",
           "    public static final class JwtClaims {",
           "        private JwtClaims() {}",
           "        public static final String SUBJECT_DID = \"sub\", KYC_TIER = \"kyc_tier\", ROLES = \"roles\", CORRELATION_ID = \"cid\";",
           "    }", "",
           "    public static final class CorrelationContext {",
           "        public final String correlationId, traceId, actorDid;",
           "        public CorrelationContext(String correlationId, String traceId, String actorDid) {",
           "            this.correlationId = correlationId; this.traceId = traceId; this.actorDid = actorDid;",
           "        }",
           "        public Map<String, String> headers() {",
           "            var h = new HashMap<String, String>();",
           "            if (correlationId != null) h.put(\"x-correlation-id\", correlationId);",
           "            if (traceId != null) h.put(\"traceparent\", traceId);",
           "            return h;",
           "        }",
           "    }", "}"]
    w.write("%s/Security.java" % SRC, _cls("\n".join(se)))

    # validation
    w.write("%s/Validation.java" % SRC, _cls('''/** Validation utilities. */
public final class Validation {
    private Validation() {}
    public static boolean validateTopic(String name) { return Topics.META.containsKey(name); }
    public static long validateMoney(long poisha) { return poisha; }
}
'''))

    # API Documentation Standard helper (Spring auto-configuration): supplies the platform OpenAPI
    # document (doc "v1" + Bearer/JWT scheme). springdoc serves Swagger UI /docs + JSON
    # /swagger/v1/swagger.json (paths set by the service application.yml). Services need no Swagger code.
    w.write("%s/DkdApiDocs.java" % SRC, _cls('''import io.swagger.v3.oas.models.Components;
import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.security.SecurityScheme;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;

/** Platform API Documentation Standard: OpenAPI document "v1" + Bearer (JWT) security scheme.
 *  Auto-configured from the SDK — services inherit identical docs with no Swagger code. */
@AutoConfiguration
public class DkdApiDocs {
    @Bean
    @ConditionalOnMissingBean
    public OpenAPI dkdOpenAPI(org.springframework.core.env.Environment env) {
        String title = env.getProperty("spring.application.name", "DOKANDAR service");
        return new OpenAPI()
            .info(new Info().title(title).version("v1").description(title + " REST API."))
            .components(new Components().addSecuritySchemes("Bearer",
                new SecurityScheme().type(SecurityScheme.Type.HTTP).scheme("bearer").bearerFormat("JWT")
                    .description("JWT bearer token (injected by the API gateway in production).")));
    }
}
'''))

    # Register the auto-configuration (Spring Boot 3 AutoConfiguration.imports).
    w.write("src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports",
            "com.dokandar.platform.DkdApiDocs\n", with_banner=False)

    # pom (no banner — XML)
    w.write("pom.xml", '''<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.dokandar</groupId>
  <artifactId>dkd-platform-sdk</artifactId>
  <version>%s</version>
  <packaging>jar</packaging>
  <properties>
    <maven.compiler.release>21</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>
  <dependencies>
    <!-- API Documentation Standard: springdoc brings Swagger UI + OpenAPI to every service transitively;
         the DkdApiDocs auto-configuration (this SDK) supplies the OpenAPI document + Bearer scheme. -->
    <dependency>
      <groupId>org.springdoc</groupId>
      <artifactId>springdoc-openapi-starter-webmvc-ui</artifactId>
      <version>2.7.0</version>
    </dependency>
    <dependency>
      <groupId>org.junit.jupiter</groupId>
      <artifactId>junit-jupiter</artifactId>
      <version>5.11.4</version>
      <scope>test</scope>
    </dependency>
  </dependencies>
  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-surefire-plugin</artifactId>
        <version>3.5.2</version>
      </plugin>
    </plugins>
  </build>
</project>
''' % meta["contract_version"], with_banner=False)

    # test
    w.write("%s/SdkTest.java" % TST, _cls('''import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class SdkTest {
    @Test void provenance() { assertEquals(%s, Provenance.CONTRACT_VERSION); }

    @Test void idsTypedAndValidated() {
        var d = new Ids.DID("did:dokandar:abc");
        assertEquals("did:dokandar:abc", d.toString());
        assertTrue(Ids.DID.IMMUTABLE);
        assertEquals(1, Ids.DID.OWNER_CONTEXT);
        assertThrows(IllegalArgumentException.class, () -> new Ids.PPID("did:dokandar:x"));
    }

    @Test void topics() {
        assertEquals(59, Topics.META.size());
        assertEquals(3, Topics.topicMeta("custody.passport.CustodyInitialized.v1").producer());
    }

    @Test void money() { assertEquals(5000L, new Money(5000L).poisha); }

    @Test void errorCode() {
        assertEquals("dokandar.finance.idempotency.duplicate_key",
                     Errors.errorCode("finance", "idempotency", "duplicate_key"));
        assertThrows(IllegalArgumentException.class, () -> Errors.errorCode("frobnicate", "x", "y"));
    }
}
''' % _q(meta["contract_version"])))

    return list(w.written)
