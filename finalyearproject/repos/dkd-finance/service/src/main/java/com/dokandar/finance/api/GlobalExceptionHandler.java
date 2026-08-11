package com.dokandar.finance.api;

import com.dokandar.platform.Dto;
import com.dokandar.platform.Errors;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.MissingRequestHeaderException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.servlet.resource.NoResourceFoundException;

/**
 * RFC-7807 problem+json wrapped in the fleet {success,data,error,meta} envelope.
 * Error codes follow dokandar.finance.<category>.<reason>; internals never leak.
 */
@RestControllerAdvice
public class GlobalExceptionHandler {
    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    @ExceptionHandler(Errors.DokandarException.class)
    public ResponseEntity<Dto.Response<Void>> dokandar(Errors.DokandarException e) {
        return problem(e.httpStatus, e.code, e.getMessage());
    }

    @ExceptionHandler({HttpMessageNotReadableException.class, MissingRequestHeaderException.class,
                       IllegalArgumentException.class})
    public ResponseEntity<Dto.Response<Void>> badRequest(Exception e) {
        return problem(400, Errors.errorCode("finance", "request", "malformed"), e.getMessage());
    }

    @ExceptionHandler(NoResourceFoundException.class)
    public ResponseEntity<Dto.Response<Void>> noRoute(NoResourceFoundException e) {
        return problem(404, Errors.errorCode("finance", "request", "not_found"), "no such resource");
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<Dto.Response<Void>> unexpected(Exception e) {
        log.error("unhandled error", e);
        return problem(500, Errors.errorCode("finance", "internal", "unexpected"),
            "internal error — see service logs");
    }

    private ResponseEntity<Dto.Response<Void>> problem(int status, String code, String detail) {
        var pd = new Errors.ProblemDetails(
            "about:blank", HttpStatus.valueOf(status).getReasonPhrase(), status, code, detail, null, null);
        return ResponseEntity.status(status)
            .contentType(MediaType.APPLICATION_PROBLEM_JSON)
            .body(Dto.Response.fail(pd, null));
    }
}
