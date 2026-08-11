// Verify-only RS256 (auth's PUBLIC key) + the east-west INTERNAL_SERVICE_TOKEN.
// Ported from 06-cart/src/auth/jwt.ts: algorithms are PINNED to ['RS256'] so
// alg:none and HS256-with-the-public-key forgeries are rejected; the issuer is
// checked. 14-notification mints no keys and exposes no gRPC — it only verifies.
import * as crypto from 'crypto';
import * as jwt from 'jsonwebtoken';
import { config } from '../config';

let pub: string | null | undefined;
function key(): string | null {
  if (pub !== undefined) return pub || null;
  if (!config.jwtPublicKeyB64) { pub = ''; return null; }
  try { pub = Buffer.from(config.jwtPublicKeyB64, 'base64').toString('utf8'); return pub; } catch { pub = ''; return null; }
}

// verifyToken('Bearer <jwt>') -> decoded claims | null. Null on: no header, empty
// token, no/invalid public key, bad signature, wrong alg, wrong issuer, or expiry.
export function verifyToken(authHeader?: string): any | null {
  if (!authHeader) return null;
  const tok = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!tok) return null;
  const k = key();
  if (!k) return null;
  try { return jwt.verify(tok, k, { algorithms: ['RS256'], issuer: config.jwtIssuer }); } catch { return null; }
}

// Owner scope helper — the opaque user id is the JWT subject.
export function getUserId(claims: any): string | null {
  return claims && typeof claims.sub === 'string' && claims.sub ? claims.sub : null;
}

// Constant-time compare of the x-internal-token header against INTERNAL_SERVICE_TOKEN.
// FAIL-CLOSED: empty expected token or empty/missing supplied header -> false.
// timingSafeEqual throws on unequal-length buffers, so we length-guard first (an
// early length-mismatch return is acceptable; the secret's length is not sensitive).
export function verifyInternalToken(headerVal?: string): boolean {
  const expected = config.internalServiceToken;
  if (!expected || !headerVal) return false;
  const a = Buffer.from(headerVal);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  try { return crypto.timingSafeEqual(a, b); } catch { return false; }
}
