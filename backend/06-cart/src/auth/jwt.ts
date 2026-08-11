import * as jwt from 'jsonwebtoken';
import { config } from '../config';
let pub: string | null | undefined;
function key(): string | null {
  if (pub !== undefined) return pub || null;
  if (!config.jwtPublicKeyB64) { pub = ''; return null; }
  try { pub = Buffer.from(config.jwtPublicKeyB64, 'base64').toString('utf8'); return pub; } catch { pub = ''; return null; }
}
export function verifyToken(authHeader?: string): any | null {
  if (!authHeader) return null;
  const tok = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!tok) return null;
  const k = key(); if (!k) return null;
  try { return jwt.verify(tok, k, { algorithms: ['RS256'], issuer: config.jwtIssuer }); } catch { return null; }
}
