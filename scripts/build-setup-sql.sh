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

# Обновления для уже установленной базы: каждая миграция отдельно, в транзакции.
# Если база ставилась из setup_all.sql, примените по порядку только новые файлы из supabase/updates.
rm -rf supabase/updates
mkdir -p supabase/updates
for f in supabase/migrations/*.sql; do
  name=$(basename "$f")
  {
    echo "-- Sanatorium OS: обновление базы, миграция $name."
    echo "-- Supabase → SQL Editor → New query → вставить весь файл → Run. Каждое обновление применяется один раз."
    echo "-- Не редактируйте вручную: файл пересобирается скриптом scripts/build-setup-sql.sh"
    echo "begin;"
    echo
    cat "$f"
    echo
    echo "commit;"
  } > "supabase/updates/$name"
done
