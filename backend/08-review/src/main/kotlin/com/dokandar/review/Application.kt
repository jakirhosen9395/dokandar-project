package com.dokandar.review

import com.dokandar.review.api.*
import com.dokandar.review.data.Db
import com.dokandar.review.data.DbBootstrap
import com.dokandar.review.data.EsClient
import com.dokandar.review.grpc.GrpcServer
import com.dokandar.review.messaging.OutboxRelay
import com.dokandar.review.messaging.Projectors
import com.dokandar.review.observability.Log
import com.dokandar.review.observability.Metrics
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.*
import io.ktor.server.application.*
import io.ktor.server.application.hooks.*
import io.ktor.server.engine.*
import io.ktor.server.netty.*
import io.ktor.server.plugins.callid.*
import io.ktor.server.plugins.contentnegotiation.*
import io.ktor.server.plugins.statuspages.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.util.*
import co.elastic.apm.api.ElasticApm
import java.util.UUID
import kotlinx.serialization.json.Json as KJson

private val UUID_RE = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
private fun normRoute(path: String): String = if (path.startsWith("/api/")) UUID_RE.replace(path, ":id") else path
private val startKey = AttributeKey<Long>("reqStart")

fun main() {
    if (Config.serviceName.isBlank()) { System.err.println("FATAL: SERVICE_NAME required"); kotlin.system.exitProcess(1) }
    if (Config.appEnv == "stage" || Config.appEnv == "prod") {
        if (Config.jwtPublicKeyB64.isEmpty()) { System.err.println("FATAL: JWT_PUBLIC_KEY_B64 required in ${Config.appEnv}"); kotlin.system.exitProcess(1) }
        if (Config.internalServiceToken.isEmpty()) { System.err.println("FATAL: INTERNAL_SERVICE_TOKEN required in ${Config.appEnv}"); kotlin.system.exitProcess(1) }
    }
    Log.startSinks()
    Log.info("review.boot", "starting ${Config.serviceName} code_version=${Config.codeVersion} rest=${Config.servicePort} grpc=${Config.grpcPort} tenant=${Config.tenant} env=${Config.appEnv}")
    try { DbBootstrap.ensure() } catch (e: Exception) { Log.error("review.boot", "db bootstrap failed: ${e.message}"); kotlin.system.exitProcess(1) }
    Db.init()
    EsClient.ensureIndex()
    GrpcServer.start()
    Projectors.start()
    OutboxRelay.start()
    Log.warn("review.boot", "http server listening on :${Config.servicePort}")
    embeddedServer(Netty, port = Config.servicePort, host = "0.0.0.0") { module() }.start(wait = true)
}

fun Application.module() {
    install(ContentNegotiation) { json(KJson { ignoreUnknownKeys = true; isLenient = true }) }
    install(CallId) {
        header(HttpHeaders.XRequestId)
        generate { UUID.randomUUID().toString().replace("-", "") }
        verify { it.isNotEmpty() }
        replyToHeader(HttpHeaders.XRequestId)
    }
    install(StatusPages) {
        exception<AppException> { call, e -> call.json(HttpStatusCode.fromValue(e.status), errorBody(call, e.code, e.message, e.details)) }
        exception<Throwable> { call, e -> Log.error("review.error", "unhandled: ${e.message}"); call.json(HttpStatusCode.InternalServerError, errorBody(call, "internal_error", "internal error")) }
        status(HttpStatusCode.NotFound) { call, _ -> call.respondBytes(ByteArray(0), status = HttpStatusCode.NotFound) }
    }
    // NOT ignoring /ready: the Docker HEALTHCHECK probes /ready every ~30s; starting a transaction
    // for it keeps the service in the APM inventory even when idle (matches the 11 fleet services
    // that already do this). /metrics + /health + docs stay excluded.
    val ignore = setOf("/metrics", "/health", "/openapi.json", "/docs")
    val telemetry = createApplicationPlugin("Telemetry") {
        onCall { call ->
            call.attributes.put(startKey, System.nanoTime())
            if (call.request.path() !in ignore) {
                val tx = ElasticApm.startTransaction(); tx.setType("request"); call.attributes.put(txKey, tx)
            }
        }
        on(ResponseSent) { call ->
            val start = call.attributes.getOrNull(startKey) ?: return@on
            val path = call.request.path()
            val route = normRoute(path); val status = call.response.status()?.value ?: 0; val method = call.request.httpMethod.value
            call.attributes.getOrNull(txKey)?.let { tx ->
                // Bound APM cardinality: an unmatched 404 path is not a route → name it "<METHOD> unmatched".
                val txRoute = if (status == 404) "unmatched" else route
                tx.setName("$method $txRoute"); tx.setResult("HTTP ${status / 100}xx"); tx.end()
            }
            if (path == "/metrics") return@on
            Metrics.httpRequests.labels(method, route, status.toString()).inc()
            Metrics.httpDuration.labels(method, route).observe((System.nanoTime() - start) / 1e9)
            if (path != "/ready") {
                val conn = call.request.local
                Log.access("${conn.remoteHost}:${conn.remotePort}", method, call.request.uri, status, HttpStatusCode.fromValue(status).description)
            }
        }
    }
    install(telemetry)
    routing { opsRoutes(); docsRoutes(); reviewRoutes() }
}

private fun errorBody(call: ApplicationCall, code: String, message: String, details: Any? = null): Map<String, Any?> {
    val err = linkedMapOf<String, Any?>("code" to code, "message" to message, "request_id" to call.callId)
    if (details != null) err["details"] = details
    return mapOf("error" to err)
}
