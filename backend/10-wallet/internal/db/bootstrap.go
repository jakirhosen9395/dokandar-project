package db

import (
	"context"
	"embed"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

//go:embed migrations_embed/*.sql
var migrationsFS embed.FS

// EnsureDB connects to the admin `postgres` database, creates the service
// database if it is missing (idempotent; tolerates concurrent creators via
// SQLSTATE 42P04 = duplicate_database), then applies the embedded migrations.
// It runs BEFORE the HTTP/gRPC listeners bind.
//
// adminDSN must point at the `postgres` database; dbName is the service DB
// (e.g. dokandar_wallet_dev) and is validated against an identifier whitelist
// before interpolation (it cannot be parameterized in CREATE DATABASE).
func EnsureDB(ctx context.Context, adminDSN, dbName, appDSN string) error {
	if !isValidIdent(dbName) {
		return fmt.Errorf("invalid db name: %q", dbName)
	}

	conn, err := pgx.Connect(ctx, adminDSN)
	if err != nil {
		return fmt.Errorf("admin connect: %w", err)
	}
	exists := false
	{
		var one int
		row := conn.QueryRow(ctx, "SELECT 1 FROM pg_database WHERE datname = $1", dbName)
		switch err := row.Scan(&one); {
		case err == nil:
			exists = true
		case errors.Is(err, pgx.ErrNoRows):
			exists = false
		default:
			_ = conn.Close(ctx)
			return fmt.Errorf("probe db: %w", err)
		}
	}
	if !exists {
		if _, err := conn.Exec(ctx, fmt.Sprintf(`CREATE DATABASE "%s"`, dbName)); err != nil {
			var pgErr *pgconn.PgError
			if !(errors.As(err, &pgErr) && pgErr.Code == "42P04") {
				_ = conn.Close(ctx)
				return fmt.Errorf("create db: %w", err)
			}
		}
	}
	_ = conn.Close(ctx)

	return ApplyMigrations(ctx, appDSN)
}

// ApplyMigrations runs every embedded .sql file (lexical order) against the
// service database. All statements are idempotent (CREATE TABLE IF NOT EXISTS,
// guarded seed insert), so re-running on every boot is safe.
func ApplyMigrations(ctx context.Context, appDSN string) error {
	entries, err := migrationsFS.ReadDir("migrations_embed")
	if err != nil {
		return fmt.Errorf("read migrations: %w", err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && len(e.Name()) > 4 && e.Name()[len(e.Name())-4:] == ".sql" {
			names = append(names, e.Name())
		}
	}
	// embed.FS.ReadDir already returns entries sorted by filename.
	conn, err := pgx.Connect(ctx, appDSN)
	if err != nil {
		return fmt.Errorf("migrate connect: %w", err)
	}
	defer conn.Close(ctx)
	for _, n := range names {
		b, err := migrationsFS.ReadFile("migrations_embed/" + n)
		if err != nil {
			return err
		}
		if _, err := conn.Exec(ctx, string(b)); err != nil {
			return fmt.Errorf("migration %s: %w", n, err)
		}
	}
	return nil
}

// isValidIdent allows only [A-Za-z_][A-Za-z0-9_]* — safe to interpolate into
// CREATE DATABASE.
func isValidIdent(s string) bool {
	if s == "" {
		return false
	}
	for i, c := range s {
		ok := c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (i > 0 && c >= '0' && c <= '9')
		if !ok {
			return false
		}
	}
	return true
}
