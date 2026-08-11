// Package address owns the address entity + the BD geo FK chain validation
// + the default-address invariant.
package address

import (
	"context"
	"errors"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// BD mobile regex — spec invariant.
var PhoneRegex = regexp.MustCompile(`^01[3-9][0-9]{8}$`)

type Address struct {
	ID             string     `json:"id"`
	UserID         string     `json:"user_id"`
	Label          string     `json:"label"`
	RecipientName  string     `json:"recipient_name"`
	RecipientPhone string     `json:"recipient_phone"`
	DivisionCode   string     `json:"division_code"`
	DistrictCode   string     `json:"district_code"`
	UpazilaCode    string     `json:"upazila_code"`
	UnionCode      *string    `json:"union_code,omitempty"`
	Line1          string     `json:"line1"`
	Line2          *string    `json:"line2,omitempty"`
	Landmark       *string    `json:"landmark,omitempty"`
	Lat            *float64   `json:"lat,omitempty"`
	Lng            *float64   `json:"lng,omitempty"`
	IsDefault      bool       `json:"is_default"`
	DeletedAt      *time.Time `json:"deleted_at,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
}

var (
	ErrNotFound      = errors.New("address not found")
	ErrPhoneInvalid  = errors.New("recipient_phone must match ^01[3-9]\\d{8}$")
	ErrGeoChainInval = errors.New("geo_chain_invalid")
	ErrDefaultInUse  = errors.New("address is currently default; promote another first")
)

type Store struct{ DB *pgxpool.Pool }

// VerifyGeoChain — confirm the chain district→division, upazila→district,
// and (optionally) union→upazila is consistent.
func (s *Store) VerifyGeoChain(ctx context.Context, divisionCode, districtCode, upazilaCode string, unionCode *string) error {
	var ok bool
	err := s.DB.QueryRow(ctx,
		`SELECT EXISTS(
		    SELECT 1
		      FROM bd_districts d
		      JOIN bd_upazilas u ON u.district_code = d.code
		     WHERE d.code = $2
		       AND d.division_code = $1
		       AND u.code = $3
		 )`,
		divisionCode, districtCode, upazilaCode,
	).Scan(&ok)
	if err != nil {
		return err
	}
	if !ok {
		return ErrGeoChainInval
	}
	if unionCode != nil && *unionCode != "" {
		err = s.DB.QueryRow(ctx,
			`SELECT EXISTS(SELECT 1 FROM bd_unions WHERE code=$1 AND upazila_code=$2)`,
			*unionCode, upazilaCode,
		).Scan(&ok)
		if err != nil {
			return err
		}
		if !ok {
			return ErrGeoChainInval
		}
	}
	return nil
}

func (s *Store) List(ctx context.Context, userID string) ([]Address, error) {
	rows, err := s.DB.Query(ctx,
		`SELECT id::text, user_id::text, label, recipient_name, recipient_phone,
		        division_code, district_code, upazila_code, union_code,
		        line1, line2, landmark, lat, lng, is_default, deleted_at, created_at, updated_at
		   FROM addresses
		  WHERE user_id = $1 AND deleted_at IS NULL
		  ORDER BY is_default DESC, created_at ASC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Address{}
	for rows.Next() {
		a := Address{}
		if err := rows.Scan(&a.ID, &a.UserID, &a.Label, &a.RecipientName, &a.RecipientPhone,
			&a.DivisionCode, &a.DistrictCode, &a.UpazilaCode, &a.UnionCode,
			&a.Line1, &a.Line2, &a.Landmark, &a.Lat, &a.Lng, &a.IsDefault, &a.DeletedAt,
			&a.CreatedAt, &a.UpdatedAt,
		); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

func (s *Store) Get(ctx context.Context, userID, id string) (*Address, error) {
	a := &Address{}
	err := s.DB.QueryRow(ctx,
		`SELECT id::text, user_id::text, label, recipient_name, recipient_phone,
		        division_code, district_code, upazila_code, union_code,
		        line1, line2, landmark, lat, lng, is_default, deleted_at, created_at, updated_at
		   FROM addresses WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`,
		id, userID,
	).Scan(&a.ID, &a.UserID, &a.Label, &a.RecipientName, &a.RecipientPhone,
		&a.DivisionCode, &a.DistrictCode, &a.UpazilaCode, &a.UnionCode,
		&a.Line1, &a.Line2, &a.Landmark, &a.Lat, &a.Lng, &a.IsDefault, &a.DeletedAt,
		&a.CreatedAt, &a.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return a, err
}

// Add — caller passes the tx so the address insert + outbox row commit
// atomically.
func (s *Store) Add(ctx context.Context, tx pgx.Tx, in Address) (string, error) {
	if in.IsDefault {
		if _, err := tx.Exec(ctx,
			`UPDATE addresses SET is_default = false
			   WHERE user_id = $1 AND is_default AND deleted_at IS NULL`,
			in.UserID); err != nil {
			return "", err
		}
	}
	var id string
	err := tx.QueryRow(ctx,
		`INSERT INTO addresses
		   (user_id, label, recipient_name, recipient_phone,
		    division_code, district_code, upazila_code, union_code,
		    line1, line2, landmark, lat, lng, is_default)
		 VALUES
		   ($1,$2,$3,$4, $5,$6,$7,$8, $9,$10,$11,$12,$13,$14)
		 RETURNING id::text`,
		in.UserID, in.Label, in.RecipientName, in.RecipientPhone,
		in.DivisionCode, in.DistrictCode, in.UpazilaCode, in.UnionCode,
		in.Line1, in.Line2, in.Landmark, in.Lat, in.Lng, in.IsDefault,
	).Scan(&id)
	if err != nil {
		return "", err
	}
	return id, nil
}

// Update writes the changed fields; ownership check baked into the WHERE.
func (s *Store) Update(ctx context.Context, tx pgx.Tx, userID, id string, in Address) (bool, error) {
	tag, err := tx.Exec(ctx,
		`UPDATE addresses
		    SET label           = COALESCE(NULLIF($3,''), label),
		        recipient_name  = COALESCE(NULLIF($4,''), recipient_name),
		        recipient_phone = COALESCE(NULLIF($5,''), recipient_phone),
		        division_code   = COALESCE(NULLIF($6,''), division_code),
		        district_code   = COALESCE(NULLIF($7,''), district_code),
		        upazila_code    = COALESCE(NULLIF($8,''), upazila_code),
		        union_code      = COALESCE($9, union_code),
		        line1           = COALESCE(NULLIF($10,''), line1),
		        line2           = COALESCE($11, line2),
		        landmark        = COALESCE($12, landmark),
		        lat             = COALESCE($13, lat),
		        lng             = COALESCE($14, lng),
		        updated_at      = now()
		  WHERE id = $2 AND user_id = $1 AND deleted_at IS NULL`,
		userID, id,
		in.Label, in.RecipientName, in.RecipientPhone,
		in.DivisionCode, in.DistrictCode, in.UpazilaCode, in.UnionCode,
		in.Line1, in.Line2, in.Landmark, in.Lat, in.Lng,
	)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

// SoftDelete sets deleted_at. Refuses if currently default (caller must
// promote another first).
func (s *Store) SoftDelete(ctx context.Context, tx pgx.Tx, userID, id string) error {
	var isDefault bool
	err := tx.QueryRow(ctx,
		`SELECT is_default FROM addresses WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL`,
		id, userID).Scan(&isDefault)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if isDefault {
		return ErrDefaultInUse
	}
	_, err = tx.Exec(ctx,
		`UPDATE addresses SET deleted_at = now(), updated_at = now()
		   WHERE id = $1 AND user_id = $2`, id, userID)
	return err
}

// SetDefault demotes any current default and promotes the chosen address
// inside one statement (atomic vs the partial unique index).
func (s *Store) SetDefault(ctx context.Context, tx pgx.Tx, userID, id string) error {
	var ok bool
	err := tx.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM addresses
		    WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL)`,
		id, userID).Scan(&ok)
	if err != nil {
		return err
	}
	if !ok {
		return ErrNotFound
	}
	_, err = tx.Exec(ctx,
		`UPDATE addresses
		    SET is_default = (id = $2::uuid),
		        updated_at = CASE WHEN id = $2::uuid OR is_default THEN now() ELSE updated_at END
		  WHERE user_id = $1 AND deleted_at IS NULL`, userID, id)
	return err
}
