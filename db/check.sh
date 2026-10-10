#!/usr/bin/env bash
# Применяет все миграции к пустой базе и гоняет проверки.
# Нужен psql и доступ к PostgreSQL 18 (переменные PGHOST, PGPORT, PGUSER, PGPASSWORD).
# База из PGDATABASE (по умолчанию monitor_check) пересоздаётся: не указывайте рабочую базу.
set -euo pipefail
cd "$(dirname "$0")"
db="${PGDATABASE:-monitor_check}"
psql -v ON_ERROR_STOP=1 -q -d postgres -c "DROP DATABASE IF EXISTS \"$db\"" -c "CREATE DATABASE \"$db\""
for f in migrations/*.sql; do
  echo "== $f"
  psql -v ON_ERROR_STOP=1 -q -d "$db" -f "$f"
done
for f in tests/*.sql; do
  echo "== $f"
  psql -v ON_ERROR_STOP=1 -q -o /dev/null -d "$db" -f "$f"
done
