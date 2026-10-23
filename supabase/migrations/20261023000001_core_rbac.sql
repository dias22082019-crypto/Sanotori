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
