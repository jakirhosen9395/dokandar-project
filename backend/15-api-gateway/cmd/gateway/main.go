// dokandar-gateway entrypoint (15-api-gateway) — the stateless edge ingress.
//
// Boot order (architecture.md §14):
//
//	config → fail-fast SERVICE_NAME → logging (3-sink: stdout+Mongo+ES)
//	→ APM (outermost trace root) → Redis (rate-limiter; failure does NOT block
//	boot) → JWKS verifier (warm cache; tolerate slow auth) → build ops/jwks/
//	ratelimit/proxy → Echo (APM outermost) → /ready 200 once listening
//	→ block on SIGTERM → graceful shutdown.
//
// The gateway gates /ready on NOTHING external (§8.1): Redis down or an upstream
// blip must never pull the single front door out of the LB.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.elastic.co/apm/v2"

	"github.com/dokandar/dokandar-gateway/internal/app"
	"github.com/dokandar/dokandar-gateway/internal/config"
	"github.com/dokandar/dokandar-gateway/internal/db"
	"github.com/dokandar/dokandar-gateway/internal/jwks"
	"github.com/dokandar/dokandar-gateway/internal/observability"
	"github.com/dokandar/dokandar-gateway/internal/ops"
	"github.com/dokandar/dokandar-gateway/internal/proxy"
	"github.com/dokandar/dokandar-gateway/internal/ratelimit"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	bootTime := time.Now()

	settings, err := config.Load()
	if err != nil {
		return err
	}
	codeVersion := config.CodeVersion()

	rootCtx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// 1) Logging (3-sink: stdout + Mongo + ES :9200). Before APM so APM-warn
	//    logs already have a sink.
	sinks, err := observability.Setup(rootCtx, settings.LogLevel, observability.SinkConfig{
		ServiceName: settings.ServiceName,
		MongoURI:    settings.MongoLogURI,
		MongoDB:     settings.MongoLogDB,
		ESURL:       settings.ElasticSearchURL,
		ESUsername:  settings.ElasticSearchUsername,
		ESPassword:  settings.ElasticSearchPassword,
	})
	if err != nil {
		return fmt.Errorf("logging: %w", err)
	}
	defer sinks.Close(2 * time.Second)

	slog.Info("gateway starting up", "name", "gateway.main",
		"code_version", codeVersion, "env", settings.AppEnv, "tenant", settings.Tenant)

	// 2) APM (never blocks boot). Outermost Echo middleware is wired in app.New.
	if err := observability.SetupAPM(
		settings.APMServiceName, codeVersion, settings.AppEnv,
		settings.APMServerURL, settings.APMSecretToken,
	); err != nil {
		slog.Warn("apm setup failed (continuing)", "name", "gateway.main", "err", err.Error())
	}

	// 3) Redis (rate-limiter; DB 13). A failure does NOT block boot — the
	//    rate-limit degrades per route policy and /ready stays green (§8.1, §13).
	rdb, err := db.NewRedis(rootCtx, settings.RedisOptions())
	if err != nil {
		slog.Warn("redis connect failed (degraded — rate-limit per policy)", "name", "gateway.main", "err", err.Error())
	}
	if rdb != nil {
		defer func() { _ = rdb.Close() }()
	}

	// 4) JWKS verifier (RS256 pinned; 5-min cache; static-key fallback). Warm
	//    the cache but tolerate a slow/down auth — never block /ready (§14).
	verifier, err := jwks.NewVerifier(rootCtx, jwks.Config{
		JWKSURL:      settings.JWKSURL,
		CacheTTL:     time.Duration(settings.JWKSCacheTTLSeconds) * time.Second,
		Algorithms:   settings.JWTAlgorithmsList(),
		Issuer:       settings.JWTIssuer,
		Audience:     settings.JWTAudience,
		PublicKeyB64: settings.JWTPublicKeyB64,
	})
	if err != nil {
		return fmt.Errorf("jwks verifier: %w", err)
	}

	// 5) Rate-limiter (Redis token bucket; degradable).
	limiter := ratelimit.New(rdb, ratelimit.Config{
		Max:      settings.RateLimitMax,
		WindowMS: settings.RateLimitWindowMS,
	})

	// 6) Reverse-proxy + route table (verbatim path forwarding to UPSTREAM_<SVC>).
	router := proxy.New(proxy.Config{
		Upstreams:   settings.Upstreams,
		ReadTimeout: time.Duration(settings.UpstreamReadTimeoutMS) * time.Millisecond,
	}, verifier, limiter)

	// 7) Ops handlers (the five ops endpoints + identity block).
	opsH := ops.New(ops.Deps{
		Settings:  settings,
		Code:      codeVersion,
		BootTime:  bootTime,
		DataDir:   "data",
		Redis:     rdb,
		JWKS:      verifier,
		Logs:      sinks,
		Upstreams: settings.Upstreams,
	})

	// 8) Build the Echo instance (APM outermost) and serve.
	e := app.New(app.Deps{
		Settings: settings,
		Tracer:   apm.DefaultTracer(),
		Ops:      opsH.Handlers(),
		Routes:   router.Routes(),
	})

	errCh := make(chan error, 1)
	go func() {
		addr := fmt.Sprintf("0.0.0.0:%d", settings.ServicePort)
		slog.Info("http server listening", "name", "gateway.http", "addr", addr)
		if err := e.Start(addr); err != nil {
			errCh <- err
		}
	}()

	// 9) Block on SIGTERM, then graceful shutdown.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	select {
	case sig := <-stop:
		slog.Info("shutdown signal", "name", "gateway.main", "sig", sig.String())
	case err := <-errCh:
		return fmt.Errorf("http listen: %w", err)
	}
	shutCtx, shutCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutCancel()
	_ = e.Shutdown(shutCtx)
	cancel()
	return nil
}
