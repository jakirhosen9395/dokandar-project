package com.dokandar.review.messaging

import co.elastic.apm.api.ElasticApm
import com.dokandar.review.Config
import com.dokandar.review.data.Db
import com.dokandar.review.observability.Log
import com.dokandar.review.observability.Metrics
import org.apache.kafka.clients.producer.KafkaProducer
import org.apache.kafka.clients.producer.ProducerConfig
import org.apache.kafka.clients.producer.ProducerRecord
import org.apache.kafka.common.serialization.ByteArraySerializer
import org.apache.kafka.common.serialization.StringSerializer
import java.util.Properties
import kotlin.concurrent.thread

// Transactional-outbox relay: poll unsent (FOR UPDATE SKIP LOCKED), publish (acks=all, idempotent),
// mark sent. Publish-before-mark ⇒ at-least-once. Adaptive idle backoff.
object OutboxRelay {
    fun start() {
        if (Config.kafkaBootstrap.isEmpty()) return
        thread(isDaemon = true, name = "outbox-relay") {
            val props = Properties().apply {
                put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, Config.kafkaBootstrap)
                put(ProducerConfig.ACKS_CONFIG, "all"); put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true)
                put(ProducerConfig.CLIENT_ID_CONFIG, "08-review-outbox")
                put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer::class.java.name)
                put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, ByteArraySerializer::class.java.name)
            }
            var producer: KafkaProducer<String, ByteArray>? = null
            while (producer == null) {
                try { producer = KafkaProducer(props); Log.info("review.outbox", "kafka producer connected") }
                catch (e: Exception) { Log.warn("review.outbox", "connect retry: ${e.message}"); Thread.sleep(5000) }
            }
            var idle = 0
            while (true) {
                val n = try { tick(producer) } catch (e: Exception) { Log.warn("review.outbox", "tick error: ${e.message}"); Thread.sleep(2000); continue }
                idle = if (n > 0) 0 else minOf(idle + 1, 5)
                Thread.sleep(1000L * (1 + idle))
            }
        }
    }

    private fun tick(producer: KafkaProducer<String, ByteArray>): Int = Db.tx { c ->
        val rs = c.prepareStatement("SELECT id,topic,key,payload FROM outbox WHERE sent_at IS NULL ORDER BY id LIMIT 100 FOR UPDATE SKIP LOCKED").executeQuery()
        data class Row(val id: Long, val topic: String, val key: String?, val payload: String)
        val rows = ArrayList<Row>(); while (rs.next()) rows.add(Row(rs.getLong("id"), rs.getString("topic"), rs.getString("key"), rs.getString("payload")))
        if (rows.isEmpty()) return@tx 0
        // The relay runs on a daemon thread with no APM transaction, so the kafka producer.send
        // would be an orphan span (dropped). Start + ACTIVATE a transaction so the producer spans
        // attach → Kafka shows in Dependencies + the service map, and the relay logs correlate.
        val tx = ElasticApm.startTransaction().apply { setType("messaging"); setName("OutboxRelay tick") }
        val scope = tx.activate()
        try {
            val sent = ArrayList<Long>()
            for (r in rows) {
                try { producer.send(ProducerRecord(r.topic, r.key, r.payload.toByteArray())).get(); sent.add(r.id) }
                catch (e: Exception) { Log.warn("review.outbox", "produce failed id=${r.id}: ${e.message}"); break }
            }
            if (sent.isNotEmpty()) {
                val arr = c.createArrayOf("bigint", sent.toTypedArray())
                c.prepareStatement("UPDATE outbox SET sent_at=now() WHERE id=ANY(?)").apply { setArray(1, arr) }.executeUpdate()
                Metrics.outboxPublished.labels(Metrics.SVC).inc(sent.size.toDouble())
                Log.info("review.outbox", "published ${sent.size} event(s)")
            }
            return@tx sent.size
        } finally {
            scope.close(); tx.end()
        }
    }
}
