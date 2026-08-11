package com.dokandar.review.observability

import com.dokandar.review.Config
import com.mongodb.client.MongoClient
import com.mongodb.client.MongoClients
import com.mongodb.client.MongoCollection
import org.bson.Document
import co.elastic.apm.api.ElasticApm
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Base64
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.concurrent.thread

// Three-sink structured logging mirroring 01-auth/04-catalog: stdout JSON w/ elasticapm_* fields,
// MongoDB forensic collection <service>, Elasticsearch data stream logs-app-08-review-* (:9200).
// Trace ids read from SLF4J MDC — the Elastic APM -javaagent injects trace.id/transaction.id/span.id.
object Log {
    private val mongoQ = ConcurrentLinkedQueue<Document>()
    private val esQ = ConcurrentLinkedQueue<Map<String, Any?>>()
    @Volatile private var mongoColl: MongoCollection<Document>? = null
    @Volatile private var mongoUp = false
    private val http: HttpClient = HttpClient.newHttpClient()
    private val ts = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss,SSS")
    private val access = DateTimeFormatter.ofPattern("dd-MM-yyyy HH:mm:ss")

    val mongoHealthy: Boolean get() = mongoUp

    private fun apmFields(): Map<String, Any?> {
        var trace: String? = null; var tx: String? = null; var span: String? = null
        try {
            val s = ElasticApm.currentSpan(); trace = s.traceId.ifEmpty { null }; span = s.id.ifEmpty { null }
            tx = ElasticApm.currentTransaction().id.ifEmpty { null }
        } catch (_: Throwable) {}
        val m = linkedMapOf<String, Any?>(
            "elasticapm_service_name" to Config.apmServiceName,
            "elasticapm_service_environment" to Config.appEnv,
        )
        if (trace != null) m["elasticapm_trace_id"] = trace
        if (tx != null) m["elasticapm_transaction_id"] = tx
        m["elasticapm_labels"] = linkedMapOf(
            "transaction.id" to tx, "trace.id" to trace, "span.id" to span,
            "service.name" to Config.apmServiceName, "service.environment" to Config.appEnv,
        )
        return m
    }

    fun info(name: String, msg: String) = emit("INFO", name, msg)
    fun warn(name: String, msg: String) = emit("WARNING", name, msg)
    fun error(name: String, msg: String) = emit("ERROR", name, msg)

    private fun emit(level: String, name: String, msg: String) {
        val now = ZonedDateTime.now()
        val af = apmFields()
        val stdout = linkedMapOf<String, Any?>("asctime" to now.format(ts), "name" to name, "levelname" to level, "message" to msg)
        stdout.putAll(af)
        println(Json.encode(stdout))
        val trace = af["elasticapm_trace_id"]
        val doc = linkedMapOf<String, Any?>(
            "@timestamp" to now.withZoneSameInstant(java.time.ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")),
            "log" to mapOf("level" to level.lowercase(), "logger" to name),
            "message" to msg,
            "service" to mapOf("name" to Config.serviceName, "version" to Config.codeVersion, "environment" to Config.appEnv),
            "labels" to mapOf("tenant" to Config.tenant, "env_version" to Config.envVersion),
        )
        doc.putAll(af)
        if (trace != null) { doc["trace"] = mapOf("id" to trace); doc["transaction"] = mapOf("id" to af["elasticapm_transaction_id"]) }
        if (Config.mongoLogUri.isNotEmpty() && mongoQ.size < 5000) mongoQ.add(Document(doc))
        if (Config.esUrl.isNotEmpty() && esQ.size < 5000) esQ.add(doc)
    }

    fun access(ip: String, method: String, path: String, status: Int, reason: String) =
        println("${ZonedDateTime.now().format(access)}    $ip - \"$method $path HTTP/1.1\" $status $reason")

    fun startSinks() {
        if (Config.mongoLogUri.isNotEmpty()) {
            try {
                val c: MongoClient = MongoClients.create(Config.mongoLogUri)
                mongoColl = c.getDatabase(Config.mongoLogDb).getCollection(Config.serviceName); mongoUp = true
            } catch (e: Exception) { System.err.println("mongo log sink connect failed: ${e.message}") }
            thread(isDaemon = true, name = "mongo-log-sink") {
                while (true) {
                    Thread.sleep(2000)
                    val coll = mongoColl ?: continue
                    val batch = ArrayList<Document>(); while (batch.size < 500) { val d = mongoQ.poll() ?: break; batch.add(d) }
                    if (batch.isEmpty()) continue
                    try { coll.insertMany(batch); mongoUp = true } catch (e: Exception) { mongoUp = false }
                }
            }
        }
        if (Config.esUrl.isNotEmpty()) {
            val ds = "logs-app-${Config.serviceName}-default"
            val url = "${Config.esUrl.trimEnd('/')}/$ds/_bulk"
            val auth = if (Config.esUser.isNotEmpty()) "Basic " + Base64.getEncoder().encodeToString("${Config.esUser}:${Config.esPassword}".toByteArray()) else null
            thread(isDaemon = true, name = "es-log-sink") {
                while (true) {
                    Thread.sleep(2000)
                    val batch = ArrayList<Map<String, Any?>>(); while (batch.size < 500) { val d = esQ.poll() ?: break; batch.add(d) }
                    if (batch.isEmpty()) continue
                    val sb = StringBuilder()
                    for (d in batch) { sb.append("{\"create\":{}}\n"); sb.append(Json.encode(d)); sb.append("\n") }
                    try {
                        val b = HttpRequest.newBuilder(URI.create(url)).header("content-type", "application/x-ndjson")
                        if (auth != null) b.header("Authorization", auth)
                        http.send(b.POST(HttpRequest.BodyPublishers.ofString(sb.toString())).build(), HttpResponse.BodyHandlers.ofString())
                    } catch (_: Exception) {}
                }
            }
        }
    }
}
