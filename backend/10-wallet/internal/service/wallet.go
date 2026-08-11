// Package service holds the double-entry wallet ledger. Money is integer
// paisa; the 50,000 BDT cap (5,000,000 paisa) and the debit-XOR-credit rule
// are enforced in Postgres (DB CHECK constraints) — this code is the
// SERIALIZABLE writer with idempotency + outbox in one transaction.
package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/redis/go-redis/v9"
	"gorm.io/gorm"

	walletdb "github.com/dokandar/dokandar-wallet/internal/db"
	"github.com/dokandar/dokandar-wallet/internal/observability"
)

// ----- DTOs (response shapes the handlers + gRPC serialise) -----------------

type Wallet struct {
	UserID         uuid.UUID `json:"user_id"`
	Currency       string    `json:"currency"`
	Status         string    `json:"status"`
	BalanceMinor   int64     `json:"balance_minor"`
	AvailableMinor int64     `json:"available_minor"`
	Version        int64     `json:"version"`
}

type Entry struct {
	ID             uuid.UUID  `json:"id"`
	WalletUserID   uuid.UUID  `json:"wallet_user_id"`
	DebitMinor     int64      `json:"debit_minor"`
	CreditMinor    int64      `json:"credit_minor"`
	Kind           string     `json:"kind"`
	OrderID        *uuid.UUID `json:"order_id,omitempty"`
	IdempotencyKey string     `json:"idempotency_key"`
	PostedAt       time.Time  `json:"posted_at"`
}

type CashbackRule struct {
	ID               uuid.UUID `json:"id"`
	Trigger          string    `json:"trigger"`
	FundedBy         string    `json:"funded_by"`
	RewardKind       string    `json:"reward_kind"`
	RewardValue      int64     `json:"reward_value"`
	RewardCapMinor   *int64    `json:"reward_cap_minor,omitempty"`
	MinSubtotalMinor *int64    `json:"min_subtotal_minor,omitempty"`
	MaxPerUser       int       `json:"max_per_user"`
}

type DebitReq struct {
	UserID         uuid.UUID  `json:"user_id"`
	AmountMinor    int64      `json:"amount_minor"`
	IdempotencyKey string     `json:"idempotency_key"`
	OrderID        *uuid.UUID `json:"order_id,omitempty"`
}

type CreditReq struct {
	UserID         uuid.UUID  `json:"user_id"`
	AmountMinor    int64      `json:"amount_minor"`
	IdempotencyKey string     `json:"idempotency_key"`
	Kind           string     `json:"kind"`
	OrderID        *uuid.UUID `json:"order_id,omitempty"`
}

// ----- Service --------------------------------------------------------------

type Topics struct {
	Credited string
	Debited  string
	Cashback string
}

// Service is the ledger. It owns the GORM handle + Redis (Redlock) + the cap.
type Service struct {
	DB           *gorm.DB
	Redis        *redis.Client
	WalletMaxMin int64
	Topics       Topics
}

var (
	ErrInsufficientBalance = errors.New("insufficient_balance")
	ErrWalletMaxExceeded   = errors.New("wallet_max_exceeded")
	ErrInvalidAmount       = errors.New("invalid_amount")
)

const lockTTL = 5 * time.Second

func lockKey(userID string) string { return "wallet:lock:" + userID }

// isSerializationFailure reports a Postgres 40001 (serialization_failure) or
// 40P01 (deadlock_detected) — both are retryable for a SERIALIZABLE tx.
func isSerializationFailure(err error) bool {
	var pg *pgconn.PgError
	return errors.As(err, &pg) && (pg.Code == "40001" || pg.Code == "40P01")
}

// postLedger runs fn inside a SERIALIZABLE transaction, retrying the whole
// transaction on 40001/40P01 with quadratic backoff. ctx carries the APM
// transaction so any GORM spans nest under the HTTP/gRPC transaction.
func (s *Service) postLedger(ctx context.Context, fn func(tx *gorm.DB) error) error {
	const maxAttempts = 5
	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		tx := s.DB.WithContext(ctx).Begin(&sql.TxOptions{Isolation: sql.LevelSerializable})
		if tx.Error != nil {
			return tx.Error
		}
		err := fn(tx)
		if err != nil {
			tx.Rollback()
			if isSerializationFailure(err) {
				lastErr = err
				time.Sleep(time.Duration(attempt*attempt) * 5 * time.Millisecond)
				continue
			}
			return err
		}
		if err := tx.Commit().Error; err != nil {
			if isSerializationFailure(err) {
				lastErr = err
				time.Sleep(time.Duration(attempt*attempt) * 5 * time.Millisecond)
				continue
			}
			return err
		}
		return nil
	}
	return fmt.Errorf("ledger post exhausted %d serializable retries: %w", maxAttempts, lastErr)
}

// ----- Reads ----------------------------------------------------------------

// GetOrCreate ensures the wallet + balance rows exist and returns the joined
// wallet view. Used by GET /me and GET /balance/:user_id.
func (s *Service) GetOrCreate(ctx context.Context, userID uuid.UUID) (*Wallet, error) {
	db := s.DB.WithContext(ctx)
	if err := db.Exec(
		`INSERT INTO wallets (user_id) VALUES (?) ON CONFLICT (user_id) DO NOTHING`, userID).Error; err != nil {
		return nil, err
	}
	if err := db.Exec(
		`INSERT INTO wallet_balances (user_id) VALUES (?) ON CONFLICT (user_id) DO NOTHING`, userID).Error; err != nil {
		return nil, err
	}
	return loadWallet(db, userID)
}

func (s *Service) Entries(ctx context.Context, userID uuid.UUID, limit int) ([]Entry, error) {
	db := s.DB.WithContext(ctx)
	rows, err := db.Raw(`
		SELECT id, wallet_user_id, debit_minor, credit_minor, kind, order_id, idempotency_key, posted_at
		FROM wallet_entries WHERE wallet_user_id = ? ORDER BY posted_at DESC LIMIT ?`,
		userID, limit).Rows()
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Entry{}
	for rows.Next() {
		var e Entry
		var orderID *uuid.UUID
		if err := rows.Scan(&e.ID, &e.WalletUserID, &e.DebitMinor, &e.CreditMinor, &e.Kind, &orderID, &e.IdempotencyKey, &e.PostedAt); err != nil {
			return nil, err
		}
		e.OrderID = orderID
		out = append(out, e)
	}
	return out, rows.Err()
}

func (s *Service) ListCashbackRules(ctx context.Context) ([]CashbackRule, error) {
	db := s.DB.WithContext(ctx)
	rows, err := db.Raw(`
		SELECT id, trigger, funded_by, reward_kind, reward_value, reward_cap_minor, min_subtotal_minor, max_per_user
		FROM cashback_rules WHERE state = 'active' ORDER BY created_at DESC`).Rows()
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []CashbackRule{}
	for rows.Next() {
		var r CashbackRule
		if err := rows.Scan(&r.ID, &r.Trigger, &r.FundedBy, &r.RewardKind, &r.RewardValue, &r.RewardCapMinor, &r.MinSubtotalMinor, &r.MaxPerUser); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// ----- Writes (the money paths) ---------------------------------------------

// Debit moves money out (kind = order_payment). Idempotency is resolved BEFORE
// the sufficiency check: a replayed debit (same idempotency_key) returns the
// current wallet unchanged — it must NOT 409 even once the balance is spent,
// or the saga would mistake a successful debit for a failure.
func (s *Service) Debit(ctx context.Context, req DebitReq) (*Wallet, error) {
	if req.AmountMinor <= 0 {
		return nil, ErrInvalidAmount
	}
	tok, _ := walletdb.AcquireLock(ctx, s.Redis, lockKey(req.UserID.String()), lockTTL)
	defer walletdb.ReleaseLock(ctx, s.Redis, lockKey(req.UserID.String()), tok)

	insufficient := false
	err := s.postLedger(ctx, func(tx *gorm.DB) error {
		if err := ensureRows(tx, req.UserID); err != nil {
			return err
		}
		// Idempotency FIRST: a no-op on replay (RowsAffected == 0).
		res := tx.Exec(`
			INSERT INTO wallet_entries (wallet_user_id, debit_minor, kind, order_id, idempotency_key)
			VALUES (?, ?, 'order_payment', ?, ?)
			ON CONFLICT (idempotency_key) DO NOTHING`,
			req.UserID, req.AmountMinor, req.OrderID, req.IdempotencyKey)
		if res.Error != nil {
			return res.Error
		}
		if res.RowsAffected == 0 {
			return nil // replay — leave balance untouched
		}
		// Fresh debit: sufficiency check on the current balance.
		w, err := loadWallet(tx, req.UserID)
		if err != nil {
			return err
		}
		if w.AvailableMinor < req.AmountMinor {
			insufficient = true
			return ErrInsufficientBalance
		}
		if err := tx.Exec(`
			UPDATE wallet_balances
			SET balance_minor = balance_minor - ?, available_minor = available_minor - ?,
			    version = version + 1, updated_at = now()
			WHERE user_id = ?`, req.AmountMinor, req.AmountMinor, req.UserID).Error; err != nil {
			return err
		}
		return emitOutbox(tx, s.Topics.Debited, req.UserID.String(), map[string]any{
			"event": "WalletDebited", "user_id": req.UserID.String(), "amount_minor": req.AmountMinor,
		})
	})
	if err != nil {
		if insufficient || errors.Is(err, ErrInsufficientBalance) {
			observability.WalletInsufficient.WithLabelValues(observability.ServiceVal).Inc()
			return nil, ErrInsufficientBalance
		}
		return nil, err
	}
	observability.WalletDebitsTotal.WithLabelValues(observability.ServiceVal, "order_payment").Inc()
	slog.InfoContext(ctx, "wallet debited", "name", "wallet.ledger", "user_id", req.UserID.String(), "amount_minor", req.AmountMinor)
	return s.GetOrCreate(ctx, req.UserID)
}

// Credit moves money in (default kind = refund_to_wallet). Idempotency before
// the cap check, mirroring Debit.
func (s *Service) Credit(ctx context.Context, req CreditReq) (*Wallet, error) {
	if req.AmountMinor <= 0 {
		return nil, ErrInvalidAmount
	}
	kind := req.Kind
	if kind == "" {
		kind = "refund_to_wallet"
	}
	tok, _ := walletdb.AcquireLock(ctx, s.Redis, lockKey(req.UserID.String()), lockTTL)
	defer walletdb.ReleaseLock(ctx, s.Redis, lockKey(req.UserID.String()), tok)

	overCap := false
	err := s.postLedger(ctx, func(tx *gorm.DB) error {
		if err := ensureRows(tx, req.UserID); err != nil {
			return err
		}
		res := tx.Exec(`
			INSERT INTO wallet_entries (wallet_user_id, credit_minor, kind, order_id, idempotency_key)
			VALUES (?, ?, ?, ?, ?)
			ON CONFLICT (idempotency_key) DO NOTHING`,
			req.UserID, req.AmountMinor, kind, req.OrderID, req.IdempotencyKey)
		if res.Error != nil {
			return res.Error
		}
		if res.RowsAffected == 0 {
			return nil // replay
		}
		w, err := loadWallet(tx, req.UserID)
		if err != nil {
			return err
		}
		if w.BalanceMinor+req.AmountMinor > s.WalletMaxMin {
			overCap = true
			return ErrWalletMaxExceeded
		}
		if err := tx.Exec(`
			UPDATE wallet_balances
			SET balance_minor = balance_minor + ?, available_minor = available_minor + ?,
			    version = version + 1, updated_at = now()
			WHERE user_id = ?`, req.AmountMinor, req.AmountMinor, req.UserID).Error; err != nil {
			return err
		}
		return emitOutbox(tx, s.Topics.Credited, req.UserID.String(), map[string]any{
			"event": "WalletCredited", "user_id": req.UserID.String(), "amount_minor": req.AmountMinor, "kind": kind,
		})
	})
	if err != nil {
		if overCap || errors.Is(err, ErrWalletMaxExceeded) {
			return nil, ErrWalletMaxExceeded
		}
		return nil, err
	}
	observability.WalletCreditsTotal.WithLabelValues(observability.ServiceVal, kind).Inc()
	slog.InfoContext(ctx, "wallet credited", "name", "wallet.ledger", "user_id", req.UserID.String(), "amount_minor", req.AmountMinor, "kind", kind)
	return s.GetOrCreate(ctx, req.UserID)
}

// Topup is a customer-facing credit with kind = topup (subject to the cap).
func (s *Service) Topup(ctx context.Context, userID uuid.UUID, amount int64, idemKey string) (*Wallet, error) {
	return s.Credit(ctx, CreditReq{UserID: userID, AmountMinor: amount, IdempotencyKey: idemKey, Kind: "topup"})
}

// GrantCashbackForOrder applies every active rule for a placed order. Dedup is
// the wallet_entries UNIQUE idempotency_key on "cashback:<ruleID>:<orderID>" →
// exactly one grant per rule+order regardless of redelivery.
func (s *Service) GrantCashbackForOrder(ctx context.Context, userID, orderID uuid.UUID, subtotal int64) error {
	rules, err := s.ListCashbackRules(ctx)
	if err != nil {
		return err
	}
	for _, r := range rules {
		if r.MinSubtotalMinor != nil && *r.MinSubtotalMinor > subtotal {
			continue
		}
		var amt int64
		if r.RewardKind == "percent_back" {
			amt = subtotal * r.RewardValue / 100
		} else {
			amt = r.RewardValue
		}
		if r.RewardCapMinor != nil && amt > *r.RewardCapMinor {
			amt = *r.RewardCapMinor
		}
		if amt <= 0 {
			continue
		}
		oid := orderID
		idem := fmt.Sprintf("cashback:%s:%s", r.ID.String(), orderID.String())
		if _, err := s.Credit(ctx, CreditReq{
			UserID: userID, AmountMinor: amt, IdempotencyKey: idem, Kind: "cashback", OrderID: &oid,
		}); err != nil {
			// over-cap / transient — swallow per choreography (best-effort grant).
			continue
		}
		observability.WalletCashbackGranted.WithLabelValues(observability.ServiceVal).Inc()
	}
	return nil
}

// ----- helpers --------------------------------------------------------------

// ensureRows upserts the wallet + balance shells inside a tx (idempotent).
func ensureRows(tx *gorm.DB, userID uuid.UUID) error {
	if err := tx.Exec(
		`INSERT INTO wallets (user_id) VALUES (?) ON CONFLICT (user_id) DO NOTHING`, userID).Error; err != nil {
		return err
	}
	return tx.Exec(
		`INSERT INTO wallet_balances (user_id) VALUES (?) ON CONFLICT (user_id) DO NOTHING`, userID).Error
}

// loadWallet reads the joined wallet view on the given handle (pool or tx).
func loadWallet(db *gorm.DB, userID uuid.UUID) (*Wallet, error) {
	w := &Wallet{}
	row := db.Raw(`
		SELECT w.user_id, w.currency, w.status, b.balance_minor, b.available_minor, b.version
		FROM wallets w JOIN wallet_balances b USING (user_id) WHERE w.user_id = ?`, userID).Row()
	if err := row.Scan(&w.UserID, &w.Currency, &w.Status, &w.BalanceMinor, &w.AvailableMinor, &w.Version); err != nil {
		return nil, err
	}
	return w, nil
}

// emitOutbox writes the transactional-outbox row in the SAME tx as the ledger
// move. The relay later ships it to Kafka (acks=all) and marks sent_at.
func emitOutbox(tx *gorm.DB, topic, key string, payload map[string]any) error {
	b, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	return tx.Exec(`INSERT INTO outbox (topic, key, payload) VALUES (?, ?, ?::jsonb)`,
		topic, key, string(b)).Error
}

// CountPending returns the number of un-shipped outbox rows (the
// wallet_outbox_pending gauge source).
func (s *Service) CountPending(ctx context.Context) (int64, error) {
	var n int64
	err := s.DB.WithContext(ctx).Raw(`SELECT count(*) FROM outbox WHERE sent_at IS NULL`).Scan(&n).Error
	return n, err
}
