// Package v1 wires the /api/v1/profile/* HTTP handlers — /me, /me/addresses,
// /me/avatar, /me/addresses/{id}/default, /geo/*, /admin/profiles/{user_id}.
// Auth middleware (when applied) places sub + role on the request context.
package v1

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/dokandar/dokandar-profile/internal/app"
	"github.com/dokandar/dokandar-profile/internal/auth"
	"github.com/dokandar/dokandar-profile/internal/config"
	"github.com/dokandar/dokandar-profile/internal/domain/address"
	"github.com/dokandar/dokandar-profile/internal/domain/geo"
	"github.com/dokandar/dokandar-profile/internal/domain/outbox"
	"github.com/dokandar/dokandar-profile/internal/domain/profile"
	"github.com/dokandar/dokandar-profile/internal/observability"
)

type Handler struct {
	Settings  *config.Settings
	DB        *pgxpool.Pool
	Profiles  *profile.Store
	Addresses *address.Store
	Geo       *geo.Store
	Outbox    *outbox.Store
	Redis     *redis.Client
	CacheTTL  time.Duration
}

// Routes returns a router that:
//   - mounts public geo endpoints (no JWT),
//   - mounts protected /me + /me/addresses + /admin behind `verify`.
func (h *Handler) Routes(verify func(http.Handler) http.Handler) http.Handler {
	r := chi.NewRouter()

	// Public — BD geo reference data for the storefront address picker.
	r.Get("/geo/divisions", h.listDivisions)
	r.Get("/geo/divisions/{code}/districts", h.listDistricts)
	r.Get("/geo/districts/{code}/upazilas", h.listUpazilas)
	r.Get("/geo/upazilas/{code}/unions", h.listUnions)

	// Protected.
	r.Group(func(pr chi.Router) {
		pr.Use(verify)
		pr.Get("/me", h.getMe)
		pr.Patch("/me", h.patchMe)
		pr.Put("/me", h.patchMe) // PUT alias — OpenAPI declares PUT; update is partial either way
		pr.Post("/me/avatar", h.setAvatar)

		pr.Get("/me/addresses", h.listAddresses)
		pr.Post("/me/addresses", h.addAddress)
		pr.Get("/me/addresses/{id}", h.getAddress)
		pr.Patch("/me/addresses/{id}", h.updateAddress)
		pr.Delete("/me/addresses/{id}", h.deleteAddress)
		pr.Post("/me/addresses/{id}/default", h.setDefaultAddress)

		pr.Get("/admin/profiles/{user_id}", h.adminGetProfile)
	})

	return r
}

// ===========================================================================
//  /me
// ===========================================================================

func (h *Handler) getMe(w http.ResponseWriter, r *http.Request) {
	uid, _ := auth.UserID(r.Context())
	body, err := h.composeMeBody(r.Context(), uid)
	if err != nil {
		if errors.Is(err, profile.ErrNotFound) {
			app.WriteError(w, r, http.StatusNotFound, "profile_not_found",
				"Profile not found. The user signup event may not have been consumed yet.", nil)
			return
		}
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	observability.ProfileGet.WithLabelValues("ok").Inc()
	app.PrettyJSON(w, http.StatusOK, body)
}

type patchMeReq struct {
	NameEn         *string `json:"name_en"`
	NameBn         *string `json:"name_bn"`
	Gender         *string `json:"gender"`
	DOB            *string `json:"dob"`     // YYYY-MM-DD
	Locale         *string `json:"locale"`
	WhatsappNumber *string `json:"whatsapp_number"`
}

func (h *Handler) patchMe(w http.ResponseWriter, r *http.Request) {
	uid, _ := auth.UserID(r.Context())
	var in patchMeReq
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		app.WriteError(w, r, http.StatusUnprocessableEntity, "validation_error", "invalid JSON body", nil)
		return
	}
	if in.Locale != nil && *in.Locale != "bn" && *in.Locale != "en" {
		app.WriteError(w, r, http.StatusUnprocessableEntity, "invalid_request",
			"locale must be 'bn' or 'en'", nil)
		return
	}
	if in.Gender != nil && !validGender(*in.Gender) {
		app.WriteError(w, r, http.StatusUnprocessableEntity, "invalid_request",
			"gender must be one of m|f|x|prefer_not_say", nil)
		return
	}
	if in.WhatsappNumber != nil && *in.WhatsappNumber != "" && !address.PhoneRegex.MatchString(*in.WhatsappNumber) {
		app.WriteError(w, r, http.StatusUnprocessableEntity, "phone_invalid",
			"whatsapp_number must match ^01[3-9]\\d{8}$", nil)
		return
	}
	var dob *time.Time
	if in.DOB != nil && *in.DOB != "" {
		t, err := time.Parse("2006-01-02", *in.DOB)
		if err != nil {
			app.WriteError(w, r, http.StatusUnprocessableEntity, "invalid_request",
				"dob must be YYYY-MM-DD", nil)
			return
		}
		dob = &t
	}
	p, err := h.Profiles.Update(r.Context(), uid, profile.UpdateInput{
		NameEn: in.NameEn, NameBn: in.NameBn, Gender: in.Gender, DOB: dob,
		Locale: in.Locale, WhatsappNumber: in.WhatsappNumber,
	})
	if err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	if err := h.emitProfileChanged(r.Context(), p); err != nil {
		// log only — write succeeded already
		_ = err
	}
	h.invalidateProfileCache(r.Context(), uid)
	observability.ProfilePatch.WithLabelValues("ok").Inc()

	body, _ := h.composeMeBody(r.Context(), uid)
	app.PrettyJSON(w, http.StatusOK, body)
}

type setAvatarReq struct {
	MediaID string `json:"media_id"`
}

// setAvatar — spec §8.3. When Media service is deployed, this calls
// media.GetSignedURL to validate the media_id; while it's absent, we
// store the id and construct an avatar_url client-side. (Validation +
// canonical URL come from Media once it lands.)
func (h *Handler) setAvatar(w http.ResponseWriter, r *http.Request) {
	uid, _ := auth.UserID(r.Context())
	var in setAvatarReq
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		app.WriteError(w, r, http.StatusUnprocessableEntity, "validation_error", "invalid JSON body", nil)
		return
	}
	if in.MediaID == "" {
		app.WriteError(w, r, http.StatusUnprocessableEntity, "validation_error", "media_id required", nil)
		return
	}
	p, err := h.Profiles.SetAvatar(r.Context(), uid, in.MediaID)
	if err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	h.invalidateProfileCache(r.Context(), uid)
	app.PrettyJSON(w, http.StatusOK, map[string]any{
		"profile":    p,
		"avatar_url": h.composeAvatarURL(p),
	})
}

// ===========================================================================
//  /me/addresses
// ===========================================================================

func (h *Handler) listAddresses(w http.ResponseWriter, r *http.Request) {
	uid, _ := auth.UserID(r.Context())
	addrs, err := h.Addresses.List(r.Context(), uid)
	if err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	// Hydrate each row with division/district/upazila/union names so the
	// frontend doesn't need a separate lookup.
	items := make([]map[string]any, 0, len(addrs))
	for i := range addrs {
		a := &addrs[i]
		h2, _ := h.Geo.Hydrate(r.Context(), a.DivisionCode, a.DistrictCode, a.UpazilaCode, a.UnionCode)
		items = append(items, hydrate(a, h2))
	}
	app.PrettyJSON(w, http.StatusOK, map[string]any{"items": items})
}

type addressReq struct {
	Label          string   `json:"label"`
	RecipientName  string   `json:"recipient_name"`
	RecipientPhone string   `json:"recipient_phone"`
	DivisionCode   string   `json:"division_code"`
	DistrictCode   string   `json:"district_code"`
	UpazilaCode    string   `json:"upazila_code"`
	UnionCode      *string  `json:"union_code"`
	Line1          string   `json:"line1"`
	Line2          *string  `json:"line2"`
	Landmark       *string  `json:"landmark"`
	Lat            *float64 `json:"lat"`
	Lng            *float64 `json:"lng"`
	IsDefault      bool     `json:"is_default"`
}

func (h *Handler) addAddress(w http.ResponseWriter, r *http.Request) {
	uid, _ := auth.UserID(r.Context())
	var in addressReq
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		app.WriteError(w, r, http.StatusUnprocessableEntity, "validation_error", "invalid JSON body", nil)
		return
	}
	if !address.PhoneRegex.MatchString(in.RecipientPhone) {
		app.WriteError(w, r, http.StatusUnprocessableEntity, "phone_invalid",
			"recipient_phone must match ^01[3-9]\\d{8}$", nil)
		return
	}
	if in.Label == "" || in.RecipientName == "" || in.Line1 == "" ||
		in.DivisionCode == "" || in.DistrictCode == "" || in.UpazilaCode == "" {
		app.WriteError(w, r, http.StatusUnprocessableEntity, "validation_error",
			"label, recipient_name, line1, division_code, district_code, upazila_code are required", nil)
		return
	}
	if err := h.Addresses.VerifyGeoChain(r.Context(), in.DivisionCode, in.DistrictCode, in.UpazilaCode, in.UnionCode); err != nil {
		if errors.Is(err, address.ErrGeoChainInval) {
			app.WriteError(w, r, http.StatusUnprocessableEntity, "geo_chain_invalid",
				"district/upazila/union must match the FK chain under the division", nil)
			return
		}
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}

	tx, err := h.DB.Begin(r.Context())
	if err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	defer tx.Rollback(r.Context())

	id, err := h.Addresses.Add(r.Context(), tx, address.Address{
		UserID: uid, Label: in.Label, RecipientName: in.RecipientName,
		RecipientPhone: in.RecipientPhone, DivisionCode: in.DivisionCode,
		DistrictCode: in.DistrictCode, UpazilaCode: in.UpazilaCode, UnionCode: in.UnionCode,
		Line1: in.Line1, Line2: in.Line2, Landmark: in.Landmark,
		Lat: in.Lat, Lng: in.Lng, IsDefault: in.IsDefault,
	})
	if err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	if in.IsDefault {
		if _, err := tx.Exec(r.Context(),
			`UPDATE profiles SET default_address_id = $2::uuid, updated_at = now() WHERE user_id = $1`,
			uid, id); err != nil {
			app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
			return
		}
	}
	payload, _ := json.Marshal(map[string]any{
		"event": "AddressChanged", "op": "created",
		"user_id": uid, "address_id": id,
		"snapshot": map[string]any{
			"division_code": in.DivisionCode, "district_code": in.DistrictCode,
			"upazila_code": in.UpazilaCode, "union_code": in.UnionCode,
			"lat": in.Lat, "lng": in.Lng, "is_default": in.IsDefault,
		},
	})
	if err := outbox.Insert(r.Context(), tx, h.Settings.KafkaTopicAddressChanged, uid, payload); err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	observability.AddressesAdded.Inc()
	h.invalidateProfileCache(r.Context(), uid)

	got, _ := h.Addresses.Get(r.Context(), uid, id)
	h2, _ := h.Geo.Hydrate(r.Context(), got.DivisionCode, got.DistrictCode, got.UpazilaCode, got.UnionCode)
	app.PrettyJSON(w, http.StatusCreated, hydrate(got, h2))
}

func (h *Handler) getAddress(w http.ResponseWriter, r *http.Request) {
	uid, _ := auth.UserID(r.Context())
	id := chi.URLParam(r, "id")
	if !reqValidUUID(w, r, id) {
		return
	}
	got, err := h.Addresses.Get(r.Context(), uid, id)
	if errors.Is(err, address.ErrNotFound) {
		app.WriteError(w, r, http.StatusNotFound, "not_found", "Address not found.", nil)
		return
	}
	if err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	h2, _ := h.Geo.Hydrate(r.Context(), got.DivisionCode, got.DistrictCode, got.UpazilaCode, got.UnionCode)
	app.PrettyJSON(w, http.StatusOK, hydrate(got, h2))
}

func (h *Handler) updateAddress(w http.ResponseWriter, r *http.Request) {
	uid, _ := auth.UserID(r.Context())
	id := chi.URLParam(r, "id")
	if !reqValidUUID(w, r, id) {
		return
	}
	var in addressReq
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		app.WriteError(w, r, http.StatusUnprocessableEntity, "validation_error", "invalid JSON body", nil)
		return
	}
	if in.RecipientPhone != "" && !address.PhoneRegex.MatchString(in.RecipientPhone) {
		app.WriteError(w, r, http.StatusUnprocessableEntity, "phone_invalid",
			"recipient_phone must match ^01[3-9]\\d{8}$", nil)
		return
	}
	// If any geo code changed, re-verify the chain. For PATCH simplicity:
	// require ALL four codes if ANY are sent.
	anyGeo := in.DivisionCode != "" || in.DistrictCode != "" || in.UpazilaCode != "" || in.UnionCode != nil
	allGeo := in.DivisionCode != "" && in.DistrictCode != "" && in.UpazilaCode != ""
	if anyGeo && !allGeo {
		app.WriteError(w, r, http.StatusUnprocessableEntity, "validation_error",
			"to change geo, send division_code + district_code + upazila_code together (union_code optional)", nil)
		return
	}
	if allGeo {
		if err := h.Addresses.VerifyGeoChain(r.Context(), in.DivisionCode, in.DistrictCode, in.UpazilaCode, in.UnionCode); err != nil {
			if errors.Is(err, address.ErrGeoChainInval) {
				app.WriteError(w, r, http.StatusUnprocessableEntity, "geo_chain_invalid",
					"district/upazila/union must match the FK chain", nil)
				return
			}
			app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
			return
		}
	}

	tx, err := h.DB.Begin(r.Context())
	if err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	defer tx.Rollback(r.Context())

	updated, err := h.Addresses.Update(r.Context(), tx, uid, id, address.Address{
		Label: in.Label, RecipientName: in.RecipientName, RecipientPhone: in.RecipientPhone,
		DivisionCode: in.DivisionCode, DistrictCode: in.DistrictCode,
		UpazilaCode: in.UpazilaCode, UnionCode: in.UnionCode,
		Line1: in.Line1, Line2: in.Line2, Landmark: in.Landmark, Lat: in.Lat, Lng: in.Lng,
	})
	if err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	if !updated {
		app.WriteError(w, r, http.StatusNotFound, "not_found", "Address not found.", nil)
		return
	}
	payload, _ := json.Marshal(map[string]any{
		"event": "AddressChanged", "op": "updated",
		"user_id": uid, "address_id": id,
	})
	if err := outbox.Insert(r.Context(), tx, h.Settings.KafkaTopicAddressChanged, uid, payload); err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	h.invalidateProfileCache(r.Context(), uid)
	got, _ := h.Addresses.Get(r.Context(), uid, id)
	h2, _ := h.Geo.Hydrate(r.Context(), got.DivisionCode, got.DistrictCode, got.UpazilaCode, got.UnionCode)
	app.PrettyJSON(w, http.StatusOK, hydrate(got, h2))
}

func (h *Handler) deleteAddress(w http.ResponseWriter, r *http.Request) {
	uid, _ := auth.UserID(r.Context())
	id := chi.URLParam(r, "id")
	if !reqValidUUID(w, r, id) {
		return
	}

	tx, err := h.DB.Begin(r.Context())
	if err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	defer tx.Rollback(r.Context())

	if err := h.Addresses.SoftDelete(r.Context(), tx, uid, id); err != nil {
		switch {
		case errors.Is(err, address.ErrNotFound):
			app.WriteError(w, r, http.StatusNotFound, "not_found", "Address not found.", nil)
		case errors.Is(err, address.ErrDefaultInUse):
			app.WriteError(w, r, http.StatusConflict, "default_in_use",
				"Set another address as default before deleting this one", nil)
		default:
			app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		}
		return
	}
	payload, _ := json.Marshal(map[string]any{
		"event": "AddressChanged", "op": "deleted", "user_id": uid, "address_id": id,
	})
	_ = outbox.Insert(r.Context(), tx, h.Settings.KafkaTopicAddressChanged, uid, payload)
	if err := tx.Commit(r.Context()); err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	h.invalidateProfileCache(r.Context(), uid)
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) setDefaultAddress(w http.ResponseWriter, r *http.Request) {
	uid, _ := auth.UserID(r.Context())
	id := chi.URLParam(r, "id")
	if !reqValidUUID(w, r, id) {
		return
	}

	tx, err := h.DB.Begin(r.Context())
	if err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	defer tx.Rollback(r.Context())

	if err := h.Addresses.SetDefault(r.Context(), tx, uid, id); err != nil {
		if errors.Is(err, address.ErrNotFound) {
			app.WriteError(w, r, http.StatusNotFound, "not_found", "Address not found.", nil)
			return
		}
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	if _, err := tx.Exec(r.Context(),
		`UPDATE profiles SET default_address_id = $2::uuid, updated_at = now() WHERE user_id = $1`,
		uid, id); err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	payload, _ := json.Marshal(map[string]any{
		"event": "AddressChanged", "op": "default_changed",
		"user_id": uid, "address_id": id,
	})
	_ = outbox.Insert(r.Context(), tx, h.Settings.KafkaTopicAddressChanged, uid, payload)
	if err := tx.Commit(r.Context()); err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	observability.DefaultAddressChanges.Inc()
	h.invalidateProfileCache(r.Context(), uid)
	w.WriteHeader(http.StatusNoContent)
}

// ===========================================================================
//  /geo/*
// ===========================================================================

func (h *Handler) listDivisions(w http.ResponseWriter, r *http.Request) {
	items, err := h.Geo.Divisions(r.Context())
	if err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	app.PrettyJSON(w, http.StatusOK, map[string]any{"items": items})
}
func (h *Handler) listDistricts(w http.ResponseWriter, r *http.Request) {
	items, err := h.Geo.Districts(r.Context(), chi.URLParam(r, "code"))
	if errors.Is(err, geo.ErrNotFound) {
		app.WriteError(w, r, http.StatusNotFound, "not_found", "Division not found.", nil)
		return
	}
	if err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	app.PrettyJSON(w, http.StatusOK, map[string]any{"items": items})
}
func (h *Handler) listUpazilas(w http.ResponseWriter, r *http.Request) {
	items, err := h.Geo.Upazilas(r.Context(), chi.URLParam(r, "code"))
	if errors.Is(err, geo.ErrNotFound) {
		app.WriteError(w, r, http.StatusNotFound, "not_found", "District not found.", nil)
		return
	}
	if err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	app.PrettyJSON(w, http.StatusOK, map[string]any{"items": items})
}
func (h *Handler) listUnions(w http.ResponseWriter, r *http.Request) {
	items, err := h.Geo.Unions(r.Context(), chi.URLParam(r, "code"))
	if errors.Is(err, geo.ErrNotFound) {
		app.WriteError(w, r, http.StatusNotFound, "not_found", "Upazila not found.", nil)
		return
	}
	if err != nil {
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	app.PrettyJSON(w, http.StatusOK, map[string]any{"items": items})
}

// ===========================================================================
//  /admin/profiles/{user_id}
// ===========================================================================

func (h *Handler) adminGetProfile(w http.ResponseWriter, r *http.Request) {
	role := auth.Role(r.Context())
	if role != "platform_admin" && role != "admin" && role != "platform_staff" {
		app.WriteError(w, r, http.StatusForbidden, "forbidden",
			"platform_admin / admin / platform_staff role required", nil)
		return
	}
	target := chi.URLParam(r, "user_id")
	if !reqValidUUID(w, r, target) {
		return
	}
	body, err := h.composeMeBody(r.Context(), target)
	if err != nil {
		if errors.Is(err, profile.ErrNotFound) {
			app.WriteError(w, r, http.StatusNotFound, "not_found", "Profile not found.", nil)
			return
		}
		app.WriteError(w, r, http.StatusInternalServerError, "internal_error", err.Error(), nil)
		return
	}
	app.PrettyJSON(w, http.StatusOK, body)
}

// ===========================================================================
//  Helpers
// ===========================================================================

func (h *Handler) composeMeBody(ctx context.Context, uid string) (map[string]any, error) {
	p, err := h.Profiles.Get(ctx, uid)
	if err != nil {
		return nil, err
	}
	addrs, _ := h.Addresses.List(ctx, uid)
	// hydrate default address if present
	var def any
	for i := range addrs {
		a := &addrs[i]
		if a.IsDefault {
			h2, _ := h.Geo.Hydrate(ctx, a.DivisionCode, a.DistrictCode, a.UpazilaCode, a.UnionCode)
			def = hydrate(a, h2)
			break
		}
	}
	body := map[string]any{
		"user_id":         p.UserID,
		"phone":           p.Phone,
		"email":           p.Email,
		"name_en":         p.NameEn,
		"name_bn":         p.NameBn,
		"gender":          p.Gender,
		"dob":             p.DOB,
		"locale":          p.Locale,
		"avatar_media_id": p.AvatarMediaID,
		"avatar_url":      h.composeAvatarURL(p),
		"default_address": def,
		"kyc":             p.Kyc,
		"whatsapp_number": p.WhatsappNumber,
		"created_at":      p.CreatedAt,
		"updated_at":      p.UpdatedAt,
	}
	return body, nil
}

func (h *Handler) composeAvatarURL(p *profile.Profile) string {
	if p.AvatarMediaID == nil || *p.AvatarMediaID == "" {
		return ""
	}
	// Stub URL pattern. Replace with media.GetSignedURL once Media lands.
	return "media://" + *p.AvatarMediaID
}

func (h *Handler) emitProfileChanged(ctx context.Context, p *profile.Profile) error {
	tx, err := h.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	payload, _ := json.Marshal(map[string]any{
		"event":   "ProfileChanged",
		"user_id": p.UserID,
		"snapshot": map[string]any{
			"name_en":         p.NameEn,
			"name_bn":         p.NameBn,
			"locale":          p.Locale,
			"kyc":             p.Kyc,
			"whatsapp_number": p.WhatsappNumber,
		},
	})
	if err := outbox.Insert(ctx, tx, h.Settings.KafkaTopicProfileChanged, p.UserID, payload); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func hydrate(a *address.Address, h *geo.Hydrated) map[string]any {
	o := map[string]any{
		"id":              a.ID,
		"label":           a.Label,
		"recipient_name":  a.RecipientName,
		"recipient_phone": a.RecipientPhone,
		"line1":           a.Line1,
		"line2":           a.Line2,
		"landmark":        a.Landmark,
		"lat":             a.Lat,
		"lng":             a.Lng,
		"is_default":      a.IsDefault,
		"created_at":      a.CreatedAt,
		"updated_at":      a.UpdatedAt,
	}
	if h != nil {
		o["division"] = h.Division
		o["district"] = h.District
		o["upazila"] = h.Upazila
		if h.Union != nil {
			o["union"] = *h.Union
		}
	}
	return o
}

func cacheKey(uid string) string { return "profile:" + uid }

func (h *Handler) invalidateProfileCache(ctx context.Context, uid string) {
	if h.Redis == nil {
		return
	}
	h.Redis.Del(ctx, cacheKey(uid))
}

func validGender(g string) bool {
	switch g {
	case "m", "f", "x", "prefer_not_say":
		return true
	}
	return false
}

// reqValidUUID rejects a malformed UUID path param with a clean 400 envelope
// instead of letting it reach pgx (which 500s and leaks the SQLSTATE 22P02).
func reqValidUUID(w http.ResponseWriter, r *http.Request, id string) bool {
	if _, err := uuid.Parse(id); err != nil {
		app.WriteError(w, r, http.StatusBadRequest, "invalid_uuid", "path parameter must be a valid UUID", nil)
		return false
	}
	return true
}
