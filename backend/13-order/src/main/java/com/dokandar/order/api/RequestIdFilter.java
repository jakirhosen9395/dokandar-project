package com.dokandar.order.api;

import jakarta.servlet.*;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.util.UUID;

/** Honour-or-mint X-Request-Id; stash on the request + echo on the response header. */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class RequestIdFilter implements Filter {
    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {
        HttpServletRequest req = (HttpServletRequest) request;
        HttpServletResponse res = (HttpServletResponse) response;
        String rid = req.getHeader("x-request-id");
        if (rid == null || rid.isBlank() || !rid.matches("[A-Za-z0-9._-]{1,64}"))
            rid = UUID.randomUUID().toString().replace("-", "");
        req.setAttribute("request_id", rid);
        res.setHeader("x-request-id", rid);
        chain.doFilter(request, response);
    }
}
