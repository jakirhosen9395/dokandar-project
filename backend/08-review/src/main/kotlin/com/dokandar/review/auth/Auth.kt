package com.dokandar.review.auth

import com.auth0.jwt.JWT
import com.auth0.jwt.algorithms.Algorithm
import com.dokandar.review.Config
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.interfaces.RSAPublicKey
import java.security.spec.X509EncodedKeySpec
import java.util.Base64

data class AuthUser(val sub: String, val role: String) {
    val isAdmin get() = role == "admin" || role == "platform_staff"
    val isShopkeeper get() = isAdmin || role == "shopkeeper" || role == "shop_staff"
}

object Auth {
    private val key: RSAPublicKey? by lazy { loadKey() }
    private fun loadKey(): RSAPublicKey? {
        if (Config.jwtPublicKeyB64.isEmpty()) return null
        return try {
            val pem = String(Base64.getDecoder().decode(Config.jwtPublicKeyB64))
                .replace("-----BEGIN PUBLIC KEY-----", "").replace("-----END PUBLIC KEY-----", "")
                .replace(Regex("\\s"), "")
            val der = Base64.getDecoder().decode(pem)
            KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(der)) as RSAPublicKey
        } catch (e: Exception) { System.err.println("JWT key load failed: ${e.message}"); null }
    }

    fun keyConfigured() = Config.jwtPublicKeyB64.isNotEmpty()

    fun verify(authHeader: String?): AuthUser? {
        if (authHeader.isNullOrBlank()) return null
        val tok = if (authHeader.startsWith("Bearer ", ignoreCase = true)) authHeader.substring(7).trim() else authHeader.trim()
        if (tok.isEmpty()) return null
        val k = key ?: return null
        return try {
            val v = JWT.require(Algorithm.RSA256(k, null)).withIssuer(Config.jwtIssuer).build().verify(tok)
            val sub = v.getClaim("sub").asString() ?: return null
            val role = (v.getClaim("role").asString() ?: "").lowercase()
            AuthUser(sub, role)
        } catch (e: Exception) { null }
    }

    // Constant-time; fail-closed on empty (spec + CLAUDE.md — NOT the scaffold's fail-open).
    fun internalOk(presented: String?): Boolean {
        val expected = Config.internalServiceToken
        if (expected.isEmpty() || presented.isNullOrEmpty()) return false
        return MessageDigest.isEqual(presented.toByteArray(Charsets.UTF_8), expected.toByteArray(Charsets.UTF_8))
    }
}
