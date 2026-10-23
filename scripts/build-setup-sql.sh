#!/usr/bin/env bash
# Собирает все миграции в один файл supabase/setup_all.sql для вставки в Supabase SQL Editor.
set -euo pipefail
cd "$(dirname "$0")/.."
{
  echo "-- Sanatorium OS: установка базы одним файлом (собрано из supabase/migrations)."
  echo "-- Supabase → SQL Editor → New query → вставить весь файл → Run. Выполняется один раз на пустом проекте."
  echo "-- Не редактируйте вручную: файл пересобирается скриптом scripts/build-setup-sql.sh"
  echo "begin;"
  for f in supabase/migrations/*.sql; do
    echo
    echo "-- ===== $f ====="
    cat "$f"
  done
  echo
  echo "commit;"
} > supabase/setup_all.sql
