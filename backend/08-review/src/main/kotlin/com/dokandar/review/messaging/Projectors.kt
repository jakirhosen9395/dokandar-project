package com.dokandar.review.messaging

import com.dokandar.review.Config
import com.dokandar.review.data.Db
import com.dokandar.review.observability.Log
import com.dokandar.review.observability.Metrics
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.*
import org.apache.kafka.clients.consumer.ConsumerConfig
import org.apache.kafka.clients.consumer.KafkaConsumer
import org.apache.kafka.common.serialization.StringDeserializer
import java.time.Duration
import java.util.Properties
import kotlin.concurrent.thread

// Consume order.delivered/refunded → purchase_eligibility. Commit-after-handle; consumers idempotent.
object Projectors {
    fun start() {
        if (Config.kafkaBootstrap.isEmpty()) return
        consumer("delivered", Config.topicOrderDelivered) { onDelivered(it) }
        consumer("refunded", Config.topicOrderRefunded) { onRefunded(it) }
    }

    private fun consumer(name: String, topic: String, handler: (JsonObject) -> Unit) {
        thread(isDaemon = true, name = "projector-$name") {
            val props = Properties().apply {
                put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, Config.kafkaBootstrap)
                put(ConsumerConfig.GROUP_ID_CONFIG, "${Config.kafkaGroupPrefix}-$name")
                put(ConsumerConfig.CLIENT_ID_CONFIG, "08-review-$name")
                put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, false)
                put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest")
                put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer::class.java.name)
                put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer::class.java.name)
            }
            while (true) {
                try {
                    KafkaConsumer<String, String>(props).use { c ->
                        c.subscribe(listOf(topic))
                        Log.info("review.consumer", "consuming $topic (group=${Config.kafkaGroupPrefix}-$name)")
                        while (true) {
                            val records = c.poll(Duration.ofMillis(1000))
                            for (r in records) {
                                try {
                                    handler(Json.parseToJsonElement(r.value() ?: "{}").jsonObject)
                                    c.commitSync(); Metrics.reviewKafka.labels(Metrics.SVC, topic, "ok").inc()
                                } catch (e: SerializationException) {
                                    c.commitSync(); Metrics.reviewKafka.labels(Metrics.SVC, topic, "skip").inc()
                                } catch (e: Exception) {
                                    Log.warn("review.consumer", "$name handler error: ${e.message}")
                                    Metrics.reviewKafka.labels(Metrics.SVC, topic, "error").inc(); Thread.sleep(2000)
                                }
                            }
                        }
                    }
                } catch (e: Exception) { Log.warn("review.consumer", "$name consumer failed: ${e.message}"); Thread.sleep(5000) }
            }
        }
    }

    private fun s(o: JsonObject, vararg keys: String): String? {
        for (k in keys) { val v = o[k]; if (v is JsonPrimitive) return v.contentOrNull }
        return null
    }

    private fun onDelivered(ev: JsonObject) {
        val userId = s(ev, "user_id", "customer_id") ?: return
        val orderId = s(ev, "order_id", "id") ?: return
        val items = ArrayList<Pair<String?, String>>()
        val subOrders = ev["sub_orders"] as? JsonArray
        if (subOrders != null) {
            for (so in subOrders) {
                val soo = so.jsonObject; val sid = s(soo, "shop_id")
                (soo["items"] as? JsonArray)?.forEach { s(it.jsonObject, "product_id")?.let { pid -> items.add(sid to pid) } }
            }
        } else {
            val sid = s(ev, "shop_id")
            (ev["items"] as? JsonArray)?.forEach { s(it.jsonObject, "product_id")?.let { pid -> items.add(sid to pid) } }
        }
        if (items.isEmpty()) return
        Db.tx { c ->
            for ((sid, pid) in items) {
                c.prepareStatement("INSERT INTO purchase_eligibility (user_id,order_id,product_id,shop_id,eligible) VALUES (?::uuid,?::uuid,?::uuid,?::uuid,true) ON CONFLICT (user_id,order_id,product_id) DO UPDATE SET eligible=true")
                    .apply { setString(1, userId); setString(2, orderId); setString(3, pid); setString(4, sid) }.executeUpdate()
            }
        }
        Log.info("review.consumer", "eligibility granted user=$userId order=$orderId items=${items.size}")
    }

    private fun onRefunded(ev: JsonObject) {
        val userId = s(ev, "user_id", "customer_id") ?: return
        val orderId = s(ev, "order_id", "id") ?: return
        Db.conn { c -> c.prepareStatement("UPDATE purchase_eligibility SET eligible=false WHERE user_id=?::uuid AND order_id=?::uuid").apply { setString(1, userId); setString(2, orderId) }.executeUpdate() }
        Log.info("review.consumer", "eligibility clawed back user=$userId order=$orderId")
    }
}
