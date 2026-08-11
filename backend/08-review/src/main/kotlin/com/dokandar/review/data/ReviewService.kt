package com.dokandar.review.data

import com.dokandar.review.AppException
import com.dokandar.review.Config
import com.dokandar.review.api.*
import com.dokandar.review.auth.AuthUser
import com.dokandar.review.observability.Json
import com.dokandar.review.observability.Log
import com.dokandar.review.observability.Metrics
import java.sql.Connection
import java.sql.ResultSet
import java.sql.SQLException
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.UUID

object ReviewService {
    private const val SVC = Metrics.SVC
    private val ISO = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)
    private fun ts(rs: ResultSet, col: String): String? = rs.getTimestamp(col)?.toInstant()?.let { ISO.format(it) }

    private fun reviewRow(rs: ResultSet): LinkedHashMap<String, Any?> {
        val arr = rs.getArray("media_ids")
        val media = if (arr != null) (arr.array as Array<*>).map { it.toString() } else emptyList<String>()
        return linkedMapOf(
            "id" to rs.getString("id"), "user_id" to rs.getString("user_id"), "target_kind" to rs.getString("target_kind"),
            "product_id" to rs.getString("product_id"), "shop_id" to rs.getString("shop_id"), "order_id" to rs.getString("order_id"),
            "rating" to rs.getInt("rating"), "title" to rs.getString("title"), "body" to rs.getString("body"),
            "media_ids" to media, "votes_helpful" to rs.getInt("votes_helpful"), "votes_not" to rs.getInt("votes_not"),
            "reports_count" to rs.getInt("reports_count"), "status" to rs.getString("status"),
            "created_at" to ts(rs, "created_at"), "updated_at" to ts(rs, "updated_at"),
        )
    }

    // ── reads ──────────────────────────────────────────────────────────────
    fun list(productId: String?, shopId: String?, page: Int, size: Int): List<Map<String, Any?>> = Db.conn { c ->
        val sz = size.coerceIn(1, 100); val off = page.coerceAtLeast(0) * sz
        val (col, value) = when {
            !productId.isNullOrEmpty() -> "product_id" to productId
            !shopId.isNullOrEmpty() -> "shop_id" to shopId
            else -> return@conn emptyList()
        }
        val rs = c.prepareStatement("SELECT * FROM reviews WHERE $col=?::uuid AND status='visible' ORDER BY created_at DESC LIMIT ? OFFSET ?")
            .apply { setString(1, value); setInt(2, sz); setInt(3, off) }.executeQuery()
        val out = ArrayList<Map<String, Any?>>(); while (rs.next()) out.add(reviewRow(rs)); out
    }

    fun get(id: String): Map<String, Any?> = Db.conn { c ->
        val rs = c.prepareStatement("SELECT * FROM reviews WHERE id=?::uuid").apply { setString(1, id) }.executeQuery()
        if (!rs.next()) throw AppException(404, "not_found", "review not found")
        reviewRow(rs)
    }

    fun aggregate(targetKind: String, targetId: String): Map<String, Any?> = Db.conn { c ->
        val rs = c.prepareStatement("SELECT * FROM rating_aggregates WHERE target_kind=? AND target_id=?::uuid")
            .apply { setString(1, targetKind); setString(2, targetId) }.executeQuery()
        if (!rs.next()) return@conn linkedMapOf("target_kind" to targetKind, "target_id" to targetId, "count" to 0, "avg" to 0.0,
            "histogram" to linkedMapOf("1" to 0, "2" to 0, "3" to 0, "4" to 0, "5" to 0))
        val count = rs.getInt("count"); val sum = rs.getInt("sum_rating")
        linkedMapOf("target_kind" to targetKind, "target_id" to targetId, "count" to count,
            "avg" to if (count == 0) 0.0 else sum.toDouble() / count,
            "histogram" to linkedMapOf("1" to rs.getInt("n1"), "2" to rs.getInt("n2"), "3" to rs.getInt("n3"), "4" to rs.getInt("n4"), "5" to rs.getInt("n5")))
    }

    fun search(q: String): List<Map<String, Any?>> = EsClient.search(q)

    // ── post ───────────────────────────────────────────────────────────────
    fun post(user: AuthUser, b: PostReviewBody): Map<String, Any?> {
        if (b.target_kind !in setOf("product", "shop")) throw AppException(422, "invalid_request", "target_kind must be product|shop")
        if (b.rating !in 1..5) throw AppException(422, "invalid_request", "rating must be 1..5")
        val (targetKind, targetId) = when (b.target_kind) {
            "product" -> "product" to (b.product_id ?: throw AppException(422, "invalid_request", "product_id required when target_kind='product'"))
            else -> "shop" to (b.shop_id ?: throw AppException(422, "invalid_request", "shop_id required when target_kind='shop'"))
        }
        val doc = Db.tx { c ->
            if (Config.enforceVerifiedPurchase && !checkEligible(c, user.sub, b.order_id, b.product_id)) {
                Metrics.reviewPosts.labels(SVC, "no_eligibility").inc()
                throw AppException(403, "not_verified_purchase", "user has no eligible purchase for this target/order")
            }
            val media = c.createArrayOf("uuid", b.media_ids.map { UUID.fromString(it) }.toTypedArray())
            // Idempotent insert: ON CONFLICT DO NOTHING avoids throwing PSQLException(23505) on a
            // duplicate review — the JDBC agent instrumentation captures that exception as an APM error
            // at the driver BEFORE the app's catch could convert it. A conflict now returns no row, so
            // we surface the duplicate as the 409 business outcome with no SQL exception thrown. (Other
            // SQL errors are NOT caught here, so genuine DB faults still surface in the Errors tab.)
            val rs = c.prepareStatement("INSERT INTO reviews (user_id,target_kind,product_id,shop_id,order_id,rating,title,body,media_ids) VALUES (?::uuid,?,?::uuid,?::uuid,?::uuid,?,?,?,?) ON CONFLICT (user_id,target_kind,product_id,shop_id,order_id) DO NOTHING RETURNING *").apply {
                setString(1, user.sub); setString(2, targetKind); setString(3, b.product_id); setString(4, b.shop_id)
                setString(5, b.order_id); setInt(6, b.rating); setString(7, b.title); setString(8, b.body); setArray(9, media)
            }.executeQuery()
            if (!rs.next()) { Metrics.reviewPosts.labels(SVC, "duplicate").inc(); throw AppException(409, "review_exists", "you have already reviewed this target for this order") }
            val row = reviewRow(rs)
            applyAggregateDelta(c, targetKind, targetId, 1, b.rating, null)
            emitOutbox(c, Config.topicReviewPosted, row["id"].toString(), mapOf("event" to "ReviewPosted", "review_id" to row["id"], "target_kind" to targetKind, "target_id" to targetId, "user_id" to user.sub, "rating" to b.rating))
            row
        }
        Metrics.reviewPosts.labels(SVC, "ok").inc()
        EsClient.indexAsync(doc["id"].toString(), doc)
        Log.info("review.api", "review posted id=${doc["id"]} user=${user.sub} target=$targetKind:$targetId rating=${b.rating}")
        return doc
    }

    fun patch(user: AuthUser, id: String, b: PatchReviewBody): Map<String, Any?> {
        val doc = Db.tx { c ->
            val rs = c.prepareStatement("SELECT * FROM reviews WHERE id=?::uuid FOR UPDATE").apply { setString(1, id) }.executeQuery()
            if (!rs.next()) throw AppException(404, "not_found", "review not found")
            val old = reviewRow(rs)
            if (old["user_id"] != user.sub) throw AppException(403, "not_author", "only the author can edit")
            val created = rs.getTimestamp("created_at").toInstant()
            if (Instant.now().isAfter(created.plusSeconds(Config.editWindowDays * 86400L))) throw AppException(403, "edit_window_closed", "reviews are editable for ${Config.editWindowDays} days")
            val oldRating = old["rating"] as Int
            val newRating = b.rating ?: oldRating
            if (b.rating != null && b.rating !in 1..5) throw AppException(422, "invalid_request", "rating must be 1..5")
            val rs2 = c.prepareStatement("UPDATE reviews SET rating=COALESCE(?,rating), title=COALESCE(?,title), body=COALESCE(?,body), updated_at=now() WHERE id=?::uuid RETURNING *").apply {
                if (b.rating != null) setInt(1, b.rating) else setNull(1, java.sql.Types.SMALLINT)
                setString(2, b.title); setString(3, b.body); setString(4, id)
            }.executeQuery()
            rs2.next(); val row = reviewRow(rs2)
            if (newRating != oldRating) applyAggregateDelta(c, old["target_kind"].toString(), (old["product_id"] ?: old["shop_id"]).toString(), 0, newRating, oldRating)
            emitOutbox(c, Config.topicReviewUpdated, id, mapOf("event" to "ReviewUpdated", "review_id" to id, "rating" to newRating))
            row
        }
        EsClient.indexAsync(id, doc)
        return doc
    }

    fun delete(user: AuthUser, id: String) {
        Db.tx { c ->
            val rs = c.prepareStatement("SELECT * FROM reviews WHERE id=?::uuid FOR UPDATE").apply { setString(1, id) }.executeQuery()
            if (!rs.next()) return@tx
            val row = reviewRow(rs)
            if (row["user_id"] != user.sub && !user.isAdmin) throw AppException(403, "not_author", "only the author or an admin can delete")
            applyAggregateDelta(c, row["target_kind"].toString(), (row["product_id"] ?: row["shop_id"]).toString(), -1, null, row["rating"] as Int)
            c.prepareStatement("DELETE FROM reviews WHERE id=?::uuid").apply { setString(1, id) }.executeUpdate()
            emitOutbox(c, Config.topicReviewDeleted, id, mapOf("event" to "ReviewDeleted", "review_id" to id))
        }
        EsClient.deleteAsync(id)
    }

    fun reply(user: AuthUser, id: String, b: ReplyBody): Map<String, Any?> {
        if (b.body.isBlank()) throw AppException(422, "invalid_request", "body required")
        Db.tx { c ->
            if (!c.prepareStatement("SELECT 1 FROM reviews WHERE id=?::uuid").apply { setString(1, id) }.executeQuery().next())
                throw AppException(404, "not_found", "review not found")
            c.prepareStatement("INSERT INTO review_replies (review_id,shopkeeper_id,body) VALUES (?::uuid,?::uuid,?) ON CONFLICT (review_id) DO UPDATE SET body=EXCLUDED.body, created_at=now()")
                .apply { setString(1, id); setString(2, user.sub); setString(3, b.body) }.executeUpdate()
            emitOutbox(c, Config.topicReviewReply, id, mapOf("event" to "ReviewReplyPosted", "review_id" to id, "shopkeeper_id" to user.sub))
        }
        return linkedMapOf("ok" to true, "review_id" to id)
    }

    fun vote(user: AuthUser, id: String, b: VoteBody): Map<String, Any?> {
        Db.tx { c ->
            if (!c.prepareStatement("SELECT 1 FROM reviews WHERE id=?::uuid").apply { setString(1, id) }.executeQuery().next())
                throw AppException(404, "not_found", "review not found")
            val prev = c.prepareStatement("SELECT is_helpful FROM review_votes WHERE review_id=?::uuid AND user_id=?::uuid").apply { setString(1, id); setString(2, user.sub) }.executeQuery()
            if (!prev.next()) {
                c.prepareStatement("INSERT INTO review_votes (review_id,user_id,is_helpful) VALUES (?::uuid,?::uuid,?)").apply { setString(1, id); setString(2, user.sub); setBoolean(3, b.is_helpful) }.executeUpdate()
                val col = if (b.is_helpful) "votes_helpful" else "votes_not"
                c.prepareStatement("UPDATE reviews SET $col=$col+1 WHERE id=?::uuid").apply { setString(1, id) }.executeUpdate()
            } else if (prev.getBoolean("is_helpful") != b.is_helpful) {
                val inc = if (b.is_helpful) "votes_helpful" else "votes_not"; val dec = if (b.is_helpful) "votes_not" else "votes_helpful"
                c.prepareStatement("UPDATE reviews SET $inc=$inc+1, $dec=greatest(0,$dec-1) WHERE id=?::uuid").apply { setString(1, id) }.executeUpdate()
                c.prepareStatement("UPDATE review_votes SET is_helpful=?, voted_at=now() WHERE review_id=?::uuid AND user_id=?::uuid").apply { setBoolean(1, b.is_helpful); setString(2, id); setString(3, user.sub) }.executeUpdate()
            }
        }
        Metrics.reviewVotes.labels(SVC).inc()
        return linkedMapOf("ok" to true)
    }

    fun report(user: AuthUser, id: String, b: ReportBody): Map<String, Any?> {
        if (b.reason !in setOf("spam", "hate", "off_topic", "pii", "other")) throw AppException(422, "invalid_request", "invalid reason")
        val autoHidden = Db.tx { c ->
            if (!c.prepareStatement("SELECT 1 FROM reviews WHERE id=?::uuid").apply { setString(1, id) }.executeQuery().next())
                throw AppException(404, "not_found", "review not found")
            try {
                c.prepareStatement("INSERT INTO review_reports (review_id,reporter_id,reason) VALUES (?::uuid,?::uuid,?)").apply { setString(1, id); setString(2, user.sub); setString(3, b.reason) }.executeUpdate()
                c.prepareStatement("UPDATE reviews SET reports_count=reports_count+1 WHERE id=?::uuid").apply { setString(1, id) }.executeUpdate()
            } catch (e: SQLException) { if (e.sqlState != "23505") throw e }
            val rs = c.prepareStatement("SELECT reports_count, status FROM reviews WHERE id=?::uuid").apply { setString(1, id) }.executeQuery(); rs.next()
            if (rs.getString("status") == "visible" && rs.getInt("reports_count") >= Config.reportThreshold) {
                c.prepareStatement("UPDATE reviews SET status='hidden', updated_at=now() WHERE id=?::uuid").apply { setString(1, id) }.executeUpdate()
                Metrics.reviewHidden.labels(SVC).inc(); true
            } else false
        }
        Metrics.reviewReports.labels(SVC, b.reason).inc()
        return linkedMapOf("ok" to true, "auto_hidden" to autoHidden)
    }

    fun setStatus(id: String, status: String): Map<String, Any?> {
        Db.conn { c ->
            if (c.prepareStatement("UPDATE reviews SET status=?, updated_at=now() WHERE id=?::uuid").apply { setString(1, status); setString(2, id) }.executeUpdate() == 0)
                throw AppException(404, "not_found", "review not found")
        }
        return linkedMapOf("ok" to true)
    }

    // ── eligibility ──────────────────────────────────────────────────────
    private fun checkEligible(c: Connection, userId: String, orderId: String, productId: String?): Boolean {
        val rs = c.prepareStatement("SELECT eligible FROM purchase_eligibility WHERE user_id=?::uuid AND order_id=?::uuid AND (?::uuid IS NULL OR product_id=?::uuid) LIMIT 1")
            .apply { setString(1, userId); setString(2, orderId); setString(3, productId); setString(4, productId) }.executeQuery()
        return rs.next() && rs.getBoolean("eligible")
    }
    fun hasPurchasedRest(userId: String, orderId: String, productId: String): Boolean = Db.conn { c -> checkEligible(c, userId, orderId, productId) }

    // gRPC: read by (user_id, product_id|shop_id) where eligible=true → (has_purchased, order_id)
    fun hasPurchasedGrpc(userId: String, productId: String?, shopId: String?): Pair<Boolean, String?> = Db.conn { c ->
        val sql = StringBuilder("SELECT order_id FROM purchase_eligibility WHERE user_id=?::uuid AND eligible=true")
        if (!productId.isNullOrEmpty()) sql.append(" AND product_id=?::uuid")
        else if (!shopId.isNullOrEmpty()) sql.append(" AND shop_id=?::uuid")
        sql.append(" LIMIT 1")
        val ps = c.prepareStatement(sql.toString()); ps.setString(1, userId)
        if (!productId.isNullOrEmpty()) ps.setString(2, productId) else if (!shopId.isNullOrEmpty()) ps.setString(2, shopId)
        val rs = ps.executeQuery()
        if (rs.next()) true to rs.getString("order_id") else false to null
    }

    // ── aggregate delta (never recompute) ───────────────────────────────
    private fun applyAggregateDelta(c: Connection, targetKind: String, targetId: String, countDelta: Int, newRating: Int?, oldRating: Int?) {
        val sumDelta = if (countDelta == 0) (newRating ?: 0) - (oldRating ?: 0) else countDelta * (newRating ?: -(oldRating ?: 0))
        val dn = IntArray(6)
        if (countDelta == 1 && newRating != null) dn[newRating] += 1
        if (countDelta == -1 && oldRating != null) dn[oldRating] -= 1
        if (countDelta == 0 && newRating != null && oldRating != null && newRating != oldRating) { dn[oldRating] -= 1; dn[newRating] += 1 }
        c.prepareStatement("""
            INSERT INTO rating_aggregates (target_kind,target_id,count,sum_rating,n1,n2,n3,n4,n5)
            VALUES (?,?::uuid,?,?,?,?,?,?,?)
            ON CONFLICT (target_kind,target_id) DO UPDATE SET
              count = rating_aggregates.count + ?, sum_rating = rating_aggregates.sum_rating + ?,
              n1 = greatest(0, rating_aggregates.n1 + ?), n2 = greatest(0, rating_aggregates.n2 + ?),
              n3 = greatest(0, rating_aggregates.n3 + ?), n4 = greatest(0, rating_aggregates.n4 + ?),
              n5 = greatest(0, rating_aggregates.n5 + ?), updated_at = now()
        """).apply {
            setString(1, targetKind); setString(2, targetId)
            setInt(3, maxOf(0, countDelta)); setInt(4, maxOf(0, sumDelta))
            for (r in 1..5) setInt(4 + r, maxOf(0, dn[r]))
            setInt(10, countDelta); setInt(11, sumDelta)
            for (r in 1..5) setInt(11 + r, dn[r])
        }.executeUpdate()
        emitOutbox(c, Config.topicRatingChanged, "$targetKind:$targetId", mapOf("event" to "RatingAggregateChanged", "target_kind" to targetKind, "target_id" to targetId, "delta_count" to countDelta, "delta_sum" to sumDelta))
        Metrics.reviewAggUpdates.labels(SVC).inc()
    }

    private fun emitOutbox(c: Connection, topic: String, key: String, payload: Map<String, Any?>) {
        val pg = org.postgresql.util.PGobject().apply { type = "jsonb"; value = Json.encode(payload) }
        c.prepareStatement("INSERT INTO outbox (topic,key,payload) VALUES (?,?,?)").apply { setString(1, topic); setString(2, key); setObject(3, pg) }.executeUpdate()
    }
}
