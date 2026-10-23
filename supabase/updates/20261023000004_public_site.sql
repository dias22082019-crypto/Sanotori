-- Sanatorium OS: обновление базы, миграция 20261023000004_public_site.sql.
-- Supabase → SQL Editor → New query → вставить весь файл → Run. Каждое обновление применяется один раз.
-- Не редактируйте вручную: файл пересобирается скриптом scripts/build-setup-sql.sh
begin;

-- Sanatorium OS · 0004 · Публичная страница санатория
-- Аноним не читает таблицу organizations напрямую. Функция отдаёт только опубликованные
-- санатории и только безопасные поля: без БИН, юридических реквизитов и внутренних настроек.

create or replace function public.get_public_sanatorium(p_slug text)
returns table (
  slug text, name text, description text, logo_path text, city text, address text,
  phone text, email text, whatsapp_phone text, default_language public.app_language,
  check_in_time text, check_out_time text
)
language sql stable security definer set search_path = '' as $$
  select o.slug, o.name, o.description, o.logo_path, o.city, o.address,
         o.phone, o.email, o.whatsapp_phone, o.default_language,
         o.booking_settings ->> 'check_in_time', o.booking_settings ->> 'check_out_time'
  from public.organizations o
  where o.slug = lower(p_slug) and o.is_published
$$;

revoke all on function public.get_public_sanatorium(text) from public;
grant execute on function public.get_public_sanatorium(text) to anon, authenticated;

commit;
