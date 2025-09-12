#!/bin/bash
export PGPASSWORD=$POSTGRESQL_ADMIN_PASSWORD
BACKUP_DIR="/mnt/postgresql-backup"

psql -U postgres -t -A -c \
  "SELECT datname FROM pg_database WHERE datallowconn AND datname NOT IN ('postgres','template0','template1');" \
  | while read db; do
      echo "🔄 Dumping $db"
      pg_dump -U postgres --format=custom --file="$BACKUP_DIR/${db}.dump" "$db"
    done
