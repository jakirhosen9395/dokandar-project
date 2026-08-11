// JWT authentication + authorization. Signature verification is delegated to an injectable
// Verifier (the platform JWKS integration point).
export interface Claims { sub?: string; kyc_tier?: string; roles?: string[]; cid?: string; }

export interface Verifier { verify(token: string): boolean; }
export class NoopVerifier implements Verifier { verify(): boolean { return true; } }

export class Jwt {
  constructor(public readonly issuer: string, private readonly verifier: Verifier = new NoopVerifier()) {}

  parse(authorization: string | undefined): Claims | null {
    if (!authorization || !authorization.startsWith("Bearer ")) return null;
    const token = authorization.slice("Bearer ".length);
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    if (!this.verifier.verify(token)) return null;
    try {
      const payload = Buffer.from(parts[1], "base64url").toString("utf8");
      return JSON.parse(payload) as Claims;
    } catch { return null; }
  }
}

export function hasRole(c: Claims | null, role: string): boolean {
  return !!c && Array.isArray(c.roles) && c.roles.includes(role);
}
