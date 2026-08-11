package com.dokandar.catalog.api;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.MDC;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.servlet.HandlerMapping;

import java.io.IOException;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.Set;

/**
 * One structured access line per genuine request to stdout. Probe/scrape traffic
 * — {@code /ready}, {@code /metrics}, AND {@code /health} (§16-g / §10.2) — is
 * excluded. The line carries the TEMPLATED route (never the raw path — a raw
 * {@code /products/<uuid>} would leak ids + blow up cardinality), the true client
 * IP (X-Forwarded-For / CF-Connecting-IP), status, latency_ms, request_id, trace_id.
 */
@Component
@Order(Ordered.LOWEST_PRECEDENCE)
public class AccessLogFilter extends OncePerRequestFilter {
    private static final DateTimeFormatter TS = DateTimeFormatter.ofPattern("dd-MM-yyyy HH:mm:ss");
    private static final Set<String> SILENT = Set.of("/ready", "/metrics", "/health");

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        long t0 = System.nanoTime();
        try {
            chain.doFilter(req, res);
        } finally {
            String path = req.getRequestURI();
            if (!SILENT.contains(path)) {
                long latencyMs = (System.nanoTime() - t0) / 1_000_000;
                String route = templatedRoute(req, path);
                String ts = LocalDateTime.now(ZoneOffset.UTC).format(TS);
                String reqId = String.valueOf(req.getAttribute("request_id"));
                String traceId = mdcOr(MDC.get("trace.id"));
                System.out.println(ts + "  " + clientIp(req) + " \"" + req.getMethod() + " " + route + " "
                        + req.getProtocol() + "\" " + res.getStatus() + " " + latencyMs + "ms"
                        + " request_id=" + reqId + " trace_id=" + traceId);
            }
        }
    }

    /** Spring's best-matching pattern (e.g. /api/v1/catalog/products/{id}); falls back to a sentinel, never the raw path. */
    private static String templatedRoute(HttpServletRequest req, String rawPath) {
        Object p = req.getAttribute(HandlerMapping.BEST_MATCHING_PATTERN_ATTRIBUTE);
        if (p != null) return p.toString();
        return SILENT.contains(rawPath) ? rawPath : "unmapped";
    }

    /** True client IP: CF-Connecting-IP → left-most X-Forwarded-For → remote peer. */
    private static String clientIp(HttpServletRequest req) {
        String cf = req.getHeader("CF-Connecting-IP");
        if (cf != null && !cf.isBlank()) return cf.trim();
        String xff = req.getHeader("X-Forwarded-For");
        if (xff != null && !xff.isBlank()) return xff.split(",")[0].trim();
        return req.getRemoteAddr();
    }

    private static String mdcOr(String v) { return (v == null || v.isBlank()) ? "-" : v; }
}
