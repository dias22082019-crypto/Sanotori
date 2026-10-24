-- Sanatorium OS: обновление базы, миграция 20261030000012_whatsapp_kaspi.sql.
-- Supabase → SQL Editor → New query → вставить весь файл → Run. Каждое обновление применяется один раз.
-- Не редактируйте вручную: файл пересобирается скриптом scripts/build-setup-sql.sh
begin;

-- Sanatorium OS · 0012 · WhatsApp (официальный WhatsApp Cloud API от Meta) и ссылка на оплату Kaspi
-- Принципы:
--  * токен доступа Meta и App Secret хранятся только в Supabase Vault; клиенту они не возвращаются никогда,
--    расшифровать их могут только серверные функции, которые вызываются ключом service_role из Edge Functions;
--  * сообщение сначала создаётся в базе (проверка прав, тарифа, окна 24 часа), затем Edge Function отправляет его
--    в Meta и записывает ответ: «отправлено» показывается только после ответа Meta, без имитации успеха;
--  * вебхук Meta принимается Edge Function после проверки подписи X-Hub-Signature-256 (App Secret санатория);
--  * переписка — персональные данные гостя: читать её могут только сотрудники с правом messages.read;
--  * чтение переписки при истёкшей подписке не блокируется, отправка — да (модуль integrations, тариф Business+);
--  * Kaspi: открытого API для приёма оплат нет, поэтому хранится только ссылка или QR на оплату из Kaspi,
--    а поступление сотрудник отмечает в брони вручную, как и раньше («Kaspi перевод»).

-- В Supabase расширение Vault включено по умолчанию; строка ниже ничего не меняет, если оно уже есть
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'supabase_vault') then
    create extension if not exists supabase_vault with schema vault;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Kaspi: ссылка на оплату (Kaspi Pay / Kaspi QR), которую санаторий получает в приложении Kaspi
-- ---------------------------------------------------------------------------
alter table public.organizations
  add column kaspi_pay_url text
    check (kaspi_pay_url is null or (char_length(kaspi_pay_url) <= 500
           and kaspi_pay_url ~* '^https://([a-z0-9-]+\.)*kaspi\.kz(/[^[:space:]]*)?$'));

-- ---------------------------------------------------------------------------
-- WhatsApp: подключение санатория
-- ---------------------------------------------------------------------------
create type public.whatsapp_check_status as enum ('not_checked', 'ok', 'error');

create table public.whatsapp_accounts (
  tenant_id        uuid primary key references public.organizations(id) on delete cascade,
  phone_number_id  text not null check (phone_number_id ~ '^[0-9]{5,25}$'),
  waba_id          text check (waba_id is null or waba_id ~ '^[0-9]{5,25}$'),
  token_secret_id  uuid,
  app_secret_id    uuid,
  verify_token     text not null check (char_length(verify_token) = 64),
  is_enabled       boolean not null default true,
  status           public.whatsapp_check_status not null default 'not_checked',
  display_phone    text check (char_length(display_phone) <= 40),
  verified_name    text check (char_length(verified_name) <= 200),
  last_error       text check (char_length(last_error) <= 500),
  checked_at       timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
-- Один номер WhatsApp не может принадлежать двум санаториям: по нему вебхук находит санаторий
create unique index whatsapp_accounts_phone_uidx on public.whatsapp_accounts (phone_number_id);
create unique index whatsapp_accounts_verify_uidx on public.whatsapp_accounts (verify_token);

create trigger whatsapp_accounts_updated_at before update on public.whatsapp_accounts
  for each row execute function app.touch_updated_at();

-- Таблица закрыта целиком: клиент работает только через функции ниже
alter table public.whatsapp_accounts enable row level security;
revoke all on public.whatsapp_accounts from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Сообщения
-- ---------------------------------------------------------------------------
create type public.message_direction as enum ('in', 'out');
create type public.message_status as enum ('queued', 'sending', 'sent', 'delivered', 'read', 'failed', 'received');

create table public.messages (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.organizations(id) on delete cascade,
  channel        text not null default 'whatsapp' check (channel = 'whatsapp'),
  direction      public.message_direction not null,
  phone          text not null check (phone ~ '^\+[1-9][0-9]{6,14}$'),
  guest_id       uuid,
  booking_id     uuid,
  contact_name   text check (char_length(contact_name) <= 200),
  kind           text not null default 'text' check (kind in ('text', 'template', 'other')),
  body           text check (char_length(body) <= 4096),
  template_name  text check (template_name is null or (template_name ~ '^[a-z0-9_]+$' and char_length(template_name) <= 512)),
  template_lang  text check (template_lang is null or template_lang ~ '^[a-z]{2,3}(_[A-Z]{2})?$'),
  wa_message_id  text check (char_length(wa_message_id) <= 200),
  status         public.message_status not null,
  error          text check (char_length(error) <= 500),
  seen_at        timestamptz,
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now(),
  status_at      timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id) on delete set null (guest_id),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id) on delete set null (booking_id)
);
create unique index messages_wa_id_uidx on public.messages (tenant_id, wa_message_id) where wa_message_id is not null;
create index messages_thread_idx on public.messages (tenant_id, phone, created_at desc);
create index messages_guest_idx on public.messages (tenant_id, guest_id) where guest_id is not null;

alter table public.messages enable row level security;
create policy messages_select on public.messages for select to authenticated
  using (app.has_permission(tenant_id, 'messages.read'));
-- Запись только функциями (отправка проходит через Edge Function и проверку прав)
revoke insert, update, delete on public.messages from anon, authenticated;
revoke all on public.messages from anon;

-- ---------------------------------------------------------------------------
-- Вспомогательное: секреты в Vault
-- ---------------------------------------------------------------------------
create or replace function app.vault_put(p_id uuid, p_secret text, p_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  if p_id is not null and exists (select 1 from vault.secrets where id = p_id) then
    perform vault.update_secret(p_id, p_secret);
    return p_id;
  end if;
  return vault.create_secret(p_secret, p_name);
end $$;

create or replace function app.vault_get(p_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select decrypted_secret from vault.decrypted_secrets where id = p_id
$$;

create or replace function app.vault_drop(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from vault.secrets where id = p_id;
exception when insufficient_privilege then
  -- если удалять из Vault нельзя, затираем значение, чтобы старый токен перестал существовать
  perform vault.update_secret(p_id, 'revoked');
end $$;

revoke all on function app.vault_put(uuid, text, text), app.vault_get(uuid), app.vault_drop(uuid) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Настройки WhatsApp для сотрудников
-- ---------------------------------------------------------------------------

-- Состояние подключения. Токены не возвращаются; verify_token и адрес вебхука видит только settings.manage.
create or replace function public.whatsapp_settings(p_tenant uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_a public.whatsapp_accounts;
  v_admin boolean := app.has_permission(p_tenant, 'settings.manage');
begin
  if not (v_admin or app.has_permission(p_tenant, 'messages.read')) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  select * into v_a from public.whatsapp_accounts where tenant_id = p_tenant;
  if not found then
    return jsonb_build_object('connected', false, 'feature', app.plan_has_feature(p_tenant, 'integrations'));
  end if;
  return jsonb_build_object(
    'connected', true,
    'feature', app.plan_has_feature(p_tenant, 'integrations'),
    'is_enabled', v_a.is_enabled,
    'phone_number_id', v_a.phone_number_id,
    'waba_id', v_a.waba_id,
    'has_token', v_a.token_secret_id is not null,
    'has_app_secret', v_a.app_secret_id is not null,
    'status', v_a.status,
    'display_phone', v_a.display_phone,
    'verified_name', v_a.verified_name,
    'last_error', v_a.last_error,
    'checked_at', v_a.checked_at,
    'verify_token', case when v_admin then v_a.verify_token end);
end $$;

-- Сохранение подключения. Пустой токен или App Secret означает «оставить прежний».
create or replace function public.save_whatsapp_settings(
  p_tenant uuid, p_phone_number_id text, p_waba_id text default null,
  p_access_token text default null, p_app_secret text default null, p_enabled boolean default true
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_a public.whatsapp_accounts;
  v_new boolean;
  v_token text := nullif(btrim(coalesce(p_access_token, '')), '');
  v_secret text := nullif(btrim(coalesce(p_app_secret, '')), '');
  v_phone text := btrim(coalesce(p_phone_number_id, ''));
  v_waba text := nullif(btrim(coalesce(p_waba_id, '')), '');
  v_changed text[] := '{}';
begin
  if not app.has_permission(p_tenant, 'settings.manage') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not app.feature_enabled(p_tenant, 'integrations') then
    raise exception 'integrations are not available' using errcode = '42501';
  end if;
  if v_phone !~ '^[0-9]{5,25}$' or (v_waba is not null and v_waba !~ '^[0-9]{5,25}$') then
    raise exception 'invalid whatsapp ids' using errcode = '22023';
  end if;
  if (v_token is not null and (char_length(v_token) < 20 or char_length(v_token) > 1000 or v_token ~ '[[:space:]]'))
     or (v_secret is not null and v_secret !~ '^[0-9a-fA-F]{16,128}$') then
    raise exception 'invalid whatsapp credentials' using errcode = '22023';
  end if;

  select * into v_a from public.whatsapp_accounts where tenant_id = p_tenant for update;
  v_new := not found;
  if v_new and v_token is null then
    raise exception 'access token is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.whatsapp_accounts where phone_number_id = v_phone and tenant_id <> p_tenant) then
    raise exception 'whatsapp number is used by another sanatorium' using errcode = '23505';
  end if;

  if v_new then
    insert into public.whatsapp_accounts (tenant_id, phone_number_id, waba_id, verify_token, is_enabled)
    values (p_tenant, v_phone, v_waba, encode(extensions.gen_random_bytes(32), 'hex'), coalesce(p_enabled, true))
    returning * into v_a;
    v_changed := array['phone_number_id', 'access_token'];
  else
    if v_a.phone_number_id is distinct from v_phone then v_changed := v_changed || 'phone_number_id'::text; end if;
    if v_a.waba_id is distinct from v_waba then v_changed := v_changed || 'waba_id'::text; end if;
    if v_a.is_enabled is distinct from coalesce(p_enabled, true) then v_changed := v_changed || 'is_enabled'::text; end if;
    if v_token is not null then v_changed := v_changed || 'access_token'::text; end if;
  end if;
  if v_secret is not null then v_changed := v_changed || 'app_secret'::text; end if;

  update public.whatsapp_accounts set
    phone_number_id = v_phone,
    waba_id = v_waba,
    is_enabled = coalesce(p_enabled, true),
    token_secret_id = case when v_token is null then token_secret_id
                           else app.vault_put(token_secret_id, v_token, 'whatsapp_token_' || p_tenant) end,
    app_secret_id = case when v_secret is null then app_secret_id
                         else app.vault_put(app_secret_id, v_secret, 'whatsapp_app_secret_' || p_tenant) end,
    -- новые реквизиты нужно проверить заново
    status = case when v_token is not null or v_a.phone_number_id is distinct from v_phone then 'not_checked' else status end,
    last_error = case when v_token is not null or v_a.phone_number_id is distinct from v_phone then null else last_error end
  where tenant_id = p_tenant;

  -- в журнал попадают только названия изменённых полей, без токенов
  perform app.log_audit(p_tenant, case when v_new then 'integration.whatsapp_connect' else 'integration.whatsapp_update' end,
    'organization', p_tenant, 'success', jsonb_build_object('changed', to_jsonb(v_changed)));
  return public.whatsapp_settings(p_tenant);
end $$;

-- Отключение: удаляет секреты из Vault. Переписка остаётся.
create or replace function public.disconnect_whatsapp(p_tenant uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_a public.whatsapp_accounts;
begin
  if not app.has_permission(p_tenant, 'settings.manage') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  select * into v_a from public.whatsapp_accounts where tenant_id = p_tenant for update;
  if not found then
    return;
  end if;
  delete from public.whatsapp_accounts where tenant_id = p_tenant;
  if v_a.token_secret_id is not null then perform app.vault_drop(v_a.token_secret_id); end if;
  if v_a.app_secret_id is not null then perform app.vault_drop(v_a.app_secret_id); end if;
  perform app.log_audit(p_tenant, 'integration.whatsapp_disconnect', 'organization', p_tenant);
end $$;

-- Проверка подключения: вызывается Edge Function от имени сотрудника перед запросом к Meta
create or replace function public.whatsapp_begin_check(p_tenant uuid) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.has_permission(p_tenant, 'settings.manage') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not exists (select 1 from public.whatsapp_accounts where tenant_id = p_tenant and token_secret_id is not null) then
    raise exception 'whatsapp is not connected' using errcode = 'P0002';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Переписка для сотрудников
-- ---------------------------------------------------------------------------

-- Последнее входящее от номера: WhatsApp разрешает свободный текст только 24 часа после него
create or replace function app.whatsapp_window_open(p_tenant uuid, p_phone text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.messages
    where tenant_id = p_tenant and phone = p_phone and direction = 'in' and created_at > now() - interval '24 hours'
  )
$$;
revoke all on function app.whatsapp_window_open(uuid, text) from public, anon;
grant execute on function app.whatsapp_window_open(uuid, text) to authenticated, service_role;

-- Список диалогов: по одному на номер, с последним сообщением и числом непрочитанных
create or replace function public.message_threads(p_tenant uuid) returns table (
  phone text, guest_id uuid, guest_name text, contact_name text,
  last_at timestamptz, last_direction public.message_direction, last_body text, last_kind text, last_status public.message_status,
  unread bigint, window_open boolean
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.has_permission(p_tenant, 'messages.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  return query
  with last as (
    select distinct on (m.phone) m.phone, m.created_at, m.direction, m.body, m.kind, m.template_name, m.status
    from public.messages m where m.tenant_id = p_tenant
    order by m.phone, m.created_at desc
  )
  select l.phone,
         g.id, g.full_name,
         (select m.contact_name from public.messages m
          where m.tenant_id = p_tenant and m.phone = l.phone and m.contact_name is not null
          order by m.created_at desc limit 1),
         l.created_at, l.direction, coalesce(l.body, l.template_name), l.kind, l.status,
         (select count(*) from public.messages m
          where m.tenant_id = p_tenant and m.phone = l.phone and m.direction = 'in' and m.seen_at is null),
         app.whatsapp_window_open(p_tenant, l.phone)
  from last l
  left join public.guests g on g.tenant_id = p_tenant and g.phone = l.phone and g.archived_at is null
  order by l.created_at desc
  limit 300;
end $$;

-- Отметить входящие диалога прочитанными
create or replace function public.mark_thread_seen(p_tenant uuid, p_phone text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not app.has_permission(p_tenant, 'messages.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  update public.messages set seen_at = now()
  where tenant_id = p_tenant and phone = p_phone and direction = 'in' and seen_at is null;
end $$;

-- Создание исходящего сообщения (шаг 1 из 2): проверки и запись «в очереди».
-- Отправляет его Edge Function whatsapp (шаг 2), статус меняется только по ответу Meta.
create or replace function public.whatsapp_queue_message(
  p_tenant uuid, p_phone text, p_text text default null,
  p_template_name text default null, p_template_lang text default null, p_booking_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_a public.whatsapp_accounts;
  v_text text := nullif(btrim(coalesce(p_text, '')), '');
  v_tpl text := nullif(btrim(coalesce(p_template_name, '')), '');
  v_guest uuid;
  v_id uuid;
begin
  if not app.has_permission(p_tenant, 'messages.send') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not app.feature_enabled(p_tenant, 'integrations') then
    raise exception 'integrations are not available' using errcode = '42501';
  end if;
  select * into v_a from public.whatsapp_accounts where tenant_id = p_tenant;
  if not found or v_a.token_secret_id is null or not v_a.is_enabled then
    raise exception 'whatsapp is not connected' using errcode = 'P0002';
  end if;
  if p_phone is null or p_phone !~ '^\+[1-9][0-9]{6,14}$' then
    raise exception 'invalid phone' using errcode = '22023';
  end if;
  if (v_text is null) = (v_tpl is null) then
    raise exception 'text or template is required' using errcode = '22023';
  end if;
  if v_text is not null and char_length(v_text) > 4096 then
    raise exception 'text is too long' using errcode = '22023';
  end if;
  if v_tpl is not null and (v_tpl !~ '^[a-z0-9_]+$' or char_length(v_tpl) > 512 or coalesce(p_template_lang, '') !~ '^[a-z]{2,3}(_[A-Z]{2})?$') then
    raise exception 'invalid template' using errcode = '22023';
  end if;
  -- правило WhatsApp: свободный текст — только в течение 24 часов после последнего сообщения гостя
  if v_text is not null and not app.whatsapp_window_open(p_tenant, p_phone) then
    raise exception 'whatsapp 24h window is closed' using errcode = '22023';
  end if;
  if p_booking_id is not null and not exists (select 1 from public.bookings where id = p_booking_id and tenant_id = p_tenant) then
    raise exception 'booking not found' using errcode = 'P0002';
  end if;
  select id into v_guest from public.guests where tenant_id = p_tenant and phone = p_phone and archived_at is null;

  insert into public.messages (tenant_id, direction, phone, guest_id, booking_id, kind, body, template_name, template_lang, status, created_by)
  values (p_tenant, 'out', p_phone, v_guest, p_booking_id, case when v_tpl is null then 'text' else 'template' end,
          v_text, v_tpl, case when v_tpl is null then null else p_template_lang end, 'queued', auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Функции только для Edge Functions (ключ service_role). Клиенту недоступны.
-- ---------------------------------------------------------------------------

-- Шаг 2 отправки: забрать сообщение из очереди вместе с реквизитами. Повторно забрать нельзя.
create or replace function public.whatsapp_claim_message(p_message_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_m public.messages;
  v_a public.whatsapp_accounts;
begin
  update public.messages set status = 'sending', status_at = now()
  where id = p_message_id and status = 'queued' and direction = 'out' and created_at > now() - interval '10 minutes'
  returning * into v_m;
  if not found then
    raise exception 'message is not queued' using errcode = 'P0002';
  end if;
  select * into v_a from public.whatsapp_accounts where tenant_id = v_m.tenant_id and is_enabled;
  if not found or v_a.token_secret_id is null then
    -- без исключения: иначе откатится и отметка «не отправлено»
    update public.messages set status = 'failed', error = 'WhatsApp is not connected', status_at = now() where id = v_m.id;
    return jsonb_build_object('message_id', v_m.id, 'error', 'whatsapp is not connected');
  end if;
  return jsonb_build_object(
    'message_id', v_m.id, 'tenant_id', v_m.tenant_id,
    'phone_number_id', v_a.phone_number_id, 'access_token', app.vault_get(v_a.token_secret_id),
    'to', substr(v_m.phone, 2), 'kind', v_m.kind, 'body', v_m.body,
    'template_name', v_m.template_name, 'template_lang', v_m.template_lang);
end $$;

-- Результат отправки по ответу Meta
create or replace function public.whatsapp_finish_message(p_message_id uuid, p_wa_message_id text, p_error text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.messages set
    status = case when p_wa_message_id is not null and p_error is null then 'sent' else 'failed' end::public.message_status,
    wa_message_id = coalesce(p_wa_message_id, wa_message_id),
    error = left(p_error, 500),
    status_at = now()
  where id = p_message_id and status = 'sending';
end $$;

-- Реквизиты для проверки подключения (после whatsapp_begin_check от имени сотрудника)
create or replace function public.whatsapp_credentials(p_tenant uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('phone_number_id', phone_number_id, 'access_token', app.vault_get(token_secret_id))
  from public.whatsapp_accounts where tenant_id = p_tenant and token_secret_id is not null
$$;

create or replace function public.whatsapp_set_check_result(
  p_tenant uuid, p_ok boolean, p_display_phone text, p_verified_name text, p_error text
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.whatsapp_accounts set
    status = case when p_ok then 'ok' else 'error' end::public.whatsapp_check_status,
    display_phone = case when p_ok then left(p_display_phone, 40) else display_phone end,
    verified_name = case when p_ok then left(p_verified_name, 200) else verified_name end,
    last_error = case when p_ok then null else left(p_error, 500) end,
    checked_at = now()
  where tenant_id = p_tenant;
end $$;

-- Вебхук: проверка verify_token при подписке (GET от Meta)
create or replace function public.whatsapp_verify_token_valid(p_token text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.whatsapp_accounts where verify_token = p_token and is_enabled)
$$;

-- Вебхук: App Secret номера для проверки подписи. null — номер не подключён или секрет не задан.
create or replace function public.whatsapp_app_secret(p_phone_number_id text) returns text
language sql stable security definer set search_path = '' as $$
  select app.vault_get(app_secret_id) from public.whatsapp_accounts
  where phone_number_id = p_phone_number_id and app_secret_id is not null and is_enabled
$$;

-- Вебхук: входящие сообщения и статусы доставки (value из entry[].changes[] с field = messages).
-- Повторы от Meta не создают дублей (уникальный wa_message_id), статусы не откатываются назад.
create or replace function public.whatsapp_ingest(p_phone_number_id text, p_value jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_tenant uuid;
  v_msg jsonb;
  v_st jsonb;
  v_phone text;
  v_name text;
  v_type text;
  v_body text;
  v_in int := 0;
  v_upd int := 0;
  v_n int;
  v_rank_new int;
begin
  select tenant_id into v_tenant from public.whatsapp_accounts where phone_number_id = p_phone_number_id and is_enabled;
  if v_tenant is null then
    return jsonb_build_object('ignored', true);
  end if;

  for v_msg in select * from jsonb_array_elements(coalesce(p_value -> 'messages', '[]'::jsonb)) loop
    v_phone := '+' || regexp_replace(coalesce(v_msg ->> 'from', ''), '[^0-9]', '', 'g');
    continue when v_phone !~ '^\+[1-9][0-9]{6,14}$' or coalesce(v_msg ->> 'id', '') = '';
    v_type := coalesce(v_msg ->> 'type', 'other');
    v_body := case v_type
      when 'text' then v_msg #>> '{text,body}'
      when 'button' then v_msg #>> '{button,text}'
      when 'interactive' then coalesce(v_msg #>> '{interactive,button_reply,title}', v_msg #>> '{interactive,list_reply,title}')
      else coalesce(v_msg #>> array[v_type, 'caption'], null) end;
    v_name := null;
    select c ->> 'name' into v_name from (
      select c #> '{profile}' as c from jsonb_array_elements(coalesce(p_value -> 'contacts', '[]'::jsonb)) c
      where regexp_replace(coalesce(c ->> 'wa_id', ''), '[^0-9]', '', 'g') = substr(v_phone, 2)) x;

    insert into public.messages (tenant_id, direction, phone, guest_id, contact_name, kind, body, wa_message_id, status, created_at, status_at)
    values (v_tenant, 'in', v_phone,
            (select id from public.guests where tenant_id = v_tenant and phone = v_phone and archived_at is null),
            left(v_name, 200), case when v_type in ('text', 'button', 'interactive') then 'text' else 'other' end,
            left(v_body, 4096), left(v_msg ->> 'id', 200), 'received',
            coalesce(to_timestamp(nullif(v_msg ->> 'timestamp', '')::bigint), now()), now())
    on conflict (tenant_id, wa_message_id) where wa_message_id is not null do nothing;
    get diagnostics v_n = row_count;
    v_in := v_in + v_n;
  end loop;

  for v_st in select * from jsonb_array_elements(coalesce(p_value -> 'statuses', '[]'::jsonb)) loop
    v_rank_new := case v_st ->> 'status' when 'sent' then 1 when 'delivered' then 2 when 'read' then 3 when 'failed' then 4 else 0 end;
    continue when v_rank_new = 0;
    update public.messages m set
      status = (v_st ->> 'status')::public.message_status,
      error = case when v_st ->> 'status' = 'failed'
                   then left(coalesce(v_st #>> '{errors,0,title}', v_st #>> '{errors,0,message}', 'failed'), 500) else m.error end,
      status_at = now()
    where m.tenant_id = v_tenant and m.direction = 'out' and m.wa_message_id = v_st ->> 'id'
      and (case m.status when 'sent' then 1 when 'delivered' then 2 when 'read' then 3 when 'failed' then 4 else 0 end) < v_rank_new;
    get diagnostics v_n = row_count;
    v_upd := v_upd + v_n;
  end loop;

  return jsonb_build_object('received', v_in, 'statuses', v_upd);
end $$;

-- ---------------------------------------------------------------------------
-- Права на функции
-- ---------------------------------------------------------------------------
revoke all on function
  public.whatsapp_settings(uuid),
  public.save_whatsapp_settings(uuid, text, text, text, text, boolean),
  public.disconnect_whatsapp(uuid),
  public.whatsapp_begin_check(uuid),
  public.message_threads(uuid),
  public.mark_thread_seen(uuid, text),
  public.whatsapp_queue_message(uuid, text, text, text, text, uuid),
  public.whatsapp_claim_message(uuid),
  public.whatsapp_finish_message(uuid, text, text),
  public.whatsapp_credentials(uuid),
  public.whatsapp_set_check_result(uuid, boolean, text, text, text),
  public.whatsapp_verify_token_valid(text),
  public.whatsapp_app_secret(text),
  public.whatsapp_ingest(text, jsonb)
  from public, anon, authenticated;

grant execute on function
  public.whatsapp_settings(uuid),
  public.save_whatsapp_settings(uuid, text, text, text, text, boolean),
  public.disconnect_whatsapp(uuid),
  public.whatsapp_begin_check(uuid),
  public.message_threads(uuid),
  public.mark_thread_seen(uuid, text),
  public.whatsapp_queue_message(uuid, text, text, text, text, uuid)
  to authenticated;

grant execute on function
  public.whatsapp_claim_message(uuid),
  public.whatsapp_finish_message(uuid, text, text),
  public.whatsapp_credentials(uuid),
  public.whatsapp_set_check_result(uuid, boolean, text, text, text),
  public.whatsapp_verify_token_valid(text),
  public.whatsapp_app_secret(text),
  public.whatsapp_ingest(text, jsonb)
  to service_role;

commit;
