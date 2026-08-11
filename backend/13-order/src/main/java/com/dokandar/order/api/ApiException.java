package com.dokandar.order.api;

import java.util.List;
import java.util.Map;

/** Carries the platform error envelope's status + code + message (+ optional details[]). */
public class ApiException extends RuntimeException {
    public final int status;
    public final String code;
    public final List<Map<String, Object>> details;

    public ApiException(int status, String code, String message) { this(status, code, message, null); }
    public ApiException(int status, String code, String message, List<Map<String, Object>> details) {
        super(message);
        this.status = status;
        this.code = code;
        this.details = details;
    }

    public static ApiException badUuid() { return new ApiException(400, "invalid_uuid", "path parameter must be a valid UUID"); }
    public static ApiException notFound(String msg) { return new ApiException(404, "not_found", msg); }
    public static ApiException validation(String msg) { return new ApiException(422, "validation_error", msg); }
    public static ApiException validation(String msg, List<Map<String, Object>> details) { return new ApiException(422, "validation_error", msg, details); }
    public static ApiException forbidden(String code, String msg) { return new ApiException(403, code, msg); }
}
