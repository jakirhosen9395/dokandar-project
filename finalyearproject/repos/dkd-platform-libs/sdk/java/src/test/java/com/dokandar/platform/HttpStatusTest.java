// HAND-AUTHORED test (NOT dkdgen-generated).
// PL-06 conformance: the full EF-API-3 error -> HTTP status vocabulary maps correctly,
// including the 400/422 split, 423 Locked, and 429 + Retry-After.
package com.dokandar.platform;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class HttpStatusTest {

    @Test
    void extendedExceptionsCarryTheirCanonStatus() {
        assertEquals(400, new HttpStatus.MalformedRequestException("c", "m").httpStatus);
        assertEquals(422, new HttpStatus.BusinessValidationException("c", "m").httpStatus);
        assertEquals(403, new HttpStatus.AuthorizationException("c", "m").httpStatus);
        assertEquals(409, new HttpStatus.StateConflictException("c", "m").httpStatus);
        assertEquals(423, new HttpStatus.LockedException("c", "m").httpStatus);
        assertEquals(503, new HttpStatus.UnavailableException("c", "m").httpStatus);
    }

    @Test
    void malformedAndBusinessValidationAreDistinctStatuses() {
        // the generated module conflated these as ValidationException=400; PL-06 splits 400 vs 422.
        assertNotEquals(
            new HttpStatus.MalformedRequestException("c", "m").httpStatus,
            new HttpStatus.BusinessValidationException("c", "m").httpStatus);
    }

    @Test
    void rateLimitCarriesRetryAfter() {
        HttpStatus.RateLimitException ex = new HttpStatus.RateLimitException("c", "slow down", 30);
        assertEquals(429, ex.httpStatus);
        assertEquals("30", ex.retryAfterHeader().get("Retry-After"));
        assertThrows(IllegalArgumentException.class, () -> new HttpStatus.RateLimitException("c", "m", -1));
    }

    @Test
    void statusForMapsDokandarExceptionsAndDefaultsTo500() {
        assertEquals(423, HttpStatus.statusFor(new HttpStatus.LockedException("c", "frozen")));
        assertEquals(429, HttpStatus.statusFor(new HttpStatus.RateLimitException("c", "m", 1)));
        // generated trio still resolves through the shared base.
        assertEquals(400, HttpStatus.statusFor(new Errors.ValidationException("c", "m")));
        assertEquals(409, HttpStatus.statusFor(new Errors.BusinessException("c", "m")));
        assertEquals(503, HttpStatus.statusFor(new Errors.InfrastructureException("c", "m")));
        // PL-03 idempotency exceptions map too.
        assertEquals(409, HttpStatus.statusFor(new Idempotency.KeyConflictException("k")));
        // anything else -> internal 500.
        assertEquals(500, HttpStatus.statusFor(new RuntimeException("boom")));
    }

    @Test
    void asyncAcceptedConstantIs202() {
        assertEquals(202, HttpStatus.ACCEPTED);
    }
}
