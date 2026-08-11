//! Verify-only RS256 JWT (auth's PUBLIC key) — gates POST /admin/reindex.
use crate::config::Config;
use base64::Engine;
use jsonwebtoken::{decode, Algorithm, DecodingKey, Validation};
use serde::Deserialize;

#[derive(Deserialize)]
pub struct Claims {
    pub sub: Option<String>,
    pub role: Option<String>,
    pub roles: Option<Vec<String>>,
}

pub enum AuthErr { Missing, Invalid }

pub fn verify(cfg: &Config, bearer: Option<&str>) -> Result<Claims, AuthErr> {
    let raw = bearer.ok_or(AuthErr::Missing)?;
    let tok = raw.strip_prefix("Bearer ").or_else(|| raw.strip_prefix("bearer ")).unwrap_or(raw).trim();
    if tok.is_empty() { return Err(AuthErr::Missing); }
    if cfg.jwt_public_key_b64.is_empty() { return Err(AuthErr::Invalid); }
    let pem = base64::engine::general_purpose::STANDARD
        .decode(cfg.jwt_public_key_b64.trim()).map_err(|_| AuthErr::Invalid)?;
    let key = DecodingKey::from_rsa_pem(&pem).map_err(|_| AuthErr::Invalid)?;
    let mut val = Validation::new(Algorithm::RS256);
    val.validate_aud = false;
    if !cfg.jwt_issuer.is_empty() { val.set_issuer(&[cfg.jwt_issuer.clone()]); }
    let data = decode::<Claims>(tok, &key, &val).map_err(|_| AuthErr::Invalid)?;
    Ok(data.claims)
}

pub fn is_admin(c: &Claims) -> bool {
    c.role.as_deref() == Some("admin")
        || c.roles.as_ref().map(|r| r.iter().any(|x| x == "admin")).unwrap_or(false)
}
