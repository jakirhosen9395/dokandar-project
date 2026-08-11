"""KYC submission flow + lang column.

  - kyc_status enum: unverified | submitted | verified | rejected
  - users.kyc + users.lang columns
  - kyc_submissions table (nid_key, trade_license_key, bank_account_last4,
    mobile_wallet_number, submitted_at, reviewed_by, reviewed_at,
    decision, rejection_reason)
  - default admin auto-promoted to kyc='verified'

Revision ID: 0002_kyc
Revises: 0001_init
Create Date: 2026-05-27
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "0002_kyc"
down_revision = "0001_init"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # ---- enum ----------------------------------------------------------
    kyc_status = postgresql.ENUM(
        "unverified", "submitted", "verified", "rejected",
        name="kyc_status",
    )
    kyc_status.create(op.get_bind(), checkfirst=True)

    # ---- users: add kyc + lang columns --------------------------------
    op.add_column("users", sa.Column(
        "kyc",
        postgresql.ENUM(name="kyc_status", create_type=False),
        nullable=False, server_default="unverified",
    ))
    op.add_column("users", sa.Column(
        "lang", sa.String(2), nullable=False, server_default="bn",
    ))
    op.create_index(
        "idx_users_kyc", "users", ["kyc"],
        postgresql_where=sa.text("kyc <> 'unverified'"),
    )

    # ---- kyc_submissions ----------------------------------------------
    op.create_table(
        "kyc_submissions",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True,
                  server_default=sa.text("gen_random_uuid()")),
        sa.Column("user_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="CASCADE"),
                  nullable=False),
        sa.Column("nid_key", sa.String(255), nullable=False),
        sa.Column("trade_license_key", sa.String(255)),
        sa.Column("bank_account_last4", sa.String(8)),
        sa.Column("mobile_wallet_number", sa.String(20)),
        sa.Column("submitted_at", sa.DateTime(timezone=True),
                  nullable=False, server_default=sa.text("now()")),
        sa.Column("reviewed_by", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("users.id")),
        sa.Column("reviewed_at", sa.DateTime(timezone=True)),
        sa.Column("decision",
                  postgresql.ENUM(name="kyc_status", create_type=False)),
        sa.Column("rejection_reason", sa.Text()),
    )
    op.create_index(
        "idx_kyc_user_submitted", "kyc_submissions",
        ["user_id", sa.text("submitted_at DESC")],
    )
    op.create_index(
        "idx_kyc_pending", "kyc_submissions", ["submitted_at"],
        postgresql_where=sa.text("decision IS NULL"),
    )

    # ---- default admin lands verified --------------------------------
    op.execute(
        "UPDATE users SET kyc = 'verified' "
        "WHERE role = 'admin' AND kyc = 'unverified'"
    )


def downgrade() -> None:
    op.drop_index("idx_kyc_pending", table_name="kyc_submissions")
    op.drop_index("idx_kyc_user_submitted", table_name="kyc_submissions")
    op.drop_table("kyc_submissions")
    op.drop_index("idx_users_kyc", table_name="users")
    op.drop_column("users", "lang")
    op.drop_column("users", "kyc")
    postgresql.ENUM(name="kyc_status").drop(op.get_bind(), checkfirst=True)
