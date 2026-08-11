package com.dokandar.review.api

import com.dokandar.review.AppException
import com.dokandar.review.auth.Auth
import com.dokandar.review.auth.AuthUser
import com.dokandar.review.observability.Json
import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.response.*
import io.ktor.util.*
import co.elastic.apm.api.Transaction
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

suspend fun ApplicationCall.json(status: HttpStatusCode, body: Any?) =
    respondText(Json.encode(body, pretty = true) + "\n", ContentType.Application.Json, status)

val txKey = AttributeKey<Transaction>("apmTx")
// Run blocking work on Dispatchers.IO with the request's APM transaction ACTIVE on that thread, so the
// agent's JDBC spans nest under it (Service Map) and the MDC trace.id reaches the logger.
suspend fun <T> ApplicationCall.io(block: () -> T): T = withContext(Dispatchers.IO) {
    val scope = attributes.getOrNull(txKey)?.activate()
    try { block() } finally { scope?.close() }
}

fun ApplicationCall.requireUser(): AuthUser {
    if (!Auth.keyConfigured()) throw AppException(503, "server_misconfigured", "JWT_PUBLIC_KEY_B64 not configured")
    val h = request.headers["Authorization"]
    if (h.isNullOrBlank() || !h.startsWith("Bearer ", ignoreCase = true)) throw AppException(401, "missing_token", "Bearer token required")
    return Auth.verify(h) ?: throw AppException(401, "invalid_token", "invalid or expired token")
}
fun ApplicationCall.requireShopkeeper(): AuthUser { val u = requireUser(); if (!u.isShopkeeper) throw AppException(403, "insufficient_role", "shopkeeper or admin required"); return u }
fun ApplicationCall.requireAdmin(): AuthUser { val u = requireUser(); if (!u.isAdmin) throw AppException(403, "insufficient_role", "admin or platform_staff required"); return u }
