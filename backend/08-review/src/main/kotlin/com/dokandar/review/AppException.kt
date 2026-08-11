package com.dokandar.review

// Maps to the {"error":{"code","message","request_id","details"?}} envelope at the StatusPages boundary.
class AppException(val status: Int, val code: String, override val message: String, val details: Any? = null) : RuntimeException(message)
