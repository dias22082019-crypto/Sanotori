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
