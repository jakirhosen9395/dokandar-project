// dokandar-wallet entrypoint. Boot order (each dep self-bootstraps before the
// listener binds):
//
//	config → fail-fast SERVICE_NAME → logging (3-sink) → APM → ensure_db
//	→ GORM + Redis → service → outbox relay + order.placed consumer
//	→ gRPC server → Fiber HTTP → block on SIGTERM → graceful shutdown.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gofiber/fiber/v3"
	"go.elastic.co/apm/v2"

	"github.com/dokandar/dokandar-wallet/internal/app"
	"github.com/dokandar/dokandar-wallet/internal/auth"
	"github.com/dokandar/dokandar-wallet/internal/config"
	"github.com/dokandar/dokandar-wallet/internal/db"
	"github.com/dokandar/dokandar-wallet/internal/grpcsrv"
	"github.com/dokandar/dokandar-wallet/internal/handler"
	"github.com/dokandar/dokandar-wallet/internal/messaging"
	"github.com/dokandar/dokandar-wallet/internal/observability"
	"github.com/dokandar/dokandar-wallet/internal/service"
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

	// 1) Logging (3-sink: stdout + Mongo + ES). Before APM so APM-warn logs
	//    already have a sink.
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

	slog.Info("wallet starting up", "name", "wallet.main",
		"code_version", codeVersion, "env", settings.AppEnv, "tenant", settings.Tenant)

	// 2) APM (never blocks boot).
	if err := observability.SetupAPM(
		settings.APMServiceName, codeVersion, settings.AppEnv,
		settings.APMServerURL, settings.APMSecretToken,
	); err != nil {
		slog.Warn("apm setup failed (continuing)", "name", "wallet.main", "err", err.Error())
	}

	// 3) ensure_db (create-if-missing → migrate) BEFORE listeners bind.
	if err := db.EnsureDB(rootCtx, settings.PostgresAdminDSN(), settings.PostgresDB, settings.PostgresDSN()); err != nil {
		return fmt.Errorf("ensure_db: %w", err)
	}

	// 4) GORM + Redis.
	gdb, err := db.OpenGorm(rootCtx, settings.PostgresDSN())
	if err != nil {
		return fmt.Errorf("postgres: %w", err)
	}
	defer db.CloseGorm(gdb)

	rdb, err := db.NewRedis(rootCtx, settings.RedisOptions())
	if err != nil {
		slog.Warn("redis connect failed (degraded — Redlock off)", "name", "wallet.main", "err", err.Error())
	}
	if rdb != nil {
		defer rdb.Close()
	}

	// 5) Auth verifier (RS256 verify-only).
	verifier, err := auth.NewVerifier(settings.JWTPublicKeyB64, settings.JWTIssuer, settings.InternalServiceToken)
	if err != nil {
		return fmt.Errorf("jwt verifier: %w", err)
	}

	// 6) Ledger service.
	svc := &service.Service{
		DB:           gdb,
		Redis:        rdb,
		WalletMaxMin: settings.WalletMaxMinor,
		Topics: service.Topics{
			Credited: settings.KafkaTopicCredited,
			Debited:  settings.KafkaTopicDebited,
			Cashback: settings.KafkaTopicCashback,
		},
	}

	// 7) Outbox relay (background).
	writer := messaging.NewWriter(settings.KafkaBootstrap)
	if writer != nil {
		defer writer.Close()
		relay := &messaging.OutboxRelay{DB: gdb, Writer: writer, Interval: 500 * time.Millisecond, BatchSize: 100}
		go relay.Run(rootCtx)
	}

	// 8) order.placed consumer (background).
	consumer := &messaging.OrderPlacedConsumer{
		Brokers: settings.KafkaBootstrap,
		Topic:   settings.KafkaTopicOrderPlaced,
		GroupID: settings.KafkaConsumerGroup,
		Service: svc,
	}
	go consumer.Run(rootCtx)

	// 9) gRPC server (background).
	if settings.GRPCEnabled {
		grpcAddr := fmt.Sprintf("0.0.0.0:%d", settings.GRPCPort)
		go func() {
			slog.Info("grpc Wallet listening", "name", "wallet.grpc", "addr", grpcAddr)
			if err := grpcsrv.Serve(rootCtx, grpcAddr, settings.InternalServiceToken, &grpcsrv.Server{Svc: svc}); err != nil {
				slog.Warn("grpc server stopped", "name", "wallet.grpc", "err", err.Error())
			}
		}()
	}

	// 10) HTTP (Fiber).
	ops := &handler.Ops{
		Settings: settings,
		DB:       gdb,
		Redis:    rdb,
		Logs:     sinks,
		BootTime: bootTime,
		DataDir:  "data",
	}
	wh := &handler.Wallet{Svc: svc}
	a := app.New(app.Deps{Ops: ops, Wallet: wh, Verifier: verifier, Tracer: apm.DefaultTracer()})

	errCh := make(chan error, 1)
	go func() {
		addr := fmt.Sprintf("0.0.0.0:%d", settings.ServicePort)
		slog.Info("http server listening", "name", "wallet.http", "addr", addr)
		if err := a.Listen(addr, fiber.ListenConfig{DisableStartupMessage: true}); err != nil {
			errCh <- err
		}
	}()

	// 11) Block on SIGTERM, then graceful shutdown.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	select {
	case sig := <-stop:
		slog.Info("shutdown signal", "name", "wallet.main", "sig", sig.String())
	case err := <-errCh:
		return fmt.Errorf("http listen: %w", err)
	}
	_ = a.ShutdownWithTimeout(5 * time.Second)
	cancel()
	return nil
}
