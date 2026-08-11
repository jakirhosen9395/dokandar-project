package com.dokandar.review.grpc

import com.dokandar.review.Config
import com.dokandar.review.auth.Auth
import com.dokandar.review.data.ReviewService
import com.dokandar.review.grpc.proto.HasPurchasedRequest
import com.dokandar.review.grpc.proto.HasPurchasedResponse
import com.dokandar.review.grpc.proto.ReviewQueryGrpcKt
import com.dokandar.review.observability.Log
import io.grpc.Metadata
import io.grpc.Server
import io.grpc.ServerBuilder
import io.grpc.ServerCall
import io.grpc.ServerCallHandler
import io.grpc.ServerInterceptor
import io.grpc.ServerInterceptors
import io.grpc.Status
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class ReviewQueryService : ReviewQueryGrpcKt.ReviewQueryCoroutineImplBase() {
    override suspend fun hasPurchased(request: HasPurchasedRequest): HasPurchasedResponse {
        val (has, orderId) = withContext(Dispatchers.IO) {
            ReviewService.hasPurchasedGrpc(request.userId, request.productId.ifEmpty { null }, request.shopId.ifEmpty { null })
        }
        return HasPurchasedResponse.newBuilder().setHasPurchased(has).setOrderId(orderId ?: "").build()
    }
}

// Fail-closed constant-time x-internal-token check (MessageDigest.isEqual via Auth.internalOk).
class InternalTokenInterceptor : ServerInterceptor {
    private val key = Metadata.Key.of("x-internal-token", Metadata.ASCII_STRING_MARSHALLER)
    override fun <ReqT, RespT> interceptCall(call: ServerCall<ReqT, RespT>, headers: Metadata, next: ServerCallHandler<ReqT, RespT>): ServerCall.Listener<ReqT> {
        if (!Auth.internalOk(headers.get(key))) {
            call.close(Status.UNAUTHENTICATED.withDescription("x-internal-token missing or invalid"), Metadata())
            return object : ServerCall.Listener<ReqT>() {}
        }
        return next.startCall(call, headers)
    }
}

object GrpcServer {
    private var server: Server? = null
    fun start() {
        server = ServerBuilder.forPort(Config.grpcPort)
            .addService(ServerInterceptors.intercept(ReviewQueryService(), InternalTokenInterceptor()))
            .build().start()
        Log.warn("review.grpc", "gRPC server listening on :${Config.grpcPort}")
    }
    fun stop() { server?.shutdown() }
}
