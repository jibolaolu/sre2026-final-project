"""Baseline schema for user-service.

Revision ID: 0001
Revises:
Create Date: 2026-10-15 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op

revision: str = "0001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id          VARCHAR(100) PRIMARY KEY,
            full_name   VARCHAR(255) NOT NULL,
            email       VARCHAR(255) NOT NULL UNIQUE,
            created_at  TIMESTAMP DEFAULT NOW()
        )
    """)


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS users")
