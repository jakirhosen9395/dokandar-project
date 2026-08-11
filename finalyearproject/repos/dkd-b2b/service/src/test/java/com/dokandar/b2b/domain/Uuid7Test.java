package com.dokandar.b2b.domain;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.HashSet;
import java.util.Set;
import org.junit.jupiter.api.Test;

class Uuid7Test {

    @Test
    void hasCanonicalShapeVersionAndVariant() {
        String u = Uuid7.generate();
        assertTrue(u.matches("^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"),
            "not a v7 uuid: " + u);
    }

    @Test
    void encodesTimestampInFirst48Bits() {
        long ms = 0x0190_1234_5678L;
        String u = Uuid7.generate(ms);
        assertEquals("019012345678", u.substring(0, 8) + u.substring(9, 13));
    }

    @Test
    void timestampPrefixOrdersAcrossMillis() {
        String early = Uuid7.generate(1_000_000L);
        String late = Uuid7.generate(2_000_000L);
        assertTrue(early.compareTo(late) < 0);
    }

    @Test
    void generatesUniqueValues() {
        Set<String> seen = new HashSet<>();
        for (int i = 0; i < 10_000; i++) assertTrue(seen.add(Uuid7.generate()));
    }
}
