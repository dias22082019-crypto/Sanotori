-- Тесты финансов: оплаты, возвраты, аннулирование, доп. услуги, расходы, отчёт (сценарии ТЗ 3, 10, 13, 14)
\set ON_ERROR_STOP on
\set QUIET on

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000004a1', 'owner4a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000004a2', 'reception4a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000004a3', 'accountant4a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000004a4', 'maid4a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000004b1', 'owner4b@example.kz', now());

set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000004a1', 'owner4a@example.kz');
select public.create_organization('Сарыагаш Кайнар', 'kainar', 'Сарыагаш') as org4a \gset
select tests.login('00000000-0000-0000-0000-0000000004b1', 'owner4b@example.kz');
select public.create_organization('Тараз Шипа', 'taraz-shipa', 'Тараз') as org4b \gset
reset role;
select set_config('t4.a', :'org4a', false), set_config('t4.b', :'org4b', false) \gset

insert into public.organization_members (tenant_id, user_id, role_id, status)
select :'org4a', u, r.id, 'active'
from (values ('00000000-0000-0000-0000-0000000004a2'::uuid, 'receptionist'),
             ('00000000-0000-0000-0000-0000000004a3'::uuid, 'accountant'),
             ('00000000-0000-0000-0000-0000000004a4'::uuid, 'housekeeping')) v(u, code)
join public.roles r on r.code = v.code and r.tenant_id is null;

set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000004a1', 'owner4a@example.kz');
insert into public.room_types (tenant_id, name, base_price) values (:'org4a', 'Стандарт', 20000) returning id as rt4 \gset
insert into public.rooms (tenant_id, room_type_id, number) values (:'org4a', :'rt4', '1') returning id as room4 \gset
insert into public.guests (tenant_id, full_name) values (:'org4a', 'Гость Финансов') returning id as guest4 \gset
select public.create_booking(:'org4a', :'guest4', :'rt4', :'room4', current_date + 1, current_date + 4, 1, 0) as booking4 \gset
reset role;
select set_config('t4.booking', :'booking4', false) \gset

-- ============================================================================
-- Ресепшен принимает оплату; возврат и аннулирование ему недоступны
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000004a2', 'reception4a@example.kz');
do $$
declare b uuid := current_setting('t4.booking')::uuid; r record;
begin
  perform public.add_booking_payment(b, 'payment', 'kaspi_transfer', 18000, 'предоплата 30%');
  perform public.add_booking_extra(b, 'Трансфер из Шымкента', 1, 7000);
  select * into r from public.booking_balances where booking_id = b;
  assert r.charges = 67000 and r.paid = 18000 and r.balance = 49000, format('balance wrong: %s', to_jsonb(r));
  begin
    perform public.add_booking_payment(b, 'payment', 'cash', 0);
    raise exception 'FAIL: zero payment accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.add_booking_payment(b, 'payment', 'cash', 10.005);
    raise exception 'FAIL: fractional tiyn accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.add_booking_payment(b, 'refund', 'cash', 1000, 'ошибка');
    raise exception 'FAIL: receptionist made a refund';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.void_booking_payment((select id from public.booking_payments limit 1), 'ошибка');
    raise exception 'FAIL: receptionist voided a payment';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.booking_payments (tenant_id, booking_id, method, amount)
    values (current_setting('t4.a')::uuid, b, 'cash', 1);
    raise exception 'FAIL: direct payment insert allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.expenses (tenant_id, category_id, amount, spent_on, created_by)
    values (current_setting('t4.a')::uuid, gen_random_uuid(), 1, current_date, auth.uid());
    raise exception 'FAIL: receptionist created an expense';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  13a  receptionist: payments and extras; no refunds, voids or expenses';
end $$;

-- ============================================================================
-- Бухгалтер: возврат не больше оплаченного, аннулирование с причиной, расходы, отчёт
-- ============================================================================
select tests.login('00000000-0000-0000-0000-0000000004a3', 'accountant4a@example.kz');
do $$
declare
  a uuid := current_setting('t4.a')::uuid;
  b uuid := current_setting('t4.booking')::uuid;
  p uuid; cat uuid; e uuid; rep jsonb;
begin
  begin
    perform public.add_booking_payment(b, 'refund', 'cash', 18000.01, 'больше оплаты');
    raise exception 'FAIL: refund above paid accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.add_booking_payment(b, 'refund', 'cash', 100);
    raise exception 'FAIL: refund without reason accepted';
  exception when invalid_parameter_value then null;
  end;
  perform public.add_booking_payment(b, 'refund', 'kaspi_transfer', 3000, 'скидка постоянному гостю');
  p := public.add_booking_payment(b, 'payment', 'cash', 50000, 'ошибочно внесено');
  begin
    perform public.void_booking_payment(p, '  ');
    raise exception 'FAIL: void without reason accepted';
  exception when invalid_parameter_value then null;
  end;
  perform public.void_booking_payment(p, 'двойной ввод');
  assert (select balance from public.booking_balances where booking_id = b) = 52000,
    'voided payment must not count; refund must increase balance';
  assert (select count(*) from public.booking_payments where booking_id = b) = 3, 'voided payment stays in history';

  insert into public.expense_categories (tenant_id, name) values (a, 'Продукты') returning id into cat;
  insert into public.expenses (tenant_id, category_id, amount, spent_on, created_by)
  values (a, cat, 12500, current_date, auth.uid()) returning id into e;
  insert into public.expenses (tenant_id, category_id, amount, spent_on, created_by)
  values (a, cat, 999, current_date, auth.uid());
  perform public.void_expense((select id from public.expenses where amount = 999), 'дубль');
  update public.expenses set amount = 1 where id = e;
  assert (select amount from public.expenses where id = e) = 12500, 'expenses must not be editable directly';

  rep := public.finance_report(a, current_date - 1, current_date + 1);
  assert (rep ->> 'payments')::numeric = 18000, format('report payments wrong: %s', rep);
  assert (rep ->> 'refunds')::numeric = 3000, format('report refunds wrong: %s', rep);
  assert (rep ->> 'expenses')::numeric = 12500, format('report expenses wrong: %s', rep);
  assert (rep -> 'by_method' ->> 'kaspi_transfer')::numeric = 15000, format('by method wrong: %s', rep);
  assert (rep ->> 'receivables')::numeric = 52000, format('receivables wrong: %s', rep);
  raise notice 'ok  13b  accountant: refund limits, voids with reason, expenses, period report';
end $$;

reset role;
do $$ begin
  assert (select count(*) from public.audit_logs
          where tenant_id = current_setting('t4.a')::uuid and action like 'payment.%') = 4,
    'payments, refunds and voids must be audited';
end $$;
set role authenticated;

-- ============================================================================
-- Горничная и другой санаторий не видят деньги
-- ============================================================================
select tests.login('00000000-0000-0000-0000-0000000004a4', 'maid4a@example.kz');
do $$
begin
  assert (select count(*) from public.booking_payments) = 0, 'housekeeping must not see payments';
  assert (select count(*) from public.booking_balances) = 0, 'housekeeping must not see balances';
  assert (select count(*) from public.expenses) = 0, 'housekeeping must not see expenses';
  begin
    perform public.finance_report(current_setting('t4.a')::uuid, current_date, current_date);
    raise exception 'FAIL: housekeeping read finance report';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.add_booking_payment(current_setting('t4.booking')::uuid, 'payment', 'cash', 100);
    raise exception 'FAIL: housekeeping took a payment';
  exception when no_data_found then null;
  end;
  raise notice 'ok  10d  housekeeping: no access to money';
end $$;

select tests.login('00000000-0000-0000-0000-0000000004b1', 'owner4b@example.kz');
do $$
begin
  assert (select count(*) from public.booking_payments) = 0 and (select count(*) from public.booking_balances) = 0
     and (select count(*) from public.booking_extras) = 0 and (select count(*) from public.expenses) = 0,
    'B must not see A finance';
  begin
    perform public.add_booking_payment(current_setting('t4.booking')::uuid, 'refund', 'cash', 1, 'x');
    raise exception 'FAIL: B refunded A booking';
  exception when no_data_found then null;
  end;
  begin
    perform public.finance_report(current_setting('t4.a')::uuid, current_date, current_date);
    raise exception 'FAIL: B read A report';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.void_booking_payment((select id from public.booking_payments limit 1), 'x');
    raise exception 'FAIL: B voided a payment';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  3c   tenant isolation for payments, balances, expenses, report';
end $$;
reset role;

-- ============================================================================
-- Отмена брони: оплата не принимается, возврат возможен; истёкшая подписка; тариф Start
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000004a1', 'owner4a@example.kz');
do $$
declare b uuid := current_setting('t4.booking')::uuid;
begin
  perform public.set_booking_status(b, 'cancelled', 'Гость отказался');
  assert (select balance from public.booking_balances where booking_id = b) = -15000,
    'cancelled booking: charges 0, prepayment shows as overpaid';
  begin
    perform public.add_booking_payment(b, 'payment', 'cash', 100);
    raise exception 'FAIL: payment on cancelled booking accepted';
  exception when invalid_parameter_value then null;
  end;
  perform public.add_booking_payment(b, 'refund', 'kaspi_transfer', 15000, 'возврат предоплаты');
  assert (select balance from public.booking_balances where booking_id = b) = 0, 'refund must close the balance';
  raise notice 'ok  13c  cancelled booking: no new payments, prepayment refundable';
end $$;
reset role;

update public.organization_subscriptions set trial_ends_at = now() - interval '1 day'
where tenant_id = current_setting('t4.a')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000004a3', 'accountant4a@example.kz');
do $$
begin
  assert (public.finance_report(current_setting('t4.a')::uuid, current_date - 1, current_date + 1) ->> 'payments')::numeric > 0,
    'expired subscription must keep reports readable';
  begin
    perform public.void_expense((select id from public.expenses where voided_at is null limit 1), 'x');
    raise exception 'FAIL: write on expired subscription';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  14d  expired subscription: reports readable, finance writes blocked';
end $$;
reset role;

-- тариф Start: оплаты по броням есть, расходов (функция finance) нет
update public.organization_subscriptions s set trial_ends_at = now() + interval '7 day',
  plan_id = (select id from public.subscription_plans where code = 'start')
where tenant_id = current_setting('t4.a')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000004a3', 'accountant4a@example.kz');
do $$
begin
  begin
    insert into public.expense_categories (tenant_id, name) values (current_setting('t4.a')::uuid, 'Связь');
    raise exception 'FAIL: expenses available on Start plan';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  14e  Start plan: expenses module disabled';
end $$;
reset role;

\echo 'ALL TESTS PASSED'
