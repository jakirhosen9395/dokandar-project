// Package infra wires the external resources: PostgreSQL (pgxpool), Redis.
// Each function returns an error so main() decides what to do (we panic on
// the ones that gate startup).
package infra

import (
	"context"
	"fmt"
	"log/slog"
	"net/url"
	"strings"
	"time"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/postgres"
	"github.com/golang-migrate/migrate/v4/source/iofs"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	migs "github.com/dokandar/dokandar-profile/migrations"
)

// NewPool opens a pgxpool against the service DSN. The DSN format in env
// files mirrors what the other services use (postgresql+asyncpg://...);
// strip the SQLAlchemy-style driver suffix to make it pgx-compatible.
func NewPool(ctx context.Context, dsn string) (*pgxpool.Pool, error) {
	cleaned := strings.Replace(dsn, "postgresql+asyncpg://", "postgres://", 1)
	cfg, err := pgxpool.ParseConfig(cleaned)
	if err != nil {
		return nil, fmt.Errorf("pgxpool parse: %w", err)
	}
	cfg.MaxConns = 10
	cfg.MaxConnLifetime = 30 * time.Minute
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("pgxpool connect: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("postgres ping: %w", err)
	}
	return pool, nil
}

// EnsureDB creates the service DB if it doesn't exist (using the admin DSN
// rewritten to point at the bootstrap `postgres` DB), then runs the embedded
// migrations against the service DSN. Idempotent — safe on every boot.
func EnsureDB(ctx context.Context, adminDSN, serviceDSN string) error {
	cleanedAdmin := strings.Replace(adminDSN, "postgresql+asyncpg://", "postgres://", 1)
	cleanedSvc := strings.Replace(serviceDSN, "postgresql+asyncpg://", "postgres://", 1)

	u, err := url.Parse(cleanedAdmin)
	if err != nil {
		return fmt.Errorf("admin dsn parse: %w", err)
	}
	u.Path = "/postgres"
	cleanedAdmin = u.String()

	su, err := url.Parse(cleanedSvc)
	if err != nil {
		return fmt.Errorf("service dsn parse: %w", err)
	}
	targetDB := strings.TrimPrefix(su.Path, "/")
	if targetDB == "" {
		return fmt.Errorf("service DSN has no database name")
	}

	if err := createDBIfMissing(ctx, cleanedAdmin, targetDB); err != nil {
		return err
	}
	return runMigrations(cleanedSvc)
}

func createDBIfMissing(ctx context.Context, adminDSN, target string) error {
	conn, err := pgx.Connect(ctx, adminDSN)
	if err != nil {
		return fmt.Errorf("admin connect: %w", err)
	}
	defer conn.Close(ctx)

	var exists bool
	if err := conn.QueryRow(ctx,
		"SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname=$1)", target,
	).Scan(&exists); err != nil {
		return fmt.Errorf("check database: %w", err)
	}
	if exists {
		slog.Info("ensure_db: database already exists", "name", target)
		return nil
	}
	slog.Info("ensure_db: creating database", "name", target)
	if _, err := conn.Exec(ctx, fmt.Sprintf(`CREATE DATABASE "%s"`, target)); err != nil {
		return fmt.Errorf("create database: %w", err)
	}
	return nil
}

func runMigrations(serviceDSN string) error {
	src, err := iofs.New(migs.FS, ".")
	if err != nil {
		return fmt.Errorf("migrations iofs: %w", err)
	}
	// The standard "postgres://" scheme is what migrate's postgres driver
	// (lib/pq under the hood) wants. Our application code uses pgx/v5 via
	// pgxpool; migrations use a separate, short-lived lib/pq connection
	// driven by golang-migrate — they don't conflict.
	//
	// lib/pq defaults sslmode=require, which fails against components hosts
	// that run plaintext PG. Force sslmode=disable on the migration URL
	// only — the application pgxpool DSN is unchanged.
	mDSN := serviceDSN
	if !strings.Contains(mDSN, "sslmode=") {
		if strings.Contains(mDSN, "?") {
			mDSN += "&sslmode=disable"
		} else {
			mDSN += "?sslmode=disable"
		}
	}
	m, err := migrate.NewWithSourceInstance("iofs", src, mDSN)
	if err != nil {
		return fmt.Errorf("migrate new: %w", err)
	}
	defer m.Close()

	if err := m.Up(); err != nil && err != migrate.ErrNoChange {
		return fmt.Errorf("migrate up: %w", err)
	}
	slog.Info("ensure_db: migrations at head")
	return nil
}
