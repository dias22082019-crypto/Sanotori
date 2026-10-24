-- Sanatorium OS: установка базы одним файлом (собрано из supabase/migrations).
-- Supabase → SQL Editor → New query → вставить весь файл → Run. Выполняется один раз на пустом проекте.
-- Не редактируйте вручную: файл пересобирается скриптом scripts/build-setup-sql.sh
begin;

-- ===== supabase/migrations/20261023000001_core_rbac.sql =====
-- Sanatorium OS · 0001 · Организации, пользователи, роли и разрешения
-- Таблицы и справочник прав. Политики RLS и серверные функции — в 0003.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists btree_gist with schema extensions;
create extension if not exists pg_trgm with schema extensions;

create schema if not exists app;

-- ---------------------------------------------------------------------------
-- Общие типы и триггер updated_at
-- ---------------------------------------------------------------------------

create type public.member_status as enum ('active', 'suspended');
create type public.audit_result as enum ('success', 'denied', 'error');
create type public.app_language as enum ('ru', 'kk');

create or replace function app.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- tenant_id нельзя менять после создания строки
create or replace function app.forbid_tenant_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.tenant_id is distinct from old.tenant_id then
    raise exception 'tenant_id is immutable' using errcode = '42501';
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Организации (санатории)
-- ---------------------------------------------------------------------------

create table public.organizations (
  id               uuid primary key default gen_random_uuid(),
  slug             text not null unique
                   check (slug ~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$'),
  name             text not null check (char_length(name) between 2 and 200),
  description      text check (char_length(description) <= 5000),
  logo_path        text,
  address          text,
  city             text,
  phone            text check (phone is null or phone ~ '^\+[1-9][0-9]{7,14}$'),
  email            text,
  whatsapp_phone   text check (whatsapp_phone is null or whatsapp_phone ~ '^\+[1-9][0-9]{7,14}$'),
  legal_name       text,
  bin              text check (bin is null or bin ~ '^[0-9]{12}$'),
  timezone         text not null default 'Asia/Almaty',
  currency         text not null default 'KZT' check (currency = 'KZT'),
  default_language public.app_language not null default 'ru',
  is_published     boolean not null default false,
  booking_settings jsonb not null default
                   '{"check_in_time": "14:00", "check_out_time": "12:00", "prepayment_percent": 30}'::jsonb,
  parent_org_id    uuid references public.organizations(id) on delete set null,
  created_by       uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create trigger organizations_updated_at before update on public.organizations
  for each row execute function app.touch_updated_at();

-- Проверка часового пояса по справочнику PostgreSQL
create or replace function app.check_org_timezone() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = new.timezone) then
    raise exception 'unknown timezone %', new.timezone using errcode = '22023';
  end if;
  return new;
end $$;

create trigger organizations_timezone before insert or update of timezone on public.organizations
  for each row execute function app.check_org_timezone();

-- ---------------------------------------------------------------------------
-- Профили пользователей (минимум личных данных сотрудников)
-- ---------------------------------------------------------------------------

create table public.user_profiles (
  id                 uuid primary key references auth.users(id) on delete cascade,
  full_name          text check (char_length(full_name) <= 200),
  phone              text check (phone is null or phone ~ '^\+[1-9][0-9]{7,14}$'),
  preferred_language public.app_language not null default 'ru',
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create trigger user_profiles_updated_at before update on public.user_profiles
  for each row execute function app.touch_updated_at();

-- Профиль создаётся автоматически при регистрации в Supabase Auth
create or replace function app.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.user_profiles (id, full_name)
  values (new.id, left(coalesce(new.raw_user_meta_data ->> 'full_name', ''), 200))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function app.handle_new_user();

-- ---------------------------------------------------------------------------
-- Администраторы платформы (super_admin). Клиент не может сюда писать:
-- запись добавляется только SQL-скриптом под service role.
-- ---------------------------------------------------------------------------

create table public.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  note       text
);

-- ---------------------------------------------------------------------------
-- Разрешения и роли
-- ---------------------------------------------------------------------------

create table public.permissions (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code ~ '^[a-z_]+\.[a-z_]+$'),
  module      text not null,
  is_medical  boolean not null default false,
  description text
);

create table public.roles (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid references public.organizations(id) on delete cascade, -- null = системная роль
  code        text not null check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  name_ru     text not null,
  name_kk     text not null,
  is_system   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint roles_system_has_no_tenant check (is_system = (tenant_id is null)),
  constraint roles_code_unique unique nulls not distinct (tenant_id, code)
);

create trigger roles_updated_at before update on public.roles
  for each row execute function app.touch_updated_at();

create table public.role_permissions (
  role_id       uuid not null references public.roles(id) on delete cascade,
  permission_id uuid not null references public.permissions(id) on delete cascade,
  primary key (role_id, permission_id)
);

create table public.departments (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.organizations(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 120),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, name)
);
create trigger departments_updated_at before update on public.departments
  for each row execute function app.touch_updated_at();
create trigger departments_tenant before update on public.departments
  for each row execute function app.forbid_tenant_change();

-- ---------------------------------------------------------------------------
-- Членство в организации
-- ---------------------------------------------------------------------------

create table public.organization_members (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.organizations(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  role_id       uuid not null references public.roles(id),
  department_id uuid references public.departments(id) on delete set null,
  status        public.member_status not null default 'active',
  invited_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (tenant_id, user_id)
);

create index organization_members_user_idx on public.organization_members (user_id) where status = 'active';
create index organization_members_role_idx on public.organization_members (role_id);

create trigger organization_members_updated_at before update on public.organization_members
  for each row execute function app.touch_updated_at();
create trigger organization_members_tenant before update on public.organization_members
  for each row execute function app.forbid_tenant_change();

-- Роль участника должна быть системной или принадлежать той же организации
create or replace function app.check_member_role_tenant() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not exists (
    select 1 from public.roles r
    where r.id = new.role_id and (r.tenant_id is null or r.tenant_id = new.tenant_id)
  ) then
    raise exception 'role does not belong to this organization' using errcode = '23514';
  end if;
  return new;
end $$;

create trigger organization_members_role_tenant before insert or update of role_id, tenant_id
  on public.organization_members for each row execute function app.check_member_role_tenant();

-- ---------------------------------------------------------------------------
-- Приглашения. Токен хранится только как SHA-256 хэш.
-- ---------------------------------------------------------------------------

create table public.invitations (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.organizations(id) on delete cascade,
  email       text not null check (email = lower(email) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  role_id     uuid not null references public.roles(id) on delete cascade,
  token_hash  bytea not null unique,
  invited_by  uuid references auth.users(id) on delete set null,
  expires_at  timestamptz not null default now() + interval '7 days',
  accepted_at timestamptz,
  accepted_by uuid references auth.users(id) on delete set null,
  revoked_at  timestamptz,
  created_at  timestamptz not null default now()
);

create index invitations_tenant_idx on public.invitations (tenant_id);
create unique index invitations_one_open_per_email
  on public.invitations (tenant_id, email) where accepted_at is null and revoked_at is null;

-- ---------------------------------------------------------------------------
-- Доступ поддержки платформы: выдаёт владелец организации, срок и журнал обязательны.
-- ---------------------------------------------------------------------------

create table public.support_access_grants (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.organizations(id) on delete cascade,
  grantee_user_id uuid not null references auth.users(id) on delete cascade,
  scope           text not null check (scope in ('settings', 'bookings_readonly')),
  reason          text not null check (char_length(reason) between 5 and 500),
  granted_by      uuid not null references auth.users(id),
  expires_at      timestamptz not null check (expires_at <= created_at + interval '7 days'),
  revoked_at      timestamptz,
  created_at      timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Журнал действий. Только добавление; без паролей, токенов и медицинских текстов.
-- ---------------------------------------------------------------------------

create table public.audit_logs (
  id            bigint generated always as identity primary key,
  tenant_id     uuid references public.organizations(id) on delete set null,
  actor_user_id uuid,
  action        text not null,
  entity_type   text,
  entity_id     uuid,
  result        public.audit_result not null default 'success',
  details       jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);

create index audit_logs_tenant_time_idx on public.audit_logs (tenant_id, created_at desc);

create or replace function app.forbid_audit_mutation() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'audit_logs is append-only' using errcode = '42501';
end $$;

create trigger audit_logs_append_only before update or delete on public.audit_logs
  for each row execute function app.forbid_audit_mutation();

-- ---------------------------------------------------------------------------
-- Справочник разрешений
-- ---------------------------------------------------------------------------

insert into public.permissions (code, module, is_medical, description) values
  ('settings.manage',    'settings',   false, 'Настройки организации и публичной страницы'),
  ('members.read',       'staff',      false, 'Просмотр сотрудников'),
  ('members.manage',     'staff',      false, 'Приглашение сотрудников и смена ролей'),
  ('roles.manage',       'staff',      false, 'Пользовательские роли'),
  ('billing.manage',     'billing',    false, 'Подписка SaaS'),
  ('audit.read',         'audit',      false, 'Журнал действий'),
  ('media.write',        'settings',   false, 'Загрузка фото и логотипа'),
  ('rooms.read',         'rooms',      false, 'Просмотр номеров'),
  ('rooms.write',        'rooms',      false, 'Изменение номеров и тарифов'),
  ('rooms.status',       'rooms',      false, 'Смена статуса уборки/обслуживания'),
  ('rooms.delete',       'rooms',      false, 'Удаление номеров'),
  ('guests.read',        'guests',     false, 'Просмотр гостей'),
  ('guests.write',       'guests',     false, 'Создание и изменение гостей'),
  ('guests.notes',       'guests',     false, 'Заметки с ограниченным доступом'),
  ('guests.export',      'guests',     false, 'Экспорт гостей'),
  ('guests.archive',     'guests',     false, 'Архивирование и обезличивание гостей'),
  ('bookings.read',      'bookings',   false, 'Просмотр бронирований'),
  ('bookings.write',     'bookings',   false, 'Создание и изменение бронирований'),
  ('bookings.checkin',   'bookings',   false, 'Заселение и выезд'),
  ('bookings.cancel',    'bookings',   false, 'Отмена бронирований'),
  ('leads.read',         'leads',      false, 'Просмотр заявок'),
  ('leads.write',        'leads',      false, 'Обработка заявок'),
  ('finance.read',       'finance',    false, 'Финансовые данные'),
  ('finance.write',      'finance',    false, 'Расходы, счета'),
  ('payments.accept',    'finance',    false, 'Приём оплаты'),
  ('refunds.create',     'finance',    false, 'Возвраты'),
  ('reports.read',       'reports',    false, 'Отчёты'),
  ('procedures.read',    'procedures', false, 'Расписание процедур'),
  ('procedures.write',   'procedures', false, 'Каталог процедур и запись'),
  ('procedures.status',  'procedures', false, 'Отметка выполнения процедур'),
  ('medical.read',       'medical',    true,  'Медицинские записи: чтение'),
  ('medical.write',      'medical',    true,  'Медицинские записи: изменение'),
  ('inventory.read',     'inventory',  false, 'Склад: просмотр'),
  ('inventory.write',    'inventory',  false, 'Склад: движения'),
  ('tasks.read',         'tasks',      false, 'Задачи'),
  ('tasks.write',        'tasks',      false, 'Назначение задач'),
  ('staff.read',         'staff',      false, 'Графики персонала'),
  ('staff.write',        'staff',      false, 'Изменение графиков'),
  ('messages.read',      'messages',   false, 'Диалоги WhatsApp'),
  ('messages.send',      'messages',   false, 'Отправка сообщений'),
  ('marketing.read',     'marketing',  false, 'Отзывы и сегменты'),
  ('marketing.write',    'marketing',  false, 'Промокоды и предложения');

-- ---------------------------------------------------------------------------
-- Системные роли и их права по умолчанию
-- ---------------------------------------------------------------------------

insert into public.roles (tenant_id, code, name_ru, name_kk, is_system) values
  (null, 'owner',        'Владелец',          'Иесі',             true),
  (null, 'director',     'Директор',          'Директор',         true),
  (null, 'manager',      'Менеджер',          'Менеджер',         true),
  (null, 'receptionist', 'Ресепшен',          'Ресепшн',          true),
  (null, 'accountant',   'Бухгалтер',         'Бухгалтер',        true),
  (null, 'doctor',       'Врач',              'Дәрігер',          true),
  (null, 'nurse',        'Медсестра',         'Мейірбике',        true),
  (null, 'housekeeping', 'Горничная',         'Үй қызметшісі',    true);

with matrix(role_code, perm_code) as (
  -- owner: всё, кроме медицинских записей
  select 'owner', code from public.permissions where not is_medical
  union all
  select 'director', unnest(array[
    'members.read','audit.read','rooms.read','rooms.write','rooms.status',
    'guests.read','guests.write','guests.notes','guests.export',
    'bookings.read','bookings.write','bookings.checkin','bookings.cancel',
    'leads.read','leads.write','finance.read','reports.read',
    'procedures.read','procedures.write','procedures.status',
    'inventory.read','tasks.read','tasks.write','staff.read','staff.write',
    'messages.read','messages.send','marketing.read','marketing.write'])
  union all
  select 'manager', unnest(array[
    'rooms.read','guests.read','guests.write','guests.notes',
    'bookings.read','bookings.write','bookings.cancel',
    'leads.read','leads.write','payments.accept',
    'procedures.read','messages.read','messages.send','tasks.read'])
  union all
  select 'receptionist', unnest(array[
    'rooms.read','rooms.status','guests.read','guests.write',
    'bookings.read','bookings.write','bookings.checkin',
    'leads.read','leads.write','payments.accept',
    'procedures.read','messages.read','messages.send','tasks.read'])
  union all
  select 'accountant', unnest(array[
    'rooms.read','guests.read','bookings.read',
    'finance.read','finance.write','payments.accept','refunds.create',
    'reports.read','inventory.read'])
  union all
  select 'doctor', unnest(array[
    'guests.read','procedures.read','procedures.write','procedures.status',
    'medical.read','medical.write','tasks.read'])
  union all
  select 'nurse', unnest(array[
    'guests.read','procedures.read','procedures.status','medical.read','tasks.read'])
  union all
  select 'housekeeping', unnest(array[
    'rooms.read','rooms.status','tasks.read'])
)
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from matrix m
join public.roles r on r.code = m.role_code and r.tenant_id is null
join public.permissions p on p.code = m.perm_code;

-- ===== supabase/migrations/20261023000002_billing.sql =====
-- Sanatorium OS · 0002 · Тарифы и подписки SaaS
-- Оплата подписки санаторием хранится отдельно от оплат гостей (те появятся в 0007).

create type public.subscription_status as enum ('trialing', 'active', 'past_due', 'suspended', 'cancelled');
create type public.billing_period as enum ('monthly', 'yearly');
create type public.payment_status as enum ('pending', 'paid', 'failed', 'cancelled', 'refunded', 'partially_refunded');

create table public.subscription_plans (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  name_ru       text not null,
  name_kk       text not null,
  description_ru text,
  description_kk text,
  price_monthly numeric(14,2) not null default 0 check (price_monthly >= 0),
  price_yearly  numeric(14,2) not null default 0 check (price_yearly >= 0),
  currency      text not null default 'KZT' check (currency = 'KZT'),
  max_staff     integer check (max_staff is null or max_staff > 0),
  max_rooms     integer check (max_rooms is null or max_rooms > 0),
  trial_days    integer not null default 14 check (trial_days between 0 and 90),
  is_active     boolean not null default true,
  is_public     boolean not null default true,
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create trigger subscription_plans_updated_at before update on public.subscription_plans
  for each row execute function app.touch_updated_at();

-- Функции, которые включает тариф (коды модулей)
create table public.plan_features (
  plan_id      uuid not null references public.subscription_plans(id) on delete cascade,
  feature_code text not null check (feature_code ~ '^[a-z_]+$'),
  primary key (plan_id, feature_code)
);

create table public.organization_subscriptions (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.organizations(id) on delete cascade,
  plan_id              uuid not null references public.subscription_plans(id),
  status               public.subscription_status not null,
  billing_period       public.billing_period not null default 'monthly',
  trial_ends_at        timestamptz,
  current_period_start timestamptz,
  current_period_end   timestamptz,
  grace_days           integer not null default 7 check (grace_days between 0 and 60),
  cancel_at            timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint trial_has_end check (status <> 'trialing' or trial_ends_at is not null),
  constraint period_is_ordered check (current_period_end is null or current_period_start is null
                                      or current_period_end > current_period_start)
);

-- У организации одна текущая подписка
create unique index organization_subscriptions_one_current
  on public.organization_subscriptions (tenant_id) where status <> 'cancelled';

create trigger organization_subscriptions_updated_at before update on public.organization_subscriptions
  for each row execute function app.touch_updated_at();
create trigger organization_subscriptions_tenant before update on public.organization_subscriptions
  for each row execute function app.forbid_tenant_change();

create table public.subscription_invoices (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.organizations(id) on delete cascade,
  subscription_id     uuid not null references public.organization_subscriptions(id) on delete cascade,
  amount              numeric(14,2) not null check (amount > 0),
  currency            text not null default 'KZT' check (currency = 'KZT'),
  period_start        timestamptz not null,
  period_end          timestamptz not null check (period_end > period_start),
  status              public.payment_status not null default 'pending',
  provider            text,
  provider_payment_id text,
  is_test             boolean not null default false,
  paid_at             timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (provider, provider_payment_id)
);

create index subscription_invoices_tenant_idx on public.subscription_invoices (tenant_id, created_at desc);
create trigger subscription_invoices_updated_at before update on public.subscription_invoices
  for each row execute function app.touch_updated_at();
create trigger subscription_invoices_tenant before update on public.subscription_invoices
  for each row execute function app.forbid_tenant_change();

-- ---------------------------------------------------------------------------
-- Начальные тарифы. Цены 0 — это заглушка: владелец платформы задаёт их в /admin/plans.
-- ---------------------------------------------------------------------------

insert into public.subscription_plans (code, name_ru, name_kk, max_staff, max_rooms, trial_days, sort_order) values
  ('start',      'Start',      'Start',      5,    30,   14, 1),
  ('business',   'Business',   'Business',   50,   300,  14, 2),
  ('enterprise', 'Enterprise', 'Enterprise', null, null, 14, 3);

with features(plan_code, feature) as (
  select 'start', unnest(array['rooms','guests','bookings','public_site'])
  union all
  select 'business', unnest(array['rooms','guests','bookings','public_site','finance','procedures',
                                  'inventory','tasks','analytics','integrations','marketing'])
  union all
  select 'enterprise', unnest(array['rooms','guests','bookings','public_site','finance','procedures',
                                    'inventory','tasks','analytics','integrations','marketing',
                                    'custom_roles','branches'])
)
insert into public.plan_features (plan_id, feature_code)
select p.id, f.feature from features f join public.subscription_plans p on p.code = f.plan_code;

-- ===== supabase/migrations/20261023000003_security_rls.sql =====
-- Sanatorium OS · 0003 · Функции проверки доступа, RLS и серверные операции
-- Принцип: клиент не пишет напрямую в таблицы членства, ролей и подписок.
-- Все изменения прав идут через функции ниже, которые сами проверяют права вызывающего.
-- Отказ (exception) откатывает транзакцию целиком, поэтому отклонённые попытки в audit_logs
-- не попадают: их фиксируют логи API Supabase и Edge Functions.

-- ---------------------------------------------------------------------------
-- Функции проверки доступа (security definer: читают таблицы прав в обход RLS,
-- чтобы политики не вызывали друг друга рекурсивно)
-- ---------------------------------------------------------------------------

create or replace function app.is_platform_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid())
$$;

create or replace function app.is_member(p_tenant uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.organization_members m
    where m.tenant_id = p_tenant and m.user_id = auth.uid() and m.status = 'active'
  )
$$;

create or replace function app.has_permission(p_tenant uuid, p_code text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.organization_members m
    join public.role_permissions rp on rp.role_id = m.role_id
    join public.permissions p on p.id = rp.permission_id
    where m.tenant_id = p_tenant and m.user_id = auth.uid()
      and m.status = 'active' and p.code = p_code
  )
$$;

create or replace function app.member_role_code(p_tenant uuid) returns text
language sql stable security definer set search_path = '' as $$
  select r.code
  from public.organization_members m join public.roles r on r.id = m.role_id
  where m.tenant_id = p_tenant and m.user_id = auth.uid() and m.status = 'active'
$$;

-- Текущая подписка позволяет изменять данные (просмотр и экспорт не ограничиваются никогда)
create or replace function app.subscription_writable(p_tenant uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.organization_subscriptions s
    where s.tenant_id = p_tenant
      and (
        (s.status = 'trialing' and s.trial_ends_at > now())
        or (s.status = 'active' and (s.current_period_end is null or s.current_period_end > now()))
        or (s.status = 'past_due'
            and coalesce(s.current_period_end, s.trial_ends_at) + make_interval(days => s.grace_days) > now())
      )
  )
$$;

-- Функция тарифа включена и подписка позволяет изменения
create or replace function app.feature_enabled(p_tenant uuid, p_feature text) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.subscription_writable(p_tenant) and exists (
    select 1
    from public.organization_subscriptions s
    join public.plan_features f on f.plan_id = s.plan_id
    where s.tenant_id = p_tenant and s.status <> 'cancelled' and f.feature_code = p_feature
  )
$$;

-- Может ли текущий пользователь выдать роль (защита от повышения прав):
-- владелец может выдать любую роль; остальные — только роль, все права которой есть у них самих,
-- и никто, кроме владельца, не выдаёт роль owner.
create or replace function app.can_grant_role(p_tenant uuid, p_role_id uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_role public.roles;
  v_caller_role text := app.member_role_code(p_tenant);
begin
  select * into v_role from public.roles where id = p_role_id;
  if not found or (v_role.tenant_id is not null and v_role.tenant_id <> p_tenant) then
    return false;
  end if;
  if v_caller_role is null or not app.has_permission(p_tenant, 'members.manage') then
    return false;
  end if;
  if v_caller_role = 'owner' then
    return true;
  end if;
  if v_role.code = 'owner' then
    return false;
  end if;
  return not exists (
    select 1 from public.role_permissions rp
    join public.permissions p on p.id = rp.permission_id
    where rp.role_id = p_role_id and not app.has_permission(p_tenant, p.code)
  );
end $$;

-- Запись в журнал: только из серверных функций
create or replace function app.log_audit(
  p_tenant uuid, p_action text, p_entity_type text, p_entity_id uuid,
  p_result public.audit_result default 'success', p_details jsonb default '{}'::jsonb
) returns void
language sql security definer set search_path = '' as $$
  insert into public.audit_logs (tenant_id, actor_user_id, action, entity_type, entity_id, result, details)
  values (p_tenant, auth.uid(), p_action, p_entity_type, p_entity_id, p_result, coalesce(p_details, '{}'::jsonb))
$$;

grant usage on schema app to anon, authenticated, service_role;
revoke all on all functions in schema app from public;
grant execute on function
  app.is_platform_admin(), app.is_member(uuid), app.has_permission(uuid, text),
  app.member_role_code(uuid), app.subscription_writable(uuid), app.feature_enabled(uuid, text),
  app.can_grant_role(uuid, uuid)
  to anon, authenticated, service_role;
-- log_audit вызывают только серверные функции (они выполняются от владельца схемы)

-- ---------------------------------------------------------------------------
-- RLS: включаем на всех таблицах. Нет политики на операцию = операция запрещена.
-- ---------------------------------------------------------------------------

alter table public.organizations              enable row level security;
alter table public.user_profiles              enable row level security;
alter table public.platform_admins            enable row level security;
alter table public.permissions                enable row level security;
alter table public.roles                      enable row level security;
alter table public.role_permissions           enable row level security;
alter table public.departments                enable row level security;
alter table public.organization_members       enable row level security;
alter table public.invitations                enable row level security;
alter table public.support_access_grants      enable row level security;
alter table public.audit_logs                 enable row level security;
alter table public.subscription_plans         enable row level security;
alter table public.plan_features              enable row level security;
alter table public.organization_subscriptions enable row level security;
alter table public.subscription_invoices      enable row level security;

-- organizations: читать могут участники и админ платформы; менять — settings.manage.
-- Создание только через create_organization(), удаление не предусмотрено.
create policy organizations_select on public.organizations for select to authenticated
  using (app.is_member(id) or app.is_platform_admin());
create policy organizations_update on public.organizations for update to authenticated
  using (app.has_permission(id, 'settings.manage'))
  with check (app.has_permission(id, 'settings.manage'));

-- Защищённые поля организации меняются только серверными функциями
create or replace function app.protect_org_columns() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon')
     and (new.slug is distinct from old.slug
          or new.created_by is distinct from old.created_by
          or new.parent_org_id is distinct from old.parent_org_id) then
    raise exception 'protected organization fields' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger organizations_protect before update on public.organizations
  for each row execute function app.protect_org_columns();

-- user_profiles: свой профиль + профили коллег по организации (имя для списков сотрудников)
create policy user_profiles_select on public.user_profiles for select to authenticated
  using (
    id = auth.uid()
    or exists (
      select 1 from public.organization_members them
      where them.user_id = user_profiles.id and app.is_member(them.tenant_id)
    )
  );
create policy user_profiles_update on public.user_profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- platform_admins: пользователь видит только свою запись (чтобы UI знал, показывать ли /admin)
create policy platform_admins_select on public.platform_admins for select to authenticated
  using (user_id = auth.uid());

-- Справочники прав и ролей: только чтение
create policy permissions_select on public.permissions for select to authenticated using (true);
create policy roles_select on public.roles for select to authenticated
  using (tenant_id is null or app.is_member(tenant_id));
create policy role_permissions_select on public.role_permissions for select to authenticated
  using (exists (select 1 from public.roles r
                 where r.id = role_id and (r.tenant_id is null or app.is_member(r.tenant_id))));

-- departments
create policy departments_select on public.departments for select to authenticated
  using (app.is_member(tenant_id));
create policy departments_insert on public.departments for insert to authenticated
  with check (app.has_permission(tenant_id, 'members.manage') and app.subscription_writable(tenant_id));
create policy departments_update on public.departments for update to authenticated
  using (app.has_permission(tenant_id, 'members.manage'))
  with check (app.has_permission(tenant_id, 'members.manage'));
create policy departments_delete on public.departments for delete to authenticated
  using (app.has_permission(tenant_id, 'members.manage'));

-- organization_members: участники видят коллег; запись только через функции
create policy organization_members_select on public.organization_members for select to authenticated
  using (app.is_member(tenant_id) or user_id = auth.uid());

-- invitations: видят те, кто управляет сотрудниками
create policy invitations_select on public.invitations for select to authenticated
  using (app.has_permission(tenant_id, 'members.manage'));

-- support_access_grants: владелец видит выданные доступы, админ платформы — свои
create policy support_access_grants_select on public.support_access_grants for select to authenticated
  using (app.has_permission(tenant_id, 'settings.manage') or grantee_user_id = auth.uid());

-- audit_logs: только чтение по праву audit.read; события платформы (tenant_id is null) — админу
create policy audit_logs_select on public.audit_logs for select to authenticated
  using ((tenant_id is not null and app.has_permission(tenant_id, 'audit.read'))
         or (tenant_id is null and app.is_platform_admin()));

-- Тарифы: публичные активные видны всем (для страницы цен), все — админу платформы
create policy subscription_plans_select_public on public.subscription_plans for select to anon, authenticated
  using ((is_active and is_public) or app.is_platform_admin());
create policy subscription_plans_admin_insert on public.subscription_plans for insert to authenticated
  with check (app.is_platform_admin());
create policy subscription_plans_admin_update on public.subscription_plans for update to authenticated
  using (app.is_platform_admin()) with check (app.is_platform_admin());

create policy plan_features_select on public.plan_features for select to anon, authenticated
  using (exists (select 1 from public.subscription_plans p
                 where p.id = plan_id and ((p.is_active and p.is_public) or app.is_platform_admin())));
create policy plan_features_admin_insert on public.plan_features for insert to authenticated
  with check (app.is_platform_admin());
create policy plan_features_admin_delete on public.plan_features for delete to authenticated
  using (app.is_platform_admin());

-- Подписки: участники видят статус своей; админ платформы — все. Изменение — только функциями.
create policy organization_subscriptions_select on public.organization_subscriptions for select to authenticated
  using (app.is_member(tenant_id) or app.is_platform_admin());

create policy subscription_invoices_select on public.subscription_invoices for select to authenticated
  using (app.has_permission(tenant_id, 'billing.manage') or app.is_platform_admin());

-- ---------------------------------------------------------------------------
-- Серверные операции (RPC). Каждая сама проверяет права и пишет журнал.
-- ---------------------------------------------------------------------------

-- Регистрация санатория: вызывающий становится owner, стартует пробный период
create or replace function public.create_organization(
  p_name text, p_slug text, p_city text default null, p_language public.app_language default 'ru'
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid    uuid := auth.uid();
  v_org_id uuid;
  v_plan   public.subscription_plans;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if (select count(*) from public.organizations where created_by = v_uid) >= 5 then
    raise exception 'organization limit reached' using errcode = '54000';
  end if;

  insert into public.organizations (name, slug, city, default_language, created_by)
  values (trim(p_name), lower(trim(p_slug)), nullif(trim(p_city), ''), p_language, v_uid)
  returning id into v_org_id;

  insert into public.organization_members (tenant_id, user_id, role_id, status)
  select v_org_id, v_uid, r.id, 'active' from public.roles r where r.code = 'owner' and r.tenant_id is null;

  select * into v_plan from public.subscription_plans where code = 'business' and is_active;
  if found then
    insert into public.organization_subscriptions (tenant_id, plan_id, status, trial_ends_at)
    values (v_org_id, v_plan.id, 'trialing', now() + make_interval(days => v_plan.trial_days));
  end if;

  perform app.log_audit(v_org_id, 'organization.create', 'organization', v_org_id);
  return v_org_id;
end $$;

-- Приглашение сотрудника. Возвращает токен один раз; в базе хранится только хэш.
create or replace function public.invite_member(p_tenant uuid, p_email text, p_role_id uuid)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_token text;
  v_email text := lower(trim(p_email));
  v_staff_count integer;
  v_max_staff integer;
begin
  if not app.can_grant_role(p_tenant, p_role_id) then
    raise exception 'not allowed to grant this role' using errcode = '42501';
  end if;
  if not app.subscription_writable(p_tenant) then
    raise exception 'subscription does not allow changes' using errcode = '42501';
  end if;

  select count(*) into v_staff_count from public.organization_members
   where tenant_id = p_tenant and status = 'active';
  select p.max_staff into v_max_staff
    from public.organization_subscriptions s join public.subscription_plans p on p.id = s.plan_id
   where s.tenant_id = p_tenant and s.status <> 'cancelled';
  if v_max_staff is not null and v_staff_count >= v_max_staff then
    raise exception 'staff limit of the plan reached' using errcode = '54000';
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  -- закрываем прежнее открытое приглашение на этот email
  update public.invitations set revoked_at = now()
   where tenant_id = p_tenant and email = v_email and accepted_at is null and revoked_at is null;

  insert into public.invitations (tenant_id, email, role_id, token_hash, invited_by)
  values (p_tenant, v_email, p_role_id, sha256(convert_to(v_token, 'UTF8')), auth.uid());

  perform app.log_audit(p_tenant, 'member.invite', 'role', p_role_id, 'success',
                        jsonb_build_object('email_domain', split_part(v_email, '@', 2)));
  return v_token;
end $$;

-- Принятие приглашения: email в токене Supabase должен совпадать с адресом приглашения
create or replace function public.accept_invitation(p_token text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(auth.jwt() ->> 'email');
  v_inv   public.invitations;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select * into v_inv from public.invitations
   where token_hash = sha256(convert_to(p_token, 'UTF8'))
     and accepted_at is null and revoked_at is null and expires_at > now()
   for update;
  if not found then
    raise exception 'invitation is invalid or expired' using errcode = 'P0002';
  end if;
  if v_inv.email <> v_email then
    raise exception 'invitation was sent to another email' using errcode = '42501';
  end if;

  insert into public.organization_members (tenant_id, user_id, role_id, status, invited_by)
  values (v_inv.tenant_id, v_uid, v_inv.role_id, 'active', v_inv.invited_by)
  on conflict (tenant_id, user_id) do update set role_id = excluded.role_id, status = 'active';

  update public.invitations set accepted_at = now(), accepted_by = v_uid where id = v_inv.id;
  perform app.log_audit(v_inv.tenant_id, 'member.accept', 'invitation', v_inv.id);
  return v_inv.tenant_id;
end $$;

-- Смена роли сотрудника
create or replace function public.assign_member_role(p_member_id uuid, p_role_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_member public.organization_members;
  v_old_code text;
begin
  select * into v_member from public.organization_members where id = p_member_id for update;
  if not found then
    raise exception 'member not found' using errcode = 'P0002';
  end if;
  if v_member.user_id = auth.uid() then
    raise exception 'cannot change own role' using errcode = '42501';
  end if;
  if not app.can_grant_role(v_member.tenant_id, p_role_id) then
    raise exception 'not allowed to grant this role' using errcode = '42501';
  end if;

  select code into v_old_code from public.roles where id = v_member.role_id;
  if v_old_code = 'owner' and app.member_role_code(v_member.tenant_id) <> 'owner' then
    raise exception 'only an owner can change another owner' using errcode = '42501';
  end if;

  update public.organization_members set role_id = p_role_id where id = p_member_id;
  perform app.log_audit(v_member.tenant_id, 'member.role_change', 'member', p_member_id, 'success',
                        jsonb_build_object('from', v_old_code,
                                           'to', (select code from public.roles where id = p_role_id)));
end $$;

-- Приостановка / возобновление доступа сотрудника
create or replace function public.set_member_status(p_member_id uuid, p_status public.member_status)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_member public.organization_members;
  v_code text;
begin
  select * into v_member from public.organization_members where id = p_member_id for update;
  if not found then
    raise exception 'member not found' using errcode = 'P0002';
  end if;
  if v_member.user_id = auth.uid() or not app.has_permission(v_member.tenant_id, 'members.manage') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select code into v_code from public.roles where id = v_member.role_id;
  if v_code = 'owner' and app.member_role_code(v_member.tenant_id) <> 'owner' then
    raise exception 'only an owner can suspend another owner' using errcode = '42501';
  end if;

  update public.organization_members set status = p_status where id = p_member_id;
  perform app.log_audit(v_member.tenant_id, 'member.status_change', 'member', p_member_id, 'success',
                        jsonb_build_object('status', p_status));
end $$;

-- В организации всегда остаётся хотя бы один активный владелец
create or replace function app.keep_one_owner() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_owner_role uuid := (select id from public.roles where code = 'owner' and tenant_id is null);
begin
  if old.role_id = v_owner_role and old.status = 'active'
     and (tg_op = 'DELETE' or new.role_id <> v_owner_role or new.status <> 'active')
     and not exists (
       select 1 from public.organization_members m
       where m.tenant_id = old.tenant_id and m.id <> old.id
         and m.role_id = v_owner_role and m.status = 'active')
  then
    raise exception 'organization must keep at least one active owner' using errcode = '23514';
  end if;
  return coalesce(new, old);
end $$;

create trigger organization_members_keep_owner before update or delete on public.organization_members
  for each row execute function app.keep_one_owner();

-- Пользовательская роль (custom): только права, которые есть у создателя; медицинские — нельзя
create or replace function public.upsert_custom_role(
  p_tenant uuid, p_code text, p_name_ru text, p_name_kk text, p_permission_codes text[]
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_role_id uuid;
  v_bad text;
begin
  if not app.has_permission(p_tenant, 'roles.manage') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not app.feature_enabled(p_tenant, 'custom_roles') then
    raise exception 'custom roles are not included in the plan' using errcode = '42501';
  end if;

  select c into v_bad from unnest(p_permission_codes) c
   where not exists (select 1 from public.permissions p where p.code = c)
      or exists (select 1 from public.permissions p where p.code = c and p.is_medical)
      or not app.has_permission(p_tenant, c)
   limit 1;
  if v_bad is not null then
    raise exception 'permission % cannot be granted', v_bad using errcode = '42501';
  end if;

  insert into public.roles (tenant_id, code, name_ru, name_kk, is_system)
  values (p_tenant, p_code, p_name_ru, p_name_kk, false)
  on conflict (tenant_id, code) do update set name_ru = excluded.name_ru, name_kk = excluded.name_kk
  returning id into v_role_id;

  delete from public.role_permissions where role_id = v_role_id;
  insert into public.role_permissions (role_id, permission_id)
  select v_role_id, p.id from public.permissions p where p.code = any (p_permission_codes);

  perform app.log_audit(p_tenant, 'role.upsert', 'role', v_role_id, 'success',
                        jsonb_build_object('permissions', p_permission_codes));
  return v_role_id;
end $$;

-- Список организаций текущего пользователя (для экрана выбора организации)
create or replace function public.my_organizations()
returns table (tenant_id uuid, slug text, name text, role_code text, logo_path text)
language sql stable security definer set search_path = '' as $$
  select o.id, o.slug, o.name, r.code, o.logo_path
  from public.organization_members m
  join public.organizations o on o.id = m.tenant_id
  join public.roles r on r.id = m.role_id
  where m.user_id = auth.uid() and m.status = 'active'
  order by o.name
$$;

-- Права текущего пользователя в организации (UI скрывает недоступное; решает всё равно RLS)
create or replace function public.my_permissions(p_tenant uuid) returns text[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(p.code order by p.code), '{}')
  from public.organization_members m
  join public.role_permissions rp on rp.role_id = m.role_id
  join public.permissions p on p.id = rp.permission_id
  where m.tenant_id = p_tenant and m.user_id = auth.uid() and m.status = 'active'
$$;

-- Супер-админ: приостановка / возобновление подписки организации
create or replace function public.admin_set_subscription_status(p_tenant uuid, p_status public.subscription_status)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not app.is_platform_admin() then
    raise exception 'platform admin only' using errcode = '42501';
  end if;
  update public.organization_subscriptions set status = p_status
   where tenant_id = p_tenant and status <> 'cancelled';
  if not found then
    raise exception 'subscription not found' using errcode = 'P0002';
  end if;
  perform app.log_audit(null, 'admin.subscription_status', 'organization', p_tenant, 'success',
                        jsonb_build_object('status', p_status));
end $$;

-- Доступ к функциям: только вошедшим пользователям
revoke execute on function
  public.create_organization(text, text, text, public.app_language),
  public.invite_member(uuid, text, uuid),
  public.accept_invitation(text),
  public.assign_member_role(uuid, uuid),
  public.set_member_status(uuid, public.member_status),
  public.upsert_custom_role(uuid, text, text, text, text[]),
  public.my_organizations(),
  public.my_permissions(uuid),
  public.admin_set_subscription_status(uuid, public.subscription_status)
  from public, anon;
grant execute on function
  public.create_organization(text, text, text, public.app_language),
  public.invite_member(uuid, text, uuid),
  public.accept_invitation(text),
  public.assign_member_role(uuid, uuid),
  public.set_member_status(uuid, public.member_status),
  public.upsert_custom_role(uuid, text, text, text, text[]),
  public.my_organizations(),
  public.my_permissions(uuid),
  public.admin_set_subscription_status(uuid, public.subscription_status)
  to authenticated;

-- ===== supabase/migrations/20261023000004_public_site.sql =====
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

-- ===== supabase/migrations/20261023000005_rooms_bookings.sql =====
-- Sanatorium OS · 0005 · Номерной фонд, гости, бронирования (этап 3)
-- Принципы:
--  * каждая таблица несёт tenant_id; связи между таблицами санатория — составными ключами
--    (tenant_id, id), поэтому бронь не может сослаться на номер или гостя чужого санатория;
--  * цену брони считает только сервер (app.calc_booking_price), клиент её не передаёт;
--  * двойная бронь одного номера невозможна на уровне БД (exclusion constraint);
--  * бронирования меняются только через функции ниже: они проверяют права, статусы и подписку.

-- ---------------------------------------------------------------------------
-- Типы
-- ---------------------------------------------------------------------------

create type public.room_status as enum ('available', 'occupied', 'cleaning', 'maintenance');
create type public.booking_status as enum (
  'new_request',  -- заявка (с сайта или вручную), номер ещё не закреплён
  'confirmed',    -- подтверждена, номер закреплён
  'checked_in',   -- гость проживает
  'checked_out',  -- выехал
  'cancelled',
  'no_show'
);
create type public.booking_source as enum ('walk_in', 'phone', 'whatsapp', 'website', 'agent', 'other');

-- ---------------------------------------------------------------------------
-- Категории номеров и цены
-- ---------------------------------------------------------------------------

create table public.room_types (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.organizations(id) on delete cascade,
  name              text not null check (char_length(trim(name)) between 1 and 120),
  description       text check (char_length(description) <= 2000),
  base_occupancy    integer not null default 2 check (base_occupancy between 1 and 20),
  max_occupancy     integer not null default 2 check (max_occupancy between 1 and 30),
  -- цена за номер за ночь при размещении до base_occupancy человек, ₸
  base_price        numeric(14,2) not null check (base_price >= 0),
  -- доплата за каждого гостя сверх base_occupancy за ночь, ₸
  extra_guest_price numeric(14,2) not null default 0 check (extra_guest_price >= 0),
  is_public         boolean not null default true,   -- показывать на публичной странице
  is_active         boolean not null default true,
  sort_order        integer not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (tenant_id, id),
  constraint occupancy_order check (max_occupancy >= base_occupancy)
);
create index room_types_tenant_idx on public.room_types (tenant_id, sort_order);

-- Сезонные цены: на даты периода (включительно) действует своя цена за ночь
create table public.room_rates (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.organizations(id) on delete cascade,
  room_type_id      uuid not null,
  name              text not null check (char_length(trim(name)) between 1 and 120),
  starts_on         date not null,
  ends_on           date not null,
  price_per_night   numeric(14,2) not null check (price_per_night >= 0),
  extra_guest_price numeric(14,2) check (extra_guest_price >= 0),  -- null = как в категории
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  foreign key (tenant_id, room_type_id) references public.room_types (tenant_id, id) on delete cascade,
  constraint rate_period_order check (ends_on >= starts_on),
  constraint rate_period_length check (ends_on - starts_on <= 366),
  -- периоды одной категории не пересекаются, иначе цена ночи неоднозначна
  constraint room_rates_no_overlap exclude using gist (
    room_type_id with =, daterange(starts_on, ends_on, '[]') with &&
  )
);
create index room_rates_type_idx on public.room_rates (room_type_id, starts_on);

create table public.rooms (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.organizations(id) on delete cascade,
  room_type_id uuid not null,
  number       text not null check (char_length(trim(number)) between 1 and 20),
  floor        text check (char_length(floor) <= 20),
  building     text check (char_length(building) <= 60),
  status       public.room_status not null default 'available',
  notes        text check (char_length(notes) <= 1000),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, number),
  foreign key (tenant_id, room_type_id) references public.room_types (tenant_id, id)
);
create index rooms_tenant_idx on public.rooms (tenant_id, number);

-- ---------------------------------------------------------------------------
-- Гости
-- ---------------------------------------------------------------------------

create table public.guests (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.organizations(id) on delete cascade,
  full_name   text not null check (char_length(trim(full_name)) between 2 and 200),
  phone       text check (phone ~ '^\+[1-9][0-9]{6,14}$'),
  email       text check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 254),
  birth_date  date check (birth_date > date '1900-01-01'),
  city        text check (char_length(city) <= 120),
  notes       text check (char_length(notes) <= 2000),
  consent_at  timestamptz,                -- согласие на обработку персональных данных
  archived_at timestamptz,
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, id)
);
-- один активный гость на номер телефона в санатории (заявки с сайта находят его по телефону)
create unique index guests_tenant_phone_uidx on public.guests (tenant_id, phone)
  where phone is not null and archived_at is null;
create index guests_tenant_name_idx on public.guests using gin (full_name extensions.gin_trgm_ops);
create index guests_tenant_idx on public.guests (tenant_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Бронирования
-- ---------------------------------------------------------------------------

create table public.booking_counters (
  tenant_id uuid primary key references public.organizations(id) on delete cascade,
  last_number integer not null default 0
);

create table public.bookings (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.organizations(id) on delete cascade,
  number          integer not null,             -- номер брони внутри санатория: 1, 2, 3…
  guest_id        uuid not null,
  room_type_id    uuid not null,
  room_id         uuid,
  check_in        date not null,
  check_out       date not null,
  nights          integer generated always as (check_out - check_in) stored,
  adults          integer not null default 1 check (adults between 1 and 30),
  children        integer not null default 0 check (children between 0 and 30),
  status          public.booking_status not null default 'confirmed',
  source          public.booking_source not null default 'phone',
  total_amount    numeric(14,2) not null check (total_amount >= 0),
  price_breakdown jsonb not null default '[]'::jsonb,
  guest_comment   text check (char_length(guest_comment) <= 2000),
  internal_notes  text check (char_length(internal_notes) <= 2000),
  cancel_reason   text check (char_length(cancel_reason) <= 500),
  checked_in_at   timestamptz,
  checked_out_at  timestamptz,
  cancelled_at    timestamptz,
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (tenant_id, number),
  foreign key (tenant_id, guest_id)     references public.guests (tenant_id, id),
  foreign key (tenant_id, room_type_id) references public.room_types (tenant_id, id),
  foreign key (tenant_id, room_id)      references public.rooms (tenant_id, id),
  constraint stay_order  check (check_out > check_in),
  constraint stay_length check (check_out - check_in <= 365),
  constraint room_required check (status in ('new_request', 'cancelled', 'no_show') or room_id is not null),
  -- Защита от двойной брони: один номер не может быть занят двумя активными бронями
  -- на пересекающиеся ночи. Интервал [заезд, выезд): выезд 10-го и заезд 10-го не конфликтуют.
  constraint bookings_no_double_booking exclude using gist (
    room_id with =, daterange(check_in, check_out, '[)') with &&
  ) where (room_id is not null and status in ('confirmed', 'checked_in', 'checked_out'))
);
create index bookings_tenant_dates_idx on public.bookings (tenant_id, check_in, check_out);
create index bookings_tenant_status_idx on public.bookings (tenant_id, status);
create index bookings_guest_idx on public.bookings (guest_id);

-- ---------------------------------------------------------------------------
-- Триггеры
-- ---------------------------------------------------------------------------

create trigger room_types_touch before update on public.room_types
  for each row execute function app.touch_updated_at();
create trigger room_types_tenant before update on public.room_types
  for each row execute function app.forbid_tenant_change();
create trigger room_rates_touch before update on public.room_rates
  for each row execute function app.touch_updated_at();
create trigger room_rates_tenant before update on public.room_rates
  for each row execute function app.forbid_tenant_change();
create trigger rooms_touch before update on public.rooms
  for each row execute function app.touch_updated_at();
create trigger rooms_tenant before update on public.rooms
  for each row execute function app.forbid_tenant_change();
create trigger guests_touch before update on public.guests
  for each row execute function app.touch_updated_at();
create trigger guests_tenant before update on public.guests
  for each row execute function app.forbid_tenant_change();
create trigger bookings_touch before update on public.bookings
  for each row execute function app.touch_updated_at();
create trigger bookings_tenant before update on public.bookings
  for each row execute function app.forbid_tenant_change();

-- Лимит номеров по тарифу (max_rooms; null = без ограничений)
create or replace function app.enforce_room_limit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_max integer;
begin
  select p.max_rooms into v_max
  from public.organization_subscriptions s join public.subscription_plans p on p.id = s.plan_id
  where s.tenant_id = new.tenant_id and s.status <> 'cancelled'
  limit 1;
  if v_max is not null and (select count(*) from public.rooms where tenant_id = new.tenant_id) >= v_max then
    raise exception 'room limit of the plan reached' using errcode = '54000';
  end if;
  return new;
end $$;
create trigger rooms_limit before insert on public.rooms
  for each row execute function app.enforce_room_limit();

-- Архивировать гостя может только guests.archive; вернуть из архива — тоже
create or replace function app.protect_guest_archive() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.archived_at is distinct from old.archived_at
     and current_user in ('authenticated', 'anon')
     and not app.has_permission(new.tenant_id, 'guests.archive') then
    raise exception 'archiving guests requires guests.archive' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger guests_archive_guard before update on public.guests
  for each row execute function app.protect_guest_archive();

-- ---------------------------------------------------------------------------
-- Вспомогательные функции
-- ---------------------------------------------------------------------------

-- Сегодняшняя дата в часовом поясе санатория (по умолчанию Asia/Almaty)
create or replace function app.tenant_today(p_tenant uuid) returns date
language sql stable security definer set search_path = '' as $$
  select (now() at time zone coalesce(
    (select timezone from public.organizations where id = p_tenant), 'Asia/Almaty'))::date
$$;

-- Расчёт стоимости: для каждой ночи берётся сезонная цена, если дата попадает в период,
-- иначе базовая цена категории; за гостей сверх base_occupancy — доплата за ночь.
-- Дети учитываются как гости при подсчёте вместимости и доплаты.
create or replace function app.calc_booking_price(
  p_tenant uuid, p_room_type_id uuid, p_check_in date, p_check_out date, p_adults integer, p_children integer
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_type   public.room_types;
  v_guests integer := coalesce(p_adults, 0) + coalesce(p_children, 0);
  v_extra  integer;
  v_total  numeric(14,2) := 0;
  v_lines  jsonb := '[]'::jsonb;
  v_day    date;
  v_rate   public.room_rates;
  v_price  numeric(14,2);
  v_extra_price numeric(14,2);
begin
  if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then
    raise exception 'check-out must be after check-in' using errcode = '22023';
  end if;
  if p_check_out - p_check_in > 365 then
    raise exception 'stay is too long' using errcode = '22023';
  end if;
  select * into v_type from public.room_types where id = p_room_type_id and tenant_id = p_tenant;
  if not found then
    raise exception 'room type not found' using errcode = 'P0002';
  end if;
  if coalesce(p_adults, 0) < 1 then
    raise exception 'at least one adult is required' using errcode = '22023';
  end if;
  if v_guests > v_type.max_occupancy then
    raise exception 'too many guests for this room type' using errcode = '22023';
  end if;
  v_extra := greatest(v_guests - v_type.base_occupancy, 0);

  v_day := p_check_in;
  while v_day < p_check_out loop
    select * into v_rate from public.room_rates r
    where r.room_type_id = p_room_type_id and v_day between r.starts_on and r.ends_on;
    if found then
      v_price := v_rate.price_per_night;
      v_extra_price := coalesce(v_rate.extra_guest_price, v_type.extra_guest_price);
    else
      v_price := v_type.base_price;
      v_extra_price := v_type.extra_guest_price;
    end if;
    v_price := v_price + v_extra * v_extra_price;
    v_total := v_total + v_price;
    v_lines := v_lines || jsonb_build_object(
      'date', v_day, 'amount', v_price, 'rate', case when v_rate.id is not null then v_rate.name end);
    v_rate := null;
    v_day := v_day + 1;
  end loop;

  return jsonb_build_object(
    'total', v_total, 'nights', p_check_out - p_check_in, 'extra_guests', v_extra, 'nights_detail', v_lines);
end $$;

-- Может ли пользователь менять бронирования (право + подписка + функция тарифа)
create or replace function app.can_write_bookings(p_tenant uuid, p_permission text) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.has_permission(p_tenant, p_permission) and app.feature_enabled(p_tenant, 'bookings')
$$;

create or replace function app.next_booking_number(p_tenant uuid) returns integer
language sql security definer set search_path = '' as $$
  insert into public.booking_counters as c (tenant_id, last_number) values (p_tenant, 1)
  on conflict (tenant_id) do update set last_number = c.last_number + 1
  returning last_number
$$;

-- Номер подходит для брони: свой санаторий, нужная категория, активен, не на обслуживании
create or replace function app.check_room_for_booking(p_tenant uuid, p_room_id uuid, p_room_type_id uuid)
returns void
language plpgsql stable security definer set search_path = '' as $$
declare v_room public.rooms;
begin
  select * into v_room from public.rooms where id = p_room_id and tenant_id = p_tenant;
  if not found then
    raise exception 'room not found' using errcode = 'P0002';
  end if;
  if v_room.room_type_id <> p_room_type_id then
    raise exception 'room does not belong to the selected room type' using errcode = '22023';
  end if;
  if not v_room.is_active or v_room.status = 'maintenance' then
    raise exception 'room is not available for booking' using errcode = '22023';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.room_types       enable row level security;
alter table public.room_rates       enable row level security;
alter table public.rooms            enable row level security;
alter table public.guests           enable row level security;
alter table public.booking_counters enable row level security;
alter table public.bookings         enable row level security;

-- Категории, цены и номера: читать — rooms.read, менять — rooms.write при активной подписке
create policy room_types_select on public.room_types for select to authenticated
  using (app.has_permission(tenant_id, 'rooms.read') or app.has_permission(tenant_id, 'bookings.read'));
create policy room_types_insert on public.room_types for insert to authenticated
  with check (app.has_permission(tenant_id, 'rooms.write') and app.feature_enabled(tenant_id, 'rooms'));
create policy room_types_update on public.room_types for update to authenticated
  using (app.has_permission(tenant_id, 'rooms.write'))
  with check (app.has_permission(tenant_id, 'rooms.write') and app.feature_enabled(tenant_id, 'rooms'));
create policy room_types_delete on public.room_types for delete to authenticated
  using (app.has_permission(tenant_id, 'rooms.delete') and app.feature_enabled(tenant_id, 'rooms'));

create policy room_rates_select on public.room_rates for select to authenticated
  using (app.has_permission(tenant_id, 'rooms.read') or app.has_permission(tenant_id, 'bookings.read'));
create policy room_rates_insert on public.room_rates for insert to authenticated
  with check (app.has_permission(tenant_id, 'rooms.write') and app.feature_enabled(tenant_id, 'rooms'));
create policy room_rates_update on public.room_rates for update to authenticated
  using (app.has_permission(tenant_id, 'rooms.write'))
  with check (app.has_permission(tenant_id, 'rooms.write') and app.feature_enabled(tenant_id, 'rooms'));
create policy room_rates_delete on public.room_rates for delete to authenticated
  using (app.has_permission(tenant_id, 'rooms.write') and app.feature_enabled(tenant_id, 'rooms'));

create policy rooms_select on public.rooms for select to authenticated
  using (app.has_permission(tenant_id, 'rooms.read') or app.has_permission(tenant_id, 'bookings.read'));
create policy rooms_insert on public.rooms for insert to authenticated
  with check (app.has_permission(tenant_id, 'rooms.write') and app.feature_enabled(tenant_id, 'rooms'));
create policy rooms_update on public.rooms for update to authenticated
  using (app.has_permission(tenant_id, 'rooms.write'))
  with check (app.has_permission(tenant_id, 'rooms.write') and app.feature_enabled(tenant_id, 'rooms'));
create policy rooms_delete on public.rooms for delete to authenticated
  using (app.has_permission(tenant_id, 'rooms.delete') and app.feature_enabled(tenant_id, 'rooms'));

-- Гости: персональные данные. Читать — guests.read, создавать и менять — guests.write.
-- Удаления нет: гостя архивируют (guests.archive), история броней сохраняется.
create policy guests_select on public.guests for select to authenticated
  using (app.has_permission(tenant_id, 'guests.read'));
create policy guests_insert on public.guests for insert to authenticated
  with check (app.has_permission(tenant_id, 'guests.write') and app.feature_enabled(tenant_id, 'guests'));
create policy guests_update on public.guests for update to authenticated
  using (app.has_permission(tenant_id, 'guests.write'))
  with check (app.has_permission(tenant_id, 'guests.write') and app.feature_enabled(tenant_id, 'guests'));

-- Бронирования: только чтение через RLS; все изменения — функциями ниже
create policy bookings_select on public.bookings for select to authenticated
  using (app.has_permission(tenant_id, 'bookings.read'));
-- booking_counters: политик нет, доступ только из функций

-- ---------------------------------------------------------------------------
-- Серверные операции с бронированиями
-- ---------------------------------------------------------------------------

-- Предварительный расчёт цены для формы брони
create or replace function public.quote_booking(
  p_tenant uuid, p_room_type_id uuid, p_check_in date, p_check_out date,
  p_adults integer default 1, p_children integer default 0
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.has_permission(p_tenant, 'bookings.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  return app.calc_booking_price(p_tenant, p_room_type_id, p_check_in, p_check_out, p_adults, p_children);
end $$;

-- Свободные номера на период (по желанию — одной категории; p_exclude_booking — при переносе брони)
create or replace function public.available_rooms(
  p_tenant uuid, p_check_in date, p_check_out date,
  p_room_type_id uuid default null, p_exclude_booking uuid default null
) returns table (id uuid, number text, floor text, room_type_id uuid, status public.room_status)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.has_permission(p_tenant, 'bookings.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_check_out <= p_check_in then
    raise exception 'check-out must be after check-in' using errcode = '22023';
  end if;
  return query
  select r.id, r.number, r.floor, r.room_type_id, r.status
  from public.rooms r
  where r.tenant_id = p_tenant and r.is_active and r.status <> 'maintenance'
    and (p_room_type_id is null or r.room_type_id = p_room_type_id)
    and not exists (
      select 1 from public.bookings b
      where b.room_id = r.id
        and b.status in ('confirmed', 'checked_in', 'checked_out')
        and daterange(b.check_in, b.check_out, '[)') && daterange(p_check_in, p_check_out, '[)')
        and (p_exclude_booking is null or b.id <> p_exclude_booking)
    )
  order by r.number;
end $$;

-- Создание брони сотрудником. Цена считается здесь, а не на клиенте.
create or replace function public.create_booking(
  p_tenant uuid, p_guest_id uuid, p_room_type_id uuid, p_room_id uuid,
  p_check_in date, p_check_out date, p_adults integer default 1, p_children integer default 0,
  p_source public.booking_source default 'phone', p_comment text default null,
  p_status public.booking_status default 'confirmed'
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_price jsonb;
  v_id    uuid;
begin
  if not app.can_write_bookings(p_tenant, 'bookings.write') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_status not in ('new_request', 'confirmed') then
    raise exception 'a booking can only be created as a request or confirmed' using errcode = '22023';
  end if;
  if p_check_out <= app.tenant_today(p_tenant) then
    raise exception 'stay must not be entirely in the past' using errcode = '22023';
  end if;
  if not exists (select 1 from public.guests g where g.id = p_guest_id and g.tenant_id = p_tenant) then
    raise exception 'guest not found' using errcode = 'P0002';
  end if;
  if p_room_id is not null then
    perform app.check_room_for_booking(p_tenant, p_room_id, p_room_type_id);
  end if;

  v_price := app.calc_booking_price(p_tenant, p_room_type_id, p_check_in, p_check_out, p_adults, p_children);

  insert into public.bookings (
    tenant_id, number, guest_id, room_type_id, room_id, check_in, check_out, adults, children,
    status, source, total_amount, price_breakdown, guest_comment, created_by)
  values (
    p_tenant, app.next_booking_number(p_tenant), p_guest_id, p_room_type_id, p_room_id,
    p_check_in, p_check_out, p_adults, coalesce(p_children, 0),
    p_status, p_source, (v_price ->> 'total')::numeric, v_price -> 'nights_detail',
    nullif(trim(p_comment), ''), auth.uid())
  returning id into v_id;

  perform app.log_audit(p_tenant, 'booking.create', 'booking', v_id, 'success',
    jsonb_build_object('status', p_status, 'check_in', p_check_in, 'check_out', p_check_out));
  return v_id;
end $$;

-- Изменение дат, номера или числа гостей. Цена пересчитывается.
-- У проживающего гостя нельзя менять дату заезда.
create or replace function public.update_booking(
  p_booking_id uuid, p_room_type_id uuid, p_room_id uuid, p_check_in date, p_check_out date,
  p_adults integer, p_children integer, p_comment text default null, p_internal_notes text default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_b     public.bookings;
  v_price jsonb;
begin
  select * into v_b from public.bookings where id = p_booking_id for update;
  if not found or not app.can_write_bookings(v_b.tenant_id, 'bookings.write') then
    raise exception 'booking not found or permission denied' using errcode = '42501';
  end if;
  if v_b.status not in ('new_request', 'confirmed', 'checked_in') then
    raise exception 'booking in status % cannot be changed', v_b.status using errcode = '22023';
  end if;
  if v_b.status = 'checked_in' and p_check_in <> v_b.check_in then
    raise exception 'check-in date of an in-house guest cannot be changed' using errcode = '22023';
  end if;
  if v_b.status <> 'new_request' and p_room_id is null then
    raise exception 'room is required' using errcode = '22023';
  end if;
  if p_room_id is not null then
    perform app.check_room_for_booking(v_b.tenant_id, p_room_id, p_room_type_id);
  end if;

  v_price := app.calc_booking_price(v_b.tenant_id, p_room_type_id, p_check_in, p_check_out, p_adults, p_children);

  update public.bookings set
    room_type_id = p_room_type_id, room_id = p_room_id,
    check_in = p_check_in, check_out = p_check_out,
    adults = p_adults, children = coalesce(p_children, 0),
    total_amount = (v_price ->> 'total')::numeric, price_breakdown = v_price -> 'nights_detail',
    guest_comment = nullif(trim(p_comment), ''), internal_notes = nullif(trim(p_internal_notes), '')
  where id = p_booking_id;

  -- номер проживающего гостя сменился: старый на уборку, новый занят
  if v_b.status = 'checked_in' and p_room_id <> v_b.room_id then
    update public.rooms set status = 'cleaning' where id = v_b.room_id;
    update public.rooms set status = 'occupied' where id = p_room_id;
  end if;

  perform app.log_audit(v_b.tenant_id, 'booking.update', 'booking', p_booking_id, 'success',
    jsonb_build_object('check_in', p_check_in, 'check_out', p_check_out, 'room_id', p_room_id,
                       'total', (v_price ->> 'total')::numeric));
end $$;

-- Смена статуса брони. Разрешённые переходы и нужные права:
--   new_request → confirmed   bookings.write (нужен номер)
--   new_request → cancelled   bookings.cancel или leads.write
--   confirmed   → checked_in  bookings.checkin (не раньше даты заезда)
--   confirmed   → cancelled   bookings.cancel (с причиной)
--   confirmed   → no_show     bookings.checkin (не раньше даты заезда)
--   checked_in  → checked_out bookings.checkin (номер уходит на уборку)
create or replace function public.set_booking_status(
  p_booking_id uuid, p_status public.booking_status, p_reason text default null, p_room_id uuid default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_b     public.bookings;
  v_today date;
  v_perm  text;
  v_room  uuid;
begin
  select * into v_b from public.bookings where id = p_booking_id for update;
  if not found or not app.has_permission(v_b.tenant_id, 'bookings.read') then
    raise exception 'booking not found' using errcode = 'P0002';
  end if;
  v_today := app.tenant_today(v_b.tenant_id);

  v_perm := case
    when v_b.status = 'new_request' and p_status = 'confirmed'   then 'bookings.write'
    when v_b.status = 'new_request' and p_status = 'cancelled'   then
      case when app.has_permission(v_b.tenant_id, 'leads.write') then 'leads.write' else 'bookings.cancel' end
    when v_b.status = 'confirmed'   and p_status = 'checked_in'  then 'bookings.checkin'
    when v_b.status = 'confirmed'   and p_status = 'cancelled'   then 'bookings.cancel'
    when v_b.status = 'confirmed'   and p_status = 'no_show'     then 'bookings.checkin'
    when v_b.status = 'checked_in'  and p_status = 'checked_out' then 'bookings.checkin'
  end;
  if v_perm is null then
    raise exception 'status change % -> % is not allowed', v_b.status, p_status using errcode = '22023';
  end if;
  if not app.can_write_bookings(v_b.tenant_id, v_perm) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  if p_status = 'confirmed' then
    v_room := coalesce(p_room_id, v_b.room_id);
    if v_room is null then
      raise exception 'room is required to confirm a booking' using errcode = '22023';
    end if;
    perform app.check_room_for_booking(v_b.tenant_id, v_room, v_b.room_type_id);
    update public.bookings set status = 'confirmed', room_id = v_room where id = p_booking_id;

  elsif p_status = 'checked_in' then
    if v_b.check_in > v_today then
      raise exception 'check-in is not possible before the arrival date' using errcode = '22023';
    end if;
    if v_b.check_out <= v_today then
      raise exception 'stay has already ended' using errcode = '22023';
    end if;
    update public.bookings set status = 'checked_in', checked_in_at = now() where id = p_booking_id;
    update public.rooms set status = 'occupied' where id = v_b.room_id;

  elsif p_status = 'checked_out' then
    -- ранний выезд освобождает оставшиеся ночи; сумма брони не меняется автоматически
    update public.bookings set
      status = 'checked_out', checked_out_at = now(),
      check_out = case when v_today < v_b.check_out then greatest(v_today, v_b.check_in + 1) else v_b.check_out end
    where id = p_booking_id;
    update public.rooms set status = 'cleaning' where id = v_b.room_id;

  elsif p_status = 'no_show' then
    if v_b.check_in > v_today then
      raise exception 'no-show is possible only from the arrival date' using errcode = '22023';
    end if;
    update public.bookings set status = 'no_show', cancelled_at = now(),
      cancel_reason = nullif(trim(p_reason), '') where id = p_booking_id;

  elsif p_status = 'cancelled' then
    if v_b.status = 'confirmed' and coalesce(trim(p_reason), '') = '' then
      raise exception 'cancellation reason is required' using errcode = '22023';
    end if;
    update public.bookings set status = 'cancelled', cancelled_at = now(),
      cancel_reason = nullif(trim(p_reason), '') where id = p_booking_id;
  end if;

  perform app.log_audit(v_b.tenant_id, 'booking.status', 'booking', p_booking_id, 'success',
    jsonb_build_object('from', v_b.status, 'to', p_status, 'reason', nullif(trim(p_reason), '')));
end $$;

-- Статус номера (уборка, обслуживание). Горничная (rooms.status) не может пометить
-- свободным номер, в котором проживает гость, и не может поставить «занят» вручную.
create or replace function public.set_room_status(p_room_id uuid, p_status public.room_status) returns void
language plpgsql security definer set search_path = '' as $$
declare v_room public.rooms;
begin
  select * into v_room from public.rooms where id = p_room_id for update;
  if not found or not (app.has_permission(v_room.tenant_id, 'rooms.status')
                       or app.has_permission(v_room.tenant_id, 'rooms.write')) then
    raise exception 'room not found or permission denied' using errcode = '42501';
  end if;
  if not app.subscription_writable(v_room.tenant_id) then
    raise exception 'subscription is read-only' using errcode = '42501';
  end if;
  if p_status = 'occupied' then
    raise exception 'occupied is set by check-in only' using errcode = '22023';
  end if;
  if exists (select 1 from public.bookings b where b.room_id = p_room_id and b.status = 'checked_in') then
    raise exception 'a guest is checked in to this room' using errcode = '22023';
  end if;
  update public.rooms set status = p_status where id = p_room_id;
  perform app.log_audit(v_room.tenant_id, 'room.status', 'room', p_room_id, 'success',
    jsonb_build_object('from', v_room.status, 'to', p_status));
end $$;

-- Сводка на сегодня для главной страницы (реальные данные, без оценок)
create or replace function public.today_summary(p_tenant uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_today date;
begin
  if not app.has_permission(p_tenant, 'bookings.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  v_today := app.tenant_today(p_tenant);
  return jsonb_build_object(
    'date', v_today,
    'arrivals', (select count(*) from public.bookings
                 where tenant_id = p_tenant and check_in = v_today and status = 'confirmed'),
    'departures', (select count(*) from public.bookings
                   where tenant_id = p_tenant and check_out = v_today and status = 'checked_in'),
    'in_house', (select count(*) from public.bookings where tenant_id = p_tenant and status = 'checked_in'),
    'requests', (select count(*) from public.bookings where tenant_id = p_tenant and status = 'new_request'),
    'rooms_total', (select count(*) from public.rooms where tenant_id = p_tenant and is_active),
    'rooms_occupied', (select count(distinct room_id) from public.bookings
                       where tenant_id = p_tenant and status = 'checked_in')
  );
end $$;

-- ---------------------------------------------------------------------------
-- Публичная страница: категории номеров и заявка на бронирование
-- ---------------------------------------------------------------------------

create or replace function public.get_public_room_types(p_slug text)
returns table (id uuid, name text, description text, base_occupancy integer, max_occupancy integer,
               price_from numeric)
language sql stable security definer set search_path = '' as $$
  select t.id, t.name, t.description, t.base_occupancy, t.max_occupancy,
         least(t.base_price, coalesce((select min(r.price_per_night) from public.room_rates r
                                       where r.room_type_id = t.id and r.ends_on >= current_date), t.base_price))
  from public.room_types t
  join public.organizations o on o.id = t.tenant_id
  where o.slug = lower(p_slug) and o.is_published and t.is_active and t.is_public
  order by t.sort_order, t.base_price
$$;

-- Ориентировочная стоимость для гостя на сайте (без проверки наличия номеров)
create or replace function public.public_quote(
  p_slug text, p_room_type_id uuid, p_check_in date, p_check_out date, p_adults integer, p_children integer
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_tenant uuid; v_price jsonb;
begin
  select t.tenant_id into v_tenant
  from public.room_types t join public.organizations o on o.id = t.tenant_id
  where t.id = p_room_type_id and o.slug = lower(p_slug) and o.is_published and t.is_active and t.is_public;
  if v_tenant is null then
    raise exception 'room type not found' using errcode = 'P0002';
  end if;
  if p_check_out - p_check_in > 60 then
    raise exception 'stay is too long for an online request' using errcode = '22023';
  end if;
  v_price := app.calc_booking_price(v_tenant, p_room_type_id, p_check_in, p_check_out, p_adults, p_children);
  return jsonb_build_object('total', v_price -> 'total', 'nights', v_price -> 'nights');
end $$;

-- Заявка с публичной страницы. Создаёт бронь в статусе new_request без номера;
-- администратор подтверждает её и выбирает номер. Гость находится по телефону или создаётся.
-- Антиспам: не больше 3 открытых заявок с одного телефона и 30 заявок в час на санаторий.
create or replace function public.submit_booking_request(
  p_slug text, p_room_type_id uuid, p_check_in date, p_check_out date,
  p_adults integer, p_children integer, p_full_name text, p_phone text,
  p_comment text default null, p_consent boolean default false
) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_tenant uuid;
  v_today  date;
  v_guest  uuid;
  v_price  jsonb;
  v_number integer;
  v_id     uuid;
begin
  if not coalesce(p_consent, false) then
    raise exception 'consent to personal data processing is required' using errcode = '22023';
  end if;
  if p_phone is null or p_phone !~ '^\+7[0-9]{10}$' then
    raise exception 'phone must be in +7XXXXXXXXXX format' using errcode = '22023';
  end if;
  if char_length(trim(coalesce(p_full_name, ''))) not between 2 and 200 then
    raise exception 'name is required' using errcode = '22023';
  end if;
  if char_length(coalesce(p_comment, '')) > 1000 then
    raise exception 'comment is too long' using errcode = '22023';
  end if;

  select t.tenant_id into v_tenant
  from public.room_types t join public.organizations o on o.id = t.tenant_id
  where t.id = p_room_type_id and o.slug = lower(p_slug) and o.is_published and t.is_active and t.is_public;
  if v_tenant is null then
    raise exception 'room type not found' using errcode = 'P0002';
  end if;
  if not (app.feature_enabled(v_tenant, 'public_site') and app.feature_enabled(v_tenant, 'bookings')) then
    raise exception 'online requests are not available' using errcode = '42501';
  end if;

  v_today := app.tenant_today(v_tenant);
  if p_check_in < v_today or p_check_in > v_today + 730 then
    raise exception 'check-in date is out of range' using errcode = '22023';
  end if;
  if p_check_out - p_check_in > 60 then
    raise exception 'stay is too long for an online request' using errcode = '22023';
  end if;

  if (select count(*) from public.bookings b
      where b.tenant_id = v_tenant and b.source = 'website' and b.created_at > now() - interval '1 hour') >= 30
     or (select count(*) from public.bookings b join public.guests g on g.id = b.guest_id
         where b.tenant_id = v_tenant and g.phone = p_phone and b.status = 'new_request') >= 3 then
    raise exception 'too many requests, please call the sanatorium' using errcode = '54000';
  end if;

  v_price := app.calc_booking_price(v_tenant, p_room_type_id, p_check_in, p_check_out, p_adults, p_children);

  -- существующего гостя не меняем (аноним не может перезаписать чужие данные)
  select id into v_guest from public.guests
  where tenant_id = v_tenant and phone = p_phone and archived_at is null;
  if v_guest is null then
    insert into public.guests (tenant_id, full_name, phone, consent_at)
    values (v_tenant, trim(p_full_name), p_phone, now())
    returning id into v_guest;
  end if;

  v_number := app.next_booking_number(v_tenant);
  insert into public.bookings (
    tenant_id, number, guest_id, room_type_id, check_in, check_out, adults, children,
    status, source, total_amount, price_breakdown, guest_comment, internal_notes)
  values (
    v_tenant, v_number, v_guest, p_room_type_id, p_check_in, p_check_out, p_adults, coalesce(p_children, 0),
    'new_request', 'website', (v_price ->> 'total')::numeric, v_price -> 'nights_detail',
    nullif(trim(p_comment), ''),
    -- имя из заявки может отличаться от карточки найденного гостя
    'Имя в заявке: ' || trim(p_full_name))
  returning id into v_id;

  perform app.log_audit(v_tenant, 'booking.request', 'booking', v_id);
  return v_number;
end $$;

-- ---------------------------------------------------------------------------
-- Доступ к функциям
-- ---------------------------------------------------------------------------

revoke all on function
  app.tenant_today(uuid),
  app.calc_booking_price(uuid, uuid, date, date, integer, integer),
  app.can_write_bookings(uuid, text),
  app.next_booking_number(uuid),
  app.check_room_for_booking(uuid, uuid, uuid),
  app.enforce_room_limit(),
  app.protect_guest_archive()
  from public, anon, authenticated;

revoke execute on function
  public.quote_booking(uuid, uuid, date, date, integer, integer),
  public.available_rooms(uuid, date, date, uuid, uuid),
  public.create_booking(uuid, uuid, uuid, uuid, date, date, integer, integer, public.booking_source, text, public.booking_status),
  public.update_booking(uuid, uuid, uuid, date, date, integer, integer, text, text),
  public.set_booking_status(uuid, public.booking_status, text, uuid),
  public.set_room_status(uuid, public.room_status),
  public.today_summary(uuid),
  public.get_public_room_types(text),
  public.public_quote(text, uuid, date, date, integer, integer),
  public.submit_booking_request(text, uuid, date, date, integer, integer, text, text, text, boolean)
  from public, anon;

grant execute on function
  public.quote_booking(uuid, uuid, date, date, integer, integer),
  public.available_rooms(uuid, date, date, uuid, uuid),
  public.create_booking(uuid, uuid, uuid, uuid, date, date, integer, integer, public.booking_source, text, public.booking_status),
  public.update_booking(uuid, uuid, uuid, date, date, integer, integer, text, text),
  public.set_booking_status(uuid, public.booking_status, text, uuid),
  public.set_room_status(uuid, public.room_status),
  public.today_summary(uuid)
  to authenticated;

grant execute on function
  public.get_public_room_types(text),
  public.public_quote(text, uuid, date, date, integer, integer),
  public.submit_booking_request(text, uuid, date, date, integer, integer, text, text, text, boolean)
  to anon, authenticated;

-- ===== supabase/migrations/20261024000006_finance.sql =====
-- Sanatorium OS · 0006 · Финансы: оплаты и возвраты по броням, доп. услуги, расходы, отчёт кассы
-- Принципы:
--  * деньги — numeric(14,2), тенге; суммы с клиента принимаются только как сумма платежа,
--    стоимость брони по-прежнему считает сервер;
--  * платежи не редактируются и не удаляются: ошибочный платёж аннулируется с причиной,
--    запись остаётся в истории и в журнале действий;
--  * «Kaspi перевод» — это ручная отметка кассира о полученном переводе, а не интеграция с Kaspi.
--    Онлайн-оплата через платёжного провайдера подключается отдельно (этап 5).

create type public.payment_method as enum ('cash', 'card', 'kaspi_transfer', 'bank_transfer', 'other');
create type public.payment_kind as enum ('payment', 'refund');

-- ---------------------------------------------------------------------------
-- Оплаты и возвраты по броне
-- ---------------------------------------------------------------------------

alter table public.bookings add constraint bookings_tenant_id_id_key unique (tenant_id, id);

create table public.booking_payments (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.organizations(id) on delete cascade,
  booking_id  uuid not null,
  kind        public.payment_kind not null default 'payment',
  method      public.payment_method not null,
  amount      numeric(14,2) not null check (amount > 0 and amount <= 100000000),
  paid_at     timestamptz not null default now(),
  note        text check (char_length(note) <= 500),
  created_by  uuid references auth.users(id) on delete set null,
  voided_at   timestamptz,
  voided_by   uuid references auth.users(id) on delete set null,
  void_reason text check (char_length(void_reason) <= 500),
  created_at  timestamptz not null default now(),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id),
  constraint void_reason_required check (voided_at is null or void_reason is not null)
);
create index booking_payments_booking_idx on public.booking_payments (booking_id);
create index booking_payments_tenant_paid_idx on public.booking_payments (tenant_id, paid_at);

-- Доп. услуги к брони (питание, трансфер, процедуры вне пакета и т. п.)
create table public.booking_extras (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.organizations(id) on delete cascade,
  booking_id  uuid not null,
  name        text not null check (char_length(trim(name)) between 1 and 200),
  quantity    numeric(10,2) not null default 1 check (quantity > 0 and quantity <= 10000),
  unit_price  numeric(14,2) not null check (unit_price >= 0 and unit_price <= 100000000),
  amount      numeric(14,2) generated always as (round(quantity * unit_price, 2)) stored,
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id) on delete cascade
);
create index booking_extras_booking_idx on public.booking_extras (booking_id);

-- Баланс брони. security_invoker: строки видны только тем, кому RLS разрешает видеть брони.
-- Отменённые брони и незаезды гостю ничего не должны: к оплате 0, переплата видна в paid_net.
create view public.booking_balances with (security_invoker = true) as
select
  b.id as booking_id,
  b.tenant_id,
  b.total_amount as accommodation,
  coalesce(x.extras, 0)::numeric(14,2) as extras,
  (case when b.status in ('cancelled', 'no_show') then 0 else b.total_amount + coalesce(x.extras, 0) end)::numeric(14,2) as charges,
  coalesce(p.paid, 0)::numeric(14,2) as paid,
  coalesce(p.refunded, 0)::numeric(14,2) as refunded,
  (coalesce(p.paid, 0) - coalesce(p.refunded, 0))::numeric(14,2) as paid_net,
  ((case when b.status in ('cancelled', 'no_show') then 0 else b.total_amount + coalesce(x.extras, 0) end)
    - coalesce(p.paid, 0) + coalesce(p.refunded, 0))::numeric(14,2) as balance
from public.bookings b
left join (
  select booking_id, sum(amount) as extras from public.booking_extras group by booking_id
) x on x.booking_id = b.id
left join (
  select booking_id,
         sum(amount) filter (where kind = 'payment') as paid,
         sum(amount) filter (where kind = 'refund') as refunded
  from public.booking_payments where voided_at is null group by booking_id
) p on p.booking_id = b.id;

-- ---------------------------------------------------------------------------
-- Расходы санатория
-- ---------------------------------------------------------------------------

create table public.expense_categories (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.organizations(id) on delete cascade,
  name       text not null check (char_length(trim(name)) between 1 and 120),
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, name)
);

create table public.expenses (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.organizations(id) on delete cascade,
  category_id uuid not null,
  amount      numeric(14,2) not null check (amount > 0 and amount <= 1000000000),
  spent_on    date not null,
  method      public.payment_method not null default 'cash',
  vendor      text check (char_length(vendor) <= 200),
  note        text check (char_length(note) <= 1000),
  created_by  uuid references auth.users(id) on delete set null,
  voided_at   timestamptz,
  voided_by   uuid references auth.users(id) on delete set null,
  void_reason text check (char_length(void_reason) <= 500),
  created_at  timestamptz not null default now(),
  foreign key (tenant_id, category_id) references public.expense_categories (tenant_id, id),
  constraint expense_void_reason_required check (voided_at is null or void_reason is not null)
);
create index expenses_tenant_date_idx on public.expenses (tenant_id, spent_on);

create trigger booking_payments_tenant before update on public.booking_payments
  for each row execute function app.forbid_tenant_change();
create trigger booking_extras_tenant before update on public.booking_extras
  for each row execute function app.forbid_tenant_change();
create trigger expense_categories_tenant before update on public.expense_categories
  for each row execute function app.forbid_tenant_change();
create trigger expenses_tenant before update on public.expenses
  for each row execute function app.forbid_tenant_change();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.booking_payments   enable row level security;
alter table public.booking_extras     enable row level security;
alter table public.expense_categories enable row level security;
alter table public.expenses           enable row level security;

-- Платежи видят финансы и кассиры (ресепшен принимает оплату). Запись — только функциями.
create policy booking_payments_select on public.booking_payments for select to authenticated
  using (app.has_permission(tenant_id, 'finance.read') or app.has_permission(tenant_id, 'payments.accept'));

-- Доп. услуги видят все, кто видит брони. Запись — только функциями (проверка статуса брони).
create policy booking_extras_select on public.booking_extras for select to authenticated
  using (app.has_permission(tenant_id, 'bookings.read') or app.has_permission(tenant_id, 'finance.read'));

-- Расходы: читать — finance.read, заводить — finance.write при включённой функции тарифа «finance».
-- Изменять и удалять нельзя, только аннулировать функцией void_expense.
create policy expense_categories_select on public.expense_categories for select to authenticated
  using (app.has_permission(tenant_id, 'finance.read'));
create policy expense_categories_insert on public.expense_categories for insert to authenticated
  with check (app.has_permission(tenant_id, 'finance.write') and app.feature_enabled(tenant_id, 'finance'));
create policy expense_categories_update on public.expense_categories for update to authenticated
  using (app.has_permission(tenant_id, 'finance.write'))
  with check (app.has_permission(tenant_id, 'finance.write') and app.feature_enabled(tenant_id, 'finance'));

create policy expenses_select on public.expenses for select to authenticated
  using (app.has_permission(tenant_id, 'finance.read'));
create policy expenses_insert on public.expenses for insert to authenticated
  with check (app.has_permission(tenant_id, 'finance.write') and app.feature_enabled(tenant_id, 'finance')
              and voided_at is null and created_by = auth.uid());

-- ---------------------------------------------------------------------------
-- Серверные операции
-- ---------------------------------------------------------------------------

-- Оплата или возврат по броне.
-- Оплата: payments.accept. Возврат: refunds.create, не больше фактически оплаченного.
-- Оплата по отменённой брони или незаезду не принимается, возврат — можно.
create or replace function public.add_booking_payment(
  p_booking_id uuid, p_kind public.payment_kind, p_method public.payment_method,
  p_amount numeric, p_note text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_b    public.bookings;
  v_net  numeric(14,2);
  v_id   uuid;
  v_perm text := case when p_kind = 'refund' then 'refunds.create' else 'payments.accept' end;
begin
  select * into v_b from public.bookings where id = p_booking_id for update;
  if not found or not (app.has_permission(v_b.tenant_id, 'bookings.read')
                       or app.has_permission(v_b.tenant_id, 'finance.read')) then
    raise exception 'booking not found' using errcode = 'P0002';
  end if;
  if not (app.has_permission(v_b.tenant_id, v_perm) and app.feature_enabled(v_b.tenant_id, 'bookings')) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
    raise exception 'amount must be positive with at most 2 decimals' using errcode = '22023';
  end if;
  if p_kind = 'payment' and v_b.status in ('cancelled', 'no_show') then
    raise exception 'payments are not accepted for a cancelled booking' using errcode = '22023';
  end if;
  if p_kind = 'refund' then
    select paid_net into v_net from public.booking_balances where booking_id = p_booking_id;
    if p_amount > coalesce(v_net, 0) then
      raise exception 'refund exceeds the amount paid' using errcode = '22023';
    end if;
    if coalesce(trim(p_note), '') = '' then
      raise exception 'refund reason is required' using errcode = '22023';
    end if;
  end if;

  insert into public.booking_payments (tenant_id, booking_id, kind, method, amount, note, created_by)
  values (v_b.tenant_id, p_booking_id, p_kind, p_method, p_amount, nullif(trim(p_note), ''), auth.uid())
  returning id into v_id;

  perform app.log_audit(v_b.tenant_id, 'payment.' || p_kind::text, 'booking', p_booking_id, 'success',
    jsonb_build_object('payment_id', v_id, 'method', p_method, 'amount', p_amount));
  return v_id;
end $$;

-- Аннулирование ошибочного платежа (finance.write, с причиной). Запись остаётся в истории.
create or replace function public.void_booking_payment(p_payment_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_p public.booking_payments;
begin
  select * into v_p from public.booking_payments where id = p_payment_id for update;
  if not found or not app.has_permission(v_p.tenant_id, 'finance.write') then
    raise exception 'payment not found or permission denied' using errcode = '42501';
  end if;
  if not app.subscription_writable(v_p.tenant_id) then
    raise exception 'subscription is read-only' using errcode = '42501';
  end if;
  if v_p.voided_at is not null then
    raise exception 'payment is already voided' using errcode = '22023';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'void reason is required' using errcode = '22023';
  end if;
  update public.booking_payments
  set voided_at = now(), voided_by = auth.uid(), void_reason = trim(p_reason)
  where id = p_payment_id;
  perform app.log_audit(v_p.tenant_id, 'payment.void', 'booking', v_p.booking_id, 'success',
    jsonb_build_object('payment_id', p_payment_id, 'amount', v_p.amount, 'kind', v_p.kind, 'reason', trim(p_reason)));
end $$;

-- Доп. услуга к брони (bookings.write или finance.write); не к отменённой брони
create or replace function public.add_booking_extra(
  p_booking_id uuid, p_name text, p_quantity numeric, p_unit_price numeric
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_b public.bookings; v_id uuid;
begin
  select * into v_b from public.bookings where id = p_booking_id for update;
  if not found or not app.has_permission(v_b.tenant_id, 'bookings.read') then
    raise exception 'booking not found' using errcode = 'P0002';
  end if;
  if not ((app.has_permission(v_b.tenant_id, 'bookings.write') or app.has_permission(v_b.tenant_id, 'finance.write'))
          and app.feature_enabled(v_b.tenant_id, 'bookings')) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_b.status in ('cancelled', 'no_show') then
    raise exception 'booking is cancelled' using errcode = '22023';
  end if;
  insert into public.booking_extras (tenant_id, booking_id, name, quantity, unit_price, created_by)
  values (v_b.tenant_id, p_booking_id, trim(p_name), p_quantity, p_unit_price, auth.uid())
  returning id into v_id;
  perform app.log_audit(v_b.tenant_id, 'booking.extra_add', 'booking', p_booking_id, 'success',
    jsonb_build_object('name', trim(p_name), 'quantity', p_quantity, 'unit_price', p_unit_price));
  return v_id;
end $$;

create or replace function public.remove_booking_extra(p_extra_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_x public.booking_extras;
begin
  select * into v_x from public.booking_extras where id = p_extra_id for update;
  if not found or not ((app.has_permission(v_x.tenant_id, 'bookings.write') or app.has_permission(v_x.tenant_id, 'finance.write'))
                       and app.feature_enabled(v_x.tenant_id, 'bookings')) then
    raise exception 'extra not found or permission denied' using errcode = '42501';
  end if;
  delete from public.booking_extras where id = p_extra_id;
  perform app.log_audit(v_x.tenant_id, 'booking.extra_remove', 'booking', v_x.booking_id, 'success',
    jsonb_build_object('name', v_x.name, 'amount', v_x.amount));
end $$;

create or replace function public.void_expense(p_expense_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_e public.expenses;
begin
  select * into v_e from public.expenses where id = p_expense_id for update;
  if not found or not (app.has_permission(v_e.tenant_id, 'finance.write') and app.feature_enabled(v_e.tenant_id, 'finance')) then
    raise exception 'expense not found or permission denied' using errcode = '42501';
  end if;
  if v_e.voided_at is not null then
    raise exception 'expense is already voided' using errcode = '22023';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'void reason is required' using errcode = '22023';
  end if;
  update public.expenses set voided_at = now(), voided_by = auth.uid(), void_reason = trim(p_reason)
  where id = p_expense_id;
  perform app.log_audit(v_e.tenant_id, 'expense.void', 'expense', p_expense_id, 'success',
    jsonb_build_object('amount', v_e.amount, 'reason', trim(p_reason)));
end $$;

-- Отчёт кассы за период [p_from, p_to] в часовом поясе санатория (finance.read).
-- Чтение и отчёты не ограничиваются истёкшей подпиской.
create or replace function public.finance_report(p_tenant uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_tz text;
  v_from timestamptz;
  v_to timestamptz;
begin
  if not app.has_permission(p_tenant, 'finance.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_to < p_from or p_to - p_from > 366 then
    raise exception 'invalid period' using errcode = '22023';
  end if;
  select coalesce(timezone, 'Asia/Almaty') into v_tz from public.organizations where id = p_tenant;
  v_from := (p_from::timestamp at time zone v_tz);
  v_to := ((p_to + 1)::timestamp at time zone v_tz);

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'payments', (select coalesce(sum(amount), 0) from public.booking_payments
                 where tenant_id = p_tenant and voided_at is null and kind = 'payment' and paid_at >= v_from and paid_at < v_to),
    'refunds', (select coalesce(sum(amount), 0) from public.booking_payments
                where tenant_id = p_tenant and voided_at is null and kind = 'refund' and paid_at >= v_from and paid_at < v_to),
    'expenses', (select coalesce(sum(amount), 0) from public.expenses
                 where tenant_id = p_tenant and voided_at is null and spent_on between p_from and p_to),
    'by_method', (select coalesce(jsonb_object_agg(method, net), '{}'::jsonb) from (
                    select method, sum(case when kind = 'payment' then amount else -amount end) as net
                    from public.booking_payments
                    where tenant_id = p_tenant and voided_at is null and paid_at >= v_from and paid_at < v_to
                    group by method) m),
    'expenses_by_category', (select coalesce(jsonb_agg(jsonb_build_object('name', c.name, 'amount', s.total) order by s.total desc), '[]'::jsonb)
                             from (select category_id, sum(amount) as total from public.expenses
                                   where tenant_id = p_tenant and voided_at is null and spent_on between p_from and p_to
                                   group by category_id) s
                             join public.expense_categories c on c.id = s.category_id),
    -- дебиторка на текущий момент: активные и завершённые брони с положительным остатком
    'receivables', (select coalesce(sum(bb.balance), 0) from public.booking_balances bb
                    join public.bookings b on b.id = bb.booking_id
                    where bb.tenant_id = p_tenant and bb.balance > 0 and b.status in ('confirmed', 'checked_in', 'checked_out'))
  );
end $$;

-- ---------------------------------------------------------------------------
-- Доступ к функциям
-- ---------------------------------------------------------------------------

revoke execute on function
  public.add_booking_payment(uuid, public.payment_kind, public.payment_method, numeric, text),
  public.void_booking_payment(uuid, text),
  public.add_booking_extra(uuid, text, numeric, numeric),
  public.remove_booking_extra(uuid),
  public.void_expense(uuid, text),
  public.finance_report(uuid, date, date)
  from public, anon;
grant execute on function
  public.add_booking_payment(uuid, public.payment_kind, public.payment_method, numeric, text),
  public.void_booking_payment(uuid, text),
  public.add_booking_extra(uuid, text, numeric, numeric),
  public.remove_booking_extra(uuid),
  public.void_expense(uuid, text),
  public.finance_report(uuid, date, date)
  to authenticated;

-- Представление баланса: только чтение, видимость определяется RLS таблицы bookings
revoke all on public.booking_balances from anon;
grant select on public.booking_balances to authenticated;

commit;
