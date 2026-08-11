package com.dokandar.review.data

import com.dokandar.review.Config
import com.dokandar.review.observability.Json
import com.dokandar.review.observability.Log
import kotlinx.serialization.json.*
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.util.Base64
import kotlin.concurrent.thread

// Business review search on the standalone ES :9201 (block 03), index dokandar-reviews.
// Best-effort + non-gating: index off the request path; search degrades (empty) if ES is down.
object EsClient {
    private val http: HttpClient = HttpClient.newHttpClient()
    private val auth = if (Config.searchEsUser.isNotEmpty())
        "Basic " + Base64.getEncoder().encodeToString("${Config.searchEsUser}:${Config.searchEsPassword}".toByteArray()) else null
    private fun enabled() = Config.searchEsUrl.isNotEmpty()
    private fun base() = Config.searchEsUrl.trimEnd('/')

    fun indexAsync(id: String, doc: Map<String, Any?>) {
        if (!enabled()) return
        thread(isDaemon = true) {
            try {
                val b = HttpRequest.newBuilder(URI.create("${base()}/${Config.esIndexReviews}/_doc/$id")).header("content-type", "application/json")
                if (auth != null) b.header("Authorization", auth)
                http.send(b.PUT(HttpRequest.BodyPublishers.ofString(Json.encode(doc))).build(), HttpResponse.BodyHandlers.ofString())
            } catch (e: Exception) { Log.warn("review.es", "index failed (non-gating): ${e.message}") }
        }
    }
    fun deleteAsync(id: String) {
        if (!enabled()) return
        thread(isDaemon = true) {
            try {
                val b = HttpRequest.newBuilder(URI.create("${base()}/${Config.esIndexReviews}/_doc/$id"))
                if (auth != null) b.header("Authorization", auth)
                http.send(b.DELETE().build(), HttpResponse.BodyHandlers.ofString())
            } catch (_: Exception) {}
        }
    }
    fun search(q: String): List<Map<String, Any?>> {
        if (!enabled()) return emptyList()
        return try {
            val body = """{"query":{"multi_match":{"query":${Json.encode(q)},"fields":["title","body"]}},"size":20}"""
            val b = HttpRequest.newBuilder(URI.create("${base()}/${Config.esIndexReviews}/_search")).header("content-type", "application/json")
            if (auth != null) b.header("Authorization", auth)
            val resp = http.send(b.POST(HttpRequest.BodyPublishers.ofString(body)).build(), HttpResponse.BodyHandlers.ofString())
            if (resp.statusCode() >= 300) return emptyList()
            val hits = kotlinx.serialization.json.Json.parseToJsonElement(resp.body()).jsonObject["hits"]?.jsonObject?.get("hits")?.jsonArray ?: return emptyList()
            hits.mapNotNull { it.jsonObject["_source"]?.jsonObject?.let { src -> src.mapValues { (_, v) -> jsonToAny(v) } } }
        } catch (e: Exception) { Log.warn("review.es", "search failed (degraded): ${e.message}"); emptyList() }
    }
    private fun jsonToAny(e: JsonElement): Any? = when (e) {
        is JsonNull -> null
        is JsonPrimitive -> if (e.isString) e.content else e.booleanOrNull ?: e.longOrNull ?: e.doubleOrNull ?: e.content
        is JsonArray -> e.map { jsonToAny(it) }
        is JsonObject -> e.mapValues { jsonToAny(it.value) }
    }
    fun ensureIndex() {
        if (!enabled()) return
        try {
            val b = HttpRequest.newBuilder(URI.create("${base()}/${Config.esIndexReviews}"))
            if (auth != null) b.header("Authorization", auth)
            val head = http.send(b.method("HEAD", HttpRequest.BodyPublishers.noBody()).build(), HttpResponse.BodyHandlers.discarding())
            if (head.statusCode() == 404) {
                val mapping = """{"mappings":{"properties":{"title":{"type":"text"},"body":{"type":"text"},"rating":{"type":"integer"},"product_id":{"type":"keyword"},"shop_id":{"type":"keyword"},"status":{"type":"keyword"},"created_at":{"type":"date"}}}}"""
                val c = HttpRequest.newBuilder(URI.create("${base()}/${Config.esIndexReviews}")).header("content-type", "application/json")
                if (auth != null) c.header("Authorization", auth)
                http.send(c.PUT(HttpRequest.BodyPublishers.ofString(mapping)).build(), HttpResponse.BodyHandlers.ofString())
                Log.info("review.es", "created index ${Config.esIndexReviews}")
            }
        } catch (e: Exception) { Log.warn("review.es", "ensureIndex failed (non-gating): ${e.message}") }
    }
}
