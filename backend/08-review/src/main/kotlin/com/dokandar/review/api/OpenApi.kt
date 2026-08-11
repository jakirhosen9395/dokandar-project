package com.dokandar.review.api

import com.dokandar.review.Config
import com.dokandar.review.observability.Json
import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.response.*
import io.ktor.server.routing.*

object OpenApi {
    private fun ref(s: String) = mapOf("\$ref" to "#/components/schemas/$s")
    private fun strProp(ex: String? = null, nullable: Boolean = false, desc: String? = null, format: String? = null, enum: List<String>? = null) =
        linkedMapOf<String, Any?>("type" to "string").apply {
            if (format != null) put("format", format)
            if (enum != null) put("enum", enum)
            if (desc != null) put("description", desc)
            if (ex != null) put("example", ex)
            if (nullable) put("nullable", true)
        }
    private fun intProp(min: Int? = null, max: Int? = null, ex: Int? = null, desc: String? = null, default: Int? = null) =
        linkedMapOf<String, Any?>("type" to "integer").apply {
            if (min != null) put("minimum", min)
            if (max != null) put("maximum", max)
            if (default != null) put("default", default)
            if (desc != null) put("description", desc)
            if (ex != null) put("example", ex)
        }

    private fun obj(props: Map<String, Any?>, required: List<String> = emptyList()) =
        linkedMapOf<String, Any?>("type" to "object", "properties" to props).apply { if (required.isNotEmpty()) put("required", required) }

    private val bearer = listOf(mapOf("HTTPBearer" to emptyList<String>()))
    private val internal = listOf(mapOf("InternalToken" to emptyList<String>()))

    // ---- builders ----------------------------------------------------------
    private fun op(
        operationId: String,
        tag: String,
        summary: String,
        description: String? = null,
        bearer: Boolean = false,
        security: List<Any>? = null,
        parameters: List<Map<String, Any?>>? = null,
        body: String? = null,
        bodyExample: Map<String, Any?>? = null,
        resp: Map<String, Any?>,
    ): Map<String, Any?> {
        val m = linkedMapOf<String, Any?>("operationId" to operationId, "tags" to listOf(tag), "summary" to summary, "responses" to resp)
        if (description != null) m["description"] = description
        val sec = security ?: if (bearer) OpenApi.bearer else null
        if (sec != null) m["security"] = sec
        if (parameters != null) m["parameters"] = parameters
        if (body != null) {
            val schemaBlock = linkedMapOf<String, Any?>("schema" to ref(body))
            if (bodyExample != null) schemaBlock["example"] = bodyExample
            m["requestBody"] = mapOf("required" to true, "content" to mapOf("application/json" to schemaBlock))
        }
        return m
    }

    private fun pathP(name: String, desc: String, ex: String, format: String? = null) =
        linkedMapOf<String, Any?>("name" to name, "in" to "path", "required" to true,
            "description" to desc, "schema" to strProp(format = format), "example" to ex)
    private fun queryP(name: String, type: String, required: Boolean, desc: String, ex: Any? = null, enum: List<String>? = null, default: Any? = null) =
        linkedMapOf<String, Any?>("name" to name, "in" to "query", "required" to required, "description" to desc,
            "schema" to linkedMapOf<String, Any?>("type" to type).apply { if (enum != null) put("enum", enum); if (default != null) put("default", default) }).apply { if (ex != null) put("example", ex) }

    // 2xx success response referencing a component schema (or plain when schema == null).
    private fun okResp(code: String, desc: String, schema: String? = null, example: Map<String, Any?>? = null): Map<String, Any?> {
        val block = linkedMapOf<String, Any?>("description" to desc)
        if (schema != null) {
            val media = linkedMapOf<String, Any?>("schema" to ref(schema))
            if (example != null) media["example"] = example
            block["content"] = mapOf("application/json" to media)
        }
        return mapOf(code to block)
    }
    // 4xx/5xx error response → ErrorEnvelope $ref.
    private fun errResp(code: String, desc: String): Map<String, Any?> =
        mapOf(code to mapOf("description" to desc,
            "content" to mapOf("application/json" to mapOf("schema" to ref("ErrorEnvelope")))))

    // merge response maps (LinkedHashMap to preserve ordering)
    private fun merge(vararg maps: Map<String, Any?>): Map<String, Any?> {
        val out = linkedMapOf<String, Any?>()
        maps.forEach { out.putAll(it) }
        return out
    }

    // ---- examples ----------------------------------------------------------
    private const val UUID_EX = "11111111-1111-4111-8111-111111111111"
    private const val PROD_EX = "22222222-2222-4222-8222-222222222222"
    private const val SHOP_EX = "33333333-3333-4333-8333-333333333333"
    private const val ORDER_EX = "44444444-4444-4444-8444-444444444444"
    private const val USER_EX = "55555555-5555-4555-8555-555555555555"

    private val postReviewEx = linkedMapOf<String, Any?>(
        "target_kind" to "product", "product_id" to PROD_EX, "order_id" to ORDER_EX,
        "rating" to 5, "title" to "Excellent", "body" to "দারুণ পণ্য, দ্রুত ডেলিভারি", "media_ids" to emptyList<String>())
    private val patchReviewEx = linkedMapOf<String, Any?>("rating" to 4, "title" to "Updated", "body" to "Still good after a week")
    private val replyEx = linkedMapOf<String, Any?>("body" to "Thank you for the feedback!")
    private val voteEx = linkedMapOf<String, Any?>("is_helpful" to true)
    private val reportEx = linkedMapOf<String, Any?>("reason" to "spam", "note" to "duplicate listing")
    private val hasPurchasedEx = linkedMapOf<String, Any?>("user_id" to USER_EX, "order_id" to ORDER_EX, "product_id" to PROD_EX)

    fun spec(): Map<String, Any?> = linkedMapOf(
        "openapi" to "3.0.3",
        "info" to linkedMapOf(
            "title" to "DOKANDAR Review Service",
            "version" to Config.codeVersion,
            "description" to buildString {
                append("**service_name**: `${Config.serviceName}` &nbsp;|&nbsp; ")
                append("**code_version**: `${Config.codeVersion}` &nbsp;|&nbsp; ")
                append("**env_version**: `${Config.envVersion}` &nbsp;|&nbsp; ")
                append("**tenant**: `${Config.tenant}` &nbsp;|&nbsp; ")
                append("**env**: `${Config.appEnv}`\n\n")
                append("Reviews, Q&A, ratings (Kotlin 2.4 / Ktor 3.5). Review CRUD with a ${Config.editWindowDays}-day edit window, ")
                append("shopkeeper replies, helpful votes, abuse reports with auto-hide at ${Config.reportThreshold} reports, admin moderation, ")
                append("incremental rating aggregates, and full-text review search (Elasticsearch). Verified-purchase enforcement via a ")
                append("local projection of order events. Exposes gRPC `ReviewQuery.HasPurchased`.\n\n")
                append("### How to test\n")
                append("1. Click **Authorize** and paste a Bearer **access token** from the auth service ")
                append("(`POST /api/v1/auth/login/request` → `/login/verify`). Public reads ")
                append("(`GET /reviews`, `/reviews/{id}`, `/reviews/search`, `/aggregate`) need no token.\n")
                append("2. To post a review you must reference a real `order_id`; duplicate `(user,target,order)` returns `409 review_exists`.\n")
                append("3. Edits are only allowed within the ${Config.editWindowDays}-day window and only by the author (`403 edit_window_closed` / `not_author`).\n")
                append("4. `reply` requires `shopkeeper`/`admin`; `hide`/`restore` require `admin`. `has-purchased` is an internal endpoint — Authorize with the **InternalToken** scheme (`x-internal-token`).\n\n")
                append("Errors use the platform envelope `{error:{code,message,request_id,details}}` with lowercase snake-case codes.")
            },
            "contact" to linkedMapOf("name" to "DOKANDAR Platform", "url" to "https://dokandar.com.bd", "email" to "api@dokandar.com.bd"),
            "license" to linkedMapOf("name" to "Proprietary"),
        ),
        "servers" to listOf(
            linkedMapOf("url" to "https://api.dokandar.com.bd", "description" to "prod"),
            linkedMapOf("url" to "http://localhost:10008", "description" to "local"),
        ),
        "tags" to listOf(
            mapOf("name" to "review", "description" to "Reviews, replies, helpful votes, abuse reports, aggregates"),
            mapOf("name" to "moderation", "description" to "Admin moderation: hide / restore reviews"),
            mapOf("name" to "internal", "description" to "Service-to-service endpoints (x-internal-token)"),
            mapOf("name" to "ops", "description" to "Operational / contract surface (/ready /health /data /metrics)"),
        ),
        "components" to mapOf(
            "securitySchemes" to mapOf(
                "HTTPBearer" to mapOf("type" to "http", "scheme" to "bearer", "bearerFormat" to "JWT", "description" to "RS256 access token minted by 01-auth"),
                "InternalToken" to mapOf("type" to "apiKey", "in" to "header", "name" to "x-internal-token", "description" to "Shared INTERNAL_SERVICE_TOKEN (constant-time compared, fail-closed)")),
            "schemas" to linkedMapOf(
                "PostReviewBody" to obj(linkedMapOf(
                    "target_kind" to strProp("product", desc = "what is being reviewed", enum = listOf("product", "shop")),
                    "product_id" to strProp(PROD_EX, nullable = true, desc = "required when target_kind=product", format = "uuid"),
                    "shop_id" to strProp(SHOP_EX, nullable = true, desc = "required when target_kind=shop", format = "uuid"),
                    "order_id" to strProp(ORDER_EX, desc = "the delivered order that proves purchase", format = "uuid"),
                    "rating" to intProp(min = 1, max = 5, ex = 5, desc = "star rating 1..5"),
                    "title" to strProp("Excellent", nullable = true),
                    "body" to strProp("দারুণ পণ্য", nullable = true, desc = "review text (UTF-8, Bangla/English)"),
                    "media_ids" to mapOf("type" to "array", "items" to strProp(format = "uuid"), "description" to "attached media ids from 12-media")),
                    listOf("target_kind", "order_id", "rating")),
                "PatchReviewBody" to obj(linkedMapOf(
                    "rating" to intProp(min = 1, max = 5, ex = 4, desc = "new star rating 1..5"),
                    "title" to strProp("Updated", nullable = true),
                    "body" to strProp(nullable = true))),
                "ReplyBody" to obj(linkedMapOf("body" to strProp("Thank you for the feedback!", desc = "shopkeeper reply text")), listOf("body")),
                "VoteBody" to obj(linkedMapOf("is_helpful" to mapOf("type" to "boolean", "description" to "true=helpful, false=not helpful", "example" to true)), listOf("is_helpful")),
                "ReportBody" to obj(linkedMapOf(
                    "reason" to strProp("spam", desc = "abuse reason", enum = listOf("spam", "offensive", "off_topic", "fake", "other")),
                    "note" to strProp("duplicate listing", nullable = true, desc = "optional free-text note")), listOf("reason")),
                "HasPurchasedBody" to obj(linkedMapOf(
                    "user_id" to strProp(USER_EX, format = "uuid"),
                    "order_id" to strProp(ORDER_EX, format = "uuid"),
                    "product_id" to strProp(PROD_EX, format = "uuid")), listOf("user_id", "order_id", "product_id")),
                "ReviewDto" to obj(linkedMapOf(
                    "id" to strProp(UUID_EX, format = "uuid"), "user_id" to strProp(format = "uuid"),
                    "target_kind" to strProp(enum = listOf("product", "shop")),
                    "product_id" to strProp(nullable = true, format = "uuid"), "shop_id" to strProp(nullable = true, format = "uuid"),
                    "order_id" to strProp(format = "uuid"), "rating" to intProp(min = 1, max = 5),
                    "title" to strProp(nullable = true), "body" to strProp(nullable = true),
                    "media_ids" to mapOf("type" to "array", "items" to strProp(format = "uuid")),
                    "votes_helpful" to intProp(), "votes_not" to intProp(), "reports_count" to intProp(),
                    "status" to strProp(enum = listOf("visible", "hidden", "removed")),
                    "created_at" to strProp(format = "date-time"), "updated_at" to strProp(format = "date-time"))),
                "AggregateDto" to obj(linkedMapOf(
                    "target_kind" to strProp(enum = listOf("product", "shop")), "target_id" to strProp(format = "uuid"),
                    "count" to intProp(desc = "total visible reviews"), "avg" to mapOf("type" to "number", "format" to "double", "description" to "mean rating"),
                    "histogram" to mapOf("type" to "object", "additionalProperties" to intProp(), "description" to "star → count, e.g. {\"5\":12,\"4\":3}"))),
                "OkResult" to obj(linkedMapOf("ok" to mapOf("type" to "boolean", "example" to true))),
                "EligibleResult" to obj(linkedMapOf("eligible" to mapOf("type" to "boolean", "description" to "true if the user purchased the product in that order", "example" to true))),
                "ErrorEnvelope" to obj(linkedMapOf("error" to obj(linkedMapOf(
                    "code" to strProp("validation_error", desc = "stable lowercase snake-case machine code"),
                    "message" to strProp("human-readable message"),
                    "request_id" to strProp(nullable = true, desc = "honour-or-mint x-request-id"),
                    "details" to mapOf("type" to "object", "nullable" to true, "additionalProperties" to true, "description" to "optional structured context")),
                    listOf("code", "message"))), listOf("error"))),
        ),
        "paths" to linkedMapOf(
            "/api/v1/review/reviews" to mapOf(
                "get" to op("listReviews", "review", "List visible reviews",
                    description = "Paged list of visible reviews filtered by `product_id` or `shop_id`.",
                    parameters = listOf(
                        queryP("product_id", "string", false, "filter by product (uuid)", PROD_EX),
                        queryP("shop_id", "string", false, "filter by shop (uuid)", SHOP_EX),
                        queryP("page", "integer", false, "zero-based page index", 0, default = 0),
                        queryP("size", "integer", false, "page size (default 20)", 20, default = 20)),
                    resp = merge(okResp("200", "array of visible reviews", "ReviewDto"), errResp("422", "invalid_request"))),
                "post" to op("postReview", "review", "Post a review", bearer = true, body = "PostReviewBody", bodyExample = postReviewEx,
                    description = "Create a review for a product or shop. Requires a delivered `order_id`; one review per `(user, target, order)`.",
                    resp = merge(okResp("201", "created review", "ReviewDto"),
                        errResp("401", "missing_token / invalid_token"), errResp("403", "not_verified_purchase"),
                        errResp("409", "review_exists"), errResp("422", "invalid_request")))),
            "/api/v1/review/reviews/search" to mapOf(
                "get" to op("searchReviews", "review", "Full-text review search (Elasticsearch)",
                    description = "Full-text search over visible review text via the business-search Elasticsearch index.",
                    parameters = listOf(queryP("q", "string", false, "search query (Bangla/English)", "great delivery")),
                    resp = okResp("200", "matching reviews", "ReviewDto"))),
            "/api/v1/review/reviews/{id}" to mapOf(
                "get" to op("getReview", "review", "Get a review",
                    parameters = listOf(pathP("id", "review id", UUID_EX, "uuid")),
                    resp = merge(okResp("200", "the review", "ReviewDto"), errResp("404", "not_found"))),
                "patch" to op("patchReview", "review", "Edit own review (within the edit window)", bearer = true,
                    description = "Update rating/title/body of your own review within the ${Config.editWindowDays}-day edit window.",
                    parameters = listOf(pathP("id", "review id", UUID_EX, "uuid")), body = "PatchReviewBody", bodyExample = patchReviewEx,
                    resp = merge(okResp("200", "updated review", "ReviewDto"),
                        errResp("401", "missing_token / invalid_token"), errResp("403", "not_author / edit_window_closed"),
                        errResp("404", "not_found"), errResp("422", "invalid_request"))),
                "delete" to op("deleteReview", "review", "Delete own review (author or admin)", bearer = true,
                    parameters = listOf(pathP("id", "review id", UUID_EX, "uuid")),
                    resp = merge(mapOf("204" to mapOf("description" to "deleted (no content)")),
                        errResp("401", "missing_token / invalid_token"), errResp("403", "not_author"), errResp("404", "not_found")))),
            "/api/v1/review/aggregate" to mapOf(
                "get" to op("getAggregate", "review", "Rating aggregate for a target",
                    description = "Returns count, mean and a star histogram for a product or shop.",
                    parameters = listOf(
                        queryP("target_kind", "string", true, "what to aggregate", "product", enum = listOf("product", "shop")),
                        queryP("target_id", "string", true, "the product/shop id (uuid)", PROD_EX)),
                    resp = merge(okResp("200", "rating aggregate", "AggregateDto"), errResp("422", "invalid_request")))),
            "/api/v1/review/reviews/{id}/reply" to mapOf(
                "post" to op("replyReview", "review", "Shopkeeper reply", bearer = true,
                    parameters = listOf(pathP("id", "review id", UUID_EX, "uuid")), body = "ReplyBody", bodyExample = replyEx,
                    resp = merge(okResp("200", "reply accepted", "OkResult"),
                        errResp("401", "missing_token / invalid_token"), errResp("403", "insufficient_role"), errResp("404", "not_found")))),
            "/api/v1/review/reviews/{id}/vote" to mapOf(
                "post" to op("voteReview", "review", "Vote helpful / not helpful", bearer = true,
                    parameters = listOf(pathP("id", "review id", UUID_EX, "uuid")), body = "VoteBody", bodyExample = voteEx,
                    resp = merge(okResp("200", "vote recorded", "OkResult"),
                        errResp("401", "missing_token / invalid_token"), errResp("404", "not_found")))),
            "/api/v1/review/reviews/{id}/report" to mapOf(
                "post" to op("reportReview", "review", "Report a review (auto-hide at threshold)", bearer = true,
                    description = "File an abuse report; the review is auto-hidden once it reaches ${Config.reportThreshold} reports.",
                    parameters = listOf(pathP("id", "review id", UUID_EX, "uuid")), body = "ReportBody", bodyExample = reportEx,
                    resp = merge(okResp("200", "report recorded", "OkResult"),
                        errResp("401", "missing_token / invalid_token"), errResp("404", "not_found"), errResp("422", "invalid_request")))),
            "/api/v1/review/reviews/{id}/hide" to mapOf(
                "post" to op("hideReview", "moderation", "Admin: hide a review", bearer = true,
                    parameters = listOf(pathP("id", "review id", UUID_EX, "uuid")),
                    resp = merge(okResp("200", "review hidden", "ReviewDto"),
                        errResp("401", "missing_token / invalid_token"), errResp("403", "insufficient_role"), errResp("404", "not_found")))),
            "/api/v1/review/reviews/{id}/restore" to mapOf(
                "post" to op("restoreReview", "moderation", "Admin: restore a review", bearer = true,
                    parameters = listOf(pathP("id", "review id", UUID_EX, "uuid")),
                    resp = merge(okResp("200", "review restored", "ReviewDto"),
                        errResp("401", "missing_token / invalid_token"), errResp("403", "insufficient_role"), errResp("404", "not_found")))),
            "/api/v1/review/has-purchased" to mapOf(
                "post" to op("hasPurchased", "internal", "Verified-purchase check (internal)", security = internal, body = "HasPurchasedBody", bodyExample = hasPurchasedEx,
                    description = "Service-to-service eligibility check. Authenticate with the **InternalToken** scheme (`x-internal-token`).",
                    resp = merge(okResp("200", "eligibility result", "EligibleResult"),
                        errResp("401", "unauthorized (x-internal-token missing or invalid)")))),
            "/ready" to mapOf("get" to op("getReady", "ops", "Readiness probe (gates PostgreSQL)",
                description = "200 only when PostgreSQL is reachable; never gates on Kafka/ES/Mongo/APM.",
                resp = merge(okResp("200", "ready"), errResp("503", "not_ready")))),
            "/health" to mapOf("get" to op("getHealth", "ops", "Full health + dependency diagnostics",
                description = "Diagnostics over all deps plus an observability block; only PostgreSQL flips status.",
                resp = merge(okResp("200", "healthy"), errResp("503", "unhealthy")))),
            "/data" to mapOf("get" to op("getData", "ops", "Tenant data snapshot",
                description = "Identity block prepended to the read-only `data/<tenant>/result.json` snapshot.",
                resp = merge(okResp("200", "snapshot"), errResp("404", "no_snapshot"), errResp("500", "snapshot_parse_failed / snapshot_not_object")))),
            "/metrics" to mapOf("get" to op("getMetrics", "ops", "Prometheus metrics",
                description = "Prometheus text exposition (RED + service counters, including review_outbox_pending).",
                resp = okResp("200", "Prometheus exposition (text/plain)")))))

    const val DOCS_HTML = """<!doctype html><html><head><meta charset="utf-8"><title>08-review API</title>
<link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css"></head><body><div id="swagger-ui"></div>
<script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
<script>window.onload=()=>{SwaggerUIBundle({url:'/openapi.json',dom_id:'#swagger-ui',deepLinking:true,persistAuthorization:true})}</script></body></html>"""
}

fun Route.docsRoutes() {
    get("/openapi.json") { call.respondText(Json.encode(OpenApi.spec()), ContentType.Application.Json) }
    get("/docs") { call.respondText(OpenApi.DOCS_HTML, ContentType.Text.Html) }
}
