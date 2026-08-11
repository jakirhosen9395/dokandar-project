// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// PL-05 — W3C Trace Context (traceparent) parse / format / inject / extract + new-id helpers.
// Replaces the bare `traceparent` header passthrough in Security.CorrelationContext /
// Outbox.OutboxRelay with a real W3C helper (EF-OBS-7: traceparent injected by the outbox,
// extracted by the inbox). Full OTel-SDK span creation stays a service-level concern; this
// primitive owns only correct W3C parse/format/inject/extract + fresh trace/span-id generation.
package com.dokandar.platform;

import java.security.SecureRandom;
import java.util.Map;
import java.util.Optional;
import java.util.regex.Pattern;

/**
 * W3C Trace Context helper. A {@code traceparent} is
 * {@code version "-" trace-id "-" span-id "-" trace-flags} = {@code 00-<32hex>-<16hex>-<2hex>}
 * with an all-zero trace-id or span-id forbidden. {@link #parse} and {@link #format} round-trip;
 * {@link #inject}/{@link #extract} move a context through HTTP or event header maps; {@link
 * #newContext} mints a fresh sampled context for a root span.
 */
public final class Trace {

    private Trace() {
    }

    /** The W3C header name carried on HTTP requests and event headers alike. */
    public static final String HEADER = "traceparent";

    private static final SecureRandom RNG = new SecureRandom();
    private static final char[] HEX = "0123456789abcdef".toCharArray();

    private static final Pattern TRACE_ID = Pattern.compile("^[0-9a-f]{32}$");
    private static final Pattern SPAN_ID = Pattern.compile("^[0-9a-f]{16}$");
    private static final Pattern FLAGS = Pattern.compile("^[0-9a-f]{2}$");
    private static final String ALL_ZERO_TRACE = "0".repeat(32);
    private static final String ALL_ZERO_SPAN = "0".repeat(16);

    /** {@code sampled} trace-flags bit (0x01) per the W3C spec. */
    public static final byte FLAG_SAMPLED = 0x01;

    /** A parsed W3C trace context. {@code flags} is the 8-bit trace-flags field. */
    public record TraceContext(String traceId, String spanId, byte flags) {
        public TraceContext {
            if (traceId == null || !TRACE_ID.matcher(traceId).matches() || traceId.equals(ALL_ZERO_TRACE)) {
                throw new IllegalArgumentException("invalid W3C trace-id: " + traceId);
            }
            if (spanId == null || !SPAN_ID.matcher(spanId).matches() || spanId.equals(ALL_ZERO_SPAN)) {
                throw new IllegalArgumentException("invalid W3C span-id: " + spanId);
            }
        }

        /** True when the {@code sampled} flag is set. */
        public boolean isSampled() {
            return (flags & FLAG_SAMPLED) != 0;
        }

        /** A child context: same trace-id, a fresh span-id, flags preserved. */
        public TraceContext childSpan() {
            return new TraceContext(traceId, newSpanId(), flags);
        }
    }

    /**
     * Parse a {@code traceparent} string. Returns empty on null/blank/malformed input (wrong field
     * count, bad version, non-hex, wrong length, or an all-zero trace/span id) — never throws, so
     * callers can treat a broken upstream header as "no context" rather than failing the request.
     */
    public static Optional<TraceContext> parse(String traceparent) {
        if (traceparent == null || traceparent.isBlank()) {
            return Optional.empty();
        }
        String[] parts = traceparent.trim().split("-", -1);
        if (parts.length != 4) {
            return Optional.empty();
        }
        String version = parts[0];
        String traceId = parts[1];
        String spanId = parts[2];
        String flags = parts[3];
        // version 00 is the only defined version; ff is forbidden. Unknown future versions are ignored.
        if (!"00".equals(version)) {
            return Optional.empty();
        }
        if (!TRACE_ID.matcher(traceId).matches() || traceId.equals(ALL_ZERO_TRACE)
            || !SPAN_ID.matcher(spanId).matches() || spanId.equals(ALL_ZERO_SPAN)
            || !FLAGS.matcher(flags).matches()) {
            return Optional.empty();
        }
        return Optional.of(new TraceContext(traceId, spanId, (byte) Integer.parseInt(flags, 16)));
    }

    /** Format a context as a version-00 {@code traceparent} string. */
    public static String format(TraceContext ctx) {
        if (ctx == null) {
            throw new IllegalArgumentException("ctx must be non-null");
        }
        return "00-" + ctx.traceId() + "-" + ctx.spanId() + "-" + hex2(ctx.flags());
    }

    /** Inject {@code ctx} as a {@code traceparent} entry into a header map (HTTP or event headers). */
    public static void inject(Map<String, String> headers, TraceContext ctx) {
        if (headers == null) {
            throw new IllegalArgumentException("headers must be non-null");
        }
        headers.put(HEADER, format(ctx));
    }

    /** Extract a context from a header map's {@code traceparent} entry (empty when absent/malformed). */
    public static Optional<TraceContext> extract(Map<String, String> headers) {
        if (headers == null) {
            return Optional.empty();
        }
        return parse(headers.get(HEADER));
    }

    /** A fresh 128-bit trace-id as 32 lowercase-hex chars (never all-zero). */
    public static String newTraceId() {
        byte[] b = new byte[16];
        do {
            RNG.nextBytes(b);
        } while (isAllZero(b));
        return hex(b);
    }

    /** A fresh 64-bit span-id as 16 lowercase-hex chars (never all-zero). */
    public static String newSpanId() {
        byte[] b = new byte[8];
        do {
            RNG.nextBytes(b);
        } while (isAllZero(b));
        return hex(b);
    }

    /** A fresh root context (new trace-id + span-id) with the {@code sampled} flag set. */
    public static TraceContext newContext() {
        return new TraceContext(newTraceId(), newSpanId(), FLAG_SAMPLED);
    }

    private static boolean isAllZero(byte[] b) {
        for (byte x : b) {
            if (x != 0) {
                return false;
            }
        }
        return true;
    }

    private static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) {
            int v = x & 0xff;
            sb.append(HEX[v >>> 4]).append(HEX[v & 0x0f]);
        }
        return sb.toString();
    }

    private static String hex2(byte flags) {
        int v = flags & 0xff;
        return "" + HEX[v >>> 4] + HEX[v & 0x0f];
    }
}
