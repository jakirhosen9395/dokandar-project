package db

import (
	"context"
	"fmt"
	"time"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// OpenGorm opens the GORM connection to the service database.
//
//   - SkipDefaultTransaction: we manage ledger transactions explicitly (the
//     SERIALIZABLE post + 40001 retry loop in service.postLedger).
//   - PrepareStmt: cache prepared statements for the hot ledger path.
//   - Logger Warn: only surface slow/erroring queries.
//
// We never AutoMigrate — the CHECK constraints (debit XOR credit, the 0..5,000,000
// balance cap) and UNIQUE idempotency_key are authored in migrations/0001_init.sql
// and applied by EnsureDB before the listener binds.
func OpenGorm(ctx context.Context, dsn string) (*gorm.DB, error) {
	gdb, err := gorm.Open(postgres.Open(dsn), &gorm.Config{
		SkipDefaultTransaction: true,
		PrepareStmt:            true,
		Logger:                 logger.Default.LogMode(logger.Warn),
	})
	if err != nil {
		return nil, fmt.Errorf("gorm open: %w", err)
	}
	sqlDB, err := gdb.DB()
	if err != nil {
		return nil, fmt.Errorf("gorm sql.DB: %w", err)
	}
	sqlDB.SetMaxOpenConns(10)
	sqlDB.SetMaxIdleConns(5)
	sqlDB.SetConnMaxLifetime(30 * time.Minute)

	pctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := sqlDB.PingContext(pctx); err != nil {
		_ = sqlDB.Close()
		return nil, fmt.Errorf("gorm ping: %w", err)
	}
	return gdb, nil
}

// PingGorm is the /ready + /health Postgres probe.
func PingGorm(ctx context.Context, gdb *gorm.DB) error {
	if gdb == nil {
		return fmt.Errorf("nil db")
	}
	sqlDB, err := gdb.DB()
	if err != nil {
		return err
	}
	return sqlDB.PingContext(ctx)
}

// CloseGorm closes the underlying *sql.DB pool.
func CloseGorm(gdb *gorm.DB) {
	if gdb == nil {
		return
	}
	if sqlDB, err := gdb.DB(); err == nil {
		_ = sqlDB.Close()
	}
}
