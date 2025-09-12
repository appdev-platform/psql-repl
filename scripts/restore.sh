#!/bin/bash
set -euo pipefail

export PGPASSWORD="$POSTGRESQL_ADMIN_PASSWORD"
BACKUP_DIR="/mnt/postgresql-backup"

for f in "$BACKUP_DIR"/backstage_*.dump; do
  db="$(basename "$f" .dump)"
  echo "🗄️ Restoring $f into $db"
  createdb -U postgres -O "$POSTGRESQL_USER" "$db" || echo "Database $db already exists"
  pg_restore -U postgres -d "$db" --role=compass --no-owner "$f"
done
