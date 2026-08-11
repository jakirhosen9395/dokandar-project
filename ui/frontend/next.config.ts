import type { NextConfig } from "next";

// connect-src must allow the RUM/APM endpoint (build-time public var) so the agent can ship traces.
const rum = process.env.NEXT_PUBLIC_RUM_SERVER_URL || "";
const connectExtra = rum ? ` ${new URL(rum).origin}` : "";

// CSP: strict by default. script/style allow 'unsafe-inline' (Next App Router inlines hydration data
// without nonces; nonce-based CSP is a documented follow-up). Everything else is locked down.
const csp = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob:",
  "font-src 'self'",
  `connect-src 'self'${connectExtra}`,
  "frame-ancestors 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "object-src 'none'",
].join("; ");

const securityHeaders = [
  { key: "Content-Security-Policy", value: csp },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=()" },
  { key: "X-DNS-Prefetch-Control", value: "off" },
];

const nextConfig: NextConfig = {
  // Minimal self-contained server for the multi-stage Docker image (small runner, K8s-ready).
  output: "standalone",
  poweredByHeader: false,
  async headers() {
    return [{ source: "/:path*", headers: securityHeaders }];
  },
};

export default nextConfig;
