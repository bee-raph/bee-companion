"""Indexes for session rotation, latest file lookup, and scheduled jobs."""

from alembic import op

revision = "0002"
down_revision = "0001"


def upgrade():
    op.create_index("ix_sessions_family", "sessions", ["family"])
    op.create_index(
        "ix_file_versions_file_created", "file_versions", ["file_id", "created"]
    )
    op.create_index("ix_jobs_due", "jobs", ["due"])
    op.create_index("ix_jobs_kind", "jobs", ["kind"])


def downgrade():
    op.drop_index("ix_jobs_kind", table_name="jobs")
    op.drop_index("ix_jobs_due", table_name="jobs")
    op.drop_index("ix_file_versions_file_created", table_name="file_versions")
    op.drop_index("ix_sessions_family", table_name="sessions")
