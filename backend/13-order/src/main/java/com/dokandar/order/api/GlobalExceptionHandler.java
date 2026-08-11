package com.dokandar.order.api;

import com.dokandar.order.auth.JwtAuth;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.HttpRequestMethodNotSupportedException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.servlet.NoHandlerFoundException;
import org.springframework.web.servlet.resource.NoResourceFoundException;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * The single error-envelope shape: {@code {error:{code, message, request_id, details?}}},
 * pretty-JSON, correlated by request_id. Unmapped paths get a BARE 404 (no body,
 * no Content-Type); method typos on a known path get a structured 405; bad JSON
 * and validation get 422; unexpected errors get a GENERIC 500 (no leak).
 */
@RestControllerAdvice
public class GlobalExceptionHandler {
    private static final Logger LOG = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    @ExceptionHandler(ApiException.class)
    public ResponseEntity<?> api(HttpServletRequest req, ApiException e) {
        return env(req, e.status, e.code, e.getMessage(), e.details);
    }

    @ExceptionHandler(JwtAuth.UnauthorizedException.class)
    public ResponseEntity<?> unauthorized(HttpServletRequest req, JwtAuth.UnauthorizedException e) {
        return env(req, 401, e.code, e.getMessage(), null);
    }

    // BARE 404 on any unmapped path: status 404, Content-Length 0, NO body, NO Content-Type.
    @ExceptionHandler({NoHandlerFoundException.class, NoResourceFoundException.class})
    public void bareNotFound(HttpServletResponse res) {
        // no flushBuffer(): let the response commit through the JsonNewlineFilter's wrapper so
        // Content-Length: 0 is preserved (no body, no Content-Type).
        res.reset();
        res.setStatus(404);
        res.setContentLength(0);
    }

    @ExceptionHandler(HttpRequestMethodNotSupportedException.class)
    public ResponseEntity<?> methodNotAllowed(HttpServletRequest req, HttpRequestMethodNotSupportedException e) {
        return env(req, 405, "method_not_allowed", "Method Not Allowed", null);
    }

    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<?> badJson(HttpServletRequest req, HttpMessageNotReadableException e) {
        return env(req, 422, "validation_error", "invalid JSON body", null);
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<?> generic(HttpServletRequest req, Exception e) {
        LOG.warn("unhandled exception path={} kind={}: {}", req.getRequestURI(), e.getClass().getSimpleName(), e.getMessage());
        return env(req, 500, "internal_error", "internal error", null);   // generic — never leak e.getMessage()
    }

    private static ResponseEntity<?> env(HttpServletRequest req, int status, String code, String msg, Object details) {
        Object rid = req.getAttribute("request_id");
        Map<String, Object> err = new LinkedHashMap<>();
        err.put("code", code);
        err.put("message", msg);
        err.put("request_id", rid == null ? "" : rid);
        if (details != null) err.put("details", details);
        return ResponseEntity.status(HttpStatus.valueOf(status)).body(Map.of("error", err));
    }
}
