package com.dokandar.review

import java.io.File

object Config {
    private fun e(k: String, d: String = "") = System.getenv(k) ?: d
    private fun i(k: String, d: Int) = System.getenv(k)?.toIntOrNull() ?: d

    val appEnv = e("APP_ENV", "dev")
    val serviceName = e("SERVICE_NAME", "08-review")
    val envVersion = e("ENV_VERSION", "v1.0.0")
    val tenant = e("TENANT", "local")
    val servicePort = i("SERVICE_PORT", 8080)
    val grpcPort = i("GRPC_PORT", 50051)
    val codeVersion = readCode()

    // PostgreSQL (sole writer)
    val pgHost = e("POSTGRES_HOST"); val pgPort = i("POSTGRES_PORT", 5432)
    val pgUser = e("POSTGRES_USER", "postgres"); val pgPassword = e("POSTGRES_PASSWORD")
    val pgDb = e("POSTGRES_DB", "dokandar_review_dev")
    fun pgUrl(db: String = pgDb) = "jdbc:postgresql://$pgHost:$pgPort/$db"

    // Kafka
    val kafkaBootstrap = e("KAFKA_BOOTSTRAP")
    val kafkaGroupPrefix = e("KAFKA_GROUP_PREFIX", "review")
    val topicOrderDelivered = e("KAFKA_TOPIC_ORDER_DELIVERED", "dokandar.order.delivered")
    val topicOrderRefunded = e("KAFKA_TOPIC_ORDER_REFUNDED", "dokandar.order.refunded")
    val topicReviewPosted = "dokandar.review.posted"
    val topicReviewUpdated = "dokandar.review.updated"
    val topicReviewDeleted = "dokandar.review.deleted"
    val topicReviewReply = "dokandar.review.reply.posted"
    val topicRatingChanged = "dokandar.rating.aggregate.changed"

    // BUSINESS-search ES (:9201, block 03) — the dokandar-reviews index
    val searchEsUrl = e("SEARCH_ES_URL"); val searchEsUser = e("SEARCH_ES_USERNAME")
    val searchEsPassword = e("SEARCH_ES_PASSWORD"); val esIndexReviews = e("ES_INDEX_REVIEWS", "dokandar-reviews")

    // LOG-sink ES (:9200, block 07)
    val esUrl = e("ELASTIC_SEARCH_URL"); val esUser = e("ELASTIC_SEARCH_USERNAME"); val esPassword = e("ELASTIC_SEARCH_PASSWORD")
    // Mongo log sink
    val mongoLogUri = e("MONGO_LOG_URI"); val mongoLogDb = e("MONGO_LOG_DB", "mongo_db_dokandar_application_logs")
    // APM
    val apmServerUrl = e("APM_SERVER_URL"); val apmServiceName = e("APM_SERVICE_NAME", "08-review")
    // identity (verify-only)
    val jwtPublicKeyB64 = e("JWT_PUBLIC_KEY_B64"); val jwtIssuer = e("JWT_ISSUER", "dokandar-auth")
    val internalServiceToken = e("INTERNAL_SERVICE_TOKEN")
    // review rules
    val editWindowDays = i("REVIEW_EDIT_WINDOW_DAYS", 7)
    val reportThreshold = i("REVIEW_REPORT_THRESHOLD", 5)
    val enforceVerifiedPurchase = e("REVIEW_ENFORCE_VERIFIED_PURCHASE", "false").lowercase() == "true"

    private fun readCode(): String {
        for (p in listOf("CODE_VERSION", "/app/CODE_VERSION")) {
            try { return File(p).readText().trim() } catch (_: Exception) {}
        }
        return "0-unknown"
    }
}
