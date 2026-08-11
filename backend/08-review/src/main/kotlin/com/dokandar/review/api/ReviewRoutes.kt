package com.dokandar.review.api

import com.dokandar.review.AppException
import com.dokandar.review.auth.Auth
import com.dokandar.review.data.ReviewService
import io.ktor.http.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*

fun Route.reviewRoutes() {
    route("/api/v1/review") {
        get("reviews") {
            val pid = call.request.queryParameters["product_id"]
            val sid = call.request.queryParameters["shop_id"]
            val page = call.request.queryParameters["page"]?.toIntOrNull() ?: 0
            val size = call.request.queryParameters["size"]?.toIntOrNull() ?: 20
            call.json(HttpStatusCode.OK, call.io { ReviewService.list(pid, sid, page, size) })
        }
        get("reviews/search") {
            val q = call.request.queryParameters["q"] ?: ""
            call.json(HttpStatusCode.OK, call.io { ReviewService.search(q) })
        }
        get("reviews/{id}") { call.json(HttpStatusCode.OK, call.io { ReviewService.get(call.parameters["id"]!!) }) }
        get("aggregate") {
            val tk = call.request.queryParameters["target_kind"] ?: throw AppException(422, "invalid_request", "target_kind required")
            if (tk !in setOf("product", "shop")) throw AppException(422, "invalid_request", "target_kind must be product|shop")
            val tid = call.request.queryParameters["target_id"] ?: throw AppException(422, "invalid_request", "target_id required")
            call.json(HttpStatusCode.OK, call.io { ReviewService.aggregate(tk, tid) })
        }
        post("reviews") {
            val u = call.requireUser(); val b = call.receive<PostReviewBody>()
            call.json(HttpStatusCode.Created, call.io { ReviewService.post(u, b) })
        }
        patch("reviews/{id}") {
            val u = call.requireUser(); val b = call.receive<PatchReviewBody>()
            call.json(HttpStatusCode.OK, call.io { ReviewService.patch(u, call.parameters["id"]!!, b) })
        }
        delete("reviews/{id}") {
            val u = call.requireUser(); call.io { ReviewService.delete(u, call.parameters["id"]!!) }
            call.respondBytes(ByteArray(0), status = HttpStatusCode.NoContent)
        }
        post("reviews/{id}/reply") {
            val u = call.requireShopkeeper(); val b = call.receive<ReplyBody>()
            call.json(HttpStatusCode.OK, call.io { ReviewService.reply(u, call.parameters["id"]!!, b) })
        }
        post("reviews/{id}/vote") {
            val u = call.requireUser(); val b = call.receive<VoteBody>()
            call.json(HttpStatusCode.OK, call.io { ReviewService.vote(u, call.parameters["id"]!!, b) })
        }
        post("reviews/{id}/report") {
            val u = call.requireUser(); val b = call.receive<ReportBody>()
            call.json(HttpStatusCode.OK, call.io { ReviewService.report(u, call.parameters["id"]!!, b) })
        }
        post("reviews/{id}/hide") { call.requireAdmin(); call.json(HttpStatusCode.OK, call.io { ReviewService.setStatus(call.parameters["id"]!!, "hidden") }) }
        post("reviews/{id}/restore") { call.requireAdmin(); call.json(HttpStatusCode.OK, call.io { ReviewService.setStatus(call.parameters["id"]!!, "visible") }) }
        post("has-purchased") {
            if (!Auth.internalOk(call.request.headers["x-internal-token"])) throw AppException(401, "unauthorized", "x-internal-token missing or invalid")
            val b = call.receive<HasPurchasedBody>()
            call.json(HttpStatusCode.OK, mapOf("eligible" to call.io { ReviewService.hasPurchasedRest(b.user_id, b.order_id, b.product_id) }))
        }
    }
}
