/**
 * Server-only configuration. None of these are prefixed `NEXT_PUBLIC_`, so Next.js never bundles
 * them into client code — the gateway URL and internal service hosts stay on the server (security
 * requirement: internal URLs must never reach the browser). Import only from Route Handlers,
 * middleware, or Server Components.
 */

export const serverEnv = {
  /** API Gateway base — the ONLY backend the BFF talks to. Browser never sees this.
   *  Default = app-server private VPC IP (frontend box is in-VPC; internal routing). */
  GATEWAY_URL: process.env.GATEWAY_URL ?? "http://172.31.14.241:10015",
  /** App host serving per-service ports for build-time spec codegen + the DEVOPS proxy. */
  SPEC_HOST: process.env.SPEC_HOST ?? "172.31.14.241",
  /** JSON map { "<svc>": "host:port" } for the DEVOPS server-side proxy (ops endpoints + docs). */
  SERVICE_HOSTS: process.env.SERVICE_HOSTS ?? "",
  /** Signing secret for the session cookie (Phase 2 wires the OTP login). */
  SESSION_COOKIE_SECRET: process.env.SESSION_COOKIE_SECRET ?? "",
  APP_ENV: process.env.APP_ENV ?? "dev",
} as const;

/** Client-safe config (only NEXT_PUBLIC_* — safe to read in the browser). */
export const publicEnv = {
  RUM_SERVER_URL: process.env.NEXT_PUBLIC_RUM_SERVER_URL ?? "",
  RUM_SERVICE_NAME: process.env.NEXT_PUBLIC_RUM_SERVICE_NAME ?? "dokandar-web",
  ENV: process.env.NEXT_PUBLIC_ENV ?? "dev",
  DEFAULT_LOCALE: process.env.NEXT_PUBLIC_DEFAULT_LOCALE ?? "en",
} as const;
