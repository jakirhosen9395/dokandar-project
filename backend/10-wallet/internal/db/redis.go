package db

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"time"

	"github.com/redis/go-redis/v9"
)

// releaseLua deletes the lock key only if it still holds OUR token (the
// Redlock-lite check-and-del; never deletes another holder's lock).
const releaseLua = `if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("DEL", KEYS[1]) else return 0 end`

// NewRedis connects (best-effort) from the prepared options. Returns
// (nil, nil) when opts is nil (Redis disabled — Redlock degrades gracefully).
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

// AcquireLock attempts SET key token NX PX ttl. Returns ("", nil) when the
// lock is held by someone else (caller proceeds best-effort — the SERIALIZABLE
// tx is the real serialization guard). Returns ("", err) when Redis is down.
func AcquireLock(ctx context.Context, rdb *redis.Client, key string, ttl time.Duration) (string, error) {
	if rdb == nil {
		return "", errors.New("no redis")
	}
	tok := randToken()
	ok, err := rdb.SetNX(ctx, key, tok, ttl).Result()
	if err != nil {
		return "", err
	}
	if !ok {
		return "", nil
	}
	return tok, nil
}

// ReleaseLock releases only if we still own the token (no-op for empty token).
func ReleaseLock(ctx context.Context, rdb *redis.Client, key, token string) error {
	if rdb == nil || token == "" {
		return nil
	}
	_, err := rdb.Eval(ctx, releaseLua, []string{key}, token).Result()
	return err
}

func randToken() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
