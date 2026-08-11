// Package geo serves the BD geo reference data: divisions → districts
// → upazilas → unions. Read-only, public (no JWT required) — used to
// power the storefront address-picker dropdowns.
package geo

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Item struct {
	Code       string  `json:"code"`
	NameEn     string  `json:"name_en"`
	NameBn     string  `json:"name_bn"`
	PostalCode *string `json:"postal_code,omitempty"`
}

var ErrNotFound = errors.New("not found")

type Store struct{ DB *pgxpool.Pool }

func (s *Store) Divisions(ctx context.Context) ([]Item, error) {
	rows, err := s.DB.Query(ctx,
		`SELECT code, name_en, name_bn FROM bd_divisions ORDER BY sort_order, code`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Item{}
	for rows.Next() {
		var it Item
		if err := rows.Scan(&it.Code, &it.NameEn, &it.NameBn); err != nil {
			return nil, err
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

func (s *Store) Districts(ctx context.Context, divisionCode string) ([]Item, error) {
	var exists bool
	if err := s.DB.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM bd_divisions WHERE code = $1)`,
		divisionCode).Scan(&exists); err != nil {
		return nil, err
	}
	if !exists {
		return nil, ErrNotFound
	}
	rows, err := s.DB.Query(ctx,
		`SELECT code, name_en, name_bn FROM bd_districts
		  WHERE division_code = $1 ORDER BY sort_order, code`, divisionCode)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Item{}
	for rows.Next() {
		var it Item
		if err := rows.Scan(&it.Code, &it.NameEn, &it.NameBn); err != nil {
			return nil, err
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

func (s *Store) Upazilas(ctx context.Context, districtCode string) ([]Item, error) {
	var exists bool
	if err := s.DB.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM bd_districts WHERE code = $1)`,
		districtCode).Scan(&exists); err != nil {
		return nil, err
	}
	if !exists {
		return nil, ErrNotFound
	}
	rows, err := s.DB.Query(ctx,
		`SELECT code, name_en, name_bn FROM bd_upazilas
		  WHERE district_code = $1 ORDER BY sort_order, code`, districtCode)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Item{}
	for rows.Next() {
		var it Item
		if err := rows.Scan(&it.Code, &it.NameEn, &it.NameBn); err != nil {
			return nil, err
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

func (s *Store) Unions(ctx context.Context, upazilaCode string) ([]Item, error) {
	var exists bool
	if err := s.DB.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM bd_upazilas WHERE code = $1)`,
		upazilaCode).Scan(&exists); err != nil {
		return nil, err
	}
	if !exists {
		return nil, ErrNotFound
	}
	rows, err := s.DB.Query(ctx,
		`SELECT code, name_en, name_bn, postal_code FROM bd_unions
		  WHERE upazila_code = $1 ORDER BY sort_order, code`, upazilaCode)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Item{}
	for rows.Next() {
		var it Item
		if err := rows.Scan(&it.Code, &it.NameEn, &it.NameBn, &it.PostalCode); err != nil {
			return nil, err
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

// Hydrate looks up the four codes and returns the human names. Used by
// /me/addresses GET responses to enrich the row.
type Hydrated struct {
	Division Item  `json:"division"`
	District Item  `json:"district"`
	Upazila  Item  `json:"upazila"`
	Union    *Item `json:"union,omitempty"`
}

func (s *Store) Hydrate(ctx context.Context, divisionCode, districtCode, upazilaCode string, unionCode *string) (*Hydrated, error) {
	h := &Hydrated{}
	if err := s.DB.QueryRow(ctx,
		`SELECT code, name_en, name_bn FROM bd_divisions WHERE code=$1`, divisionCode,
	).Scan(&h.Division.Code, &h.Division.NameEn, &h.Division.NameBn); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if err := s.DB.QueryRow(ctx,
		`SELECT code, name_en, name_bn FROM bd_districts WHERE code=$1`, districtCode,
	).Scan(&h.District.Code, &h.District.NameEn, &h.District.NameBn); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if err := s.DB.QueryRow(ctx,
		`SELECT code, name_en, name_bn FROM bd_upazilas WHERE code=$1`, upazilaCode,
	).Scan(&h.Upazila.Code, &h.Upazila.NameEn, &h.Upazila.NameBn); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if unionCode != nil && *unionCode != "" {
		var u Item
		if err := s.DB.QueryRow(ctx,
			`SELECT code, name_en, name_bn, postal_code FROM bd_unions WHERE code=$1`, *unionCode,
		).Scan(&u.Code, &u.NameEn, &u.NameBn, &u.PostalCode); err != nil {
			if !errors.Is(err, pgx.ErrNoRows) {
				return nil, err
			}
		} else {
			h.Union = &u
		}
	}
	return h, nil
}
