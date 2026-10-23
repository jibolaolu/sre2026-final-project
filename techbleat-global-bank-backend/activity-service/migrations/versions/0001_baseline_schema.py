"""Baseline schema for activity-service.

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
        CREATE TABLE IF NOT EXISTS activities (
            id            BIGSERIAL PRIMARY KEY,
            user_id       VARCHAR(100) NOT NULL,
            activity_type VARCHAR(50)  NOT NULL,
            description   TEXT,
            created_at    TIMESTAMP DEFAULT NOW()
        )
    """)
    op.execute(
        "CREATE INDEX IF NOT EXISTS idx_activities_user_id ON activities (user_id)"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS idx_activities_user_id")
    op.execute("DROP TABLE IF EXISTS activities")
