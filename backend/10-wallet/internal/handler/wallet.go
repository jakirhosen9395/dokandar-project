package handler

import (
	"errors"

	"github.com/gofiber/fiber/v3"
	"github.com/google/uuid"

	"github.com/dokandar/dokandar-wallet/internal/auth"
	"github.com/dokandar/dokandar-wallet/internal/service"
)

type Wallet struct {
	Svc *service.Service
}

// jerr writes the standard error envelope {error:{code,message,request_id}}.
func jerr(c fiber.Ctx, status int, code, message string) error {
	rid, _ := c.Locals("request_id").(string)
	return c.Status(status).JSON(fiber.Map{
		"error": fiber.Map{"code": code, "message": message, "request_id": rid},
	})
}

// uid extracts the authenticated user's UUID from the verified JWT sub.
func uid(c fiber.Ctx) (uuid.UUID, error) {
	claims, ok := auth.UserClaims(c)
	if !ok {
		return uuid.Nil, errors.New("no user claims")
	}
	sub, _ := claims["sub"].(string)
	return uuid.Parse(sub)
}

// GET /api/v1/wallet/me — get-or-create the caller's wallet.
func (h *Wallet) Me(c fiber.Ctx) error {
	userID, err := uid(c)
	if err != nil {
		return jerr(c, fiber.StatusUnauthorized, "missing_token", "invalid subject")
	}
	w, err := h.Svc.GetOrCreate(c.Context(), userID)
	if err != nil {
		return jerr(c, fiber.StatusInternalServerError, "internal_error", "could not load wallet")
	}
	return c.JSON(w)
}

// GET /api/v1/wallet/me/entries?size=N — ledger history (DESC), size 1..200.
func (h *Wallet) Entries(c fiber.Ctx) error {
	userID, err := uid(c)
	if err != nil {
		return jerr(c, fiber.StatusUnauthorized, "missing_token", "invalid subject")
	}
	limit := fiber.Query[int](c, "size", 50)
	if limit < 1 {
		limit = 1
	}
	if limit > 200 {
		limit = 200
	}
	es, err := h.Svc.Entries(c.Context(), userID, limit)
	if err != nil {
		return jerr(c, fiber.StatusInternalServerError, "internal_error", "could not load entries")
	}
	if es == nil {
		es = []service.Entry{}
	}
	return c.JSON(es)
}

type topupBody struct {
	AmountMinor int64 `json:"amount_minor"`
}

// POST /api/v1/wallet/me/topup — Idempotency-Key header required; amount>0;
// 201 on success; 409 on cap.
func (h *Wallet) Topup(c fiber.Ctx) error {
	userID, err := uid(c)
	if err != nil {
		return jerr(c, fiber.StatusUnauthorized, "missing_token", "invalid subject")
	}
	idem := c.Get("Idempotency-Key")
	if idem == "" {
		return jerr(c, fiber.StatusBadRequest, "missing_idempotency_key", "Idempotency-Key header required")
	}
	var b topupBody
	if err := c.Bind().Body(&b); err != nil || b.AmountMinor <= 0 {
		return jerr(c, fiber.StatusUnprocessableEntity, "invalid_request", "amount_minor must be > 0")
	}
	w, err := h.Svc.Topup(c.Context(), userID, b.AmountMinor, idem)
	if err != nil {
		if errors.Is(err, service.ErrWalletMaxExceeded) {
			return jerr(c, fiber.StatusConflict, "wallet_max_exceeded", "top-up would exceed the 50,000 BDT cap")
		}
		return jerr(c, fiber.StatusInternalServerError, "internal_error", "topup failed")
	}
	c.Status(fiber.StatusCreated)
	return c.JSON(w)
}

// GET /api/v1/wallet/cashback-rules — public, active rules only.
func (h *Wallet) ListCashbackRules(c fiber.Ctx) error {
	out, err := h.Svc.ListCashbackRules(c.Context())
	if err != nil {
		return jerr(c, fiber.StatusInternalServerError, "internal_error", "could not load rules")
	}
	if out == nil {
		out = []service.CashbackRule{}
	}
	return c.JSON(out)
}

// ----- East-west (internal; x-internal-token) -------------------------------

// POST /api/v1/wallet/debit — saga redemption. idempotency_key min 8 chars.
func (h *Wallet) Debit(c fiber.Ctx) error {
	var req service.DebitReq
	if err := c.Bind().Body(&req); err != nil {
		return jerr(c, fiber.StatusUnprocessableEntity, "invalid_request", "invalid body")
	}
	if len(req.IdempotencyKey) < 8 {
		return jerr(c, fiber.StatusUnprocessableEntity, "invalid_request", "idempotency_key required (min 8 chars)")
	}
	if req.AmountMinor <= 0 {
		return jerr(c, fiber.StatusUnprocessableEntity, "invalid_request", "amount_minor must be > 0")
	}
	w, err := h.Svc.Debit(c.Context(), req)
	if err != nil {
		switch {
		case errors.Is(err, service.ErrInsufficientBalance):
			return jerr(c, fiber.StatusConflict, "insufficient_balance", "not enough available balance")
		case errors.Is(err, service.ErrInvalidAmount):
			return jerr(c, fiber.StatusUnprocessableEntity, "invalid_request", "amount_minor must be > 0")
		default:
			return jerr(c, fiber.StatusInternalServerError, "internal_error", "debit failed")
		}
	}
	return c.JSON(w)
}

// POST /api/v1/wallet/credit — saga compensation / refund-to-wallet.
func (h *Wallet) Credit(c fiber.Ctx) error {
	var req service.CreditReq
	if err := c.Bind().Body(&req); err != nil {
		return jerr(c, fiber.StatusUnprocessableEntity, "invalid_request", "invalid body")
	}
	if len(req.IdempotencyKey) < 8 {
		return jerr(c, fiber.StatusUnprocessableEntity, "invalid_request", "idempotency_key required (min 8 chars)")
	}
	if req.AmountMinor <= 0 {
		return jerr(c, fiber.StatusUnprocessableEntity, "invalid_request", "amount_minor must be > 0")
	}
	w, err := h.Svc.Credit(c.Context(), req)
	if err != nil {
		switch {
		case errors.Is(err, service.ErrWalletMaxExceeded):
			return jerr(c, fiber.StatusConflict, "wallet_max_exceeded", "credit would exceed the 50,000 BDT cap")
		case errors.Is(err, service.ErrInvalidAmount):
			return jerr(c, fiber.StatusUnprocessableEntity, "invalid_request", "amount_minor must be > 0")
		default:
			return jerr(c, fiber.StatusInternalServerError, "internal_error", "credit failed")
		}
	}
	return c.JSON(w)
}

// GET /api/v1/wallet/balance/:user_id — authoritative read (get-or-create).
func (h *Wallet) Balance(c fiber.Ctx) error {
	userID, err := uuid.Parse(c.Params("user_id"))
	if err != nil {
		return jerr(c, fiber.StatusBadRequest, "bad_request", "invalid user_id")
	}
	w, err := h.Svc.GetOrCreate(c.Context(), userID)
	if err != nil {
		return jerr(c, fiber.StatusInternalServerError, "internal_error", "could not load wallet")
	}
	return c.JSON(w)
}
