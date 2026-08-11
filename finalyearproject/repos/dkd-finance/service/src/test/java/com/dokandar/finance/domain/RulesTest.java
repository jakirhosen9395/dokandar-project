package com.dokandar.finance.domain;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;

import com.dokandar.platform.Errors;
import org.junit.jupiter.api.Test;

class RulesTest {

    @Test
    void acceptsBangladeshE164Mobile() {
        assertDoesNotThrow(() -> Rules.requireBdMobile("+8801712345678"));
    }

    @Test
    void rejectsNonBdOrMalformedMobiles() {
        for (String bad : new String[]{null, "", "01712345678", "+8801", "+15551234567", "+880 1712345678"})
            assertThrows(Errors.ValidationException.class, () -> Rules.requireBdMobile(bad));
    }

    @Test
    void otpMustBeSixDigits() {
        assertDoesNotThrow(() -> Rules.requireOtpShape("123456"));
        assertThrows(Errors.ValidationException.class, () -> Rules.requireOtpShape("12345"));
        assertThrows(Errors.ValidationException.class, () -> Rules.requireOtpShape("12345a"));
        assertThrows(Errors.ValidationException.class, () -> Rules.requireOtpShape(null));
    }

    @Test
    void referenceTypeMustBeCanonical() {
        assertDoesNotThrow(() -> Rules.requireReferenceType("DEPOSIT"));
        assertDoesNotThrow(() -> Rules.requireReferenceType("ESCROW"));
        assertThrows(Errors.ValidationException.class, () -> Rules.requireReferenceType("GIFT"));
        assertThrows(Errors.ValidationException.class, () -> Rules.requireReferenceType(null));
    }

    @Test
    void didMustBeDokandarForm() {
        assertDoesNotThrow(() -> Rules.requireDid("did:dokandar:0190aaaa-bbbb-7ccc-8ddd-eeeeffff0000"));
        assertThrows(Errors.ValidationException.class, () -> Rules.requireDid("did:web:x"));
        assertThrows(Errors.ValidationException.class, () -> Rules.requireDid("did:dokandar:"));
        assertThrows(Errors.ValidationException.class, () -> Rules.requireDid(null));
    }
}
