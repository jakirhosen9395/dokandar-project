// Package db holds the gateway's only datastore client: Redis DB 13, backing
// the token-bucket rate-limiter. Connection is best-effort — a failure NEVER
// blocks boot and NEVER gates /ready (architecture.md §8.1/§13); the
// rate-limiter degrades per route policy when Redis is unreachable.
package db

import (
	"context"
	"time"

	"github.com/redis/go-redis/v9"
)

// NewRedis connects (best-effort) from the prepared options. Returns
// (nil, nil) when opts is nil (REDIS_HOST empty → Redis disabled, rate-limit
// degrades). Returns (nil, err) when a configured Redis is unreachable — the
// caller logs a warning and continues (the gateway still serves).
func NewRedis(ctx context.Context, opts *redis.Options) (*redis.Client, error) {
	if opts == nil {
		return nil, nil
	}
	if opts.DialTimeout == 0 {
		opts.DialTimeout = 2 * time.Second
	}
	rdb := redis.NewClient(opts)
	pctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if err := rdb.Ping(pctx).Err(); err != nil {
		_ = rdb.Close()
		return nil, err
	}
	return rdb, nil
}
