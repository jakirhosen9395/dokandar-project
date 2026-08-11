//! Verify-only RS256 JWT (auth's PUBLIC key) for the REST surface, plus the constant-time
//! x-internal-token check for the gRPC surface. 12-media NEVER mints keys — it pins
//! algorithms:[RS256] (rejects alg:none / HS256), checks iss + exp, and reads sub/role.
use crate::config::Config;
use actix_web::{dev::Payload, FromRequest, HttpRequest, HttpResponse};
use base64::Engine;
use jsonwebtoken::{decode, Algorithm, DecodingKey, Validation};
use serde::Deserialize;
use std::future::{ready, Ready};
use subtle::ConstantTimeEq;

#[derive(Debug, Clone, Deserialize)]
pub struct Claims {
    pub sub: Option<String>,
    pub role: Option<String>,
    pub roles: Option<Vec<String>>,
    #[allow(dead_code)]
    pub exp: Option<i64>,
}

impl Claims {
    pub fn subject(&self) -> &str {
        self.sub.as_deref().unwrap_or("")
    }
    pub fn is_admin(&self) -> bool {
        self.role.as_deref() == Some("admin")
            || self.roles.as_ref().map(|r| r.iter().any(|x| x == "admin")).unwrap_or(false)
    }
    pub fn role_str(&self) -> String {
        self.role.clone().unwrap_or_else(|| {
            self.roles.as_ref().and_then(|r| r.first().cloned()).unwrap_or_default()
        })
    }
}

pub enum AuthErr {
    Missing,
    Invalid,
}

/// Verify a raw `Authorization` header value (with or without the `Bearer ` prefix).
pub fn verify(cfg: &Config, bearer: Option<&str>) -> Result<Claims, AuthErr> {
    let raw = bearer.ok_or(AuthErr::Missing)?;
    let tok = raw
        .strip_prefix("Bearer ")
        .or_else(|| raw.strip_prefix("bearer "))
        .unwrap_or(raw)
        .trim();
    if tok.is_empty() {
        return Err(AuthErr::Missing);
    }
    if cfg.jwt_public_key_b64.is_empty() {
        return Err(AuthErr::Invalid);
    }
    let pem = base64::engine::general_purpose::STANDARD
        .decode(cfg.jwt_public_key_b64.trim())
        .map_err(|_| AuthErr::Invalid)?;
    let key = DecodingKey::from_rsa_pem(&pem).map_err(|_| AuthErr::Invalid)?;
    let mut val = Validation::new(Algorithm::RS256);
    val.validate_aud = false;
    if !cfg.jwt_issuer.is_empty() {
        val.set_issuer(&[cfg.jwt_issuer.clone()]);
    }
    let data = decode::<Claims>(tok, &key, &val).map_err(|_| AuthErr::Invalid)?;
    Ok(data.claims)
}

/// Constant-time x-internal-token compare (gRPC east-west). Fail-closed on empty config.
pub fn internal_token_ok(presented: &str, cfg: &Config) -> bool {
    if cfg.internal_service_token.is_empty() {
        return false; // fail-closed: never accept when not configured
    }
    cfg.internal_service_token.as_bytes().ct_eq(presented.as_bytes()).into()
}

/// Actix extractor — pulls + verifies the Bearer JWT, else 401 with the error envelope.
pub struct AuthUser {
    pub claims: Claims,
}

impl AuthUser {
    pub fn id(&self) -> &str {
        self.claims.subject()
    }
}

impl FromRequest for AuthUser {
    type Error = actix_web::Error;
    type Future = Ready<Result<Self, Self::Error>>;

    fn from_request(req: &HttpRequest, _pl: &mut Payload) -> Self::Future {
        let cfg = match req.app_data::<actix_web::web::Data<crate::http::AppState>>() {
            Some(st) => &st.cfg,
            None => {
                return ready(Err(actix_web::error::InternalError::from_response(
                    "no_state",
                    HttpResponse::InternalServerError().finish(),
                )
                .into()))
            }
        };
        let rid = crate::http::ops::req_id(req);
        let hdr = req
            .headers()
            .get("authorization")
            .and_then(|v| v.to_str().ok());
        match verify(cfg, hdr) {
            Ok(claims) => ready(Ok(AuthUser { claims })),
            Err(AuthErr::Missing) => ready(Err(actix_web::error::InternalError::from_response(
                "missing_token",
                crate::http::ops::err(401, "missing_token", "authorization bearer token required", &rid),
            )
            .into())),
            Err(AuthErr::Invalid) => ready(Err(actix_web::error::InternalError::from_response(
                "invalid_token",
                crate::http::ops::err(401, "invalid_token", "token verification failed", &rid),
            )
            .into())),
        }
    }
}
