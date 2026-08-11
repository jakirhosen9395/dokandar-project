// Package profile owns the profile entity + its data access. Plain pgx;
// no ORM. APM auto-instruments pgx via the tracer-attached *pgxpool.Pool.
package profile

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Profile struct {
	UserID           string     `json:"user_id"`
	Phone            string     `json:"phone"`
	Email            *string    `json:"email,omitempty"`
	NameEn           *string    `json:"name_en,omitempty"`
	NameBn           *string    `json:"name_bn,omitempty"`
	Gender           *string    `json:"gender,omitempty"`
	DOB              *time.Time `json:"dob,omitempty"`
	Locale           string     `json:"locale"`
	AvatarMediaID    *string    `json:"avatar_media_id,omitempty"`
	DefaultAddressID *string    `json:"default_address_id,omitempty"`
	Kyc              string     `json:"kyc"`
	WhatsappNumber   *string    `json:"whatsapp_number,omitempty"`
	CreatedAt        time.Time  `json:"created_at"`
	UpdatedAt        time.Time  `json:"updated_at"`
}

var ErrNotFound = errors.New("profile not found")

type Store struct{ DB *pgxpool.Pool }

func (s *Store) Get(ctx context.Context, userID string) (*Profile, error) {
	p := &Profile{}
	err := s.DB.QueryRow(ctx,
		`SELECT user_id::text, phone, email, name_en, name_bn, gender, dob, locale,
		        avatar_media_id::text, default_address_id::text, kyc, whatsapp_number,
		        created_at, updated_at
		   FROM profiles WHERE user_id = $1`, userID,
	).Scan(&p.UserID, &p.Phone, &p.Email, &p.NameEn, &p.NameBn, &p.Gender, &p.DOB,
		&p.Locale, &p.AvatarMediaID, &p.DefaultAddressID, &p.Kyc, &p.WhatsappNumber,
		&p.CreatedAt, &p.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return p, nil
}

// Upsert creates the profile shell (called from the Kafka UserCreated consumer).
func (s *Store) Upsert(ctx context.Context, userID, phone string, email *string, nameEn *string, locale string) error {
	_, err := s.DB.Exec(ctx,
		`INSERT INTO profiles (user_id, phone, email, name_en, locale)
		 VALUES ($1, $2, $3, $4, COALESCE(NULLIF($5,''), 'bn'))
		 ON CONFLICT (user_id) DO NOTHING`,
		userID, phone, email, nameEn, locale)
	return err
}

type UpdateInput struct {
	NameEn         *string
	NameBn         *string
	Gender         *string
	DOB            *time.Time
	Locale         *string
	WhatsappNumber *string
}

// Update applies a PATCH. NOT touched: kyc, default_address_id, avatar_media_id,
// phone, email — those are mutated by dedicated paths.
func (s *Store) Update(ctx context.Context, userID string, in UpdateInput) (*Profile, error) {
	_, err := s.DB.Exec(ctx,
		`UPDATE profiles
		    SET name_en         = COALESCE($2, name_en),
		        name_bn         = COALESCE($3, name_bn),
		        gender          = COALESCE($4, gender),
		        dob             = COALESCE($5, dob),
		        locale          = COALESCE($6, locale),
		        whatsapp_number = COALESCE($7, whatsapp_number),
		        updated_at      = now()
		  WHERE user_id = $1`,
		userID, in.NameEn, in.NameBn, in.Gender, in.DOB, in.Locale, in.WhatsappNumber,
	)
	if err != nil {
		return nil, err
	}
	return s.Get(ctx, userID)
}

// MirrorKyc is called by the kyc consumer. Idempotent + monotonic — events
// from different Kafka topics can arrive out of order (kyc.submitted vs
// kyc.approved are independent partitions, so the consumer may process
// `submitted` AFTER `approved` even though they were emitted in order).
// Reject any downgrade from a terminal state (verified|rejected) back to
// an in-progress state (unverified|submitted). The auth flow disallows
// re-submission after a decision, so verified/rejected stay terminal.
func (s *Store) MirrorKyc(ctx context.Context, userID, kyc string) (bool, error) {
	tag, err := s.DB.Exec(ctx,
		`UPDATE profiles SET kyc = $2, updated_at = now()
		  WHERE user_id = $1
		    AND kyc <> $2
		    AND NOT (kyc IN ('verified','rejected') AND $2 IN ('unverified','submitted'))`,
		userID, kyc)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

// MirrorAuthUser is called by the auth.user.updated consumer.
func (s *Store) MirrorAuthUser(ctx context.Context, userID, phone string, email *string) error {
	_, err := s.DB.Exec(ctx,
		`UPDATE profiles SET phone = $2, email = $3, updated_at = now() WHERE user_id = $1`,
		userID, phone, email)
	return err
}

// SetAvatar stores the media_id; the caller is expected to have validated
// the media_id with the Media service (or stubbed it for now).
func (s *Store) SetAvatar(ctx context.Context, userID, mediaID string) (*Profile, error) {
	_, err := s.DB.Exec(ctx,
		`UPDATE profiles SET avatar_media_id = $2::uuid, updated_at = now() WHERE user_id = $1`,
		userID, mediaID)
	if err != nil {
		return nil, err
	}
	return s.Get(ctx, userID)
}

// SetDefaultAddress is called from the address layer when default flips.
func (s *Store) SetDefaultAddress(ctx context.Context, userID, addressID string) error {
	_, err := s.DB.Exec(ctx,
		`UPDATE profiles SET default_address_id = $2::uuid, updated_at = now() WHERE user_id = $1`,
		userID, addressID)
	return err
}
