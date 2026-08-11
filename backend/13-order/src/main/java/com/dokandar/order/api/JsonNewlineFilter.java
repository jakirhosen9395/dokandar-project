package com.dokandar.order.api;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletOutputStream;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.util.ContentCachingResponseWrapper;

import java.io.IOException;

/**
 * Appends a trailing newline to every {@code application/json} response body so
 * the rendered JSON is byte-identical to the rest of the fleet (Python
 * {@code json.dumps}+'\n'). Excluded: {@code /metrics} (text), {@code /openapi.json}
 * + {@code /docs} + actuator (framework-serialized), and any empty/bare body
 * (so the bare-404 keeps Content-Length 0 / no Content-Type).
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 5)
public class JsonNewlineFilter extends OncePerRequestFilter {

    private static boolean excluded(String p) {
        return p.equals("/metrics") || p.equals("/openapi.json") || p.startsWith("/docs")
            || p.startsWith("/swagger") || p.startsWith("/v3/api-docs") || p.startsWith("/actuator");
    }

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        if (excluded(req.getRequestURI())) { chain.doFilter(req, res); return; }
        ContentCachingResponseWrapper w = new ContentCachingResponseWrapper(res);
        try {
            chain.doFilter(req, w);
        } finally {
            byte[] body = w.getContentAsByteArray();
            String ct = w.getContentType();
            boolean json = ct != null && ct.contains("application/json");
            if (json && body.length > 0 && body[body.length - 1] != (byte) '\n' && !res.isCommitted()) {
                res.setContentLength(body.length + 1);
                ServletOutputStream out = res.getOutputStream();
                out.write(body);
                out.write('\n');
                out.flush();
            } else {
                w.copyBodyToResponse();
            }
        }
    }
}
