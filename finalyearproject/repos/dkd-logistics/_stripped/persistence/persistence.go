package persistence

import "context"

// DB is the persistence abstraction. The concrete driver (pgx for Postgres) is wired at the
// integration point. No business repositories are defined here.
type DB interface {
	Ping(ctx context.Context) error
	WithTx(ctx context.Context, fn func(tx Tx) error) error
	Close() error
}

type Tx interface {
	Exec(ctx context.Context, sql string, args ...any) error
}

// Repository is the base every context repository embeds; it carries the DB handle and the tx helper.
type Repository struct {
	DB DB
}

func (r Repository) InTx(ctx context.Context, fn func(tx Tx) error) error {
	return r.DB.WithTx(ctx, fn)
}

// Migrator runs ordered, idempotent schema migrations at startup. The driver supplies Apply.
type Migrator interface {
	Apply(ctx context.Context) error
}
