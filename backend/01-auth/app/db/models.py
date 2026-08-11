"""SQLAlchemy 2.0 ORM models — aligned to dokandar_docs/services/auth.md §5."""
from __future__ import annotations
import uuid
from datetime import datetime
from typing import Optional
from sqlalchemy import String, ForeignKey, DateTime, CHAR, Text, text
from sqlalchemy.dialects.postgresql import UUID as PG_UUID, INET, ENUM, JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


user_role_enum = ENUM(
    "admin", "shopkeeper", "shop_staff", "platform_staff", "customer",
    name="user_role", create_type=False,
)
user_status_enum = ENUM(
    "active", "suspended", "pending",
    name="user_status", create_type=False,
)
kyc_status_enum = ENUM(
    "unverified", "submitted", "verified", "rejected",
    name="kyc_status", create_type=False,
)


class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(
        PG_UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    phone: Mapped[str] = mapped_column(String(20), unique=True, nullable=False)
    email: Mapped[Optional[str]] = mapped_column(String(255), unique=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    lang: Mapped[str] = mapped_column(String(2), nullable=False, server_default="bn")
    role: Mapped[str] = mapped_column(user_role_enum, nullable=False, server_default="customer")
    status: Mapped[str] = mapped_column(user_status_enum, nullable=False, server_default="active")
    kyc: Mapped[str] = mapped_column(kyc_status_enum, nullable=False, server_default="unverified")
    created_by: Mapped[Optional[uuid.UUID]] = mapped_column(
        PG_UUID(as_uuid=True), ForeignKey("users.id"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )


class RefreshToken(Base):
    __tablename__ = "refresh_tokens"

    id: Mapped[uuid.UUID] = mapped_column(
        PG_UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    token_hash: Mapped[str] = mapped_column(CHAR(64), unique=True, nullable=False)
    family_id: Mapped[uuid.UUID] = mapped_column(PG_UUID(as_uuid=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    user_agent: Mapped[Optional[str]] = mapped_column(Text)
    ip: Mapped[Optional[str]] = mapped_column(INET)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )


class KYCSubmission(Base):
    """KYC submission — one row per shopkeeper attempt.

    The actual NID + trade-license bytes live in RustFS via Media's presigned
    URLs; we keep only the object keys and the simple disclosure fields.
    """
    __tablename__ = "kyc_submissions"

    id: Mapped[uuid.UUID] = mapped_column(
        PG_UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    nid_key: Mapped[str] = mapped_column(String(255), nullable=False)
    trade_license_key: Mapped[Optional[str]] = mapped_column(String(255))
    bank_account_last4: Mapped[Optional[str]] = mapped_column(String(8))
    mobile_wallet_number: Mapped[Optional[str]] = mapped_column(String(20))
    submitted_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )
    reviewed_by: Mapped[Optional[uuid.UUID]] = mapped_column(
        PG_UUID(as_uuid=True), ForeignKey("users.id"), nullable=True
    )
    reviewed_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    decision: Mapped[Optional[str]] = mapped_column(kyc_status_enum)
    rejection_reason: Mapped[Optional[str]] = mapped_column(Text)


class Outbox(Base):
    """Transactional outbox — events written in the same TX as the business change."""
    __tablename__ = "outbox"

    id: Mapped[uuid.UUID] = mapped_column(
        PG_UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    topic: Mapped[str] = mapped_column(Text, nullable=False)
    key: Mapped[Optional[str]] = mapped_column(Text)
    payload: Mapped[dict] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )
    sent_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), index=True)
