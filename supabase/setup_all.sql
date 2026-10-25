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

-- ===== supabase/migrations/20261025000007_procedures_tasks.sql =====
-- Sanatorium OS · 0007 · Процедуры и задачи сотрудников
-- Принципы:
--  * процедуры — это расписание и счёт, а не медицинская карта: в записи нет диагнозов и назначений врача,
--    только вид процедуры, время, кабинет, специалист и короткая служебная заметка;
--  * цену процедуры берёт сервер из справочника в момент записи; «входит в путёвку» — цена 0;
--  * один кабинет, один специалист и один гость не могут быть заняты двумя процедурами одновременно
--    (exclusion constraints в БД);
--  * стоимость процедур по брони попадает в баланс брони (booking_balances);
--  * задачи видят исполнитель и те, кто назначает задачи; уборка после выезда создаётся автоматически.

create type public.procedure_status as enum ('scheduled', 'done', 'no_show', 'cancelled');
create type public.task_status as enum ('open', 'in_progress', 'done', 'cancelled');
create type public.task_priority as enum ('low', 'normal', 'high');
create type public.task_category as enum ('cleaning', 'maintenance', 'reception', 'medical', 'other');

-- ---------------------------------------------------------------------------
-- Справочник процедур и кабинеты
-- ---------------------------------------------------------------------------

create table public.procedure_types (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.organizations(id) on delete cascade,
  name         text not null check (char_length(trim(name)) between 1 and 200),
  duration_min integer not null check (duration_min between 5 and 480),
  price        numeric(14,2) not null default 0 check (price >= 0 and price <= 10000000),
  description  text check (char_length(description) <= 1000),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, name)
);

create table public.treatment_rooms (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.organizations(id) on delete cascade,
  name       text not null check (char_length(trim(name)) between 1 and 100),
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, name)
);

-- ---------------------------------------------------------------------------
-- Записи на процедуры
-- ---------------------------------------------------------------------------

create table public.procedure_appointments (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.organizations(id) on delete cascade,
  guest_id          uuid not null,
  booking_id        uuid,
  procedure_type_id uuid not null,
  treatment_room_id uuid,
  specialist_id     uuid,
  starts_at         timestamptz not null,
  ends_at           timestamptz not null,
  status            public.procedure_status not null default 'scheduled',
  price             numeric(14,2) not null default 0 check (price >= 0),
  included          boolean not null default false,
  note              text check (char_length(note) <= 500),
  cancel_reason     text check (char_length(cancel_reason) <= 500),
  created_by        uuid references auth.users(id) on delete set null,
  completed_by      uuid references auth.users(id) on delete set null,
  completed_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id),
  foreign key (tenant_id, procedure_type_id) references public.procedure_types (tenant_id, id),
  foreign key (tenant_id, treatment_room_id) references public.treatment_rooms (tenant_id, id),
  foreign key (tenant_id, specialist_id) references public.organization_members (tenant_id, user_id),
  constraint procedure_time_order check (ends_at > starts_at),
  constraint procedure_room_busy exclude using gist (
    treatment_room_id with =, tstzrange(starts_at, ends_at, '[)') with &&
  ) where (treatment_room_id is not null and status in ('scheduled', 'done')),
  constraint procedure_specialist_busy exclude using gist (
    specialist_id with =, tstzrange(starts_at, ends_at, '[)') with &&
  ) where (specialist_id is not null and status in ('scheduled', 'done')),
  constraint procedure_guest_busy exclude using gist (
    guest_id with =, tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status in ('scheduled', 'done'))
);
create index procedure_appointments_tenant_time_idx on public.procedure_appointments (tenant_id, starts_at);
create index procedure_appointments_booking_idx on public.procedure_appointments (booking_id) where booking_id is not null;

-- ---------------------------------------------------------------------------
-- Задачи сотрудников
-- ---------------------------------------------------------------------------

create table public.tasks (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.organizations(id) on delete cascade,
  title        text not null check (char_length(trim(title)) between 1 and 200),
  description  text check (char_length(description) <= 2000),
  category     public.task_category not null default 'other',
  priority     public.task_priority not null default 'normal',
  status       public.task_status not null default 'open',
  -- manual — создана сотрудником; room_cleaning — создана автоматически, когда номер ушёл на уборку
  source       text not null default 'manual' check (source in ('manual', 'room_cleaning')),
  assignee_id  uuid,
  room_id      uuid,
  due_at       timestamptz,
  created_by   uuid references auth.users(id) on delete set null,
  completed_by uuid references auth.users(id) on delete set null,
  completed_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  foreign key (tenant_id, assignee_id) references public.organization_members (tenant_id, user_id),
  foreign key (tenant_id, room_id) references public.rooms (tenant_id, id)
);
create index tasks_tenant_status_idx on public.tasks (tenant_id, status, due_at);
create index tasks_assignee_idx on public.tasks (assignee_id) where status in ('open', 'in_progress');

create trigger procedure_types_tenant before update on public.procedure_types
  for each row execute function app.forbid_tenant_change();
create trigger procedure_types_updated_at before update on public.procedure_types
  for each row execute function app.touch_updated_at();
create trigger treatment_rooms_tenant before update on public.treatment_rooms
  for each row execute function app.forbid_tenant_change();
create trigger procedure_appointments_tenant before update on public.procedure_appointments
  for each row execute function app.forbid_tenant_change();
create trigger procedure_appointments_updated_at before update on public.procedure_appointments
  for each row execute function app.touch_updated_at();
create trigger tasks_tenant before update on public.tasks
  for each row execute function app.forbid_tenant_change();
create trigger tasks_updated_at before update on public.tasks
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.procedure_types        enable row level security;
alter table public.treatment_rooms        enable row level security;
alter table public.procedure_appointments enable row level security;
alter table public.tasks                  enable row level security;

-- Справочник процедур нужен расписанию и карточке брони; правят врач, директор, владелец
create policy procedure_types_select on public.procedure_types for select to authenticated
  using (app.has_permission(tenant_id, 'procedures.read') or app.has_permission(tenant_id, 'bookings.read'));
create policy procedure_types_insert on public.procedure_types for insert to authenticated
  with check (app.has_permission(tenant_id, 'procedures.write') and app.feature_enabled(tenant_id, 'procedures'));
create policy procedure_types_update on public.procedure_types for update to authenticated
  using (app.has_permission(tenant_id, 'procedures.write'))
  with check (app.has_permission(tenant_id, 'procedures.write') and app.feature_enabled(tenant_id, 'procedures'));

create policy treatment_rooms_select on public.treatment_rooms for select to authenticated
  using (app.has_permission(tenant_id, 'procedures.read'));
create policy treatment_rooms_insert on public.treatment_rooms for insert to authenticated
  with check (app.has_permission(tenant_id, 'procedures.write') and app.feature_enabled(tenant_id, 'procedures'));
create policy treatment_rooms_update on public.treatment_rooms for update to authenticated
  using (app.has_permission(tenant_id, 'procedures.write'))
  with check (app.has_permission(tenant_id, 'procedures.write') and app.feature_enabled(tenant_id, 'procedures'));

-- Записи видят расписание (procedures.read) и касса/финансы — иначе баланс брони считался бы неверно.
-- Запись — только функциями.
create policy procedure_appointments_select on public.procedure_appointments for select to authenticated
  using (app.has_permission(tenant_id, 'procedures.read') or app.has_permission(tenant_id, 'finance.read')
         or app.has_permission(tenant_id, 'payments.accept'));

-- Задачи: назначающий (tasks.write) видит все; остальные — свои, общие (без исполнителя) и созданные ими
create policy tasks_select on public.tasks for select to authenticated
  using (app.has_permission(tenant_id, 'tasks.write')
         or (app.has_permission(tenant_id, 'tasks.read')
             and (assignee_id = auth.uid() or assignee_id is null or created_by = auth.uid())));

-- ---------------------------------------------------------------------------
-- Баланс брони теперь включает процедуры (запланированные и проведённые)
-- ---------------------------------------------------------------------------

create or replace view public.booking_balances with (security_invoker = true) as
select
  b.id as booking_id,
  b.tenant_id,
  b.total_amount as accommodation,
  coalesce(x.extras, 0)::numeric(14,2) as extras,
  (case when b.status in ('cancelled', 'no_show') then 0
        else b.total_amount + coalesce(x.extras, 0) + coalesce(pr.procedures, 0) end)::numeric(14,2) as charges,
  coalesce(p.paid, 0)::numeric(14,2) as paid,
  coalesce(p.refunded, 0)::numeric(14,2) as refunded,
  (coalesce(p.paid, 0) - coalesce(p.refunded, 0))::numeric(14,2) as paid_net,
  ((case when b.status in ('cancelled', 'no_show') then 0
         else b.total_amount + coalesce(x.extras, 0) + coalesce(pr.procedures, 0) end)
    - coalesce(p.paid, 0) + coalesce(p.refunded, 0))::numeric(14,2) as balance,
  coalesce(pr.procedures, 0)::numeric(14,2) as procedures
from public.bookings b
left join (
  select booking_id, sum(amount) as extras from public.booking_extras group by booking_id
) x on x.booking_id = b.id
left join (
  select booking_id, sum(price) as procedures from public.procedure_appointments
  where booking_id is not null and status in ('scheduled', 'done') group by booking_id
) pr on pr.booking_id = b.id
left join (
  select booking_id,
         sum(amount) filter (where kind = 'payment') as paid,
         sum(amount) filter (where kind = 'refund') as refunded
  from public.booking_payments where voided_at is null group by booking_id
) p on p.booking_id = b.id;

-- ---------------------------------------------------------------------------
-- Вспомогательные проверки
-- ---------------------------------------------------------------------------

-- Есть ли у сотрудника (не у текущего пользователя) право в организации
create or replace function app.member_has_permission(p_tenant uuid, p_user uuid, p_code text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.organization_members m
    join public.role_permissions rp on rp.role_id = m.role_id
    join public.permissions p on p.id = rp.permission_id
    where m.tenant_id = p_tenant and m.user_id = p_user and m.status = 'active' and p.code = p_code
  )
$$;

-- Проверка места и времени процедуры; возвращает ends_at
create or replace function app.check_procedure_slot(
  p_tenant uuid, p_guest uuid, p_booking uuid, p_starts timestamptz, p_duration interval,
  p_room uuid, p_specialist uuid
) returns timestamptz
language plpgsql stable security definer set search_path = '' as $$
declare
  v_tz  text;
  v_day date;
  v_b   public.bookings;
begin
  if p_starts is null then
    raise exception 'start time is required' using errcode = '22023';
  end if;
  if p_starts < now() - interval '1 day' then
    raise exception 'procedure time is in the past' using errcode = '22023';
  end if;
  select coalesce(timezone, 'Asia/Almaty') into v_tz from public.organizations where id = p_tenant;
  v_day := (p_starts at time zone v_tz)::date;

  if p_booking is not null then
    select * into v_b from public.bookings where id = p_booking and tenant_id = p_tenant;
    if not found or v_b.guest_id <> p_guest then
      raise exception 'booking does not belong to the guest' using errcode = '22023';
    end if;
    if v_b.status not in ('confirmed', 'checked_in') then
      raise exception 'booking is not active' using errcode = '22023';
    end if;
    if v_day < v_b.check_in or v_day > v_b.check_out then
      raise exception 'procedure is outside the stay dates' using errcode = '22023';
    end if;
  end if;

  if p_room is not null and not exists (
    select 1 from public.treatment_rooms where id = p_room and tenant_id = p_tenant and is_active
  ) then
    raise exception 'treatment room is not available' using errcode = '22023';
  end if;
  if p_specialist is not null and not app.member_has_permission(p_tenant, p_specialist, 'procedures.status') then
    raise exception 'specialist is not available' using errcode = '22023';
  end if;
  return p_starts + p_duration;
end $$;

-- ---------------------------------------------------------------------------
-- Серверные операции: процедуры
-- ---------------------------------------------------------------------------

-- Запись гостя на процедуру (procedures.write). Цена — из справочника; included = входит в путёвку (0 ₸).
-- Без явной брони процедура привязывается к активной брони гостя на этот день.
create or replace function public.schedule_procedure(
  p_guest_id uuid, p_procedure_type_id uuid, p_starts_at timestamptz,
  p_booking_id uuid default null, p_room_id uuid default null, p_specialist_id uuid default null,
  p_included boolean default false, p_note text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_g    public.guests;
  v_t    public.procedure_types;
  v_ends timestamptz;
  v_booking uuid;
  v_id   uuid;
begin
  select * into v_g from public.guests where id = p_guest_id;
  if not found or not (app.has_permission(v_g.tenant_id, 'procedures.read') or app.has_permission(v_g.tenant_id, 'guests.read')) then
    raise exception 'guest not found' using errcode = 'P0002';
  end if;
  if not (app.has_permission(v_g.tenant_id, 'procedures.write') and app.feature_enabled(v_g.tenant_id, 'procedures')) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_g.archived_at is not null then
    raise exception 'guest is archived' using errcode = '22023';
  end if;
  select * into v_t from public.procedure_types where id = p_procedure_type_id and tenant_id = v_g.tenant_id and is_active;
  if not found then
    raise exception 'procedure is not available' using errcode = '22023';
  end if;

  -- Без явной брони процедура привязывается к активной брони гостя на этот день,
  -- чтобы стоимость попала в счёт (врач не видит брони, но записывает гостя).
  v_booking := p_booking_id;
  if v_booking is null and p_starts_at is not null then
    select b.id into v_booking
    from public.bookings b
    join public.organizations o on o.id = b.tenant_id
    where b.tenant_id = v_g.tenant_id and b.guest_id = p_guest_id and b.status in ('confirmed', 'checked_in')
      and (p_starts_at at time zone coalesce(o.timezone, 'Asia/Almaty'))::date between b.check_in and b.check_out
    order by (b.status = 'checked_in') desc, b.check_in
    limit 1;
  end if;

  v_ends := app.check_procedure_slot(v_g.tenant_id, p_guest_id, v_booking, p_starts_at,
                                     make_interval(mins => v_t.duration_min), p_room_id, p_specialist_id);

  insert into public.procedure_appointments (
    tenant_id, guest_id, booking_id, procedure_type_id, treatment_room_id, specialist_id,
    starts_at, ends_at, price, included, note, created_by
  ) values (
    v_g.tenant_id, p_guest_id, v_booking, p_procedure_type_id, p_room_id, p_specialist_id,
    p_starts_at, v_ends, case when coalesce(p_included, false) then 0 else v_t.price end,
    coalesce(p_included, false), nullif(trim(p_note), ''), auth.uid()
  ) returning id into v_id;

  perform app.log_audit(v_g.tenant_id, 'procedure.schedule', 'procedure_appointment', v_id, 'success',
    jsonb_build_object('procedure', v_t.name, 'starts_at', p_starts_at, 'booking_id', v_booking));
  return v_id;
end $$;

-- Перенос записи (procedures.write): время, кабинет, специалист. Длительность сохраняется.
create or replace function public.reschedule_procedure(
  p_appointment_id uuid, p_starts_at timestamptz, p_room_id uuid default null, p_specialist_id uuid default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare v_a public.procedure_appointments; v_ends timestamptz;
begin
  select * into v_a from public.procedure_appointments where id = p_appointment_id for update;
  if not found or not (app.has_permission(v_a.tenant_id, 'procedures.write') and app.feature_enabled(v_a.tenant_id, 'procedures')) then
    raise exception 'appointment not found or permission denied' using errcode = '42501';
  end if;
  if v_a.status <> 'scheduled' then
    raise exception 'only scheduled procedures can be moved' using errcode = '22023';
  end if;
  v_ends := app.check_procedure_slot(v_a.tenant_id, v_a.guest_id, v_a.booking_id, p_starts_at,
                                     v_a.ends_at - v_a.starts_at, p_room_id, p_specialist_id);
  update public.procedure_appointments
  set starts_at = p_starts_at, ends_at = v_ends, treatment_room_id = p_room_id, specialist_id = p_specialist_id
  where id = p_appointment_id;
  perform app.log_audit(v_a.tenant_id, 'procedure.reschedule', 'procedure_appointment', p_appointment_id, 'success',
    jsonb_build_object('from', v_a.starts_at, 'to', p_starts_at));
end $$;

-- Статус записи.
--  done / no_show — procedures.status (врач, медсестра), не раньше дня процедуры;
--  cancelled — procedures.write; scheduled (отмена ошибочной отметки) — procedures.write.
create or replace function public.set_procedure_status(
  p_appointment_id uuid, p_status public.procedure_status, p_reason text default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_a   public.procedure_appointments;
  v_tz  text;
  v_perm text := case when p_status in ('done', 'no_show') then 'procedures.status' else 'procedures.write' end;
begin
  select * into v_a from public.procedure_appointments where id = p_appointment_id for update;
  if not found or not app.has_permission(v_a.tenant_id, 'procedures.read') then
    raise exception 'appointment not found' using errcode = 'P0002';
  end if;
  if not (app.has_permission(v_a.tenant_id, v_perm) and app.feature_enabled(v_a.tenant_id, 'procedures')) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not ((v_a.status = 'scheduled' and p_status in ('done', 'no_show', 'cancelled'))
          or (v_a.status in ('done', 'no_show') and p_status = 'scheduled')) then
    raise exception 'invalid status transition' using errcode = '22023';
  end if;
  if p_status in ('done', 'no_show') then
    select coalesce(timezone, 'Asia/Almaty') into v_tz from public.organizations where id = v_a.tenant_id;
    if (v_a.starts_at at time zone v_tz)::date > app.tenant_today(v_a.tenant_id) then
      raise exception 'procedure has not started yet' using errcode = '22023';
    end if;
  end if;

  update public.procedure_appointments
  set status = p_status,
      completed_at = case when p_status in ('done', 'no_show') then now() end,
      completed_by = case when p_status in ('done', 'no_show') then auth.uid() end,
      cancel_reason = case when p_status = 'cancelled' then nullif(trim(p_reason), '') end
  where id = p_appointment_id;
  perform app.log_audit(v_a.tenant_id, 'procedure.' || p_status::text, 'procedure_appointment', p_appointment_id, 'success',
    jsonb_build_object('from', v_a.status, 'reason', nullif(trim(p_reason), '')));
end $$;

-- Отмена брони или незаезд снимают запланированные процедуры этой брони
create or replace function app.cancel_booking_procedures() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.procedure_appointments
  set status = 'cancelled', cancel_reason = 'booking ' || new.status::text
  where booking_id = new.id and status = 'scheduled';
  return null;
end $$;

create trigger bookings_cancel_procedures after update of status on public.bookings
  for each row when (new.status in ('cancelled', 'no_show') and old.status is distinct from new.status)
  execute function app.cancel_booking_procedures();

-- Сотрудники организации с правом: специалисты (procedures.status) или исполнители задач (tasks.read)
create or replace function public.staff_directory(p_tenant uuid, p_permission text)
returns table (user_id uuid, full_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_permission not in ('procedures.status', 'tasks.read') or not app.is_member(p_tenant) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  return query
    select m.user_id, coalesce(nullif(trim(u.full_name), ''), '—')
    from public.organization_members m
    left join public.user_profiles u on u.id = m.user_id
    where m.tenant_id = p_tenant and m.status = 'active'
      and app.member_has_permission(p_tenant, m.user_id, p_permission)
    order by 2;
end $$;

-- ---------------------------------------------------------------------------
-- Серверные операции: задачи
-- ---------------------------------------------------------------------------

create or replace function app.check_task_refs(p_tenant uuid, p_assignee uuid, p_room uuid) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_assignee is not null and not app.member_has_permission(p_tenant, p_assignee, 'tasks.read') then
    raise exception 'assignee is not available' using errcode = '22023';
  end if;
  if p_room is not null and not exists (select 1 from public.rooms where id = p_room and tenant_id = p_tenant) then
    raise exception 'room not found' using errcode = '22023';
  end if;
end $$;

create or replace function public.create_task(
  p_tenant uuid, p_title text, p_description text default null,
  p_category public.task_category default 'other', p_priority public.task_priority default 'normal',
  p_assignee_id uuid default null, p_room_id uuid default null, p_due_at timestamptz default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not (app.has_permission(p_tenant, 'tasks.write') and app.feature_enabled(p_tenant, 'tasks')) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  perform app.check_task_refs(p_tenant, p_assignee_id, p_room_id);
  insert into public.tasks (tenant_id, title, description, category, priority, assignee_id, room_id, due_at, created_by)
  values (p_tenant, trim(p_title), nullif(trim(p_description), ''), coalesce(p_category, 'other'),
          coalesce(p_priority, 'normal'), p_assignee_id, p_room_id, p_due_at, auth.uid())
  returning id into v_id;
  perform app.log_audit(p_tenant, 'task.create', 'task', v_id, 'success',
    jsonb_build_object('title', trim(p_title), 'assignee_id', p_assignee_id));
  return v_id;
end $$;

create or replace function public.update_task(
  p_task_id uuid, p_title text, p_description text, p_category public.task_category,
  p_priority public.task_priority, p_assignee_id uuid, p_room_id uuid, p_due_at timestamptz
) returns void
language plpgsql security definer set search_path = '' as $$
declare v_t public.tasks;
begin
  select * into v_t from public.tasks where id = p_task_id for update;
  if not found or not (app.has_permission(v_t.tenant_id, 'tasks.write') and app.feature_enabled(v_t.tenant_id, 'tasks')) then
    raise exception 'task not found or permission denied' using errcode = '42501';
  end if;
  if v_t.status in ('done', 'cancelled') then
    raise exception 'task is closed' using errcode = '22023';
  end if;
  perform app.check_task_refs(v_t.tenant_id, p_assignee_id, p_room_id);
  update public.tasks
  set title = trim(p_title), description = nullif(trim(p_description), ''), category = p_category,
      priority = p_priority, assignee_id = p_assignee_id, room_id = p_room_id, due_at = p_due_at
  where id = p_task_id;
  perform app.log_audit(v_t.tenant_id, 'task.update', 'task', p_task_id, 'success',
    jsonb_build_object('assignee_id', p_assignee_id));
end $$;

-- Статус задачи.
--  tasks.write: любые переходы, включая отмену и повторное открытие;
--  исполнитель (tasks.read): своя или общая задача — взять в работу, вернуть, выполнить.
--  Общую задачу берёт тот, кто начал её выполнять. Выполненная уборка освобождает номер.
create or replace function public.set_task_status(p_task_id uuid, p_status public.task_status)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_t       public.tasks;
  v_manager boolean;
begin
  select * into v_t from public.tasks where id = p_task_id for update;
  if not found or not app.has_permission(v_t.tenant_id, 'tasks.read') and not app.has_permission(v_t.tenant_id, 'tasks.write') then
    raise exception 'task not found' using errcode = 'P0002';
  end if;
  v_manager := app.has_permission(v_t.tenant_id, 'tasks.write');
  if not v_manager and not (v_t.assignee_id is null or v_t.assignee_id = auth.uid()) then
    raise exception 'task not found' using errcode = 'P0002';
  end if;
  if not app.feature_enabled(v_t.tenant_id, 'tasks') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_t.status = p_status then
    return;
  end if;
  if not v_manager and (p_status = 'cancelled' or v_t.status in ('done', 'cancelled')) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  update public.tasks
  set status = p_status,
      assignee_id = coalesce(assignee_id, case when p_status in ('in_progress', 'done') then auth.uid() end),
      completed_at = case when p_status = 'done' then now() end,
      completed_by = case when p_status = 'done' then auth.uid() end
  where id = p_task_id;

  if p_status = 'done' and v_t.source = 'room_cleaning' and v_t.room_id is not null then
    update public.rooms set status = 'available' where id = v_t.room_id and status = 'cleaning';
  end if;

  perform app.log_audit(v_t.tenant_id, 'task.' || p_status::text, 'task', p_task_id, 'success',
    jsonb_build_object('from', v_t.status));
end $$;

-- Номер ушёл на уборку → задача горничным; номер снова свободен → открытая уборка закрывается
create or replace function app.room_cleaning_task() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'cleaning' and old.status <> 'cleaning' and app.feature_enabled(new.tenant_id, 'tasks')
     and not exists (select 1 from public.tasks where room_id = new.id and source = 'room_cleaning'
                     and status in ('open', 'in_progress')) then
    insert into public.tasks (tenant_id, title, category, priority, source, room_id, created_by)
    values (new.tenant_id, 'Уборка номера ' || new.number, 'cleaning', 'normal', 'room_cleaning', new.id, auth.uid());
  elsif new.status = 'available' and old.status = 'cleaning' then
    update public.tasks set status = 'done', completed_at = now(), completed_by = auth.uid()
    where room_id = new.id and source = 'room_cleaning' and status in ('open', 'in_progress');
  end if;
  return null;
end $$;

create trigger rooms_cleaning_task after update of status on public.rooms
  for each row execute function app.room_cleaning_task();

-- ---------------------------------------------------------------------------
-- Доступ к функциям
-- ---------------------------------------------------------------------------

revoke execute on function
  app.member_has_permission(uuid, uuid, text),
  app.check_procedure_slot(uuid, uuid, uuid, timestamptz, interval, uuid, uuid),
  app.check_task_refs(uuid, uuid, uuid),
  app.cancel_booking_procedures(),
  app.room_cleaning_task()
  from public, anon, authenticated;

revoke execute on function
  public.schedule_procedure(uuid, uuid, timestamptz, uuid, uuid, uuid, boolean, text),
  public.reschedule_procedure(uuid, timestamptz, uuid, uuid),
  public.set_procedure_status(uuid, public.procedure_status, text),
  public.staff_directory(uuid, text),
  public.create_task(uuid, text, text, public.task_category, public.task_priority, uuid, uuid, timestamptz),
  public.update_task(uuid, text, text, public.task_category, public.task_priority, uuid, uuid, timestamptz),
  public.set_task_status(uuid, public.task_status)
  from public, anon;
grant execute on function
  public.schedule_procedure(uuid, uuid, timestamptz, uuid, uuid, uuid, boolean, text),
  public.reschedule_procedure(uuid, timestamptz, uuid, uuid),
  public.set_procedure_status(uuid, public.procedure_status, text),
  public.staff_directory(uuid, text),
  public.create_task(uuid, text, text, public.task_category, public.task_priority, uuid, uuid, timestamptz),
  public.update_task(uuid, text, text, public.task_category, public.task_priority, uuid, uuid, timestamptz),
  public.set_task_status(uuid, public.task_status)
  to authenticated;

revoke all on public.booking_balances from anon;
grant select on public.booking_balances to authenticated;

-- ===== supabase/migrations/20261026000008_audit_billing.sql =====
-- Sanatorium OS · 0008 · Журнал действий и подписка
-- Принципы:
--  * журнал пополняется не только серверными функциями, но и триггерами на справочниках и настройках:
--    видно, кто и когда изменил цену номера, процедуры или настройки санатория;
--  * по гостям в журнал попадают только названия изменённых полей, без значений (персональные данные);
--  * онлайн-оплаты подписки нет: владелец санатория оставляет заявку на тариф, владелец платформы
--    получает оплату вне системы и включает тариф вручную (admin_set_plan). Счёт или «успешную оплату»
--    система не изображает;
--  * заявку можно оставить и при истёкшей подписке — иначе из неё не выбраться.

-- ---------------------------------------------------------------------------
-- Журнал изменений справочников и настроек
-- ---------------------------------------------------------------------------

create or replace function app.audit_row_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_new     jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_old     jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_row     jsonb := coalesce(v_new, v_old);
  v_tenant  uuid;
  v_entity  text;
  v_changed text[];
  v_values  jsonb := '{}'::jsonb;
  v_key     text;
  -- поля, значения которых не являются персональными данными и полезны в журнале
  v_tracked text[] := array['name', 'number', 'base_price', 'extra_guest_price', 'price_per_night', 'price',
                            'duration_min', 'starts_on', 'ends_on', 'is_active', 'is_public', 'is_published',
                            'amount', 'spent_on', 'timezone', 'default_language', 'slug', 'max_occupancy', 'base_occupancy'];
begin
  v_entity := case tg_table_name
    when 'organizations' then 'settings'
    when 'room_types' then 'room_type'
    when 'room_rates' then 'room_rate'
    when 'rooms' then 'room'
    when 'procedure_types' then 'procedure_type'
    when 'treatment_rooms' then 'treatment_room'
    when 'expense_categories' then 'expense_category'
    when 'expenses' then 'expense'
    when 'guests' then 'guest'
    else tg_table_name end;
  v_tenant := case when tg_table_name = 'organizations' then (v_row ->> 'id')::uuid else (v_row ->> 'tenant_id')::uuid end;
  -- удаление санатория целиком (каскад) в журнал не пишем: строка организации уже удалена
  if tg_op = 'DELETE' and not exists (select 1 from public.organizations where id = v_tenant) then
    return null;
  end if;

  if tg_op = 'UPDATE' then
    select coalesce(array_agg(k order by k), '{}') into v_changed
    from jsonb_object_keys(v_new) k
    where k not in ('updated_at', 'created_at') and v_new -> k is distinct from v_old -> k;
    if cardinality(v_changed) = 0 then
      return null;
    end if;
    -- статус номера пишет set_room_status(), дубль не нужен
    if tg_table_name = 'rooms' and v_changed <@ array['status'] then
      return null;
    end if;
    if tg_table_name <> 'guests' then
      foreach v_key in array v_changed loop
        if v_key = any (v_tracked) then
          v_values := v_values || jsonb_build_object(v_key, jsonb_build_object('from', v_old -> v_key, 'to', v_new -> v_key));
        end if;
      end loop;
    end if;
    perform app.log_audit(v_tenant, v_entity || '.update', v_entity, (v_row ->> 'id')::uuid, 'success',
      jsonb_build_object('changed', to_jsonb(v_changed)) || case when v_values = '{}'::jsonb then '{}'::jsonb
                                                                  else jsonb_build_object('values', v_values) end);
  else
    if tg_table_name <> 'guests' then
      foreach v_key in array v_tracked loop
        if v_row ? v_key and v_row -> v_key <> 'null'::jsonb then
          v_values := v_values || jsonb_build_object(v_key, v_row -> v_key);
        end if;
      end loop;
    end if;
    perform app.log_audit(v_tenant, v_entity || case when tg_op = 'INSERT' then '.create' else '.delete' end,
      v_entity, (v_row ->> 'id')::uuid, 'success', v_values);
  end if;
  return null;
end $$;

create trigger organizations_audit after update on public.organizations
  for each row execute function app.audit_row_change();
create trigger room_types_audit after insert or update or delete on public.room_types
  for each row execute function app.audit_row_change();
create trigger room_rates_audit after insert or update or delete on public.room_rates
  for each row execute function app.audit_row_change();
create trigger rooms_audit after insert or update or delete on public.rooms
  for each row execute function app.audit_row_change();
create trigger procedure_types_audit after insert or update on public.procedure_types
  for each row execute function app.audit_row_change();
create trigger treatment_rooms_audit after insert or update on public.treatment_rooms
  for each row execute function app.audit_row_change();
create trigger expense_categories_audit after insert or update on public.expense_categories
  for each row execute function app.audit_row_change();
create trigger expenses_audit after insert on public.expenses
  for each row execute function app.audit_row_change();
create trigger guests_audit after insert or update on public.guests
  for each row execute function app.audit_row_change();

revoke execute on function app.audit_row_change() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Подписка: сводка для владельца, заявка на тариф, ручное включение тарифа владельцем платформы
-- ---------------------------------------------------------------------------

create type public.plan_request_status as enum ('open', 'done', 'cancelled');

create table public.plan_change_requests (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.organizations(id) on delete cascade,
  plan_id        uuid not null references public.subscription_plans(id),
  billing_period public.billing_period not null default 'monthly',
  note           text check (char_length(note) <= 1000),
  status         public.plan_request_status not null default 'open',
  requested_by   uuid references auth.users(id) on delete set null,
  resolved_by    uuid references auth.users(id) on delete set null,
  resolved_at    timestamptz,
  created_at     timestamptz not null default now()
);
create unique index plan_change_requests_one_open on public.plan_change_requests (tenant_id) where status = 'open';
create index plan_change_requests_status_idx on public.plan_change_requests (status, created_at desc);

alter table public.plan_change_requests enable row level security;
create policy plan_change_requests_select on public.plan_change_requests for select to authenticated
  using (app.has_permission(tenant_id, 'billing.manage') or app.is_platform_admin());

-- Сводка подписки: тариф, сроки, лимиты и их использование, модули тарифа (billing.manage).
-- Работает и при истёкшей подписке.
create or replace function public.subscription_overview(p_tenant uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_s public.organization_subscriptions;
  v_p public.subscription_plans;
begin
  if not app.has_permission(p_tenant, 'billing.manage') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  select * into v_s from public.organization_subscriptions where tenant_id = p_tenant and status <> 'cancelled';
  if not found then
    raise exception 'subscription not found' using errcode = 'P0002';
  end if;
  select * into v_p from public.subscription_plans where id = v_s.plan_id;
  return jsonb_build_object(
    'plan_code', v_p.code, 'plan_name_ru', v_p.name_ru, 'plan_name_kk', v_p.name_kk,
    'status', v_s.status, 'billing_period', v_s.billing_period,
    'trial_ends_at', v_s.trial_ends_at, 'current_period_end', v_s.current_period_end, 'grace_days', v_s.grace_days,
    'writable', app.subscription_writable(p_tenant),
    'staff_count', (select count(*) from public.organization_members where tenant_id = p_tenant and status = 'active'),
    'max_staff', v_p.max_staff,
    'rooms_count', (select count(*) from public.rooms where tenant_id = p_tenant and is_active),
    'max_rooms', v_p.max_rooms,
    'features', (select coalesce(jsonb_agg(feature_code order by feature_code), '[]'::jsonb)
                 from public.plan_features where plan_id = v_p.id),
    'open_request', (select jsonb_build_object('id', r.id, 'plan_code', p.code, 'billing_period', r.billing_period, 'created_at', r.created_at)
                     from public.plan_change_requests r join public.subscription_plans p on p.id = r.plan_id
                     where r.tenant_id = p_tenant and r.status = 'open')
  );
end $$;

-- Заявка на тариф (billing.manage). Новая заявка заменяет открытую. Доступна и при истёкшей подписке.
create or replace function public.request_plan_change(
  p_tenant uuid, p_plan_code text, p_period public.billing_period default 'monthly', p_note text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_plan public.subscription_plans; v_id uuid;
begin
  if not app.has_permission(p_tenant, 'billing.manage') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  select * into v_plan from public.subscription_plans where code = p_plan_code and is_active and is_public;
  if not found then
    raise exception 'plan not found' using errcode = '22023';
  end if;
  update public.plan_change_requests set status = 'cancelled', resolved_at = now(), resolved_by = auth.uid()
  where tenant_id = p_tenant and status = 'open';
  insert into public.plan_change_requests (tenant_id, plan_id, billing_period, note, requested_by)
  values (p_tenant, v_plan.id, coalesce(p_period, 'monthly'), nullif(trim(p_note), ''), auth.uid())
  returning id into v_id;
  perform app.log_audit(p_tenant, 'billing.request', 'plan_change_request', v_id, 'success',
    jsonb_build_object('plan', v_plan.code, 'period', p_period));
  return v_id;
end $$;

create or replace function public.cancel_plan_request(p_request_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_r public.plan_change_requests;
begin
  select * into v_r from public.plan_change_requests where id = p_request_id for update;
  if not found or not app.has_permission(v_r.tenant_id, 'billing.manage') or v_r.status <> 'open' then
    raise exception 'request not found' using errcode = 'P0002';
  end if;
  update public.plan_change_requests set status = 'cancelled', resolved_at = now(), resolved_by = auth.uid()
  where id = p_request_id;
  perform app.log_audit(v_r.tenant_id, 'billing.request_cancel', 'plan_change_request', p_request_id, 'success', '{}'::jsonb);
end $$;

-- Владелец платформы включает тариф после оплаты вне системы. Открытая заявка закрывается.
-- Событие пишется в журнал санатория, чтобы владелец видел, кто и когда сменил тариф.
create or replace function public.admin_set_plan(
  p_tenant uuid, p_plan_code text, p_period public.billing_period, p_period_end timestamptz
) returns void
language plpgsql security definer set search_path = '' as $$
declare v_plan public.subscription_plans; v_old text;
begin
  if not app.is_platform_admin() then
    raise exception 'platform admin only' using errcode = '42501';
  end if;
  select * into v_plan from public.subscription_plans where code = p_plan_code and is_active;
  if not found then
    raise exception 'plan not found' using errcode = '22023';
  end if;
  if p_period_end is null or p_period_end <= now() then
    raise exception 'period end must be in the future' using errcode = '22023';
  end if;
  select p.code into v_old from public.organization_subscriptions s join public.subscription_plans p on p.id = s.plan_id
  where s.tenant_id = p_tenant and s.status <> 'cancelled';
  update public.organization_subscriptions
  set plan_id = v_plan.id, billing_period = coalesce(p_period, 'monthly'), status = 'active',
      current_period_start = now(), current_period_end = p_period_end
  where tenant_id = p_tenant and status <> 'cancelled';
  if not found then
    raise exception 'subscription not found' using errcode = 'P0002';
  end if;
  update public.plan_change_requests set status = 'done', resolved_at = now(), resolved_by = auth.uid()
  where tenant_id = p_tenant and status = 'open';
  perform app.log_audit(p_tenant, 'billing.plan_set', 'organization', p_tenant, 'success',
    jsonb_build_object('from', v_old, 'plan', v_plan.code, 'period', p_period, 'until', p_period_end));
end $$;

revoke execute on function
  public.subscription_overview(uuid),
  public.request_plan_change(uuid, text, public.billing_period, text),
  public.cancel_plan_request(uuid),
  public.admin_set_plan(uuid, text, public.billing_period, timestamptz)
  from public, anon;
grant execute on function
  public.subscription_overview(uuid),
  public.request_plan_change(uuid, text, public.billing_period, text),
  public.cancel_plan_request(uuid),
  public.admin_set_plan(uuid, text, public.billing_period, timestamptz)
  to authenticated;

-- ===== supabase/migrations/20261027000009_analytics.sql =====
-- Sanatorium OS · 0009 · Аналитика
-- Принципы:
--  * отчёт считает сервер одним вызовом analytics_report; клиент только рисует;
--  * доступ — право reports.read и модуль analytics в тарифе; при истёкшей подписке отчёт читается
--    (чтение и выгрузка не блокируются), поэтому проверяется тариф, а не возможность записи;
--  * в отчёте нет персональных данных гостей: только количества и суммы;
--  * загрузка и начисления по проживанию считаются по ночам: стоимость брони делится поровну на её ночи,
--    ночь относится к дате заезда в эту ночь; поступления — по дате оплаты в часовом поясе санатория.

-- Есть ли модуль в тарифе (без проверки, открыта ли запись): для отчётов, которые читаются всегда
create or replace function app.plan_has_feature(p_tenant uuid, p_feature text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.organization_subscriptions s
    join public.plan_features f on f.plan_id = s.plan_id
    where s.tenant_id = p_tenant and s.status <> 'cancelled' and f.feature_code = p_feature
  )
$$;
revoke execute on function app.plan_has_feature(uuid, text) from public, anon;
grant execute on function app.plan_has_feature(uuid, text) to authenticated;

create or replace function public.analytics_report(p_tenant uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_tz text;
  v_from timestamptz;
  v_to timestamptz;
  v_days integer;
  v_rooms integer;
  v_result jsonb;
begin
  if not app.has_permission(p_tenant, 'reports.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not app.plan_has_feature(p_tenant, 'analytics') then
    raise exception 'analytics is not in the plan' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'invalid period' using errcode = '22023';
  end if;

  select coalesce(timezone, 'Asia/Almaty') into v_tz from public.organizations where id = p_tenant;
  v_from := (p_from::timestamp at time zone v_tz);
  v_to := ((p_to + 1)::timestamp at time zone v_tz);
  v_days := p_to - p_from + 1;
  select count(*) into v_rooms from public.rooms where tenant_id = p_tenant and is_active;

  with days as (
    select d::date as day from generate_series(p_from, p_to, interval '1 day') d
  ),
  stays as (
    select b.id, b.guest_id, b.room_type_id, b.check_in, b.check_out, b.total_amount / b.nights as per_night
    from public.bookings b
    where b.tenant_id = p_tenant and b.room_id is not null
      and b.status in ('confirmed', 'checked_in', 'checked_out')
      and b.check_in <= p_to and b.check_out > p_from
  ),
  nights as (
    select d.day, s.id, s.guest_id, s.room_type_id, s.check_in, s.per_night
    from days d join stays s on d.day >= s.check_in and d.day < s.check_out
  ),
  created as (
    select b.source, b.status, b.nights, b.total_amount,
           b.check_in - (b.created_at at time zone v_tz)::date as lead_days
    from public.bookings b
    where b.tenant_id = p_tenant and b.created_at >= v_from and b.created_at < v_to
  ),
  pays as (
    select (p.paid_at at time zone v_tz)::date as day,
           case when p.kind = 'payment' then p.amount else -p.amount end as net
    from public.booking_payments p
    where p.tenant_id = p_tenant and p.voided_at is null and p.paid_at >= v_from and p.paid_at < v_to
  ),
  months as (
    select distinct date_trunc('month', day)::date as month from days
  ),
  procs as (
    select a.procedure_type_id, a.status, a.price
    from public.procedure_appointments a
    where a.tenant_id = p_tenant and a.starts_at >= v_from and a.starts_at < v_to
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'days', v_days, 'rooms', v_rooms,
    'room_nights', (select count(*) from nights),
    'accommodation', (select coalesce(round(sum(per_night), 2), 0) from nights),
    'received', (select coalesce(sum(net), 0) from pays),
    'expenses', (select coalesce(sum(e.amount), 0) from public.expenses e
                 where e.tenant_id = p_tenant and e.voided_at is null and e.spent_on between p_from and p_to),
    'guests', (select count(distinct guest_id) from nights),
    'returning_guests', (select count(distinct n.guest_id) from nights n
                         where exists (select 1 from public.bookings o
                                       where o.tenant_id = p_tenant and o.guest_id = n.guest_id and o.id <> n.id
                                         and o.status in ('confirmed', 'checked_in', 'checked_out')
                                         and o.check_in < n.check_in)),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'occupied',
                (select count(*) from nights n where n.day = d.day)) order by d.day), '[]'::jsonb)
              from days d),
    'monthly', (select coalesce(jsonb_agg(jsonb_build_object(
                  'month', m.month,
                  'room_nights', (select count(*) from nights n where date_trunc('month', n.day) = m.month),
                  'days', (select count(*) from days d where date_trunc('month', d.day) = m.month),
                  'accommodation', (select coalesce(round(sum(per_night), 2), 0) from nights n where date_trunc('month', n.day) = m.month),
                  'received', (select coalesce(sum(net), 0) from pays p where date_trunc('month', p.day) = m.month),
                  'expenses', (select coalesce(sum(e.amount), 0) from public.expenses e
                               where e.tenant_id = p_tenant and e.voided_at is null and e.spent_on between p_from and p_to
                                 and date_trunc('month', e.spent_on) = m.month)
                ) order by m.month), '[]'::jsonb)
                from months m),
    'bookings', (select jsonb_build_object(
                   'created', count(*),
                   'cancelled', count(*) filter (where status = 'cancelled'),
                   'no_show', count(*) filter (where status = 'no_show'),
                   'requests', count(*) filter (where status = 'new_request'),
                   'avg_nights', coalesce(round(avg(nights) filter (where status not in ('cancelled', 'no_show')), 1), 0),
                   'avg_lead_days', coalesce(round(avg(greatest(lead_days, 0)) filter (where status not in ('cancelled', 'no_show')), 1), 0))
                 from created),
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('source', source, 'bookings', cnt, 'cancelled', cancelled, 'amount', amount)
                  order by cnt desc, source), '[]'::jsonb)
                from (select source, count(*) as cnt,
                             count(*) filter (where status in ('cancelled', 'no_show')) as cancelled,
                             coalesce(sum(total_amount) filter (where status not in ('cancelled', 'no_show')), 0) as amount
                      from created group by source) s),
    'room_types', (select coalesce(jsonb_agg(jsonb_build_object('name', rt.name, 'rooms', rt.rooms,
                     'room_nights', coalesce(n.cnt, 0), 'accommodation', coalesce(n.amount, 0))
                     order by coalesce(n.cnt, 0) desc, rt.name), '[]'::jsonb)
                   from (select t.id, t.name, (select count(*) from public.rooms r where r.room_type_id = t.id and r.is_active) as rooms
                         from public.room_types t where t.tenant_id = p_tenant and t.is_active) rt
                   left join (select room_type_id, count(*) as cnt, round(sum(per_night), 2) as amount
                              from nights group by room_type_id) n on n.room_type_id = rt.id),
    'procedures', (select coalesce(jsonb_agg(jsonb_build_object('name', pt.name, 'done', s.done, 'no_show', s.no_show, 'amount', s.amount)
                     order by s.done desc, pt.name), '[]'::jsonb)
                   from (select procedure_type_id,
                                count(*) filter (where status = 'done') as done,
                                count(*) filter (where status = 'no_show') as no_show,
                                coalesce(sum(price) filter (where status = 'done'), 0) as amount
                         from procs group by procedure_type_id) s
                   join public.procedure_types pt on pt.id = s.procedure_type_id
                   where s.done > 0 or s.no_show > 0)
  ) into v_result;
  return v_result;
end $$;

revoke execute on function public.analytics_report(uuid, date, date) from public, anon;
grant execute on function public.analytics_report(uuid, date, date) to authenticated;

-- ===== supabase/migrations/20261028000010_inventory.sql =====
-- Sanatorium OS · 0010 · Склад
-- Принципы:
--  * остаток товара хранится в inventory_items.quantity, но меняется только функцией record_inventory_move:
--    каждое изменение — строка в inventory_movements с остатком после операции (история не правится и не удаляется);
--  * виды движений: приход, выдача (в номер или службе), списание (порча, брак — с причиной),
--    инвентаризация (вводится фактический остаток, разница записывается движением);
--  * уйти в минус нельзя: выдача и списание больше остатка отклоняются;
--  * склад — модуль тарифа «inventory»; при истёкшей подписке остатки и история читаются, но не меняются;
--  * права по умолчанию: смотреть — владелец, директор, бухгалтер, горничная; вести движения — владелец,
--    директор и бухгалтер (inventory.write).

create type public.inventory_category as enum ('linen', 'amenities', 'cleaning', 'food', 'medical', 'office', 'other');
create type public.inventory_move_kind as enum ('receipt', 'issue', 'writeoff', 'adjustment');

create table public.inventory_items (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.organizations(id) on delete cascade,
  name         text not null check (char_length(trim(name)) between 1 and 200),
  category     public.inventory_category not null default 'other',
  unit         text not null default 'шт' check (char_length(trim(unit)) between 1 and 20),
  quantity     numeric(14,3) not null default 0 check (quantity >= 0),
  min_quantity numeric(14,3) not null default 0 check (min_quantity >= 0 and min_quantity <= 100000000),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, name)
);

create table public.inventory_movements (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.organizations(id) on delete cascade,
  item_id       uuid not null,
  kind          public.inventory_move_kind not null,
  quantity      numeric(14,3) not null,           -- изменение остатка: плюс — приход, минус — расход
  balance_after numeric(14,3) not null check (balance_after >= 0),
  unit_cost     numeric(14,2) check (unit_cost >= 0 and unit_cost <= 100000000),
  room_id       uuid,
  note          text check (char_length(note) <= 500),
  created_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now(),
  foreign key (tenant_id, item_id) references public.inventory_items (tenant_id, id),
  foreign key (tenant_id, room_id) references public.rooms (tenant_id, id),
  constraint inventory_move_sign check (
    (kind = 'receipt' and quantity > 0) or (kind in ('issue', 'writeoff') and quantity < 0) or kind = 'adjustment'),
  constraint inventory_writeoff_reason check (kind <> 'writeoff' or char_length(trim(note)) > 0),
  constraint inventory_cost_on_receipt check (unit_cost is null or kind = 'receipt'),
  constraint inventory_room_on_issue check (room_id is null or kind = 'issue')
);
create index inventory_movements_item_idx on public.inventory_movements (tenant_id, item_id, created_at desc);
create index inventory_movements_tenant_date_idx on public.inventory_movements (tenant_id, created_at desc);

create trigger inventory_items_tenant before update on public.inventory_items
  for each row execute function app.forbid_tenant_change();
create trigger inventory_items_touch before update on public.inventory_items
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------------------
-- RLS и права на столбцы
-- ---------------------------------------------------------------------------

alter table public.inventory_items     enable row level security;
alter table public.inventory_movements enable row level security;

create policy inventory_items_select on public.inventory_items for select to authenticated
  using (app.has_permission(tenant_id, 'inventory.read'));
create policy inventory_items_insert on public.inventory_items for insert to authenticated
  with check (app.has_permission(tenant_id, 'inventory.write') and app.feature_enabled(tenant_id, 'inventory'));
create policy inventory_items_update on public.inventory_items for update to authenticated
  using (app.has_permission(tenant_id, 'inventory.write'))
  with check (app.has_permission(tenant_id, 'inventory.write') and app.feature_enabled(tenant_id, 'inventory'));

create policy inventory_movements_select on public.inventory_movements for select to authenticated
  using (app.has_permission(tenant_id, 'inventory.read'));

-- Остаток нельзя задать или поправить напрямую: только через движения
revoke all on public.inventory_items from anon;
revoke insert, update, delete on public.inventory_items from authenticated;
grant select on public.inventory_items to authenticated;
grant insert (tenant_id, name, category, unit, min_quantity, is_active) on public.inventory_items to authenticated;
grant update (name, category, unit, min_quantity, is_active) on public.inventory_items to authenticated;
revoke all on public.inventory_movements from anon;
revoke insert, update, delete on public.inventory_movements from authenticated;
grant select on public.inventory_movements to authenticated;

-- ---------------------------------------------------------------------------
-- Права по умолчанию для системных ролей
-- ---------------------------------------------------------------------------

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from (values ('director', 'inventory.write'), ('accountant', 'inventory.write'), ('housekeeping', 'inventory.read')) v(role_code, perm_code)
join public.roles r on r.code = v.role_code and r.tenant_id is null
join public.permissions p on p.code = v.perm_code
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Журнал: изменения карточек товаров (остаток пишет функция движения)
-- ---------------------------------------------------------------------------

create or replace function app.audit_row_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_new     jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_old     jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_row     jsonb := coalesce(v_new, v_old);
  v_tenant  uuid;
  v_entity  text;
  v_changed text[];
  v_values  jsonb := '{}'::jsonb;
  v_key     text;
  -- поля, значения которых не являются персональными данными и полезны в журнале
  v_tracked text[] := array['name', 'number', 'base_price', 'extra_guest_price', 'price_per_night', 'price',
                            'duration_min', 'starts_on', 'ends_on', 'is_active', 'is_public', 'is_published',
                            'amount', 'spent_on', 'timezone', 'default_language', 'slug', 'max_occupancy', 'base_occupancy',
                            'unit', 'category', 'min_quantity'];
begin
  v_entity := case tg_table_name
    when 'organizations' then 'settings'
    when 'room_types' then 'room_type'
    when 'room_rates' then 'room_rate'
    when 'rooms' then 'room'
    when 'procedure_types' then 'procedure_type'
    when 'treatment_rooms' then 'treatment_room'
    when 'expense_categories' then 'expense_category'
    when 'expenses' then 'expense'
    when 'guests' then 'guest'
    when 'inventory_items' then 'inventory_item'
    else tg_table_name end;
  v_tenant := case when tg_table_name = 'organizations' then (v_row ->> 'id')::uuid else (v_row ->> 'tenant_id')::uuid end;
  -- удаление санатория целиком (каскад) в журнал не пишем: строка организации уже удалена
  if tg_op = 'DELETE' and not exists (select 1 from public.organizations where id = v_tenant) then
    return null;
  end if;

  if tg_op = 'UPDATE' then
    select coalesce(array_agg(k order by k), '{}') into v_changed
    from jsonb_object_keys(v_new) k
    where k not in ('updated_at', 'created_at') and v_new -> k is distinct from v_old -> k;
    if cardinality(v_changed) = 0 then
      return null;
    end if;
    -- статус номера пишет set_room_status(), дубль не нужен
    if tg_table_name = 'rooms' and v_changed <@ array['status'] then
      return null;
    end if;
    -- остаток товара меняет record_inventory_move(), он пишет своё событие
    if tg_table_name = 'inventory_items' and v_changed <@ array['quantity'] then
      return null;
    end if;
    if tg_table_name <> 'guests' then
      foreach v_key in array v_changed loop
        if v_key = any (v_tracked) then
          v_values := v_values || jsonb_build_object(v_key, jsonb_build_object('from', v_old -> v_key, 'to', v_new -> v_key));
        end if;
      end loop;
    end if;
    perform app.log_audit(v_tenant, v_entity || '.update', v_entity, (v_row ->> 'id')::uuid, 'success',
      jsonb_build_object('changed', to_jsonb(v_changed)) || case when v_values = '{}'::jsonb then '{}'::jsonb
                                                                  else jsonb_build_object('values', v_values) end);
  else
    if tg_table_name <> 'guests' then
      foreach v_key in array v_tracked loop
        if v_row ? v_key and v_row -> v_key <> 'null'::jsonb then
          v_values := v_values || jsonb_build_object(v_key, v_row -> v_key);
        end if;
      end loop;
    end if;
    perform app.log_audit(v_tenant, v_entity || case when tg_op = 'INSERT' then '.create' else '.delete' end,
      v_entity, (v_row ->> 'id')::uuid, 'success', v_values);
  end if;
  return null;
end $$;

create trigger inventory_items_audit after insert or update on public.inventory_items
  for each row execute function app.audit_row_change();

-- ---------------------------------------------------------------------------
-- Движение по складу
-- ---------------------------------------------------------------------------

-- p_quantity: для прихода, выдачи и списания — количество (больше нуля);
-- для инвентаризации — фактический остаток (ноль и больше), записывается разница.
create or replace function public.record_inventory_move(
  p_item uuid, p_kind public.inventory_move_kind, p_quantity numeric,
  p_note text default null, p_unit_cost numeric default null, p_room uuid default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_item  public.inventory_items;
  v_delta numeric(14,3);
  v_bal   numeric(14,3);
  v_id    uuid;
  v_note  text := nullif(trim(p_note), '');
begin
  select * into v_item from public.inventory_items where id = p_item for update;
  if not found or not app.has_permission(v_item.tenant_id, 'inventory.write')
     or not app.feature_enabled(v_item.tenant_id, 'inventory') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_quantity is null or p_quantity < 0 or p_quantity > 100000000 or p_quantity <> round(p_quantity, 3)
     or (p_kind <> 'adjustment' and p_quantity = 0) then
    raise exception 'invalid quantity' using errcode = '22023';
  end if;
  if p_kind <> 'adjustment' and not v_item.is_active then
    raise exception 'item is archived' using errcode = '22023';
  end if;
  if p_kind = 'writeoff' and v_note is null then
    raise exception 'writeoff reason required' using errcode = '22023';
  end if;
  if p_unit_cost is not null and (p_kind <> 'receipt' or p_unit_cost < 0 or p_unit_cost <> round(p_unit_cost, 2)) then
    raise exception 'invalid unit cost' using errcode = '22023';
  end if;
  if p_room is not null and (p_kind <> 'issue'
     or not exists (select 1 from public.rooms where id = p_room and tenant_id = v_item.tenant_id)) then
    raise exception 'invalid room' using errcode = '22023';
  end if;

  v_delta := case p_kind when 'receipt' then p_quantity
                         when 'adjustment' then p_quantity - v_item.quantity
                         else -p_quantity end;
  v_bal := v_item.quantity + v_delta;
  if v_bal < 0 then
    raise exception 'not enough stock' using errcode = '22023';
  end if;

  update public.inventory_items set quantity = v_bal where id = p_item;
  insert into public.inventory_movements (tenant_id, item_id, kind, quantity, balance_after, unit_cost, room_id, note, created_by)
  values (v_item.tenant_id, p_item, p_kind, v_delta, v_bal, p_unit_cost, p_room, v_note, auth.uid())
  returning id into v_id;

  perform app.log_audit(v_item.tenant_id, 'inventory.' || p_kind::text, 'inventory_item', p_item, 'success',
    jsonb_build_object('name', v_item.name, 'quantity', v_delta, 'balance', v_bal, 'unit', v_item.unit)
    || case when v_note is not null and p_kind = 'writeoff' then jsonb_build_object('reason', v_note) else '{}'::jsonb end);
  return jsonb_build_object('id', v_id, 'balance', v_bal);
end $$;

revoke execute on function public.record_inventory_move(uuid, public.inventory_move_kind, numeric, text, numeric, uuid) from public, anon;
grant execute on function public.record_inventory_move(uuid, public.inventory_move_kind, numeric, text, numeric, uuid) to authenticated;

-- ===== supabase/migrations/20261029000011_reviews_promos.sql =====
-- Sanatorium OS · 0011 · Отзывы и акции
-- Принципы:
--  * отзыв оставляет только гость, который действительно жил: после выезда сотрудник получает одноразовую ссылку
--    и отправляет её гостю сам (WhatsApp, SMS). Сервис рассылки не изображается;
--  * по ссылке гость видит только название санатория и даты проживания — без своих персональных данных;
--  * на публичной странице показываются только отзывы, которые гость разрешил публиковать и сотрудник опубликовал;
--    имя — только то, что гость сам указал для публикации;
--  * промокод применяет сотрудник к брони; размер скидки считает сервер и пересчитывает при изменении брони;
--    скидка уменьшает стоимость проживания в балансе брони, в отчётах и аналитике;
--  * модуль тарифа «marketing»: при истёкшей подписке отзывы и промокоды читаются, но не меняются.

create type public.review_status as enum ('new', 'published', 'hidden');
create type public.promo_kind as enum ('percent', 'fixed');

-- ---------------------------------------------------------------------------
-- Промокоды
-- ---------------------------------------------------------------------------

create table public.promo_codes (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.organizations(id) on delete cascade,
  code        text not null check (code ~ '^[A-Z0-9][A-Z0-9_-]{2,29}$'),
  description text check (char_length(description) <= 300),
  kind        public.promo_kind not null,
  value       numeric(14,2) not null check (value > 0),
  valid_from  date,
  valid_to    date,
  min_nights  integer not null default 1 check (min_nights between 1 and 365),
  max_uses    integer check (max_uses between 1 and 100000),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, code),
  constraint promo_percent_range check (kind <> 'percent' or value <= 100),
  constraint promo_fixed_range check (kind <> 'fixed' or value <= 100000000),
  constraint promo_dates check (valid_to is null or valid_from is null or valid_to >= valid_from)
);

create trigger promo_codes_tenant before update on public.promo_codes
  for each row execute function app.forbid_tenant_change();
create trigger promo_codes_touch before update on public.promo_codes
  for each row execute function app.touch_updated_at();

alter table public.bookings
  add column promo_code_id   uuid,
  add column discount_amount numeric(14,2) not null default 0 check (discount_amount >= 0),
  add constraint bookings_promo_fk foreign key (tenant_id, promo_code_id) references public.promo_codes (tenant_id, id),
  add constraint bookings_discount_le_total check (discount_amount <= total_amount);

-- Скидка всегда считается от текущей стоимости проживания: при переносе дат и смене номера пересчитывается
create or replace function app.apply_booking_discount() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_promo public.promo_codes;
begin
  if new.promo_code_id is null then
    new.discount_amount := 0;
  else
    select * into v_promo from public.promo_codes where id = new.promo_code_id;
    new.discount_amount := least(new.total_amount,
      case v_promo.kind when 'percent' then round(new.total_amount * v_promo.value / 100, 0) else v_promo.value end);
  end if;
  return new;
end $$;

create trigger bookings_discount before insert or update of total_amount, promo_code_id on public.bookings
  for each row execute function app.apply_booking_discount();

alter table public.promo_codes enable row level security;

create policy promo_codes_select on public.promo_codes for select to authenticated
  using (app.has_permission(tenant_id, 'marketing.read') or app.has_permission(tenant_id, 'bookings.write'));
create policy promo_codes_insert on public.promo_codes for insert to authenticated
  with check (app.has_permission(tenant_id, 'marketing.write') and app.feature_enabled(tenant_id, 'marketing'));
create policy promo_codes_update on public.promo_codes for update to authenticated
  using (app.has_permission(tenant_id, 'marketing.write'))
  with check (app.has_permission(tenant_id, 'marketing.write') and app.feature_enabled(tenant_id, 'marketing'));
revoke all on public.promo_codes from anon;
revoke delete on public.promo_codes from authenticated;

-- Применить промокод к брони (или снять его, p_code = null).
-- Условия: код активен, заезд в сроке действия, ночей не меньше минимума, лимит применений не исчерпан.
create or replace function public.apply_promo_code(p_booking_id uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_b     public.bookings;
  v_promo public.promo_codes;
  v_used  integer;
  v_code  text := upper(trim(coalesce(p_code, '')));
begin
  select * into v_b from public.bookings where id = p_booking_id for update;
  if not found or not app.has_permission(v_b.tenant_id, 'bookings.write')
     or not app.feature_enabled(v_b.tenant_id, 'marketing') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_b.status not in ('new_request', 'confirmed', 'checked_in') then
    raise exception 'booking is closed' using errcode = '22023';
  end if;

  if v_code = '' then
    update public.bookings set promo_code_id = null where id = p_booking_id;
    perform app.log_audit(v_b.tenant_id, 'booking.promo_remove', 'booking', p_booking_id);
    return jsonb_build_object('discount', 0);
  end if;

  select * into v_promo from public.promo_codes where tenant_id = v_b.tenant_id and code = v_code;
  if not found or not v_promo.is_active then
    raise exception 'promo code not found' using errcode = 'P0002';
  end if;
  if (v_promo.valid_from is not null and v_b.check_in < v_promo.valid_from)
     or (v_promo.valid_to is not null and v_b.check_in > v_promo.valid_to) then
    raise exception 'promo code is not valid for these dates' using errcode = '22023';
  end if;
  if v_b.nights < v_promo.min_nights then
    raise exception 'stay is too short for this promo code' using errcode = '22023';
  end if;
  if v_promo.max_uses is not null then
    select count(*) into v_used from public.bookings
    where promo_code_id = v_promo.id and id <> p_booking_id and status not in ('cancelled', 'no_show');
    if v_used >= v_promo.max_uses then
      raise exception 'promo code usage limit reached' using errcode = '22023';
    end if;
  end if;

  update public.bookings set promo_code_id = v_promo.id where id = p_booking_id returning * into v_b;
  perform app.log_audit(v_b.tenant_id, 'booking.promo_apply', 'booking', p_booking_id, 'success',
    jsonb_build_object('code', v_promo.code, 'amount', v_b.discount_amount));
  return jsonb_build_object('discount', v_b.discount_amount, 'code', v_promo.code);
end $$;

-- Сколько раз применён каждый промокод (без отменённых броней)
create or replace function public.promo_code_usage(p_tenant uuid) returns table (promo_code_id uuid, uses bigint, discount numeric)
language sql stable security definer set search_path = '' as $$
  select b.promo_code_id, count(*), coalesce(sum(b.discount_amount), 0)
  from public.bookings b
  where b.tenant_id = p_tenant and b.promo_code_id is not null and b.status not in ('cancelled', 'no_show')
    and app.has_permission(p_tenant, 'marketing.read')
  group by b.promo_code_id
$$;

-- ---------------------------------------------------------------------------
-- Баланс брони: проживание за вычетом скидки
-- ---------------------------------------------------------------------------

create or replace view public.booking_balances with (security_invoker = true) as
select
  b.id as booking_id,
  b.tenant_id,
  (b.total_amount - b.discount_amount)::numeric(14,2) as accommodation,
  coalesce(x.extras, 0)::numeric(14,2) as extras,
  (case when b.status in ('cancelled', 'no_show') then 0
        else b.total_amount - b.discount_amount + coalesce(x.extras, 0) + coalesce(pr.procedures, 0) end)::numeric(14,2) as charges,
  coalesce(p.paid, 0)::numeric(14,2) as paid,
  coalesce(p.refunded, 0)::numeric(14,2) as refunded,
  (coalesce(p.paid, 0) - coalesce(p.refunded, 0))::numeric(14,2) as paid_net,
  ((case when b.status in ('cancelled', 'no_show') then 0
         else b.total_amount - b.discount_amount + coalesce(x.extras, 0) + coalesce(pr.procedures, 0) end)
    - coalesce(p.paid, 0) + coalesce(p.refunded, 0))::numeric(14,2) as balance,
  coalesce(pr.procedures, 0)::numeric(14,2) as procedures,
  b.discount_amount as discount
from public.bookings b
left join (
  select booking_id, sum(amount) as extras from public.booking_extras group by booking_id
) x on x.booking_id = b.id
left join (
  select booking_id, sum(price) as procedures from public.procedure_appointments
  where booking_id is not null and status in ('scheduled', 'done') group by booking_id
) pr on pr.booking_id = b.id
left join (
  select booking_id,
         sum(amount) filter (where kind = 'payment') as paid,
         sum(amount) filter (where kind = 'refund') as refunded
  from public.booking_payments where voided_at is null group by booking_id
) p on p.booking_id = b.id;

revoke all on public.booking_balances from anon;
grant select on public.booking_balances to authenticated;

-- Аналитика считает начисления за проживание с учётом скидки
create or replace function public.analytics_report(p_tenant uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_tz text;
  v_from timestamptz;
  v_to timestamptz;
  v_days integer;
  v_rooms integer;
  v_result jsonb;
begin
  if not app.has_permission(p_tenant, 'reports.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not app.plan_has_feature(p_tenant, 'analytics') then
    raise exception 'analytics is not in the plan' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'invalid period' using errcode = '22023';
  end if;

  select coalesce(timezone, 'Asia/Almaty') into v_tz from public.organizations where id = p_tenant;
  v_from := (p_from::timestamp at time zone v_tz);
  v_to := ((p_to + 1)::timestamp at time zone v_tz);
  v_days := p_to - p_from + 1;
  select count(*) into v_rooms from public.rooms where tenant_id = p_tenant and is_active;

  with days as (
    select d::date as day from generate_series(p_from, p_to, interval '1 day') d
  ),
  stays as (
    select b.id, b.guest_id, b.room_type_id, b.check_in, b.check_out, (b.total_amount - b.discount_amount) / b.nights as per_night
    from public.bookings b
    where b.tenant_id = p_tenant and b.room_id is not null
      and b.status in ('confirmed', 'checked_in', 'checked_out')
      and b.check_in <= p_to and b.check_out > p_from
  ),
  nights as (
    select d.day, s.id, s.guest_id, s.room_type_id, s.check_in, s.per_night
    from days d join stays s on d.day >= s.check_in and d.day < s.check_out
  ),
  created as (
    select b.source, b.status, b.nights, b.total_amount - b.discount_amount as total_amount,
           b.check_in - (b.created_at at time zone v_tz)::date as lead_days
    from public.bookings b
    where b.tenant_id = p_tenant and b.created_at >= v_from and b.created_at < v_to
  ),
  pays as (
    select (p.paid_at at time zone v_tz)::date as day,
           case when p.kind = 'payment' then p.amount else -p.amount end as net
    from public.booking_payments p
    where p.tenant_id = p_tenant and p.voided_at is null and p.paid_at >= v_from and p.paid_at < v_to
  ),
  months as (
    select distinct date_trunc('month', day)::date as month from days
  ),
  procs as (
    select a.procedure_type_id, a.status, a.price
    from public.procedure_appointments a
    where a.tenant_id = p_tenant and a.starts_at >= v_from and a.starts_at < v_to
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'days', v_days, 'rooms', v_rooms,
    'room_nights', (select count(*) from nights),
    'accommodation', (select coalesce(round(sum(per_night), 2), 0) from nights),
    'received', (select coalesce(sum(net), 0) from pays),
    'expenses', (select coalesce(sum(e.amount), 0) from public.expenses e
                 where e.tenant_id = p_tenant and e.voided_at is null and e.spent_on between p_from and p_to),
    'guests', (select count(distinct guest_id) from nights),
    'returning_guests', (select count(distinct n.guest_id) from nights n
                         where exists (select 1 from public.bookings o
                                       where o.tenant_id = p_tenant and o.guest_id = n.guest_id and o.id <> n.id
                                         and o.status in ('confirmed', 'checked_in', 'checked_out')
                                         and o.check_in < n.check_in)),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'occupied',
                (select count(*) from nights n where n.day = d.day)) order by d.day), '[]'::jsonb)
              from days d),
    'monthly', (select coalesce(jsonb_agg(jsonb_build_object(
                  'month', m.month,
                  'room_nights', (select count(*) from nights n where date_trunc('month', n.day) = m.month),
                  'days', (select count(*) from days d where date_trunc('month', d.day) = m.month),
                  'accommodation', (select coalesce(round(sum(per_night), 2), 0) from nights n where date_trunc('month', n.day) = m.month),
                  'received', (select coalesce(sum(net), 0) from pays p where date_trunc('month', p.day) = m.month),
                  'expenses', (select coalesce(sum(e.amount), 0) from public.expenses e
                               where e.tenant_id = p_tenant and e.voided_at is null and e.spent_on between p_from and p_to
                                 and date_trunc('month', e.spent_on) = m.month)
                ) order by m.month), '[]'::jsonb)
                from months m),
    'bookings', (select jsonb_build_object(
                   'created', count(*),
                   'cancelled', count(*) filter (where status = 'cancelled'),
                   'no_show', count(*) filter (where status = 'no_show'),
                   'requests', count(*) filter (where status = 'new_request'),
                   'avg_nights', coalesce(round(avg(nights) filter (where status not in ('cancelled', 'no_show')), 1), 0),
                   'avg_lead_days', coalesce(round(avg(greatest(lead_days, 0)) filter (where status not in ('cancelled', 'no_show')), 1), 0))
                 from created),
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('source', source, 'bookings', cnt, 'cancelled', cancelled, 'amount', amount)
                  order by cnt desc, source), '[]'::jsonb)
                from (select source, count(*) as cnt,
                             count(*) filter (where status in ('cancelled', 'no_show')) as cancelled,
                             coalesce(sum(total_amount) filter (where status not in ('cancelled', 'no_show')), 0) as amount
                      from created group by source) s),
    'room_types', (select coalesce(jsonb_agg(jsonb_build_object('name', rt.name, 'rooms', rt.rooms,
                     'room_nights', coalesce(n.cnt, 0), 'accommodation', coalesce(n.amount, 0))
                     order by coalesce(n.cnt, 0) desc, rt.name), '[]'::jsonb)
                   from (select t.id, t.name, (select count(*) from public.rooms r where r.room_type_id = t.id and r.is_active) as rooms
                         from public.room_types t where t.tenant_id = p_tenant and t.is_active) rt
                   left join (select room_type_id, count(*) as cnt, round(sum(per_night), 2) as amount
                              from nights group by room_type_id) n on n.room_type_id = rt.id),
    'procedures', (select coalesce(jsonb_agg(jsonb_build_object('name', pt.name, 'done', s.done, 'no_show', s.no_show, 'amount', s.amount)
                     order by s.done desc, pt.name), '[]'::jsonb)
                   from (select procedure_type_id,
                                count(*) filter (where status = 'done') as done,
                                count(*) filter (where status = 'no_show') as no_show,
                                coalesce(sum(price) filter (where status = 'done'), 0) as amount
                         from procs group by procedure_type_id) s
                   join public.procedure_types pt on pt.id = s.procedure_type_id
                   where s.done > 0 or s.no_show > 0)
  ) into v_result;
  return v_result;
end $$;

-- ---------------------------------------------------------------------------
-- Отзывы
-- ---------------------------------------------------------------------------

create table public.review_requests (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.organizations(id) on delete cascade,
  booking_id uuid not null unique,
  token      text not null unique check (char_length(token) = 64),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '60 days',
  used_at    timestamptz,
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id)
);

create table public.reviews (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.organizations(id) on delete cascade,
  booking_id      uuid not null unique,
  guest_id        uuid not null,
  rating          smallint not null check (rating between 1 and 5),
  comment         text check (char_length(comment) <= 2000),
  author_name     text check (char_length(author_name) <= 60),
  publish_consent boolean not null default false,
  status          public.review_status not null default 'new',
  reply           text check (char_length(reply) <= 2000),
  replied_at      timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id),
  constraint review_publish_needs_consent check (status <> 'published' or publish_consent)
);
create index reviews_tenant_created_idx on public.reviews (tenant_id, created_at desc);

create trigger reviews_touch before update on public.reviews
  for each row execute function app.touch_updated_at();

alter table public.review_requests enable row level security;
alter table public.reviews         enable row level security;

-- Читать отзывы — marketing.read; менять — только функциями
create policy reviews_select on public.reviews for select to authenticated
  using (app.has_permission(tenant_id, 'marketing.read'));
create policy review_requests_select on public.review_requests for select to authenticated
  using (app.has_permission(tenant_id, 'marketing.read'));
revoke all on public.reviews, public.review_requests from anon;
revoke insert, update, delete on public.reviews, public.review_requests from authenticated;

-- Ссылка на отзыв для завершённого проживания. Повторный вызов возвращает ту же ссылку (и продлевает срок).
create or replace function public.create_review_request(p_booking_id uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_b     public.bookings;
  v_req   public.review_requests;
begin
  select * into v_b from public.bookings where id = p_booking_id;
  if not found
     or not (app.has_permission(v_b.tenant_id, 'bookings.checkin') or app.has_permission(v_b.tenant_id, 'marketing.write'))
     or not app.feature_enabled(v_b.tenant_id, 'marketing') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_b.status <> 'checked_out' then
    raise exception 'review is available after check-out' using errcode = '22023';
  end if;

  select * into v_req from public.review_requests where booking_id = p_booking_id;
  if found then
    if v_req.used_at is not null then
      raise exception 'review already received' using errcode = '22023';
    end if;
    update public.review_requests set expires_at = now() + interval '60 days' where id = v_req.id;
    return v_req.token;
  end if;

  insert into public.review_requests (tenant_id, booking_id, token, created_by)
  values (v_b.tenant_id, p_booking_id,
          replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), auth.uid())
  returning * into v_req;
  perform app.log_audit(v_b.tenant_id, 'review.request', 'booking', p_booking_id);
  return v_req.token;
end $$;

-- Форма отзыва для гостя (аноним): только название санатория и даты, без персональных данных
create or replace function public.get_review_form(p_token text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_req public.review_requests;
  v_b   public.bookings;
  v_o   public.organizations;
begin
  select * into v_req from public.review_requests where token = p_token;
  if not found then
    return jsonb_build_object('state', 'not_found');
  end if;
  select * into v_b from public.bookings where id = v_req.booking_id;
  select * into v_o from public.organizations where id = v_req.tenant_id;
  return jsonb_build_object(
    'state', case when v_req.used_at is not null then 'used'
                  when v_req.expires_at < now() then 'expired'
                  when not app.plan_has_feature(v_req.tenant_id, 'marketing') then 'unavailable'
                  else 'open' end,
    'sanatorium', v_o.name, 'slug', case when v_o.is_published then v_o.slug end,
    'default_language', v_o.default_language,
    'check_in', v_b.check_in, 'check_out', v_b.check_out);
end $$;

-- Отзыв гостя по одноразовой ссылке (аноним)
create or replace function public.submit_review(
  p_token text, p_rating integer, p_comment text default null, p_author_name text default null, p_publish_consent boolean default false
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_req public.review_requests;
  v_b   public.bookings;
begin
  select * into v_req from public.review_requests where token = p_token for update;
  if not found or v_req.expires_at < now() or not app.plan_has_feature(v_req.tenant_id, 'marketing') then
    raise exception 'review link is not valid' using errcode = 'P0002';
  end if;
  if v_req.used_at is not null then
    raise exception 'review already received' using errcode = '22023';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then
    raise exception 'rating must be from 1 to 5' using errcode = '22023';
  end if;
  if char_length(coalesce(p_comment, '')) > 2000 or char_length(coalesce(p_author_name, '')) > 60 then
    raise exception 'text is too long' using errcode = '22023';
  end if;

  select * into v_b from public.bookings where id = v_req.booking_id;
  insert into public.reviews (tenant_id, booking_id, guest_id, rating, comment, author_name, publish_consent)
  values (v_req.tenant_id, v_req.booking_id, v_b.guest_id, p_rating, nullif(trim(p_comment), ''),
          nullif(trim(p_author_name), ''), coalesce(p_publish_consent, false));
  update public.review_requests set used_at = now() where id = v_req.id;
  perform app.log_audit(v_req.tenant_id, 'review.received', 'booking', v_req.booking_id, 'success',
    jsonb_build_object('rating', p_rating));
end $$;

-- Модерация: опубликовать (только с согласия гостя), скрыть, ответить
create or replace function public.moderate_review(p_review_id uuid, p_status public.review_status, p_reply text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_r public.reviews;
  v_reply text := nullif(trim(p_reply), '');
begin
  select * into v_r from public.reviews where id = p_review_id for update;
  if not found or not app.has_permission(v_r.tenant_id, 'marketing.write')
     or not app.feature_enabled(v_r.tenant_id, 'marketing') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_status = 'published' and not v_r.publish_consent then
    raise exception 'guest did not allow publishing' using errcode = '22023';
  end if;
  if char_length(coalesce(v_reply, '')) > 2000 then
    raise exception 'text is too long' using errcode = '22023';
  end if;
  update public.reviews
  set status = p_status, reply = v_reply,
      replied_at = case when v_reply is distinct from v_r.reply then case when v_reply is null then null else now() end
                        else v_r.replied_at end
  where id = p_review_id;
  perform app.log_audit(v_r.tenant_id, 'review.' || p_status::text, 'review', p_review_id, 'success',
    jsonb_build_object('rating', v_r.rating) || case when v_reply is distinct from v_r.reply then jsonb_build_object('replied', v_reply is not null) else '{}'::jsonb end);
end $$;

-- Опубликованные отзывы для публичной страницы (аноним)
create or replace function public.get_public_reviews(p_slug text) returns jsonb
language sql stable security definer set search_path = '' as $$
  with o as (
    select id from public.organizations
    where slug = lower(p_slug) and is_published and app.plan_has_feature(id, 'marketing')
  ), r as (
    select rv.rating, rv.comment, rv.author_name, rv.reply, rv.created_at
    from public.reviews rv join o on o.id = rv.tenant_id
    where rv.status = 'published'
  )
  select jsonb_build_object(
    'count', (select count(*) from r),
    'average', (select round(avg(rating), 1) from r),
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
                'rating', rating, 'comment', comment, 'author_name', author_name, 'reply', reply,
                'month', to_char(created_at, 'YYYY-MM')) order by created_at desc), '[]'::jsonb)
              from (select * from r order by created_at desc limit 30) last))
$$;

-- Сводка отзывов для сотрудников
create or replace function public.review_summary(p_tenant uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when app.has_permission(p_tenant, 'marketing.read') then jsonb_build_object(
    'count', count(*), 'average', round(avg(rating), 1),
    'new', count(*) filter (where status = 'new'),
    'by_rating', jsonb_build_object('5', count(*) filter (where rating = 5), '4', count(*) filter (where rating = 4),
                                    '3', count(*) filter (where rating = 3), '2', count(*) filter (where rating = 2),
                                    '1', count(*) filter (where rating = 1)))
  end
  from public.reviews where tenant_id = p_tenant
$$;

-- ---------------------------------------------------------------------------
-- Журнал: изменения промокодов
-- ---------------------------------------------------------------------------

create or replace function app.audit_row_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_new     jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_old     jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_row     jsonb := coalesce(v_new, v_old);
  v_tenant  uuid;
  v_entity  text;
  v_changed text[];
  v_values  jsonb := '{}'::jsonb;
  v_key     text;
  -- поля, значения которых не являются персональными данными и полезны в журнале
  v_tracked text[] := array['name', 'number', 'base_price', 'extra_guest_price', 'price_per_night', 'price',
                            'duration_min', 'starts_on', 'ends_on', 'is_active', 'is_public', 'is_published',
                            'amount', 'spent_on', 'timezone', 'default_language', 'slug', 'max_occupancy', 'base_occupancy',
                            'unit', 'category', 'min_quantity',
                            'code', 'kind', 'value', 'valid_from', 'valid_to', 'min_nights', 'max_uses'];
begin
  v_entity := case tg_table_name
    when 'organizations' then 'settings'
    when 'room_types' then 'room_type'
    when 'room_rates' then 'room_rate'
    when 'rooms' then 'room'
    when 'procedure_types' then 'procedure_type'
    when 'treatment_rooms' then 'treatment_room'
    when 'expense_categories' then 'expense_category'
    when 'expenses' then 'expense'
    when 'guests' then 'guest'
    when 'inventory_items' then 'inventory_item'
    when 'promo_codes' then 'promo_code'
    else tg_table_name end;
  v_tenant := case when tg_table_name = 'organizations' then (v_row ->> 'id')::uuid else (v_row ->> 'tenant_id')::uuid end;
  -- удаление санатория целиком (каскад) в журнал не пишем: строка организации уже удалена
  if tg_op = 'DELETE' and not exists (select 1 from public.organizations where id = v_tenant) then
    return null;
  end if;

  if tg_op = 'UPDATE' then
    select coalesce(array_agg(k order by k), '{}') into v_changed
    from jsonb_object_keys(v_new) k
    where k not in ('updated_at', 'created_at') and v_new -> k is distinct from v_old -> k;
    if cardinality(v_changed) = 0 then
      return null;
    end if;
    -- статус номера пишет set_room_status(), дубль не нужен
    if tg_table_name = 'rooms' and v_changed <@ array['status'] then
      return null;
    end if;
    -- остаток товара меняет record_inventory_move(), он пишет своё событие
    if tg_table_name = 'inventory_items' and v_changed <@ array['quantity'] then
      return null;
    end if;
    if tg_table_name <> 'guests' then
      foreach v_key in array v_changed loop
        if v_key = any (v_tracked) then
          v_values := v_values || jsonb_build_object(v_key, jsonb_build_object('from', v_old -> v_key, 'to', v_new -> v_key));
        end if;
      end loop;
    end if;
    perform app.log_audit(v_tenant, v_entity || '.update', v_entity, (v_row ->> 'id')::uuid, 'success',
      jsonb_build_object('changed', to_jsonb(v_changed)) || case when v_values = '{}'::jsonb then '{}'::jsonb
                                                                  else jsonb_build_object('values', v_values) end);
  else
    if tg_table_name <> 'guests' then
      foreach v_key in array v_tracked loop
        if v_row ? v_key and v_row -> v_key <> 'null'::jsonb then
          v_values := v_values || jsonb_build_object(v_key, v_row -> v_key);
        end if;
      end loop;
    end if;
    perform app.log_audit(v_tenant, v_entity || case when tg_op = 'INSERT' then '.create' else '.delete' end,
      v_entity, (v_row ->> 'id')::uuid, 'success', v_values);
  end if;
  return null;
end $$;

create trigger promo_codes_audit after insert or update on public.promo_codes
  for each row execute function app.audit_row_change();

-- ---------------------------------------------------------------------------
-- Доступ к функциям
-- ---------------------------------------------------------------------------

revoke all on function app.apply_booking_discount() from public, anon, authenticated;
revoke execute on function
  public.apply_promo_code(uuid, text),
  public.promo_code_usage(uuid),
  public.create_review_request(uuid),
  public.moderate_review(uuid, public.review_status, text),
  public.review_summary(uuid)
  from public, anon;
grant execute on function
  public.apply_promo_code(uuid, text),
  public.promo_code_usage(uuid),
  public.create_review_request(uuid),
  public.moderate_review(uuid, public.review_status, text),
  public.review_summary(uuid)
  to authenticated;
revoke all on function
  public.get_review_form(text),
  public.submit_review(text, integer, text, text, boolean),
  public.get_public_reviews(text)
  from public;
grant execute on function
  public.get_review_form(text),
  public.submit_review(text, integer, text, text, boolean),
  public.get_public_reviews(text)
  to anon, authenticated;

-- ===== supabase/migrations/20261030000012_whatsapp_kaspi.sql =====
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

-- ===== supabase/migrations/20261031000013_leads.sql =====
-- Sanatorium OS · 0013 · Заявки (лиды)
-- Принципы:
--  * заявка — обращение до брони: звонок, сообщение WhatsApp, заявка с сайта, визит, агент;
--    у неё есть статус (новая → в работе → бронь / отказ), ответственный и дата следующего контакта;
--  * заявка с сайта (submit_booking_request) по-прежнему создаёт бронь «заявка» без номера, а рядом —
--    заявку со ссылкой на эту бронь; когда бронь подтверждают, заявка закрывается как «бронь»,
--    когда отменяют — как «отказ»;
--  * входящее WhatsApp с незнакомого номера (нет гостя и открытой заявки) создаёт новую заявку;
--  * бронь из заявки создаёт функция create_booking_from_lead: внутри обычный create_booking,
--    поэтому цену по-прежнему считает сервер;
--  * записи меняются только функциями; читать — leads.read, работать — leads.write; заявки входят в модуль
--    «bookings» (все тарифы); при истёкшей подписке всё читается, но не меняется;
--  * в журнал пишутся действия и названия изменённых полей, без телефонов и текста заметок.

create type public.lead_status as enum ('new', 'in_progress', 'won', 'lost');
create type public.lead_lost_reason as enum ('price', 'no_dates', 'no_answer', 'competitor', 'not_relevant', 'booking_cancelled', 'other');

create table public.lead_counters (
  tenant_id   uuid primary key references public.organizations(id) on delete cascade,
  last_number integer not null default 0
);
alter table public.lead_counters enable row level security;
revoke all on public.lead_counters from anon, authenticated;

create table public.leads (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.organizations(id) on delete cascade,
  number          integer not null,
  status          public.lead_status not null default 'new',
  source          public.booking_source not null default 'phone',
  full_name       text check (char_length(full_name) between 1 and 200),
  phone           text check (phone ~ '^\+[1-9][0-9]{6,14}$'),
  guest_id        uuid,
  booking_id      uuid,
  room_type_id    uuid,
  check_in        date,
  check_out       date,
  adults          smallint check (adults between 1 and 50),
  children        smallint check (children between 0 and 50),
  interest        text check (char_length(interest) <= 500),
  comment         text check (char_length(comment) <= 2000),
  assignee_id     uuid references auth.users(id) on delete set null,
  next_contact_at timestamptz,
  lost_reason     public.lead_lost_reason,
  lost_note       text check (char_length(lost_note) <= 500),
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  closed_at       timestamptz,
  unique (tenant_id, id),
  unique (tenant_id, number),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id) on delete set null (guest_id),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id) on delete set null (booking_id),
  foreign key (tenant_id, room_type_id) references public.room_types (tenant_id, id) on delete set null (room_type_id),
  constraint lead_contact check (full_name is not null or phone is not null),
  constraint lead_dates check (check_out is null or (check_in is not null and check_out > check_in and check_out - check_in <= 365)),
  constraint lead_lost check ((status = 'lost') = (lost_reason is not null)),
  constraint lead_closed check ((status in ('won', 'lost')) = (closed_at is not null))
);
create index leads_tenant_status_idx on public.leads (tenant_id, status, created_at desc);
create index leads_phone_idx on public.leads (tenant_id, phone) where phone is not null;
create index leads_booking_idx on public.leads (booking_id) where booking_id is not null;

create table public.lead_notes (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.organizations(id) on delete cascade,
  lead_id    uuid not null,
  body       text not null check (char_length(trim(body)) between 1 and 2000),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (tenant_id, lead_id) references public.leads (tenant_id, id) on delete cascade
);
create index lead_notes_lead_idx on public.lead_notes (tenant_id, lead_id, created_at);

create trigger leads_tenant before update on public.leads
  for each row execute function app.forbid_tenant_change();
create trigger leads_touch before update on public.leads
  for each row execute function app.touch_updated_at();

alter table public.leads enable row level security;
alter table public.lead_notes enable row level security;
create policy leads_select on public.leads for select to authenticated
  using (app.has_permission(tenant_id, 'leads.read'));
create policy lead_notes_select on public.lead_notes for select to authenticated
  using (app.has_permission(tenant_id, 'leads.read'));
revoke insert, update, delete on public.leads, public.lead_notes from authenticated;
revoke all on public.leads, public.lead_notes from anon;

-- ---------------------------------------------------------------------------
-- Вспомогательные функции
-- ---------------------------------------------------------------------------

create or replace function app.next_lead_number(p_tenant uuid) returns integer
language sql security definer set search_path = '' as $$
  insert into public.lead_counters as c (tenant_id, last_number) values (p_tenant, 1)
  on conflict (tenant_id) do update set last_number = c.last_number + 1
  returning last_number
$$;

-- Проверка полей заявки (общая для создания и изменения)
create or replace function app.check_lead_fields(
  p_tenant uuid, p_full_name text, p_phone text, p_room_type_id uuid, p_check_in date, p_check_out date,
  p_adults integer, p_children integer, p_interest text, p_comment text, p_assignee uuid
) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if nullif(btrim(coalesce(p_full_name, '')), '') is null and p_phone is null then
    raise exception 'name or phone is required' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_full_name, ''))) > 200 or char_length(coalesce(p_interest, '')) > 500
     or char_length(coalesce(p_comment, '')) > 2000 then
    raise exception 'text is too long' using errcode = '22023';
  end if;
  if p_phone is not null and p_phone !~ '^\+[1-9][0-9]{6,14}$' then
    raise exception 'invalid phone' using errcode = '22023';
  end if;
  if (p_check_out is not null and (p_check_in is null or p_check_out <= p_check_in or p_check_out - p_check_in > 365)) then
    raise exception 'invalid dates' using errcode = '22023';
  end if;
  if (p_adults is not null and p_adults not between 1 and 50) or (p_children is not null and p_children not between 0 and 50) then
    raise exception 'invalid guests count' using errcode = '22023';
  end if;
  if p_room_type_id is not null and not exists (select 1 from public.room_types where id = p_room_type_id and tenant_id = p_tenant) then
    raise exception 'room type not found' using errcode = 'P0002';
  end if;
  if p_assignee is not null and not app.member_has_permission(p_tenant, p_assignee, 'leads.write') then
    raise exception 'assignee is not available' using errcode = '22023';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Операции сотрудников
-- ---------------------------------------------------------------------------

create or replace function public.create_lead(
  p_tenant uuid, p_source public.booking_source, p_full_name text, p_phone text,
  p_room_type_id uuid default null, p_check_in date default null, p_check_out date default null,
  p_adults integer default null, p_children integer default null, p_interest text default null,
  p_comment text default null, p_assignee_id uuid default null, p_next_contact_at timestamptz default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_guest uuid;
begin
  if not app.can_write_bookings(p_tenant, 'leads.write') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  perform app.check_lead_fields(p_tenant, p_full_name, p_phone, p_room_type_id, p_check_in, p_check_out,
    p_adults, p_children, p_interest, p_comment, p_assignee_id);
  if p_phone is not null then
    select id into v_guest from public.guests where tenant_id = p_tenant and phone = p_phone and archived_at is null;
  end if;

  insert into public.leads (tenant_id, number, source, full_name, phone, guest_id, room_type_id, check_in, check_out,
    adults, children, interest, comment, assignee_id, next_contact_at, created_by)
  values (p_tenant, app.next_lead_number(p_tenant), coalesce(p_source, 'phone'), nullif(btrim(p_full_name), ''), p_phone, v_guest,
    p_room_type_id, p_check_in, p_check_out, p_adults, p_children, nullif(btrim(p_interest), ''), nullif(btrim(p_comment), ''),
    p_assignee_id, p_next_contact_at, auth.uid())
  returning id into v_id;

  perform app.log_audit(p_tenant, 'lead.create', 'lead', v_id, 'success',
    jsonb_build_object('source', coalesce(p_source, 'phone'), 'assignee_id', p_assignee_id));
  return v_id;
end $$;

create or replace function public.update_lead(
  p_lead_id uuid, p_source public.booking_source, p_full_name text, p_phone text,
  p_room_type_id uuid, p_check_in date, p_check_out date, p_adults integer, p_children integer,
  p_interest text, p_comment text, p_assignee_id uuid, p_next_contact_at timestamptz
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_l public.leads;
  v_n public.leads;
  v_changed text[] := '{}';
begin
  select * into v_l from public.leads where id = p_lead_id for update;
  if not found or not app.can_write_bookings(v_l.tenant_id, 'leads.write') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_l.status in ('won', 'lost') then
    raise exception 'lead is closed' using errcode = '22023';
  end if;
  perform app.check_lead_fields(v_l.tenant_id, p_full_name, p_phone, p_room_type_id, p_check_in, p_check_out,
    p_adults, p_children, p_interest, p_comment, p_assignee_id);

  update public.leads set
    source = coalesce(p_source, source),
    full_name = nullif(btrim(p_full_name), ''),
    phone = p_phone,
    guest_id = case when p_phone is distinct from v_l.phone
                    then (select id from public.guests where tenant_id = v_l.tenant_id and phone = p_phone and archived_at is null)
                    else guest_id end,
    room_type_id = p_room_type_id, check_in = p_check_in, check_out = p_check_out,
    adults = p_adults, children = p_children,
    interest = nullif(btrim(p_interest), ''), comment = nullif(btrim(p_comment), ''),
    assignee_id = p_assignee_id, next_contact_at = p_next_contact_at
  where id = p_lead_id
  returning * into v_n;

  if v_n.source is distinct from v_l.source then v_changed := v_changed || 'source'::text; end if;
  if v_n.full_name is distinct from v_l.full_name then v_changed := v_changed || 'full_name'::text; end if;
  if v_n.phone is distinct from v_l.phone then v_changed := v_changed || 'phone'::text; end if;
  if v_n.room_type_id is distinct from v_l.room_type_id then v_changed := v_changed || 'room_type'::text; end if;
  if v_n.check_in is distinct from v_l.check_in or v_n.check_out is distinct from v_l.check_out then v_changed := v_changed || 'dates'::text; end if;
  if v_n.adults is distinct from v_l.adults or v_n.children is distinct from v_l.children then v_changed := v_changed || 'guests'::text; end if;
  if v_n.interest is distinct from v_l.interest then v_changed := v_changed || 'interest'::text; end if;
  if v_n.comment is distinct from v_l.comment then v_changed := v_changed || 'comment'::text; end if;
  if v_n.next_contact_at is distinct from v_l.next_contact_at then v_changed := v_changed || 'next_contact_at'::text; end if;
  if v_n.assignee_id is distinct from v_l.assignee_id then v_changed := v_changed || 'assignee'::text; end if;
  if cardinality(v_changed) > 0 then
    perform app.log_audit(v_l.tenant_id, 'lead.update', 'lead', p_lead_id, 'success',
      jsonb_build_object('changed', to_jsonb(v_changed), 'number', v_l.number));
  end if;
end $$;

-- Смена статуса вручную: в работу (в том числе вернуть из отказа) или отказ с причиной.
-- «Бронь» ставится только созданием или подтверждением брони.
create or replace function public.set_lead_status(
  p_lead_id uuid, p_status public.lead_status, p_lost_reason public.lead_lost_reason default null, p_note text default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_l public.leads;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  select * into v_l from public.leads where id = p_lead_id for update;
  if not found or not app.can_write_bookings(v_l.tenant_id, 'leads.write') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if char_length(coalesce(v_note, '')) > 500 then
    raise exception 'text is too long' using errcode = '22023';
  end if;
  if p_status = 'in_progress' and v_l.status in ('new', 'lost') then
    update public.leads set status = 'in_progress', lost_reason = null, lost_note = null, closed_at = null,
      assignee_id = coalesce(assignee_id, case when app.member_has_permission(v_l.tenant_id, auth.uid(), 'leads.write') then auth.uid() end)
    where id = p_lead_id;
  elsif p_status = 'lost' and v_l.status in ('new', 'in_progress') then
    if p_lost_reason is null or p_lost_reason = 'booking_cancelled' then
      raise exception 'lost reason is required' using errcode = '22023';
    end if;
    update public.leads set status = 'lost', lost_reason = p_lost_reason, lost_note = v_note, closed_at = now()
    where id = p_lead_id;
  else
    raise exception 'status change is not allowed' using errcode = '22023';
  end if;
  perform app.log_audit(v_l.tenant_id, 'lead.status', 'lead', p_lead_id, 'success',
    jsonb_build_object('from', v_l.status, 'to', p_status, 'number', v_l.number)
    || case when p_status = 'lost' then jsonb_build_object('reason', p_lost_reason) else '{}'::jsonb end);
end $$;

create or replace function public.add_lead_note(p_lead_id uuid, p_body text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_l public.leads;
  v_id uuid;
begin
  select * into v_l from public.leads where id = p_lead_id;
  if not found or not app.can_write_bookings(v_l.tenant_id, 'leads.write') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if char_length(btrim(coalesce(p_body, ''))) not between 1 and 2000 then
    raise exception 'note is required' using errcode = '22023';
  end if;
  insert into public.lead_notes (tenant_id, lead_id, body, created_by)
  values (v_l.tenant_id, p_lead_id, btrim(p_body), auth.uid())
  returning id into v_id;
  -- заметка — это контакт с гостем: заявка уходит из «новых»
  if v_l.status = 'new' then
    update public.leads set status = 'in_progress',
      assignee_id = coalesce(assignee_id, case when app.member_has_permission(v_l.tenant_id, auth.uid(), 'leads.write') then auth.uid() end)
    where id = p_lead_id;
  end if;
  return v_id;
end $$;

-- Бронь из заявки: обычный create_booking (права bookings.write, цена на сервере) + связь с заявкой.
-- С номером бронь подтверждена и заявка закрывается как «бронь»; без номера — бронь-заявка, заявка остаётся в работе.
create or replace function public.create_booking_from_lead(
  p_lead_id uuid, p_guest_id uuid, p_room_type_id uuid, p_room_id uuid,
  p_check_in date, p_check_out date, p_adults integer default 1, p_children integer default 0, p_comment text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_l public.leads;
  v_id uuid;
  v_number integer;
begin
  select * into v_l from public.leads where id = p_lead_id for update;
  if not found or not app.can_write_bookings(v_l.tenant_id, 'leads.write') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_l.status in ('won', 'lost') then
    raise exception 'lead is closed' using errcode = '22023';
  end if;
  if v_l.booking_id is not null then
    raise exception 'lead already has a booking' using errcode = '22023';
  end if;

  v_id := public.create_booking(v_l.tenant_id, p_guest_id, p_room_type_id, p_room_id, p_check_in, p_check_out,
    p_adults, p_children, v_l.source, p_comment,
    case when p_room_id is null then 'new_request'::public.booking_status else 'confirmed'::public.booking_status end);
  select number into v_number from public.bookings where id = v_id;

  update public.leads set booking_id = v_id, guest_id = p_guest_id,
    status = case when p_room_id is null then 'in_progress'::public.lead_status else 'won'::public.lead_status end,
    closed_at = case when p_room_id is null then null else now() end
  where id = p_lead_id;
  perform app.log_audit(v_l.tenant_id, 'lead.convert', 'lead', p_lead_id, 'success',
    jsonb_build_object('number', v_l.number, 'booking', v_number));
  return v_id;
end $$;

-- Счётчики для меню и обзора
create or replace function public.lead_counts(p_tenant uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.has_permission(p_tenant, 'leads.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  return (
    select jsonb_build_object(
      'new', count(*) filter (where status = 'new'),
      'open', count(*) filter (where status in ('new', 'in_progress')),
      'overdue', count(*) filter (where status in ('new', 'in_progress') and next_contact_at < now()),
      'mine', count(*) filter (where status in ('new', 'in_progress') and assignee_id = auth.uid()))
    from public.leads where tenant_id = p_tenant);
end $$;

-- Ответственные за заявки: сотрудники с leads.write (добавлено к прежним вариантам)
create or replace function public.staff_directory(p_tenant uuid, p_permission text)
returns table (user_id uuid, full_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_permission not in ('procedures.status', 'tasks.read', 'leads.write') or not app.is_member(p_tenant) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  return query
    select m.user_id, coalesce(nullif(trim(u.full_name), ''), '—')
    from public.organization_members m
    left join public.user_profiles u on u.id = m.user_id
    where m.tenant_id = p_tenant and m.status = 'active'
      and app.member_has_permission(p_tenant, m.user_id, p_permission)
    order by 2;
end $$;

-- ---------------------------------------------------------------------------
-- Автоматические заявки
-- ---------------------------------------------------------------------------

-- Заявка с сайта: бронь без номера, созданная анонимом через submit_booking_request
create or replace function app.lead_from_website_booking() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_g public.guests;
begin
  select * into v_g from public.guests where id = new.guest_id;
  insert into public.leads (tenant_id, number, source, full_name, phone, guest_id, booking_id, room_type_id,
    check_in, check_out, adults, children, comment)
  values (new.tenant_id, app.next_lead_number(new.tenant_id), 'website',
    -- имя из формы (submit_booking_request кладёт его в служебную заметку брони), иначе из карточки гостя
    coalesce(nullif(left(btrim(substring(new.internal_notes from '^Имя в заявке: (.*)$')), 200), ''), left(v_g.full_name, 200)),
    v_g.phone, new.guest_id, new.id, new.room_type_id, new.check_in, new.check_out, new.adults, new.children, new.guest_comment);
  return null;
end $$;

create trigger bookings_website_lead after insert on public.bookings
  for each row when (new.source = 'website' and new.status = 'new_request' and auth.uid() is null)
  execute function app.lead_from_website_booking();

-- Судьба брони закрывает заявку: подтверждение — «бронь», отмена — «отказ»
create or replace function app.sync_lead_with_booking() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_l public.leads;
  v_to public.lead_status;
begin
  v_to := case when new.status in ('confirmed', 'checked_in', 'checked_out') then 'won'::public.lead_status
               when new.status in ('cancelled', 'no_show') then 'lost'::public.lead_status end;
  if v_to is null then
    return null;
  end if;
  for v_l in select * from public.leads where booking_id = new.id and status in ('new', 'in_progress') for update loop
    update public.leads set status = v_to, closed_at = now(),
      lost_reason = case when v_to = 'lost' then 'booking_cancelled'::public.lead_lost_reason end
    where id = v_l.id;
    perform app.log_audit(v_l.tenant_id, 'lead.status', 'lead', v_l.id, 'success',
      jsonb_build_object('from', v_l.status, 'to', v_to, 'number', v_l.number));
  end loop;
  return null;
end $$;

create trigger bookings_sync_lead after update of status on public.bookings
  for each row when (old.status is distinct from new.status)
  execute function app.sync_lead_with_booking();

-- Входящее WhatsApp с незнакомого номера: нет гостя и нет открытой заявки → новая заявка
create or replace function app.lead_from_whatsapp() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.guest_id is not null
     or exists (select 1 from public.guests where tenant_id = new.tenant_id and phone = new.phone and archived_at is null)
     or exists (select 1 from public.leads where tenant_id = new.tenant_id and phone = new.phone and status in ('new', 'in_progress')) then
    return null;
  end if;
  insert into public.leads (tenant_id, number, source, full_name, phone, comment)
  values (new.tenant_id, app.next_lead_number(new.tenant_id), 'whatsapp',
    nullif(left(btrim(coalesce(new.contact_name, '')), 200), ''), new.phone, nullif(left(btrim(coalesce(new.body, '')), 2000), ''));
  return null;
end $$;

create trigger messages_whatsapp_lead after insert on public.messages
  for each row when (new.direction = 'in')
  execute function app.lead_from_whatsapp();

-- Открытые заявки с сайта, пришедшие до этого обновления
do $$
declare
  b record;
begin
  for b in select bk.* from public.bookings bk
           where bk.source = 'website' and bk.status = 'new_request'
             and not exists (select 1 from public.leads l where l.booking_id = bk.id)
           order by bk.created_at loop
    insert into public.leads (tenant_id, number, source, full_name, phone, guest_id, booking_id, room_type_id,
      check_in, check_out, adults, children, comment, created_at)
    select b.tenant_id, app.next_lead_number(b.tenant_id), 'website',
      coalesce(nullif(left(btrim(substring(b.internal_notes from '^Имя в заявке: (.*)$')), 200), ''), left(g.full_name, 200)),
      g.phone, b.guest_id, b.id, b.room_type_id, b.check_in, b.check_out, b.adults, b.children, b.guest_comment, b.created_at
    from public.guests g where g.id = b.guest_id;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Доступ к функциям
-- ---------------------------------------------------------------------------

revoke all on function
  app.next_lead_number(uuid),
  app.check_lead_fields(uuid, text, text, uuid, date, date, integer, integer, text, text, uuid),
  app.lead_from_website_booking(),
  app.sync_lead_with_booking(),
  app.lead_from_whatsapp()
  from public, anon, authenticated;

revoke execute on function
  public.create_lead(uuid, public.booking_source, text, text, uuid, date, date, integer, integer, text, text, uuid, timestamptz),
  public.update_lead(uuid, public.booking_source, text, text, uuid, date, date, integer, integer, text, text, uuid, timestamptz),
  public.set_lead_status(uuid, public.lead_status, public.lead_lost_reason, text),
  public.add_lead_note(uuid, text),
  public.create_booking_from_lead(uuid, uuid, uuid, uuid, date, date, integer, integer, text),
  public.lead_counts(uuid),
  public.staff_directory(uuid, text)
  from public, anon;
grant execute on function
  public.create_lead(uuid, public.booking_source, text, text, uuid, date, date, integer, integer, text, text, uuid, timestamptz),
  public.update_lead(uuid, public.booking_source, text, text, uuid, date, date, integer, integer, text, text, uuid, timestamptz),
  public.set_lead_status(uuid, public.lead_status, public.lead_lost_reason, text),
  public.add_lead_note(uuid, text),
  public.create_booking_from_lead(uuid, uuid, uuid, uuid, date, date, integer, integer, text),
  public.lead_counts(uuid),
  public.staff_directory(uuid, text)
  to authenticated;

-- ===== supabase/migrations/20261101000014_medical.sql =====
-- Sanatorium OS · 0014 · Медицинская карта гостя
-- Принципы:
--  * медицинские сведения — особая категория персональных данных: таблицы закрыты для прямого чтения,
--    карту отдаёт только функция get_medical_card, и каждый просмотр пишется в журнал (кто и чью карту открыл);
--  * доступ только по медицинским правам: medical.read (врач, медсестра), medical.write (врач).
--    Владелец и директор медицинских прав по умолчанию не имеют, в свои роли их выдать нельзя (0003);
--  * карту заводят после согласия гостя на обработку медицинских данных (отметка и время согласия);
--  * осмотр может исправить только его автор и только в течение 24 часов; дальше запись неизменна;
--  * назначение — процедура на курс (сколько сеансов); выполнено столько, сколько отмеченных процедур
--    этого вида у гостя после назначения; записывать на процедуры по-прежнему через schedule_procedure;
--  * медкарта входит в модуль «procedures» (тариф Business и выше); при истёкшей подписке карта читается,
--    но не меняется;
--  * в журнал пишутся действие, гость и названия изменённых полей — без диагнозов, жалоб и других значений.

create type public.medical_visit_kind as enum ('initial', 'follow_up', 'final');
create type public.prescription_status as enum ('active', 'completed', 'cancelled');

create table public.medical_records (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.organizations(id) on delete cascade,
  guest_id           uuid not null,
  allergies          text check (char_length(allergies) <= 2000),
  contraindications  text check (char_length(contraindications) <= 2000),
  chronic_conditions text check (char_length(chronic_conditions) <= 2000),
  medications        text check (char_length(medications) <= 2000),
  notes              text check (char_length(notes) <= 4000),
  consent_at         timestamptz not null,
  created_by         uuid references auth.users(id) on delete set null,
  updated_by         uuid references auth.users(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (tenant_id, guest_id),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id)
);

create table public.medical_visits (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.organizations(id) on delete cascade,
  guest_id        uuid not null,
  booking_id      uuid,
  kind            public.medical_visit_kind not null default 'follow_up',
  visit_at        timestamptz not null default now(),
  complaints      text check (char_length(complaints) <= 4000),
  examination     text check (char_length(examination) <= 4000),
  diagnosis       text check (char_length(diagnosis) <= 2000),
  recommendations text check (char_length(recommendations) <= 4000),
  blood_pressure  text check (blood_pressure ~ '^[0-9]{2,3}/[0-9]{2,3}$'),
  pulse           smallint check (pulse between 20 and 250),
  temperature     numeric(4,1) check (temperature between 30 and 45),
  weight          numeric(5,1) check (weight between 1 and 400),
  doctor_id       uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id),
  constraint medical_visit_content check (coalesce(complaints, examination, diagnosis, recommendations, blood_pressure) is not null
    or pulse is not null or temperature is not null or weight is not null)
);
create index medical_visits_guest_idx on public.medical_visits (tenant_id, guest_id, visit_at desc);

create table public.medical_prescriptions (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.organizations(id) on delete cascade,
  guest_id          uuid not null,
  booking_id        uuid,
  procedure_type_id uuid not null,
  sessions          smallint not null check (sessions between 1 and 60),
  frequency         text check (char_length(frequency) <= 100),
  note              text check (char_length(note) <= 1000),
  status            public.prescription_status not null default 'active',
  prescribed_by     uuid references auth.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id),
  foreign key (tenant_id, procedure_type_id) references public.procedure_types (tenant_id, id)
);
create index medical_prescriptions_guest_idx on public.medical_prescriptions (tenant_id, guest_id, created_at desc);

create trigger medical_records_tenant before update on public.medical_records
  for each row execute function app.forbid_tenant_change();
create trigger medical_records_touch before update on public.medical_records
  for each row execute function app.touch_updated_at();
create trigger medical_visits_tenant before update on public.medical_visits
  for each row execute function app.forbid_tenant_change();
create trigger medical_visits_touch before update on public.medical_visits
  for each row execute function app.touch_updated_at();
create trigger medical_prescriptions_tenant before update on public.medical_prescriptions
  for each row execute function app.forbid_tenant_change();
create trigger medical_prescriptions_touch before update on public.medical_prescriptions
  for each row execute function app.touch_updated_at();

-- Прямого доступа нет ни у кого из клиентов: только функции ниже (каждое чтение журналируется)
alter table public.medical_records enable row level security;
alter table public.medical_visits enable row level security;
alter table public.medical_prescriptions enable row level security;
revoke all on public.medical_records, public.medical_visits, public.medical_prescriptions from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Вспомогательные функции
-- ---------------------------------------------------------------------------

create or replace function app.can_write_medical(p_tenant uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.has_permission(p_tenant, 'medical.write') and app.feature_enabled(p_tenant, 'procedures')
$$;

-- Пустая строка → null, лишние пробелы по краям убираются
create or replace function app.clean_text(p_value text) returns text
language sql immutable set search_path = '' as $$
  select nullif(btrim(coalesce(p_value, '')), '')
$$;

-- Сколько процедур назначения уже выполнено: проведённые процедуры этого вида у гостя
-- начиная с дня назначения (по времени санатория), в рамках той же брони, если она указана
create or replace function app.prescription_done(p_rx public.medical_prescriptions) returns integer
language sql stable security definer set search_path = '' as $$
  select count(*)::integer from public.procedure_appointments a
  cross join lateral (select coalesce((select timezone from public.organizations where id = p_rx.tenant_id), 'Asia/Almaty') as tz) z
  where a.tenant_id = p_rx.tenant_id and a.guest_id = p_rx.guest_id and a.procedure_type_id = p_rx.procedure_type_id
    and a.status = 'done' and (a.starts_at at time zone z.tz)::date >= (p_rx.created_at at time zone z.tz)::date
    and (p_rx.booking_id is null or a.booking_id = p_rx.booking_id)
$$;

-- ---------------------------------------------------------------------------
-- Чтение
-- ---------------------------------------------------------------------------

-- Медкарта гостя целиком и текущее проживание (для привязки осмотров и назначений).
-- Каждый вызов — запись medical.view в журнале.
create or replace function public.get_medical_card(p_guest_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_g public.guests;
  v_r public.medical_records;
  v_out jsonb;
begin
  select * into v_g from public.guests where id = p_guest_id;
  if not found or not app.has_permission(v_g.tenant_id, 'medical.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  select * into v_r from public.medical_records where tenant_id = v_g.tenant_id and guest_id = p_guest_id;

  v_out := jsonb_build_object(
    'guest', jsonb_build_object('id', v_g.id, 'full_name', v_g.full_name, 'birth_date', v_g.birth_date, 'city', v_g.city),
    'record', case when v_r.id is null then null else jsonb_build_object(
      'allergies', v_r.allergies, 'contraindications', v_r.contraindications, 'chronic_conditions', v_r.chronic_conditions,
      'medications', v_r.medications, 'notes', v_r.notes, 'consent_at', v_r.consent_at, 'updated_at', v_r.updated_at,
      'updated_by_name', (select full_name from public.user_profiles where id = v_r.updated_by)) end,
    'visits', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', v.id, 'booking_id', v.booking_id, 'kind', v.kind, 'visit_at', v.visit_at,
        'complaints', v.complaints, 'examination', v.examination, 'diagnosis', v.diagnosis, 'recommendations', v.recommendations,
        'blood_pressure', v.blood_pressure, 'pulse', v.pulse, 'temperature', v.temperature, 'weight', v.weight,
        'doctor_name', u.full_name, 'created_at', v.created_at,
        'editable', v.doctor_id = auth.uid() and v.created_at > now() - interval '24 hours')
        order by v.visit_at desc)
      from public.medical_visits v left join public.user_profiles u on u.id = v.doctor_id
      where v.tenant_id = v_g.tenant_id and v.guest_id = p_guest_id), '[]'::jsonb),
    'prescriptions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'booking_id', p.booking_id, 'procedure_type_id', p.procedure_type_id, 'procedure', t.name,
        'sessions', p.sessions, 'done', app.prescription_done(p), 'frequency', p.frequency, 'note', p.note,
        'status', p.status, 'prescribed_by_name', u.full_name, 'created_at', p.created_at)
        order by (p.status = 'active') desc, p.created_at desc)
      from public.medical_prescriptions p
      join public.procedure_types t on t.id = p.procedure_type_id
      left join public.user_profiles u on u.id = p.prescribed_by
      where p.tenant_id = v_g.tenant_id and p.guest_id = p_guest_id), '[]'::jsonb),
    'stay', (
      select jsonb_build_object('id', b.id, 'number', b.number, 'check_in', b.check_in, 'check_out', b.check_out, 'status', b.status)
      from public.bookings b
      where b.tenant_id = v_g.tenant_id and b.guest_id = p_guest_id and b.status in ('checked_in', 'confirmed')
        and b.check_out >= app.tenant_today(v_g.tenant_id)
      order by b.status = 'checked_in' desc, b.check_in limit 1),
    'can_write', app.can_write_medical(v_g.tenant_id));

  perform app.log_audit(v_g.tenant_id, 'medical.view', 'guest', p_guest_id);
  return v_out;
end $$;

-- Гости в санатории и сегодняшние заезды для врача: только отметки, без медицинского содержимого
create or replace function public.medical_overview(p_tenant uuid)
returns table (guest_id uuid, full_name text, booking_id uuid, booking_number integer, room_number text,
               check_in date, check_out date, status public.booking_status, has_card boolean, has_initial boolean,
               active_prescriptions integer)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_today date := app.tenant_today(p_tenant);
begin
  if not app.has_permission(p_tenant, 'medical.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  return query
    select g.id, g.full_name, b.id, b.number, r.number, b.check_in, b.check_out, b.status,
      exists (select 1 from public.medical_records m where m.tenant_id = p_tenant and m.guest_id = g.id),
      exists (select 1 from public.medical_visits v where v.tenant_id = p_tenant and v.guest_id = g.id
              and v.kind = 'initial' and v.visit_at >= b.check_in::timestamp - interval '1 day'),
      (select count(*)::integer from public.medical_prescriptions p where p.tenant_id = p_tenant and p.guest_id = g.id
       and p.status = 'active')
    from public.bookings b
    join public.guests g on g.id = b.guest_id
    left join public.rooms r on r.id = b.room_id
    where b.tenant_id = p_tenant
      and (b.status = 'checked_in' or (b.status = 'confirmed' and b.check_in between v_today and v_today + 1))
    order by b.status = 'checked_in' desc, b.check_in, g.full_name;
end $$;

-- ---------------------------------------------------------------------------
-- Изменения
-- ---------------------------------------------------------------------------

create or replace function public.save_medical_record(
  p_guest_id uuid, p_allergies text, p_contraindications text, p_chronic_conditions text,
  p_medications text, p_notes text, p_consent boolean default false
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_g public.guests;
  v_r public.medical_records;
  v_changed text[] := '{}';
begin
  select * into v_g from public.guests where id = p_guest_id;
  if not found or not app.can_write_medical(v_g.tenant_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if greatest(char_length(coalesce(p_allergies, '')), char_length(coalesce(p_contraindications, '')),
              char_length(coalesce(p_chronic_conditions, '')), char_length(coalesce(p_medications, ''))) > 2000
     or char_length(coalesce(p_notes, '')) > 4000 then
    raise exception 'text is too long' using errcode = '22023';
  end if;

  select * into v_r from public.medical_records where tenant_id = v_g.tenant_id and guest_id = p_guest_id for update;
  if not found then
    if not coalesce(p_consent, false) then
      raise exception 'medical consent is required' using errcode = '22023';
    end if;
    insert into public.medical_records (tenant_id, guest_id, allergies, contraindications, chronic_conditions, medications, notes,
      consent_at, created_by, updated_by)
    values (v_g.tenant_id, p_guest_id, app.clean_text(p_allergies), app.clean_text(p_contraindications),
      app.clean_text(p_chronic_conditions), app.clean_text(p_medications), app.clean_text(p_notes), now(), auth.uid(), auth.uid());
    perform app.log_audit(v_g.tenant_id, 'medical.card_create', 'guest', p_guest_id);
    return;
  end if;

  if v_r.allergies is distinct from app.clean_text(p_allergies) then v_changed := v_changed || 'allergies'::text; end if;
  if v_r.contraindications is distinct from app.clean_text(p_contraindications) then v_changed := v_changed || 'contraindications'::text; end if;
  if v_r.chronic_conditions is distinct from app.clean_text(p_chronic_conditions) then v_changed := v_changed || 'chronic_conditions'::text; end if;
  if v_r.medications is distinct from app.clean_text(p_medications) then v_changed := v_changed || 'medications'::text; end if;
  if v_r.notes is distinct from app.clean_text(p_notes) then v_changed := v_changed || 'notes'::text; end if;
  if cardinality(v_changed) = 0 then
    return;
  end if;
  update public.medical_records set allergies = app.clean_text(p_allergies), contraindications = app.clean_text(p_contraindications),
    chronic_conditions = app.clean_text(p_chronic_conditions), medications = app.clean_text(p_medications),
    notes = app.clean_text(p_notes), updated_by = auth.uid()
  where id = v_r.id;
  perform app.log_audit(v_g.tenant_id, 'medical.card_update', 'guest', p_guest_id, 'success', jsonb_build_object('changed', to_jsonb(v_changed)));
end $$;

-- Проверка полей осмотра
create or replace function app.check_medical_visit(
  p_tenant uuid, p_guest uuid, p_booking uuid, p_visit_at timestamptz, p_complaints text, p_examination text,
  p_diagnosis text, p_recommendations text, p_bp text, p_pulse integer, p_temperature numeric, p_weight numeric
) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if coalesce(app.clean_text(p_complaints), app.clean_text(p_examination), app.clean_text(p_diagnosis),
              app.clean_text(p_recommendations), app.clean_text(p_bp)) is null
     and p_pulse is null and p_temperature is null and p_weight is null then
    raise exception 'visit is empty' using errcode = '22023';
  end if;
  if greatest(char_length(coalesce(p_complaints, '')), char_length(coalesce(p_examination, '')),
              char_length(coalesce(p_recommendations, ''))) > 4000 or char_length(coalesce(p_diagnosis, '')) > 2000 then
    raise exception 'text is too long' using errcode = '22023';
  end if;
  if (app.clean_text(p_bp) is not null and app.clean_text(p_bp) !~ '^[0-9]{2,3}/[0-9]{2,3}$')
     or (p_pulse is not null and p_pulse not between 20 and 250)
     or (p_temperature is not null and p_temperature not between 30 and 45)
     or (p_weight is not null and p_weight not between 1 and 400) then
    raise exception 'invalid vitals' using errcode = '22023';
  end if;
  if p_visit_at is null or p_visit_at > now() + interval '1 hour' or p_visit_at < now() - interval '30 days' then
    raise exception 'invalid visit time' using errcode = '22023';
  end if;
  if p_booking is not null and not exists (select 1 from public.bookings where id = p_booking and tenant_id = p_tenant and guest_id = p_guest) then
    raise exception 'booking not found' using errcode = 'P0002';
  end if;
end $$;

create or replace function public.add_medical_visit(
  p_guest_id uuid, p_booking_id uuid, p_kind public.medical_visit_kind, p_visit_at timestamptz,
  p_complaints text, p_examination text, p_diagnosis text, p_recommendations text,
  p_blood_pressure text default null, p_pulse integer default null, p_temperature numeric default null, p_weight numeric default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_g public.guests;
  v_id uuid;
begin
  select * into v_g from public.guests where id = p_guest_id;
  if not found or not app.can_write_medical(v_g.tenant_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not exists (select 1 from public.medical_records where tenant_id = v_g.tenant_id and guest_id = p_guest_id) then
    raise exception 'medical card is required' using errcode = '22023';
  end if;
  perform app.check_medical_visit(v_g.tenant_id, p_guest_id, p_booking_id, coalesce(p_visit_at, now()), p_complaints, p_examination,
    p_diagnosis, p_recommendations, p_blood_pressure, p_pulse, p_temperature, p_weight);
  insert into public.medical_visits (tenant_id, guest_id, booking_id, kind, visit_at, complaints, examination, diagnosis,
    recommendations, blood_pressure, pulse, temperature, weight, doctor_id)
  values (v_g.tenant_id, p_guest_id, p_booking_id, coalesce(p_kind, 'follow_up'), coalesce(p_visit_at, now()),
    app.clean_text(p_complaints), app.clean_text(p_examination), app.clean_text(p_diagnosis), app.clean_text(p_recommendations),
    app.clean_text(p_blood_pressure), p_pulse, p_temperature, p_weight, auth.uid())
  returning id into v_id;
  perform app.log_audit(v_g.tenant_id, 'medical.visit_create', 'guest', p_guest_id, 'success',
    jsonb_build_object('visit_kind', coalesce(p_kind, 'follow_up')));
  return v_id;
end $$;

-- Исправить осмотр может только автор и только в первые 24 часа
create or replace function public.update_medical_visit(
  p_visit_id uuid, p_kind public.medical_visit_kind, p_visit_at timestamptz,
  p_complaints text, p_examination text, p_diagnosis text, p_recommendations text,
  p_blood_pressure text, p_pulse integer, p_temperature numeric, p_weight numeric
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_v public.medical_visits;
begin
  select * into v_v from public.medical_visits where id = p_visit_id for update;
  if not found or not app.can_write_medical(v_v.tenant_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_v.doctor_id is distinct from auth.uid() or v_v.created_at < now() - interval '24 hours' then
    raise exception 'visit is locked' using errcode = '42501';
  end if;
  perform app.check_medical_visit(v_v.tenant_id, v_v.guest_id, v_v.booking_id, p_visit_at, p_complaints, p_examination,
    p_diagnosis, p_recommendations, p_blood_pressure, p_pulse, p_temperature, p_weight);
  update public.medical_visits set kind = coalesce(p_kind, kind), visit_at = p_visit_at,
    complaints = app.clean_text(p_complaints), examination = app.clean_text(p_examination), diagnosis = app.clean_text(p_diagnosis),
    recommendations = app.clean_text(p_recommendations), blood_pressure = app.clean_text(p_blood_pressure),
    pulse = p_pulse, temperature = p_temperature, weight = p_weight
  where id = p_visit_id;
  perform app.log_audit(v_v.tenant_id, 'medical.visit_update', 'guest', v_v.guest_id);
end $$;

create or replace function public.add_prescription(
  p_guest_id uuid, p_booking_id uuid, p_procedure_type_id uuid, p_sessions integer,
  p_frequency text default null, p_note text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_g public.guests;
  v_id uuid;
  v_name text;
begin
  select * into v_g from public.guests where id = p_guest_id;
  if not found or not app.can_write_medical(v_g.tenant_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not exists (select 1 from public.medical_records where tenant_id = v_g.tenant_id and guest_id = p_guest_id) then
    raise exception 'medical card is required' using errcode = '22023';
  end if;
  select name into v_name from public.procedure_types where id = p_procedure_type_id and tenant_id = v_g.tenant_id and is_active;
  if v_name is null then
    raise exception 'procedure type not found' using errcode = 'P0002';
  end if;
  if p_sessions is null or p_sessions not between 1 and 60 then
    raise exception 'invalid sessions' using errcode = '22023';
  end if;
  if char_length(coalesce(p_frequency, '')) > 100 or char_length(coalesce(p_note, '')) > 1000 then
    raise exception 'text is too long' using errcode = '22023';
  end if;
  if p_booking_id is not null and not exists (select 1 from public.bookings where id = p_booking_id and tenant_id = v_g.tenant_id and guest_id = p_guest_id) then
    raise exception 'booking not found' using errcode = 'P0002';
  end if;
  insert into public.medical_prescriptions (tenant_id, guest_id, booking_id, procedure_type_id, sessions, frequency, note, prescribed_by)
  values (v_g.tenant_id, p_guest_id, p_booking_id, p_procedure_type_id, p_sessions, app.clean_text(p_frequency), app.clean_text(p_note), auth.uid())
  returning id into v_id;
  perform app.log_audit(v_g.tenant_id, 'medical.prescription_create', 'guest', p_guest_id, 'success',
    jsonb_build_object('procedure', v_name, 'sessions', p_sessions));
  return v_id;
end $$;

create or replace function public.set_prescription_status(p_prescription_id uuid, p_status public.prescription_status) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_p public.medical_prescriptions;
begin
  select * into v_p from public.medical_prescriptions where id = p_prescription_id for update;
  if not found or not app.can_write_medical(v_p.tenant_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_p.status = p_status then
    return;
  end if;
  if v_p.status <> 'active' and p_status <> 'active' then
    raise exception 'status change is not allowed' using errcode = '22023';
  end if;
  update public.medical_prescriptions set status = p_status where id = p_prescription_id;
  perform app.log_audit(v_p.tenant_id, 'medical.prescription_status', 'guest', v_p.guest_id, 'success',
    jsonb_build_object('from', v_p.status, 'to', p_status));
end $$;

-- ---------------------------------------------------------------------------
-- Доступ к функциям
-- ---------------------------------------------------------------------------

revoke all on function
  app.can_write_medical(uuid),
  app.clean_text(text),
  app.prescription_done(public.medical_prescriptions),
  app.check_medical_visit(uuid, uuid, uuid, timestamptz, text, text, text, text, text, integer, numeric, numeric)
  from public, anon, authenticated;

revoke execute on function
  public.get_medical_card(uuid),
  public.medical_overview(uuid),
  public.save_medical_record(uuid, text, text, text, text, text, boolean),
  public.add_medical_visit(uuid, uuid, public.medical_visit_kind, timestamptz, text, text, text, text, text, integer, numeric, numeric),
  public.update_medical_visit(uuid, public.medical_visit_kind, timestamptz, text, text, text, text, text, integer, numeric, numeric),
  public.add_prescription(uuid, uuid, uuid, integer, text, text),
  public.set_prescription_status(uuid, public.prescription_status)
  from public, anon;
grant execute on function
  public.get_medical_card(uuid),
  public.medical_overview(uuid),
  public.save_medical_record(uuid, text, text, text, text, text, boolean),
  public.add_medical_visit(uuid, uuid, public.medical_visit_kind, timestamptz, text, text, text, text, text, integer, numeric, numeric),
  public.update_medical_visit(uuid, public.medical_visit_kind, timestamptz, text, text, text, text, text, integer, numeric, numeric),
  public.add_prescription(uuid, uuid, uuid, integer, text, text),
  public.set_prescription_status(uuid, public.prescription_status)
  to authenticated;

-- ===== supabase/migrations/20261102000015_documents.sql =====
-- Sanatorium OS · 0015 · Документы по брони: договор, счёт на оплату, акт оказанных услуг
-- Принципы:
--  * суммы в документах берёт сервер из брони, доп. услуг, процедур и оплат — браузер только печатает;
--  * номер документу присваивается один раз на бронь (договор, счёт и акт нумеруются отдельно, подряд
--    внутри санатория); при повторной печати номер и дата не меняются, сумма обновляется по брони;
--  * печать — это выгрузка своих данных, поэтому при истёкшей подписке документы печатаются;
--  * договор печатают те, кто видит брони (bookings.read); счёт и акт — те, кто видит финансы
--    или принимает оплату (finance.read или payments.accept: бухгалтер, ресепшен, менеджер);
--  * реквизиты санатория (банк, ИИК, БИК, руководитель, ставка НДС, условия договора) хранятся
--    в organizations и меняются в настройках (settings.manage);
--  * выдача номера пишется в журнал (вид и номер документа, без данных гостя).

alter table public.organizations
  add column legal_address  text check (char_length(legal_address) <= 300),
  add column bank_name      text check (char_length(bank_name) <= 200),
  add column iik            text check (iik ~ '^KZ[0-9A-Z]{18}$'),
  add column bik            text check (bik ~ '^[A-Z0-9]{8}$'),
  add column director_name  text check (char_length(director_name) <= 200),
  add column vat_rate       numeric(4,2) check (vat_rate > 0 and vat_rate <= 30),
  add column contract_terms text check (char_length(contract_terms) <= 20000);

create type public.document_kind as enum ('contract', 'invoice', 'act');

create table public.document_counters (
  tenant_id uuid not null references public.organizations(id) on delete cascade,
  kind      public.document_kind not null,
  last      integer not null default 0,
  primary key (tenant_id, kind)
);

create table public.booking_documents (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.organizations(id) on delete cascade,
  booking_id uuid not null,
  kind       public.document_kind not null,
  number     integer not null check (number > 0),
  issued_on  date not null,
  amount     numeric(14,2) not null check (amount >= 0),
  issued_by  uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, kind, number),
  unique (tenant_id, booking_id, kind),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id) on delete cascade
);

create trigger booking_documents_tenant before update on public.booking_documents
  for each row execute function app.forbid_tenant_change();
create trigger booking_documents_touch before update on public.booking_documents
  for each row execute function app.touch_updated_at();

alter table public.document_counters enable row level security;
alter table public.booking_documents enable row level security;
revoke all on public.document_counters from anon, authenticated;
revoke all on public.booking_documents from anon, authenticated;
grant select on public.booking_documents to authenticated;

create or replace function app.can_print_document(p_tenant uuid, p_kind public.document_kind) returns boolean
language sql stable security definer set search_path = '' as $$
  select case when p_kind = 'contract' then app.has_permission(p_tenant, 'bookings.read')
              else app.has_permission(p_tenant, 'finance.read') or app.has_permission(p_tenant, 'payments.accept') end
$$;
revoke all on function app.can_print_document(uuid, public.document_kind) from public, anon;
grant execute on function app.can_print_document(uuid, public.document_kind) to authenticated;

create policy booking_documents_select on public.booking_documents for select to authenticated
  using (app.can_print_document(tenant_id, kind));

-- ---------------------------------------------------------------------------
-- Данные документа для печати
-- ---------------------------------------------------------------------------

create or replace function public.booking_document(p_booking_id uuid, p_kind public.document_kind) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_b public.bookings;
  v_o public.organizations;
  v_d public.booking_documents;
  v_today date;
  v_number integer;
  v_lines jsonb;
  v_total numeric(14,2);
  v_paid numeric(14,2);
begin
  select * into v_b from public.bookings where id = p_booking_id;
  if not found or not app.can_print_document(v_b.tenant_id, p_kind) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_b.status in ('new_request', 'cancelled', 'no_show') then
    raise exception 'booking is not confirmed' using errcode = '22023';
  end if;
  if p_kind = 'act' and v_b.status <> 'checked_out' then
    raise exception 'act requires check-out' using errcode = '22023';
  end if;
  select * into v_o from public.organizations where id = v_b.tenant_id;
  v_today := app.tenant_today(v_b.tenant_id);

  -- Строки: проживание (со скидкой), доп. услуги, платные процедуры по видам.
  -- В счёт и договор входят и запланированные процедуры, в акт — только проведённые.
  select coalesce(jsonb_agg(to_jsonb(l) - 'ord' order by l.ord, l.name), '[]'::jsonb), coalesce(sum((l.amount)), 0)
  into v_lines, v_total
  from (
    select 1 as ord, rt.name || coalesce(' · №' || r.number, '') as name, 'night' as unit, v_b.nights::numeric as quantity,
      round((v_b.total_amount - v_b.discount_amount) / greatest(v_b.nights, 1), 2) as price,
      (v_b.total_amount - v_b.discount_amount) as amount
    from public.room_types rt left join public.rooms r on r.id = v_b.room_id
    where rt.id = v_b.room_type_id
    union all
    select 2, e.name, 'pcs', e.quantity, e.unit_price, e.amount
    from public.booking_extras e where e.booking_id = v_b.id
    union all
    select 3, t.name, 'session', count(*)::numeric, min(a.price), sum(a.price)
    from public.procedure_appointments a join public.procedure_types t on t.id = a.procedure_type_id
    where a.booking_id = v_b.id and a.price > 0
      and a.status = any (case when p_kind = 'act' then array['done']::public.procedure_status[]
                               else array['scheduled', 'done']::public.procedure_status[] end)
    group by t.name, a.price
  ) l
  where l.amount > 0;

  select coalesce(sum(amount) filter (where kind = 'payment'), 0) - coalesce(sum(amount) filter (where kind = 'refund'), 0)
  into v_paid from public.booking_payments where booking_id = v_b.id and voided_at is null;

  -- Номер: один раз на бронь и вид документа; сумма обновляется по текущей брони
  select * into v_d from public.booking_documents where tenant_id = v_b.tenant_id and booking_id = v_b.id and kind = p_kind for update;
  if not found then
    insert into public.document_counters (tenant_id, kind, last) values (v_b.tenant_id, p_kind, 1)
    on conflict (tenant_id, kind) do update set last = public.document_counters.last + 1
    returning last into v_number;
    insert into public.booking_documents (tenant_id, booking_id, kind, number, issued_on, amount, issued_by)
    values (v_b.tenant_id, v_b.id, p_kind, v_number, v_today, v_total, auth.uid())
    returning * into v_d;
    perform app.log_audit(v_b.tenant_id, 'document.issue', 'booking', v_b.id, 'success',
      jsonb_build_object('document', p_kind, 'document_number', v_number, 'booking_number', v_b.number));
  elsif v_d.amount <> v_total then
    update public.booking_documents set amount = v_total where id = v_d.id returning * into v_d;
  end if;

  return jsonb_build_object(
    'document', jsonb_build_object('kind', v_d.kind, 'number', v_d.number, 'issued_on', v_d.issued_on),
    'organization', jsonb_build_object(
      'name', v_o.name, 'legal_name', v_o.legal_name, 'bin', v_o.bin, 'legal_address', coalesce(v_o.legal_address, v_o.address),
      'city', v_o.city, 'phone', v_o.phone, 'email', v_o.email, 'bank_name', v_o.bank_name, 'iik', v_o.iik, 'bik', v_o.bik,
      'director_name', v_o.director_name, 'vat_rate', v_o.vat_rate, 'contract_terms', v_o.contract_terms,
      'check_in_time', v_o.booking_settings ->> 'check_in_time', 'check_out_time', v_o.booking_settings ->> 'check_out_time'),
    'guest', (select jsonb_build_object('full_name', g.full_name, 'phone', g.phone, 'email', g.email, 'birth_date', g.birth_date, 'city', g.city)
              from public.guests g where g.id = v_b.guest_id),
    'booking', jsonb_build_object('number', v_b.number, 'check_in', v_b.check_in, 'check_out', v_b.check_out, 'nights', v_b.nights,
      'adults', v_b.adults, 'children', v_b.children, 'status', v_b.status, 'discount', v_b.discount_amount,
      'room_type', (select name from public.room_types where id = v_b.room_type_id),
      'room', (select number from public.rooms where id = v_b.room_id)),
    'lines', v_lines,
    'total', v_total,
    'paid', v_paid,
    'due', greatest(v_total - v_paid, 0));
end $$;

revoke execute on function public.booking_document(uuid, public.document_kind) from public, anon;
grant execute on function public.booking_document(uuid, public.document_kind) to authenticated;

commit;
