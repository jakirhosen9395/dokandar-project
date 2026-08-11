/**
 * Role model + session helpers. The real OTP login + signed session cookie are wired in Phase 2.
 * Foundation: the typed role set (verified from 01-auth `app/db/models.py:11-14`) and gate helpers.
 */

export type Role = "customer" | "shopkeeper" | "shop_staff" | "platform_staff" | "admin";

export const ROLES: readonly Role[] = ["customer", "shopkeeper", "shop_staff", "platform_staff", "admin"] as const;

/** Access-token JWT claims (verified from 01-auth `app/domain/tokens.py:49-66`). */
export interface JwtClaims {
  sub: string;
  role: Role;
  phone?: string;
  lang?: "bn" | "en";
  kyc?: string;
  iss?: string;
  iat?: number;
  exp?: number;
  jti?: string;
}

export const ROLE_GATES = {
  "/devops": ["admin", "platform_staff"],
  "/admin": ["admin", "platform_staff"],
  "/seller": ["shopkeeper", "shop_staff"],
  "/account": ["customer", "shopkeeper", "shop_staff", "platform_staff", "admin"],
} satisfies Record<string, Role[]>;

export function hasRole(role: Role | null | undefined, allowed: readonly Role[]): boolean {
  return !!role && allowed.includes(role);
}

/** User object returned by /login/verify, /signup/verify, /refresh, /me (verified live). */
export interface User {
  id: string;
  phone: string;
  name: string;
  email?: string | null;
  role: Role;
  status?: string;
  kyc?: string;
  lang?: "bn" | "en";
}

/** Backend token bundle (verified live). The refresh_token never leaves the BFF. */
export interface TokenBundle {
  access_token: string;
  refresh_token: string;
  token_type: "Bearer";
  expires_in: number;
  user: User;
}

/** What BFF auth routes return to the browser — NO refresh token. */
export interface ClientSession {
  access_token: string;
  expires_in: number;
  user: User;
}
