"""create conversation persistence tables

Revision ID: 20260625_0001
Revises:
Create Date: 2026-06-25
"""
from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "20260625_0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.Text(), primary_key=True),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "sessions",
        sa.Column("id", sa.Text(), primary_key=True),
        sa.Column("user_id", sa.Text(), nullable=False),
        sa.Column("title", sa.Text(), nullable=True),
        sa.Column("workspace_path", sa.Text(), nullable=False),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_message_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("status in ('active', 'archived')", name="ck_sessions_status"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
    )
    op.create_index(
        "ix_sessions_user_id_updated_at",
        "sessions",
        ["user_id", sa.text("updated_at DESC")],
    )
    op.create_index(
        "ix_sessions_status_updated_at",
        "sessions",
        ["status", sa.text("updated_at DESC")],
    )
    op.create_table(
        "messages",
        sa.Column("id", sa.BigInteger(), sa.Identity(), primary_key=True),
        sa.Column("session_id", sa.Text(), nullable=False),
        sa.Column("sequence", sa.BigInteger(), nullable=False),
        sa.Column("role", sa.Text(), nullable=False),
        sa.Column("content", sa.Text(), nullable=False),
        sa.Column("tool_calls", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
        sa.Column("tool_call_id", sa.Text(), nullable=True),
        sa.Column("name", sa.Text(), nullable=True),
        sa.Column(
            "metadata",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default=sa.text("'{}'::jsonb"),
            nullable=False,
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "role in ('user', 'assistant', 'system', 'tool')",
            name="ck_messages_role",
        ),
        sa.ForeignKeyConstraint(["session_id"], ["sessions.id"]),
        sa.UniqueConstraint("session_id", "sequence", name="uq_messages_session_sequence"),
    )
    op.create_index(
        "ix_messages_session_id_sequence",
        "messages",
        ["session_id", "sequence"],
    )
    op.create_index("ix_messages_session_id_id", "messages", ["session_id", "id"])


def downgrade() -> None:
    op.drop_index("ix_messages_session_id_id", table_name="messages")
    op.drop_index("ix_messages_session_id_sequence", table_name="messages")
    op.drop_table("messages")
    op.drop_index("ix_sessions_status_updated_at", table_name="sessions")
    op.drop_index("ix_sessions_user_id_updated_at", table_name="sessions")
    op.drop_table("sessions")
    op.drop_table("users")
