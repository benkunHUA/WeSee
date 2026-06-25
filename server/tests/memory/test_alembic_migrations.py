"""Integration tests for Alembic database migrations."""

from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, inspect
from testcontainers.postgres import PostgresContainer


@pytest.mark.integration
def test_initial_alembic_migration_creates_conversation_tables():
    project_root = Path(__file__).resolve().parents[2]
    with PostgresContainer("postgres:16-alpine") as postgres:
        host = postgres.get_container_host_ip()
        port = postgres.get_exposed_port(5432)
        async_url = f"postgresql+asyncpg://test:test@{host}:{port}/test"
        sync_url = f"postgresql://test:test@{host}:{port}/test"

        alembic_cfg = Config(str(project_root / "alembic.ini"))
        alembic_cfg.set_main_option("script_location", str(project_root / "migrations"))
        alembic_cfg.set_main_option("sqlalchemy.url", async_url)
        command.upgrade(alembic_cfg, "head")

        engine = create_engine(sync_url)
        try:
            inspector = inspect(engine)
            assert {"users", "sessions", "messages"}.issubset(
                set(inspector.get_table_names())
            )
            message_columns = {
                column["name"] for column in inspector.get_columns("messages")
            }
            assert {
                "id",
                "session_id",
                "sequence",
                "role",
                "content",
                "tool_calls",
                "tool_call_id",
                "name",
                "metadata",
                "created_at",
            }.issubset(message_columns)
        finally:
            engine.dispose()
