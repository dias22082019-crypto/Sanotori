#!/usr/bin/env bash
# Прогон тестов базы на чистом локальном PostgreSQL (без Supabase).
# Использование: PGHOST=... PGPORT=... PGUSER=postgres ./supabase/tests/run_local.sh
# Скрипт пересоздаёт базу sanatorium_test, применяет имитацию Supabase, все миграции и тесты.
set -euo pipefail
cd "$(dirname "$0")/../.."

DB=sanatorium_test
psql -v ON_ERROR_STOP=1 -q -d postgres -c "drop database if exists $DB" -c "create database $DB"

psql -v ON_ERROR_STOP=1 -q -d "$DB" -f supabase/tests/00_supabase_shim.sql
for f in supabase/migrations/*.sql; do
  echo "migrate: $f"
  psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$f"
done
for f in supabase/tests/[0-9][0-9]_*_test.sql; do
  echo "test: $f"
  psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$f"
done
