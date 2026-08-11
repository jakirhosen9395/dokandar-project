// dokandar-profile entrypoint. Wires the dependency graph + lifespan
// and blocks until SIGTERM. HTTP on SERVICE_PORT, gRPC on GRPC_PORT.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	v1 "github.com/dokandar/dokandar-profile/internal/api/v1"
	"github.com/dokandar/dokandar-profile/internal/app"
	"github.com/dokandar/dokandar-profile/internal/auth"
	"github.com/dokandar/dokandar-profile/internal/config"
	"github.com/dokandar/dokandar-profile/internal/domain/address"
	"github.com/dokandar/dokandar-profile/internal/domain/geo"
	"github.com/dokandar/dokandar-profile/internal/domain/outbox"
	"github.com/dokandar/dokandar-profile/internal/domain/profile"
	"github.com/dokandar/dokandar-profile/internal/grpcserver"
	"github.com/dokandar/dokandar-profile/internal/infra"
	"github.com/dokandar/dokandar-profile/internal/messaging"
	"github.com/dokandar/dokandar-profile/internal/observability"
	"github.com/dokandar/dokandar-profile/internal/ops"
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
	_ = os.Setenv("CODE_VERSION_RUNTIME", codeVersion)

	rootCtx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// 1) Logging.
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

	slog.Info("profile starting up", "name", "profile.main",
		"code_version", codeVersion, "env", settings.AppEnv, "tenant", settings.Tenant)

	// 2) APM.
	if err := observability.SetupAPM(
		settings.APMServiceName, codeVersion, settings.AppEnv,
		settings.APMServerURL, settings.APMSecretToken,
	); err != nil {
		slog.Warn("apm setup failed (continuing)", "name", "profile.main", "err", err)
	}

	// 3) ensure_db.
	if err := infra.EnsureDB(rootCtx, settings.PostgresAdminDSN, settings.PostgresDSN); err != nil {
		return fmt.Errorf("ensure_db: %w", err)
	}
	pg, err := infra.NewPool(rootCtx, settings.PostgresDSN)
	if err != nil {
		return fmt.Errorf("postgres: %w", err)
	}
	defer pg.Close()

	rdb, err := infra.NewRedis(rootCtx, settings.RedisURL)
	if err != nil {
		return fmt.Errorf("redis: %w", err)
	}
	defer rdb.Close()

	// 4) JWT verifier (RS256 from auth's public key).
	verifier, err := auth.NewVerifier(settings.JWTPublicKeyB64, settings.JWTIssuer)
	if err != nil {
		return fmt.Errorf("jwt verifier: %w", err)
	}

	// 5) Stores + handlers.
	profileStore := &profile.Store{DB: pg}
	addressStore := &address.Store{DB: pg}
	geoStore := &geo.Store{DB: pg}
	outboxStore := &outbox.Store{DB: pg}

	apiHandler := &v1.Handler{
		Settings:  settings,
		DB:        pg,
		Profiles:  profileStore,
		Addresses: addressStore,
		Geo:       geoStore,
		Outbox:    outboxStore,
		Redis:     rdb,
		CacheTTL:  time.Duration(settings.ProfileCacheTTLSecs) * time.Second,
	}
	opsHandler := &ops.Handler{
		ServiceName: settings.ServiceName,
		CodeVersion: codeVersion,
		EnvVersion:  settings.EnvVersion,
		Tenant:      settings.Tenant,
		Env:         settings.AppEnv,
		BootTime:    bootTime,
		PG:          pg, Redis: rdb, Logs: sinks,
		KafkaBroker:   settings.KafkaBootstrap,
		APMURL:        settings.APMServerURL,
		APMSvcName:    settings.APMServiceName,
		LogsMongoDB:   settings.MongoLogDB,
		LogsESURL:     settings.ElasticSearchURL,
		MediaGRPCAddr: settings.MediaGRPCAddr,
		DataDir:       "./data",
		Outbox:        outboxStore,
	}

	// 6) Multi-topic auth-event consumer (background).
	consumer := &messaging.AuthEventConsumer{
		Brokers: []string{settings.KafkaBootstrap},
		Topics: []string{
			settings.KafkaTopicUser,
			settings.KafkaTopicUserUpdated,
			settings.KafkaTopicKycSubmitted,
			settings.KafkaTopicKycApproved,
			settings.KafkaTopicKycRejected,
		},
		Group: settings.KafkaConsumerGrp,
		Store: profileStore,
	}
	go func() {
		if err := consumer.Run(rootCtx); err != nil {
			slog.Warn("kafka consumer stopped", "name", "profile.kafka", "err", err)
		}
	}()

	// 7) Outbox relay (background).
	relay := &messaging.OutboxRelay{
		Brokers:  []string{settings.KafkaBootstrap},
		Store:    outboxStore,
		Interval: 500 * time.Millisecond,
	}
	go func() {
		if err := relay.Run(rootCtx); err != nil {
			slog.Warn("outbox relay stopped", "name", "profile.outbox", "err", err)
		}
	}()

	// 8) gRPC ProfileQuery (background).
	if settings.GRPCEnabled {
		grpcAddr := fmt.Sprintf("0.0.0.0:%d", settings.GRPCPort)
		go func() {
			srv := &grpcserver.Server{
				Profiles:      profileStore,
				Addresses:     addressStore,
				InternalToken: settings.InternalServiceToken,
			}
			slog.Info("grpc ProfileQuery listening", "name", "profile.grpc", "addr", grpcAddr)
			if err := grpcserver.Serve(rootCtx, grpcAddr, srv); err != nil {
				slog.Warn("grpc server stopped", "name", "profile.grpc", "err", err)
			}
		}()
	}

	// 9) HTTP router.
	r := app.NewRouter()
	r.Get("/ready", opsHandler.Ready)
	r.Get("/health", opsHandler.Health)
	r.Get("/data", opsHandler.Data)
	r.Get("/metrics", func(w http.ResponseWriter, req *http.Request) {
		observability.MetricsHandler().ServeHTTP(w, req)
	})
	r.Get("/docs", app.ServeDocs)
	r.Get("/openapi.json", func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(app.OpenAPISpec(settings.ServiceName, codeVersion,
			settings.EnvVersion, settings.Tenant, settings.AppEnv))
	})
	r.Mount("/api/v1/profile", apiHandler.Routes(verifier.Middleware))

	addr := fmt.Sprintf("0.0.0.0:%d", settings.ServicePort)
	srv := &http.Server{Addr: addr, Handler: r, ReadHeaderTimeout: 5 * time.Second}

	// 10) Run + graceful shutdown.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	errCh := make(chan error, 1)
	go func() {
		slog.Info("http server listening", "name", "profile.http", "addr", addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case sig := <-stop:
		slog.Info("shutdown signal", "name", "profile.main", "sig", sig)
	case err := <-errCh:
		return err
	}
	shutdownCtx, sCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer sCancel()
	_ = srv.Shutdown(shutdownCtx)
	cancel()
	return nil
}
