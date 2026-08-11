<?php

namespace App\Grpc;

/**
 * East-west client for auth's gRPC `Auth.LookupShopkeeper`, used by
 * staff-assignment to verify the target user is a shop_staff owned by the
 * caller. Uses the grpc *extension*'s low-level API (Channel/Call) directly
 * — no generated stubs / google-protobuf needed (see Proto).
 *
 * Every call sends `x-internal-token` metadata = INTERNAL_SERVICE_TOKEN, as
 * auth requires (mismatch → UNAUTHENTICATED).
 */
class AuthClient
{
    public function __construct(
        private string $hostPort,
        private string $token,
    ) {
    }

    /** True when the grpc extension is loaded and a host is configured. */
    public function usable(): bool
    {
        return $this->hostPort !== '' && class_exists('\Grpc\Channel');
    }

    /**
     * @return array{exists:bool,role:string,status:string,owner_id:string}
     * @throws \RuntimeException on transport/status failure.
     */
    public function lookupShopkeeper(string $userId, int $timeoutMs = 1500): array
    {
        if (! $this->usable()) {
            throw new \RuntimeException('auth gRPC not usable (extension missing or host unset)');
        }

        $channel = new \Grpc\Channel($this->hostPort, [
            'credentials' => \Grpc\ChannelCredentials::createInsecure(),
        ]);
        try {
            $deadline = \Grpc\Timeval::now()->add(new \Grpc\Timeval($timeoutMs * 1000));
            $call = new \Grpc\Call($channel, '/dokandar.auth.v1.Auth/LookupShopkeeper', $deadline);

            $event = $call->startBatch([
                \Grpc\OP_SEND_INITIAL_METADATA  => ['x-internal-token' => [$this->token]],
                \Grpc\OP_SEND_MESSAGE           => ['message' => Proto::encodeLookupRequest($userId)],
                \Grpc\OP_SEND_CLOSE_FROM_CLIENT => true,
                \Grpc\OP_RECV_INITIAL_METADATA  => true,
                \Grpc\OP_RECV_MESSAGE           => true,
                \Grpc\OP_RECV_STATUS_ON_CLIENT  => true,
            ]);

            $status = $event->status;
            if ($status->code !== 0) {
                throw new \RuntimeException("LookupShopkeeper failed: code={$status->code} {$status->details}");
            }
            return Proto::decodeLookupResponse((string) ($event->message ?? ''));
        } finally {
            $channel->close();
        }
    }
}
