// HAND-AUTHORED test (NOT dkdgen-generated).
// PL-05 conformance: W3C traceparent parse<->format round-trip, malformed rejection,
// inject/extract over a header map, and fresh id generation.
package com.dokandar.platform;

import java.util.HashMap;
import java.util.Map;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class TraceTest {

    private static final String TP = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";

    @Test
    void parseThenFormatRoundTrips() {
        Trace.TraceContext ctx = Trace.parse(TP).orElseThrow();
        assertEquals("4bf92f3577b34da6a3ce929d0e0e4736", ctx.traceId());
        assertEquals("00f067aa0ba902b7", ctx.spanId());
        assertTrue(ctx.isSampled());
        assertEquals(TP, Trace.format(ctx));
    }

    @Test
    void malformedTraceparentsAreRejected() {
        assertTrue(Trace.parse(null).isEmpty());
        assertTrue(Trace.parse("").isEmpty());
        assertTrue(Trace.parse("00-trace-01").isEmpty(), "wrong field count / lengths");
        assertTrue(Trace.parse("ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01").isEmpty(), "bad version");
        assertTrue(Trace.parse("00-00000000000000000000000000000000-00f067aa0ba902b7-01").isEmpty(), "all-zero trace-id");
        assertTrue(Trace.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01").isEmpty(), "all-zero span-id");
        assertTrue(Trace.parse("00-4bf92f3577b34da6a3ce929d0e0e473X-00f067aa0ba902b7-01").isEmpty(), "non-hex");
    }

    @Test
    void injectAndExtractMoveContextThroughHeaders() {
        Map<String, String> headers = new HashMap<>();
        Trace.TraceContext ctx = Trace.parse(TP).orElseThrow();
        Trace.inject(headers, ctx);
        assertEquals(TP, headers.get(Trace.HEADER));

        Trace.TraceContext extracted = Trace.extract(headers).orElseThrow();
        assertEquals(ctx, extracted);
        assertTrue(Trace.extract(new HashMap<>()).isEmpty(), "absent header -> empty");
    }

    @Test
    void newIdsAreWellFormedAndNonZero() {
        assertTrue(Trace.newTraceId().matches("^[0-9a-f]{32}$"));
        assertTrue(Trace.newSpanId().matches("^[0-9a-f]{16}$"));
        Trace.TraceContext root = Trace.newContext();
        assertTrue(root.isSampled());
        // a child keeps the trace-id but gets a fresh span-id.
        Trace.TraceContext child = root.childSpan();
        assertEquals(root.traceId(), child.traceId());
        assertNotEquals(root.spanId(), child.spanId());
        assertEquals(root, Trace.parse(Trace.format(root)).orElseThrow(), "generated context round-trips");
    }
}
