package com.dokandar.review.api

import com.dokandar.review.Config
import com.dokandar.review.data.Db
import com.dokandar.review.observability.Log
import com.dokandar.review.observability.Metrics
import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import kotlinx.serialization.json.*
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI

object Ops {
    private val boot = System.currentTimeMillis()
    fun identity(): Map<String, Any?> = linkedMapOf(
        "service_name" to Config.serviceName, "code_version" to Config.codeVersion, "env_version" to Config.envVersion,
        "tenant" to Config.tenant, "env" to Config.appEnv, "uptime_seconds" to ((System.currentTimeMillis() - boot) / 1000).toInt())
}

private fun checkPg(): Triple<Boolean, Double, String> {
    val t0 = System.nanoTime()
    return try { Db.ping(); Triple(true, (System.nanoTime() - t0) / 1e6, "ok") }
    catch (e: Exception) { Triple(false, (System.nanoTime() - t0) / 1e6, "err:${e.javaClass.simpleName}") }
}
private fun checkTcp(hostPort: String, defPort: Int): Pair<Boolean, String> = try {
    val parts = hostPort.split(":"); Socket().use { it.connect(InetSocketAddress(parts[0], parts.getOrNull(1)?.toIntOrNull() ?: defPort), 2000) }; true to "metadata-ok"
} catch (e: Exception) { false to "err:${e.javaClass.simpleName}" }
private fun checkUrl(url: String): Pair<Boolean, String> = try {
    val u = URI.create(url); Socket().use { it.connect(InetSocketAddress(u.host, if (u.port > 0) u.port else 80), 2000) }; true to "tcp-ok"
} catch (e: Exception) { false to "err:${e.javaClass.simpleName}" }
private fun jsonToAny(e: JsonElement): Any? = when (e) {
    is JsonNull -> null
    is JsonPrimitive -> if (e.isString) e.content else e.booleanOrNull ?: e.longOrNull ?: e.doubleOrNull ?: e.content
    is JsonArray -> e.map { jsonToAny(it) }
    is JsonObject -> e.mapValues { jsonToAny(it.value) }
}

fun Route.opsRoutes() {
    get("/ready") {
        val pg = call.io { checkPg() }
        call.json(if (pg.first) HttpStatusCode.OK else HttpStatusCode.ServiceUnavailable, linkedMapOf(
            "status" to if (pg.first) "ready" else "not_ready", "identity" to Ops.identity(),
            "dependencies" to listOf(linkedMapOf("name" to "postgres", "reachable" to pg.first, "latency_ms" to pg.second, "detail" to pg.third))))
    }
    get("/health") {
        val pg = call.io { checkPg() }
        val kafka = call.io { checkTcp(Config.kafkaBootstrap, 9092) }
        val es = if (Config.searchEsUrl.isEmpty()) false to "es-url-empty" else call.io { checkUrl(Config.searchEsUrl) }
        val mongo = Log.mongoHealthy; val apm = Config.apmServerUrl.isNotEmpty()
        val healthy = pg.first // postgres-only gating (CLAUDE.md: never gate on kafka/es/mongo/apm)
        call.json(if (healthy) HttpStatusCode.OK else HttpStatusCode.ServiceUnavailable, linkedMapOf(
            "status" to if (healthy) "healthy" else "unhealthy", "identity" to Ops.identity(),
            "checks" to linkedMapOf(
                "postgres" to mapOf("ok" to pg.first, "latency_ms" to pg.second, "detail" to pg.third),
                "kafka" to mapOf("ok" to kafka.first, "detail" to kafka.second),
                "elasticsearch" to mapOf("ok" to es.first, "detail" to es.second),
                "mongo_logs" to mapOf("ok" to mongo, "detail" to if (mongo) "ping-ok" else "unreachable"),
                "apm" to mapOf("ok" to apm, "detail" to if (apm) "configured" else "disabled")),
            "observability" to linkedMapOf("apm_service_name" to Config.apmServiceName,
                "logs_sink_mongo" to if (Config.mongoLogUri.isEmpty()) null else "${Config.mongoLogDb}.${Config.serviceName}",
                "logs_sink_es" to if (Config.esUrl.isEmpty()) null else "${Config.esUrl}/logs-app-${Config.serviceName}-*")))
    }
    get("/data") {
        for (p in listOf("data/${Config.tenant}/result.json", "/app/data/${Config.tenant}/result.json")) {
            val f = File(p); if (!f.exists()) continue
            val parsed = try { Json.parseToJsonElement(f.readText()) }
            catch (e: Exception) { call.json(HttpStatusCode.InternalServerError, mapOf("error" to mapOf("code" to "snapshot_parse_failed", "message" to "invalid JSON"))); return@get }
            if (parsed !is JsonObject) { call.json(HttpStatusCode.InternalServerError, mapOf("error" to mapOf("code" to "snapshot_not_object", "message" to "snapshot root must be an object"))); return@get }
            val merged = LinkedHashMap<String, Any?>(); merged.putAll(Ops.identity()); parsed.forEach { (k, v) -> merged[k] = jsonToAny(v) }
            call.json(HttpStatusCode.OK, merged); return@get
        }
        call.json(HttpStatusCode.NotFound, mapOf("error" to mapOf("code" to "no_snapshot", "message" to "data/${Config.tenant}/result.json not present")))
    }
    get("/metrics") {
        try { Metrics.outboxPending.labels(Metrics.SVC).set(call.io { Db.conn { c -> c.prepareStatement("SELECT count(*) FROM outbox WHERE sent_at IS NULL").executeQuery().let { it.next(); it.getInt(1).toDouble() } } }) } catch (_: Exception) {}
        call.respondText(Metrics.render(), ContentType.parse("text/plain; version=0.0.4; charset=utf-8"))
    }
}
