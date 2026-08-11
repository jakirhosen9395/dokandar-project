package com.dokandar.finance.domain;

import com.dokandar.platform.Errors;
import java.util.Set;
import java.util.regex.Pattern;

/** Input validation at the finance boundary. Fail fast, taxonomy-coded errors. */
public final class Rules {
    /** E.164 Bangladesh mobile: +880 then 8-12 digits (canon: phone is E.164 +880...). */
    private static final Pattern BD_E164 = Pattern.compile("^\\+880\\d{8,12}$");
    private static final Pattern OTP_6 = Pattern.compile("^\\d{6}$");
    public static final Set<String> REFERENCE_TYPES =
        Set.of("ORDER", "TRADE", "ESCROW", "DEPOSIT", "WITHDRAWAL", "MFS_SETTLEMENT");
    public static final int MAX_MFS_ACCOUNTS = 5;

    private Rules() {}

    public static void requireDid(String did) {
        if (!FinanceIds.isDid(did))
            throw new Errors.ValidationException(
                Errors.errorCode("finance", "wallet", "invalid_did"),
                "ownerDid must be a did:dokandar:{uuid7}");
    }

    public static void requireBdMobile(String mobile) {
        if (mobile == null || !BD_E164.matcher(mobile).matches())
            throw new Errors.ValidationException(
                Errors.errorCode("finance", "mfs", "invalid_mobile"),
                "mobile must be E.164 +880...");
    }

    /** Dev posture: any well-formed 6-digit OTP verifies (real MFS OTP flow is NEEDS-INFO). */
    public static void requireOtpShape(String otpToken) {
        if (otpToken == null || !OTP_6.matcher(otpToken).matches())
            throw new Errors.ValidationException(
                Errors.errorCode("finance", "mfs", "invalid_otp"),
                "otpToken must be 6 digits");
    }

    public static void requireReferenceType(String referenceType) {
        if (referenceType == null || !REFERENCE_TYPES.contains(referenceType))
            throw new Errors.ValidationException(
                Errors.errorCode("finance", "ledger", "invalid_reference_type"),
                "referenceType must be one of " + REFERENCE_TYPES);
    }

    public static void requireText(String value, String field) {
        if (value == null || value.isBlank())
            throw new Errors.ValidationException(
                Errors.errorCode("finance", "request", "missing_field"),
                field + " is required");
    }
}
