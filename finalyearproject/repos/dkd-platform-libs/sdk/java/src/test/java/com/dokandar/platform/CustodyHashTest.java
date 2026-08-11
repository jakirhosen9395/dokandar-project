// HAND-AUTHORED — CustodyHash Spec v2 conformance against the shared golden fixture (PL-01).
package com.dokandar.platform;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

class CustodyHashTest {

    @Test
    void tv01GenesisDigest() {
        // TV-01-genesis — DM §5 worked example, previousHash="" included.
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("ppid", "PP-01JABCDEF");
        fields.put("gpid", "GP-rice-01JABCDEF");
        fields.put("holder", "did:dokandar:01JABCDEF");
        fields.put("holderRole", "PRODUCER");
        fields.put("quantity", 5000L);
        fields.put("unit", "kg");
        fields.put("producedAt", 1750000000000L);
        fields.put("initializedAt", 1750000001000L);
        fields.put("previousHash", "");

        assertEquals(
            "{\"gpid\":\"GP-rice-01JABCDEF\",\"holder\":\"did:dokandar:01JABCDEF\","
                + "\"holderRole\":\"PRODUCER\",\"initializedAt\":1750000001000,"
                + "\"ppid\":\"PP-01JABCDEF\",\"previousHash\":\"\","
                + "\"producedAt\":1750000000000,\"quantity\":5000,\"unit\":\"kg\"}",
            CustodyHash.canonical(fields));
        assertEquals(
            "ac543fecee75695fb2b1922ea9e0830f4bddb6ef1ad17e80f278d6171cbe0597",
            CustodyHash.eventHash(fields));
    }

    @Test
    void eventHashKeyIsAlwaysExcluded() {
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("ppid", "PP-01JABCDEF");
        fields.put("previousHash", "");
        fields.put("quantity", 5000L);
        String without = CustodyHash.eventHash(fields);
        fields.put("eventHash", "f".repeat(64));
        assertEquals(without, CustodyHash.eventHash(fields));
    }

    @Test
    void nullMembersOmittedR2() {
        Map<String, Object> fields = new HashMap<>();
        fields.put("ppid", "PP-XYZ");
        fields.put("quantity", 10L);
        fields.put("previousHash", "abc");
        fields.put("optionalNote", null);
        fields.put("anotherNull", null);
        assertEquals("{\"ppid\":\"PP-XYZ\",\"previousHash\":\"abc\",\"quantity\":10}",
            CustodyHash.canonical(fields));
        assertEquals("2038cd01eb03eef9e9885912bce2b9f48bb37cade73e80b540d71c8109555e96",
            CustodyHash.eventHash(fields));
    }

    @Test
    void unicodeAndControlEscapesR5() {
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("ppid", "PP-বাংলা");
        fields.put("label", "a<b>c&d\"e\\f");
        fields.put("ctrl", "line1\nline2\ttab");
        fields.put("emoji", "🌾");
        fields.put("previousHash", "");
        assertEquals("2feda014115b350c68bed4c3f61238c7df0451b3b78ac6087257b902ab7b5c3b",
            CustodyHash.eventHash(fields));
    }

    @Test
    void nestedSortingR3R9ArraysUnsortedR8() {
        Map<String, Object> alphaM = new LinkedHashMap<>();
        alphaM.put("b", 2L);
        alphaM.put("y", 1L);
        Map<String, Object> alpha = new LinkedHashMap<>();
        alpha.put("z", 3L);
        alpha.put("a", 2L);
        alpha.put("m", alphaM);
        Map<String, Object> listObj = new LinkedHashMap<>();
        listObj.put("k", "v");
        listObj.put("a", "z");
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("zeta", 1L);
        fields.put("alpha", alpha);
        fields.put("list", List.of(3L, 1L, 2L, listObj));
        fields.put("previousHash", "");
        assertEquals(
            "{\"alpha\":{\"a\":2,\"m\":{\"b\":2,\"y\":1},\"z\":3},"
                + "\"list\":[3,1,2,{\"a\":\"z\",\"k\":\"v\"}],\"previousHash\":\"\",\"zeta\":1}",
            CustodyHash.canonical(fields));
        assertEquals("564f6f344b5a33543985a3314d240f3e6729c8f231076207a0aca6415c1edd53",
            CustodyHash.eventHash(fields));
    }

    @Test
    void intBoolR6R7() {
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("big", 9007199254740992L);
        fields.put("neg", -42L);
        fields.put("zero", 0L);
        fields.put("flagT", true);
        fields.put("flagF", false);
        fields.put("previousHash", "");
        assertEquals(
            "{\"big\":9007199254740992,\"flagF\":false,\"flagT\":true,"
                + "\"neg\":-42,\"previousHash\":\"\",\"zero\":0}",
            CustodyHash.canonical(fields));
        assertEquals("e15d636e41dc5b5db42dcb7f1d8455ba6253f41a2bcf12b5893a834da9d505fb",
            CustodyHash.eventHash(fields));
    }

    @Test
    void transferWithPreviousHashTv07() {
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("ppid", "PP-01JABCDEF");
        fields.put("fromHolder", "did:dokandar:AAA");
        fields.put("toHolder", "did:dokandar:BBB");
        fields.put("quantity", 5000L);
        fields.put("unit", "kg");
        fields.put("transferredAt", 1750000002000L);
        fields.put("previousHash",
            "ac543fecee75695fb2b1922ea9e0830f4bddb6ef1ad17e80f278d6171cbe0597");
        assertEquals("4ee2ed980a6f4fb90a68e1a73d15f5c5ae1d65931679034dc6df8602873ed59c",
            CustodyHash.eventHash(fields));
    }

    @Test
    void recalledNoPreviousHashTv08() {
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("recallId", "RECALL-01JXYZ");
        fields.put("gpid", "GP-rice-01JABCDEF");
        fields.put("reason", "contamination");
        fields.put("issuedBy", "did:dokandar:REGULATOR");
        fields.put("affectedPpids", List.of("PP-01JABCDEF", "PP-01JABCDEG"));
        fields.put("recalledAt", 1750000003000L);
        assertEquals("5f2e4e2c854f2449c9d78526a2c73956d9208294ebd86645956004ebec244c1f",
            CustodyHash.eventHash(fields));
    }

    @Test
    void verifyEventRoundTrip() {
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("ppid", "PP-01JABCDEF");
        fields.put("previousHash", "");
        fields.put("quantity", 5000L);
        String h = CustodyHash.eventHash(fields);
        fields.put("eventHash", h);
        assertTrue(CustodyHash.verifyEvent(fields));
        fields.put("eventHash", "0".repeat(64));
        assertFalse(CustodyHash.verifyEvent(fields));
    }

    @Test
    void verifyEventRejectsMissingHash() {
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("ppid", "PP-01JABCDEF");
        assertThrows(IllegalArgumentException.class, () -> CustodyHash.verifyEvent(fields));
    }

    @Test
    void nullTopLevelRejected() {
        assertThrows(IllegalArgumentException.class, () -> CustodyHash.canonical(null));
    }
}
