// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// PL-06 — error -> HTTP status map over the FULL EF-API-3 vocabulary. The generated Errors module
// carries only the coarse trio (ValidationException=400, BusinessException=409,
// InfrastructureException=503); this primitive extends the hierarchy (extending
// Errors.DokandarException) to the canon set: 400 malformed vs 422 business-validation, 403
// four-eyes/authz, 409 state/idempotency-mismatch, 423 Locked (park/fence), 429 rate-limit
// (+Retry-After), and the 202 async escrow/payout accept — plus a statusFor mapper.
package com.dokandar.platform;

import java.util.Map;

/**
 * The canonical HTTP status vocabulary (EF-API-3) and the typed exceptions that map onto it.
 * {@link #statusFor} resolves any throwable to its wire status (any {@link Errors.DokandarException}
 * reports its own {@code httpStatus}; anything else is a 500). Splitting {@link
 * MalformedRequestException} (400) from {@link BusinessValidationException} (422) fixes the
 * generated module's conflation of "malformed" with "business-validation".
 */
public final class HttpStatus {

    private HttpStatus() {
    }

    public static final int ACCEPTED = 202;             // async escrow/payout accepted
    public static final int BAD_REQUEST = 400;          // malformed request
    public static final int FORBIDDEN = 403;            // four-eyes / authz denial
    public static final int CONFLICT = 409;             // state / idempotency-key mismatch
    public static final int UNPROCESSABLE_ENTITY = 422; // business-validation failure
    public static final int LOCKED = 423;               // park-and-freeze / fenced aggregate
    public static final int TOO_MANY_REQUESTS = 429;    // rate limit
    public static final int SERVICE_UNAVAILABLE = 503;  // dependency unavailable

    /** 400 — the request itself is malformed (bad JSON, missing/!typed field, bad header). */
    public static final class MalformedRequestException extends Errors.DokandarException {
        public MalformedRequestException(String code, String message) {
            super(code, message, BAD_REQUEST, null);
        }
    }

    /** 422 — the request is well-formed but fails a business rule / invariant. */
    public static final class BusinessValidationException extends Errors.DokandarException {
        public BusinessValidationException(String code, String message) {
            super(code, message, UNPROCESSABLE_ENTITY, null);
        }
    }

    /** 403 — authorization or a four-eyes co-sign requirement was not satisfied. */
    public static final class AuthorizationException extends Errors.DokandarException {
        public AuthorizationException(String code, String message) {
            super(code, message, FORBIDDEN, null);
        }
    }

    /** 409 — the target is in a state that conflicts with the command (incl. idempotency mismatch). */
    public static final class StateConflictException extends Errors.DokandarException {
        public StateConflictException(String code, String message) {
            super(code, message, CONFLICT, null);
        }
    }

    /** 423 — the aggregate/key is parked-and-frozen or fenced; retry is pointless until unlocked. */
    public static final class LockedException extends Errors.DokandarException {
        public LockedException(String code, String message) {
            super(code, message, LOCKED, null);
        }
    }

    /** 429 — rate limited; carries the {@code Retry-After} hint (seconds). */
    public static final class RateLimitException extends Errors.DokandarException {
        public final long retryAfterSeconds;

        public RateLimitException(String code, String message, long retryAfterSeconds) {
            super(code, message, TOO_MANY_REQUESTS, null);
            if (retryAfterSeconds < 0) {
                throw new IllegalArgumentException("retryAfterSeconds must be non-negative");
            }
            this.retryAfterSeconds = retryAfterSeconds;
        }

        /** The {@code Retry-After} response header (delta-seconds form, RFC-9110). */
        public Map<String, String> retryAfterHeader() {
            return Map.of("Retry-After", Long.toString(retryAfterSeconds));
        }
    }

    /** 503 — a required dependency (broker, datastore, downstream OHS) is unavailable. */
    public static final class UnavailableException extends Errors.DokandarException {
        public UnavailableException(String code, String message) {
            super(code, message, SERVICE_UNAVAILABLE, null);
        }
    }

    /**
     * Map any throwable to its HTTP status. A {@link Errors.DokandarException} (from either the
     * generated trio or this extended set, incl. the PL-03 idempotency exceptions) reports its own
     * {@code httpStatus}; every other throwable is an internal 500.
     */
    public static int statusFor(Throwable t) {
        if (t instanceof Errors.DokandarException d) {
            return d.httpStatus;
        }
        return 500;
    }
}
