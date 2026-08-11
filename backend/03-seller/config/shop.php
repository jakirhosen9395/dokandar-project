<?php

/**
 * Shop-service-specific configuration. Laravel-style: every value comes
 * from env() so the same image runs in every environment with only env
 * vars differing. CODE_VERSION is read from the repo-root file.
 */
return [
    'identity' => [
        'service_name' => env('SERVICE_NAME', '03-seller'),
        'code_version' => trim((string) @file_get_contents(base_path('CODE_VERSION'))) ?: '0-unknown',
        'env_version'  => env('ENV_VERSION', 'v1.0.0'),
        'tenant'       => env('TENANT', 'local'),
        'env'          => env('APP_ENV', 'dev'),
    ],
    'kafka' => [
        'bootstrap' => env('KAFKA_BOOTSTRAP', 'localhost:9092'),
        'topic_shop' => env('KAFKA_TOPIC_SHOP', 'dokandar.shop.changed'),
        'topic_staff' => env('KAFKA_TOPIC_STAFF', 'dokandar.shop.staff_assigned'),
        'consumer_group' => env('KAFKA_CONSUMER_GROUP', 'seller'),
        // NOTE: auth publishes KYC events to dokandar.kyc.* (verified from
        // auth's live env), NOT the shop.md-spec dokandar.auth.kyc.* — the
        // consumer subscribes to the real topics.
        'topic_kyc_approved' => env('KAFKA_TOPIC_KYC_APPROVED', 'dokandar.kyc.approved'),
        'topic_kyc_rejected' => env('KAFKA_TOPIC_KYC_REJECTED', 'dokandar.kyc.rejected'),
    ],
    'logs' => [
        'mongo_uri' => env('MONGO_LOG_URI', ''),
        'mongo_db'  => env('MONGO_LOG_DB', 'dokandar_logs'),
        'es_url'    => env('ELASTIC_SEARCH_URL', ''),
        'es_user'   => env('ELASTIC_SEARCH_USERNAME', ''),
        'es_pass'   => env('ELASTIC_SEARCH_PASSWORD', ''),
    ],
    'apm' => [
        'server_url'   => env('APM_SERVER_URL', ''),
        'secret_token' => env('APM_SECRET_TOKEN', ''),
        'service_name' => env('APM_SERVICE_NAME', '03-seller'),
    ],
    'jwt' => [
        'public_key_b64' => env('JWT_PUBLIC_KEY_B64', ''),
        'issuer'         => env('JWT_ISSUER', 'dokandar-auth'),
        // §16-h: audience enforcement is SUPPORTED but OFF by default — the
        // deployed 01-auth does not (yet) mint an `aud` claim, so enforcing it
        // would reject every real token. Set JWT_AUDIENCE once auth issues one.
        'audience'       => env('JWT_AUDIENCE', ''),
    ],
    // East-west gRPC. auth is wired for staff-assign verification; media +
    // coupon are diagnostic-only (services not deployed) — empty host =>
    // /health reports not_configured.
    'grpc' => [
        'auth'   => env('AUTH_GRPC_HOST') ? env('AUTH_GRPC_HOST') . ':' . env('AUTH_GRPC_PORT', '50051') : '',
        'media'  => env('MEDIA_GRPC_HOST') ? env('MEDIA_GRPC_HOST') . ':' . env('MEDIA_GRPC_PORT', '50051') : '',
        'coupon' => env('COUPON_GRPC_HOST') ? env('COUPON_GRPC_HOST') . ':' . env('COUPON_GRPC_PORT', '50051') : '',
    ],
    'internal_token' => env('INTERNAL_SERVICE_TOKEN', ''),
];
