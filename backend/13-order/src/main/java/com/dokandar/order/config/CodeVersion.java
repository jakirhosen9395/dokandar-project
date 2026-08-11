package com.dokandar.order.config;

import java.nio.file.Files;
import java.nio.file.Path;

/**
 * The repo-root CODE_VERSION value, read once at boot. The SAME value must appear
 * in the identity block, OpenAPI info.version, the APM service.version, and every
 * log line — so the version cannot lie (the operational contract).
 */
public final class CodeVersion {
    private CodeVersion() {}

    public static final String VALUE = read();

    private static String read() {
        for (String p : new String[]{"CODE_VERSION", "/app/CODE_VERSION"}) {
            try {
                String v = Files.readString(Path.of(p)).trim();
                if (!v.isBlank()) return v;
            } catch (Exception ignored) {}
        }
        return "13-order";
    }
}
