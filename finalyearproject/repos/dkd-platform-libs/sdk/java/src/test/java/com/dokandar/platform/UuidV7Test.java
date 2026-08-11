// HAND-AUTHORED test (NOT dkdgen-generated).
// PL-04 conformance: a generated v7 validates + round-trips; a v4 and a garbage body are rejected;
// prefixed-ID + GPID body shapes are enforced.
package com.dokandar.platform;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class UuidV7Test {

    // RFC-9562 example v7; a stock v4 for the negative case.
    private static final String V7 = "017f22e2-79b0-7cc3-98c4-dc0c0c07398f";
    private static final String V4 = "f47ac10b-58cc-4372-a567-0e02b2c3d479";

    @Test
    void generatorProducesValidRoundTrippableV7() {
        String id = UuidV7.generate();
        assertTrue(UuidV7.isValidV7(id), id);
        // version nibble is 7, variant is one of 8..b.
        assertEquals('7', id.charAt(14));
        assertTrue("89ab".indexOf(id.charAt(19)) >= 0, id);
    }

    @Test
    void generateAtEncodesTheTimestampInTheHighBits() {
        long ms = 1_719_792_000_000L; // 2024-07-01T00:00:00Z
        String id = UuidV7.generateAt(ms);
        assertTrue(UuidV7.isValidV7(id), id);
        assertEquals(ms, UuidV7.timestampMs(id), "48-bit unix-ms round-trips");
    }

    @Test
    void generatorIsTimeOrderedAndUnique() {
        String a = UuidV7.generateAt(1000L);
        String b = UuidV7.generateAt(2000L);
        assertTrue(a.compareTo(b) < 0, "earlier ms sorts before later ms (time-ordered)");
        assertNotEquals(UuidV7.generate(), UuidV7.generate(), "random low bits keep them unique");
    }

    @Test
    void validationAcceptsV7ButRejectsV4AndGarbage() {
        assertTrue(UuidV7.isValidV7(V7));
        assertFalse(UuidV7.isValidV7(V4), "a v4 UUID must be rejected (version nibble 4, not 7)");
        assertFalse(UuidV7.isValidV7("not-a-uuid"));
        assertFalse(UuidV7.isValidV7("017F22E2-79B0-7CC3-98C4-DC0C0C07398F"), "upper-case body rejected");
        assertFalse(UuidV7.isValidV7(null));
        assertThrows(IllegalArgumentException.class, () -> UuidV7.timestampMs(V4));
    }

    @Test
    void prefixedHelpersValidateEmbeddedV7() {
        String did = UuidV7.newPrefixed("did:dokandar:");
        assertTrue(UuidV7.isValidPrefixed(did, "did:dokandar:"));
        assertEquals(did, UuidV7.validatePrefixed(did, "did:dokandar:"));

        // a v4 body, or the wrong prefix, is rejected.
        assertFalse(UuidV7.isValidPrefixed("PP-" + V4, "PP-"));
        assertFalse(UuidV7.isValidPrefixed("did:dokandar:abc", "did:dokandar:"));
        assertFalse(UuidV7.isValidPrefixed("ORD-" + V7, "PP-"));
        assertThrows(IllegalArgumentException.class, () -> UuidV7.validatePrefixed("PP-abc", "PP-"));
    }

    @Test
    void gpidEnforcesCategoryPlusV7Body() {
        String gpid = UuidV7.newGpid("rice");
        assertTrue(UuidV7.isValidGpid(gpid), gpid);
        assertTrue(gpid.startsWith("GP-rice-"));
        assertEquals(gpid, UuidV7.validatePrefixed(gpid, "GP-rice-"));

        assertFalse(UuidV7.isValidGpid("GP-rice-01"), "ad-hoc body (not a v7) rejected");
        assertFalse(UuidV7.isValidGpid("GP-rice-" + V4), "v4 suffix rejected");
        assertThrows(IllegalArgumentException.class, () -> UuidV7.newGpid("Rice"), "category must be lowercase");
    }
}
