package infra

import (
	"context"
	"fmt"

	"github.com/redis/go-redis/v9"
)

// NewRedis opens a Redis client and pings it. APM auto-instrumentation for
// go-redis/v9 is not wired here — the apmgoredisv9 module path was not
// resolvable from the Go proxy at build time. Redis ops still show as part
// of the parent HTTP transaction; just not as standalone spans.
func NewRedis(ctx context.Context, url string) (*redis.Client, error) {
	opt, err := redis.ParseURL(url)
	if err != nil {
		return nil, fmt.Errorf("redis url parse: %w", err)
	}
	cli := redis.NewClient(opt)
	if err := cli.Ping(ctx).Err(); err != nil {
		_ = cli.Close()
		return nil, fmt.Errorf("redis ping: %w", err)
	}
	return cli, nil
}
