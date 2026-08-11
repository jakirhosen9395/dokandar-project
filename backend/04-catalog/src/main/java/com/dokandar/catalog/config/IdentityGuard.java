package com.dokandar.catalog.config;

import jakarta.annotation.PostConstruct;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * Fail-fast on a blank {@code SERVICE_NAME} — ALWAYS, independent of APP_ENV
 * (architecture.md §10.1). A blank value silently corrupts identity, logs,
 * traces, and metrics fleet-wide; it must never be hardcoded or defaulted.
 */
@Component
public class IdentityGuard {
    @Value("${dokandar.service.name:}") private String serviceName;

    @PostConstruct
    public void check() {
        if (serviceName == null || serviceName.isBlank())
            throw new IllegalStateException("SERVICE_NAME is empty — identity would be corrupt (fail-fast)");
    }
}
