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
