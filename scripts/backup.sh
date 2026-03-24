#!/usr/bin/env bash
set -euo pipefail

BORG_REPO="/opt/borg-backups/reporting-tool"
DB_VOLUME="reporting-tool_db_data"

# Dump a consistent snapshot using SQLite's online backup API.
# Safe for WAL-mode databases that may be in use.
# Skip backup if the database doesn't exist yet (e.g. first deploy)
if ! docker run --rm -v "${DB_VOLUME}:/data:ro" keinos/sqlite3 test -f /data/app.db 2>/dev/null; then
  echo "No database found in volume, skipping backup."
  exit 0
fi

mkdir -p /tmp/db-snapshot
chmod 777 /tmp/db-snapshot
docker run --rm \
  -v "${DB_VOLUME}:/data:ro" \
  -v "/tmp/db-snapshot:/snapshot" \
  keinos/sqlite3 \
  sqlite3 /data/app.db ".backup /snapshot/app.db"

borg create \
  --compression lz4 \
  "${BORG_REPO}::reporting-tool-{now:%Y-%m-%dT%H:%M:%S}" \
  /tmp/db-snapshot/

borg prune \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3 \
  "${BORG_REPO}"

rm -f /tmp/db-snapshot/app.db
