"""
dkdscaffold.runtimes.java — Java / Spring Boot 3 runtime emitter. Emits a complete Spring Boot 3.2
service skeleton (web + actuator + micrometer-prometheus + validation) realising the blueprint.
Consumes com.dokandar:dkd-platform-sdk. No business logic.
"""
from __future__ import annotations
from ..blueprint import Service
from ..render import Writer
from .common import emit_common


def emit(svc: Service, out_dir: str) -> list[str]:
    w = Writer(out_dir, "//")
    emit_common(w, svc)

    pkg = "com.dokandar." + svc.pkg
    src = "src/main/java/com/dokandar/" + svc.pkg
    tst = "src/test/java/com/dokandar/" + svc.pkg

    w.write("pom.xml", '''<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.5.6</version>
    <relativePath/>
  </parent>
  <groupId>com.dokandar</groupId>
  <artifactId>%s</artifactId>
  <version>0.1.0</version>
  <properties>
    <java.version>21</java.version>
  </properties>
  <dependencies>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-web</artifactId></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-actuator</artifactId></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-validation</artifactId></dependency>
    <dependency><groupId>io.micrometer</groupId><artifactId>micrometer-registry-prometheus</artifactId></dependency>
    <dependency><groupId>com.dokandar</groupId><artifactId>dkd-platform-sdk</artifactId><version>1.0.0</version></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-test</artifactId><scope>test</scope></dependency>
  </dependencies>
  <build>
    <plugins>
      <plugin><groupId>org.springframework.boot</groupId><artifactId>spring-boot-maven-plugin</artifactId></plugin>
    </plugins>
  </build>
</project>
''' % svc.slug)

    w.write("src/main/resources/application.yml", '''server:
  port: %d
spring:
  application:
    name: %s
# API Documentation Standard: Swagger UI at /docs, OpenAPI JSON at /swagger/v1/swagger.json.
# The OpenAPI document + Bearer scheme come from the SDK auto-configuration (DkdApiDocs) — no service code.
springdoc:
  swagger-ui:
    path: /docs
  api-docs:
    path: /swagger/v1/swagger.json
management:
  server:
    port: 9090
  endpoints:
    web:
      base-path: /
      exposure:
        include: [health, prometheus]
      path-mapping:
        prometheus: metrics
  endpoint:
    health:
      probes:
        enabled: true
  health:
    livenessstate:
      enabled: true
    readinessstate:
      enabled: true
''' % (svc.http_port, svc.slug))

    w.write("src/main/resources/logback-spring.xml", '''<configuration>
  <appender name="json" class="ch.qos.logback.core.ConsoleAppender">
    <encoder><pattern>{"ts":"%d{yyyy-MM-dd HH:mm:ss.SSS}","level":"%level","logger":"%logger{20}","msg":"%msg","cid":"%X{correlation_id}"}%n</pattern></encoder>
  </appender>
  <root level="INFO"><appender-ref ref="json"/></root>
</configuration>
''')

    w.write("%s/Application.java" % src, '''package %s;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class Application {
    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }
}
''' % pkg)

    # health/version controllers (/health /ready /live in addition to actuator probes)
    w.write("%s/http/HealthController.java" % src, '''package %s.http;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import java.util.Map;

@RestController
public class HealthController {
    @GetMapping("/health")
    public Map<String, Object> health() { return env("ok"); }

    @GetMapping("/live")
    public Map<String, Object> live() { return env("alive"); }

    @GetMapping("/ready")
    public Map<String, Object> ready() { return env("ready"); }

    private Map<String, Object> env(String status) {
        return Map.of("success", true, "data", Map.of("status", status));
    }
}
''' % pkg)

    w.write("%s/http/VersionController.java" % src, '''package %s.http;

import com.dokandar.platform.Provenance;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import java.util.Map;

@RestController
public class VersionController {
    @GetMapping("/version")
    public Map<String, Object> version() {
        return Map.of("success", true, "data", Map.of(
            "contractVersion", Provenance.CONTRACT_VERSION,
            "sdkGenerator", Provenance.GENERATOR_VERSION));
    }
}
''' % pkg)

    # filters: correlation, security headers, request logging
    w.write("%s/http/CorrelationFilter.java" % src, '''package %s.http;

import jakarta.servlet.*;
import jakarta.servlet.http.*;
import org.slf4j.MDC;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import java.io.IOException;
import java.util.UUID;

@Component
@Order(1)
public class CorrelationFilter implements Filter {
    @Override
    public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
            throws IOException, ServletException {
        HttpServletRequest r = (HttpServletRequest) req;
        HttpServletResponse w = (HttpServletResponse) res;
        String cid = r.getHeader("X-Correlation-Id");
        if (cid == null || cid.isBlank()) cid = UUID.randomUUID().toString();
        MDC.put("correlation_id", cid);
        w.setHeader("X-Correlation-Id", cid);
        try {
            chain.doFilter(req, res);
        } finally {
            MDC.remove("correlation_id");
        }
    }
}
''' % pkg)

    w.write("%s/http/SecurityHeadersFilter.java" % src, '''package %s.http;

import jakarta.servlet.*;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import java.io.IOException;

@Component
@Order(2)
public class SecurityHeadersFilter implements Filter {
    @Override
    public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
            throws IOException, ServletException {
        HttpServletResponse w = (HttpServletResponse) res;
        w.setHeader("X-Content-Type-Options", "nosniff");
        w.setHeader("X-Frame-Options", "DENY");
        w.setHeader("Referrer-Policy", "no-referrer");
        w.setHeader("Content-Security-Policy", "default-src 'none'");
        chain.doFilter(req, res);
    }
}
''' % pkg)

    # security: JWT auth + authz
    w.write("%s/security/Jwt.java" % src, '''package %s.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.Base64;
import java.util.List;

// JWT authentication (bearer extraction + claims parse) + authorization. Signature verification is
// delegated to a Verifier bean (the platform JWKS integration point).
public final class Jwt {
    public interface Verifier { boolean verify(String token); }

    public record Claims(String sub, String kyc_tier, List<String> roles, String cid) {}

    private final Verifier verifier;
    private final ObjectMapper mapper = new ObjectMapper();

    public Jwt(Verifier verifier) { this.verifier = verifier; }

    public Claims parse(String authorization) {
        if (authorization == null || !authorization.startsWith("Bearer ")) return null;
        String token = authorization.substring("Bearer ".length());
        String[] parts = token.split("\\\\.");
        if (parts.length != 3) return null;
        if (verifier != null && !verifier.verify(token)) return null;
        try {
            byte[] payload = Base64.getUrlDecoder().decode(parts[1]);
            return mapper.readValue(payload, Claims.class);
        } catch (Exception e) {
            return null;
        }
    }

    public static boolean hasRole(Claims c, String role) {
        return c != null && c.roles() != null && c.roles().contains(role);
    }
}
''' % pkg)

    w.write("%s/security/SecurityConfig.java" % src, '''package %s.security;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class SecurityConfig {
    // Default verifier accepts well-formed tokens; replace with the platform JWKS verifier.
    @Bean
    public Jwt jwt() {
        return new Jwt(token -> true);
    }
}
''' % pkg)

    # exception handling -> RFC-7807
    w.write("%s/web/GlobalExceptionHandler.java" % src, '''package %s.web;

import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class GlobalExceptionHandler {
    @ExceptionHandler(IllegalArgumentException.class)
    public ProblemDetail badRequest(IllegalArgumentException ex) {
        ProblemDetail p = ProblemDetail.forStatusAndDetail(HttpStatus.BAD_REQUEST, ex.getMessage());
        p.setProperty("code", "dokandar.%s.validation.invalid");
        return p;
    }

    @ExceptionHandler(Exception.class)
    public ProblemDetail internal(Exception ex) {
        ProblemDetail p = ProblemDetail.forStatusAndDetail(HttpStatus.INTERNAL_SERVER_ERROR, "internal error");
        p.setProperty("code", "dokandar.%s.internal.unhandled");
        return p;
    }
}
''' % (pkg, svc.context, svc.context))

    # messaging + persistence abstractions
    w.write("%s/messaging/Messaging.java" % src, '''package %s.messaging;

// Kafka + RabbitMQ bootstrap abstractions. Concrete drivers implement these at the integration
// point. No business events (R6).
public final class Messaging {
    private Messaging() {}

    public interface Publisher {
        void publish(String topic, String key, byte[] payload);
        void close();
    }

    public interface Consumer {
        void subscribe(java.util.List<String> topics, Handler handler);
        void close();
    }

    public interface Handler {
        void handle(String topic, String key, byte[] payload);
    }

    public static final class NoopPublisher implements Publisher {
        public void publish(String topic, String key, byte[] payload) { /* wired at integration point */ }
        public void close() { /* no-op */ }
    }
}
''' % pkg)

    w.write("%s/persistence/Persistence.java" % src, '''package %s.persistence;

// DB abstraction + transaction helper + repository base + migrations. The concrete driver is wired
// at the integration point. No business repositories.
public final class Persistence {
    private Persistence() {}

    public interface Db {
        void ping();
        <T> T withTx(TxFunction<T> fn);
        void close();
    }

    public interface Tx {
        void exec(String sql, Object... args);
    }

    public interface TxFunction<T> {
        T apply(Tx tx);
    }

    public interface Migrator {
        void apply();
    }

    public abstract static class RepositoryBase {
        protected final Db db;
        protected RepositoryBase(Db db) { this.db = db; }
        protected <T> T inTx(TxFunction<T> fn) { return db.withTx(fn); }
    }
}
''' % pkg)

    w.write("%s/validation/InputValidator.java" % src, '''package %s.validation;

// Boundary input validation (EF C7: reject, never coerce).
public final class InputValidator {
    private InputValidator() {}

    public static void required(String field, String value) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(field + " is required");
        }
    }
}
''' % pkg)

    # test
    w.write("%s/ApplicationTests.java" % tst, '''package %s;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
class ApplicationTests {

    @Autowired
    MockMvc mvc;

    @Test
    void contextLoads() {
    }

    @Test
    void healthIsUp() throws Exception {
        mvc.perform(get("/health"))
           .andExpect(status().isOk())
           .andExpect(jsonPath("$.success").value(true));
    }

    @Test
    void versionReportsContract() throws Exception {
        mvc.perform(get("/version"))
           .andExpect(status().isOk())
           .andExpect(jsonPath("$.data.contractVersion").value("1.0.0"));
    }

    // API Documentation Standard: OpenAPI JSON at /swagger/v1/swagger.json (doc v1 + Bearer scheme).
    @Test
    void openApiDocumentHasBearerScheme() throws Exception {
        mvc.perform(get("/swagger/v1/swagger.json"))
           .andExpect(status().isOk())
           .andExpect(jsonPath("$.info.version").value("v1"))
           .andExpect(jsonPath("$.components.securitySchemes.Bearer.scheme").value("bearer"));
    }
}
''' % pkg)

    # Dockerfile
    w.write("Dockerfile", '''# Multi-stage Spring Boot build; non-root runtime.
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml ./
RUN mvn -q -B -e -o dependency:resolve || true
COPY . .
RUN mvn -q -B package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /src/target/*.jar /app/app.jar
EXPOSE %d 9090
USER 1000:1000
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
''' % svc.http_port)

    # CI: build the SDK to local .m2, then mvn test
    w.write(".gitlab-ci.yml", '''stages: [build, package]

java:build-test:
  stage: build
  image: maven:3.9-eclipse-temurin-21
  before_script:
    - apt-get update -qq && apt-get install -y -qq git >/dev/null
    - git clone --depth 1 --branch v1.0.0 "https://gitlab-ci-token:${CI_JOB_TOKEN}@gitlab.com/%s/dkd-platform-libs.git" /tmp/libs
    - (cd /tmp/libs/sdk/java && mvn -q -B -DskipTests install)
  script:
    - mvn -q -B test

docker:build:
  stage: package
  image: docker:27
  services: [docker:27-dind]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - docker build -t "$CI_REGISTRY_IMAGE:0.1.0" .
''' % svc.group)

    return list(w.written)
