"""Add cards table for persistent card management.

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-30 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op

revision: str = "0002"
down_revision: Union[str, None] = "0001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("""
        CREATE TABLE IF NOT EXISTS cards (
            user_id        VARCHAR(100) PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
            card_number    VARCHAR(25)  NOT NULL,
            expiry         VARCHAR(7)   NOT NULL,
            frozen         BOOLEAN      NOT NULL DEFAULT FALSE,
            pin_hash       VARCHAR(64),
            daily_limit    NUMERIC(12,2) NOT NULL DEFAULT 2000,
            created_at     TIMESTAMP    DEFAULT NOW(),
            updated_at     TIMESTAMP    DEFAULT NOW()
        )
    """)
    op.execute("""
        CREATE OR REPLACE FUNCTION cards_set_updated_at()
        RETURNS TRIGGER LANGUAGE plpgsql AS $$
        BEGIN
          NEW.updated_at = NOW();
          RETURN NEW;
        END;
        $$
    """)
    op.execute("""
        CREATE TRIGGER cards_updated_at
        BEFORE UPDATE ON cards
        FOR EACH ROW EXECUTE FUNCTION cards_set_updated_at()
    """)


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS cards_updated_at ON cards")
    op.execute("DROP FUNCTION IF EXISTS cards_set_updated_at")
    op.execute("DROP TABLE IF EXISTS cards")
