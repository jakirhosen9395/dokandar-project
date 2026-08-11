package com.dokandar.review.api

import kotlinx.serialization.Serializable

@Serializable
data class PostReviewBody(
    val target_kind: String = "", val product_id: String? = null, val shop_id: String? = null,
    val order_id: String = "", val rating: Int = 0, val title: String? = null, val body: String? = null,
    val media_ids: List<String> = emptyList(),
)
@Serializable data class PatchReviewBody(val rating: Int? = null, val title: String? = null, val body: String? = null)
@Serializable data class ReplyBody(val body: String = "")
@Serializable data class VoteBody(val is_helpful: Boolean = false)
@Serializable data class ReportBody(val reason: String = "", val note: String? = null)

@Serializable data class HasPurchasedBody(val user_id: String = "", val order_id: String = "", val product_id: String = "")
