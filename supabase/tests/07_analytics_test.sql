-- Тесты аналитики: расчёты загрузки и денег, права, изоляция, тариф (сценарии ТЗ 3, 10, 14, 19)
\set ON_ERROR_STOP on
\set QUIET on

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000007a1', 'owner7a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000007a2', 'reception7a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000007a3', 'accountant7a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000007b1', 'owner7b@example.kz', now());

set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000007a1', 'owner7a@example.kz');
select public.create_organization('Сарыагаш Аналитика', 'analytics-7', 'Сарыагаш') as org7a \gset
select tests.login('00000000-0000-0000-0000-0000000007b1', 'owner7b@example.kz');
select public.create_organization('Жаркент Арасан', 'arasan-7', 'Жаркент') as org7b \gset
reset role;
select set_config('t7.a', :'org7a', false), set_config('t7.b', :'org7b', false) \gset

insert into public.organization_members (tenant_id, user_id, role_id, status)
select :'org7a', u, r.id, 'active'
from (values ('00000000-0000-0000-0000-0000000007a2'::uuid, 'receptionist'),
             ('00000000-0000-0000-0000-0000000007a3'::uuid, 'accountant')) v(u, code)
join public.roles r on r.code = v.code and r.tenant_id is null;

-- Данные за март 2026 (часовой пояс Asia/Almaty, +05:00): 3 номера, 31 день
do $$
declare
  a uuid := current_setting('t7.a')::uuid;
  st uuid; lx uuid; r1 uuid; r2 uuid; r3 uuid; g1 uuid; g2 uuid; b1 uuid; b2 uuid; b3 uuid; pt uuid;
begin
  insert into public.room_types (tenant_id, name, base_price) values (a, 'Стандарт', 20000) returning id into st;
  insert into public.room_types (tenant_id, name, base_price) values (a, 'Люкс', 50000) returning id into lx;
  insert into public.rooms (tenant_id, room_type_id, number) values (a, st, '1') returning id into r1;
  insert into public.rooms (tenant_id, room_type_id, number) values (a, st, '2') returning id into r2;
  insert into public.rooms (tenant_id, room_type_id, number) values (a, lx, '3') returning id into r3;
  insert into public.guests (tenant_id, full_name, phone) values (a, 'Гость Один', '+77010000001') returning id into g1;
  insert into public.guests (tenant_id, full_name, phone) values (a, 'Гость Два', '+77010000002') returning id into g2;

  -- 3 ночи в марте, создана в феврале
  insert into public.bookings (tenant_id, number, guest_id, room_type_id, room_id, check_in, check_out, status, source, total_amount, created_at)
  values (a, 1, g1, st, r1, '2026-03-01', '2026-03-04', 'checked_out', 'phone', 60000, '2026-02-20 10:00+05') returning id into b1;
  -- 3 ночи, из них в марте одна (10 000 ₸ из 30 000)
  insert into public.bookings (tenant_id, number, guest_id, room_type_id, room_id, check_in, check_out, status, source, total_amount, created_at)
  values (a, 2, g2, st, r2, '2026-02-27', '2026-03-02', 'checked_out', 'website', 30000, '2026-02-10 10:00+05') returning id into b2;
  -- повторный приезд гостя 1: 2 ночи в люксе, создана 5 марта
  insert into public.bookings (tenant_id, number, guest_id, room_type_id, room_id, check_in, check_out, status, source, total_amount, created_at)
  values (a, 3, g1, lx, r3, '2026-03-10', '2026-03-12', 'confirmed', 'whatsapp', 100000, '2026-03-05 12:00+05') returning id into b3;
  -- отменённая бронь не занимает номер и не даёт денег
  insert into public.bookings (tenant_id, number, guest_id, room_type_id, room_id, check_in, check_out, status, source, total_amount, created_at)
  values (a, 4, g2, st, r1, '2026-03-20', '2026-03-22', 'cancelled', 'phone', 40000, '2026-03-15 09:00+05');
  -- бронь другого периода
  insert into public.bookings (tenant_id, number, guest_id, room_type_id, room_id, check_in, check_out, status, source, total_amount, created_at)
  values (a, 5, g2, st, r2, '2026-04-10', '2026-04-12', 'confirmed', 'phone', 40000, '2026-04-01 09:00+05');

  -- оплата в 00:30 1 марта по Алматы (28 февраля по UTC) относится к марту
  insert into public.booking_payments (tenant_id, booking_id, kind, method, amount, paid_at) values
    (a, b1, 'payment', 'cash', 60000, '2026-03-01 00:30+05'),
    (a, b1, 'refund', 'cash', 5000, '2026-03-04 11:00+05'),
    (a, b3, 'payment', 'kaspi_transfer', 30000, '2026-02-28 23:30+05');
  insert into public.booking_payments (tenant_id, booking_id, kind, method, amount, paid_at, voided_at, void_reason)
  values (a, b3, 'payment', 'card', 9999, '2026-03-06 10:00+05', now(), 'ошибка');
  insert into public.expense_categories (tenant_id, name) values (a, 'Продукты');
  insert into public.expenses (tenant_id, category_id, amount, spent_on, method)
  select a, id, 12000, '2026-03-15', 'cash' from public.expense_categories where tenant_id = a;

  insert into public.procedure_types (tenant_id, name, duration_min, price) values (a, 'Массаж', 40, 8000) returning id into pt;
  insert into public.procedure_appointments (tenant_id, guest_id, booking_id, procedure_type_id, starts_at, ends_at, status, price) values
    (a, g1, b3, pt, '2026-03-10 10:00+05', '2026-03-10 10:40+05', 'done', 8000),
    (a, g1, b3, pt, '2026-03-11 10:00+05', '2026-03-11 10:40+05', 'no_show', 8000),
    (a, g1, b3, pt, '2026-03-11 12:00+05', '2026-03-11 12:40+05', 'cancelled', 8000);
end $$;

-- ============================================================================
-- Расчёты: загрузка по ночам, начисления, поступления по дате оплаты, источники, процедуры
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000007a3', 'accountant7a@example.kz');
do $$
declare r jsonb := public.analytics_report(current_setting('t7.a')::uuid, '2026-03-01', '2026-03-31');
begin
  assert (r ->> 'days')::int = 31 and (r ->> 'rooms')::int = 3, format('days/rooms: %s', r);
  assert (r ->> 'room_nights')::int = 6, format('room nights: %s', r ->> 'room_nights');
  assert (r ->> 'accommodation')::numeric = 170000, format('accommodation: %s', r ->> 'accommodation');
  assert (r ->> 'received')::numeric = 55000, format('received (tz, refund, void): %s', r ->> 'received');
  assert (r ->> 'expenses')::numeric = 12000, 'expenses';
  assert (r ->> 'guests')::int = 2 and (r ->> 'returning_guests')::int = 1, format('guests: %s/%s', r ->> 'guests', r ->> 'returning_guests');
  assert (r -> 'daily' -> 0 ->> 'occupied')::int = 2 and (r -> 'daily' -> 1 ->> 'occupied')::int = 1
     and jsonb_array_length(r -> 'daily') = 31, 'daily occupancy';
  assert jsonb_array_length(r -> 'monthly') = 1 and (r -> 'monthly' -> 0 ->> 'room_nights')::int = 6, 'monthly';
  assert r -> 'bookings' = '{"created": 2, "cancelled": 1, "no_show": 0, "requests": 0, "avg_nights": 2.0, "avg_lead_days": 5.0}'::jsonb,
    format('bookings: %s', r -> 'bookings');
  assert (select (s ->> 'amount')::numeric from jsonb_array_elements(r -> 'sources') s where s ->> 'source' = 'whatsapp') = 100000
     and (select (s ->> 'cancelled')::int from jsonb_array_elements(r -> 'sources') s where s ->> 'source' = 'phone') = 1,
    format('sources: %s', r -> 'sources');
  assert r -> 'room_types' -> 0 = '{"name": "Стандарт", "rooms": 2, "room_nights": 4, "accommodation": 70000.00}'::jsonb,
    format('room types: %s', r -> 'room_types');
  assert r -> 'procedures' = '[{"name": "Массаж", "done": 1, "no_show": 1, "amount": 8000.00}]'::jsonb,
    format('procedures: %s', r -> 'procedures');
  assert position('Гость' in r::text) = 0 and position('+7701' in r::text) = 0, 'no guest personal data in the report';
  begin
    perform public.analytics_report(current_setting('t7.a')::uuid, '2026-03-31', '2026-03-01');
    raise exception 'FAIL: reversed period accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.analytics_report(current_setting('t7.a')::uuid, '2025-01-01', '2026-03-01');
    raise exception 'FAIL: period over a year accepted';
  exception when invalid_parameter_value then null;
  end;
  raise notice 'ok  19a  analytics: nights, accrual, cash by local date, sources, procedures; no personal data';
end $$;

-- ============================================================================
-- Права и изоляция: ресепшен и другой санаторий не видят отчёт
-- ============================================================================
select tests.login('00000000-0000-0000-0000-0000000007a2', 'reception7a@example.kz');
do $$
begin
  perform public.analytics_report(current_setting('t7.a')::uuid, '2026-03-01', '2026-03-31');
  raise exception 'FAIL: reception read analytics';
exception when insufficient_privilege then
  raise notice 'ok  19b  reception has no reports.read';
end $$;
select tests.login('00000000-0000-0000-0000-0000000007b1', 'owner7b@example.kz');
do $$
begin
  begin
    perform public.analytics_report(current_setting('t7.a')::uuid, '2026-03-01', '2026-03-31');
    raise exception 'FAIL: B read A analytics';
  exception when insufficient_privilege then null;
  end;
  assert (public.analytics_report(current_setting('t7.b')::uuid, '2026-03-01', '2026-03-31') ->> 'room_nights')::int = 0,
    'B sees only its own empty report';
  raise notice 'ok  19c  tenant isolation';
end $$;
reset role;

-- ============================================================================
-- Подписка: истёкшая — отчёт читается; тариф Start — модуля нет
-- ============================================================================
update public.organization_subscriptions set trial_ends_at = now() - interval '30 days'
where tenant_id = current_setting('t7.a')::uuid;
update public.organization_subscriptions set plan_id = (select id from public.subscription_plans where code = 'start')
where tenant_id = current_setting('t7.b')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000007a1', 'owner7a@example.kz');
do $$
begin
  assert not app.subscription_writable(current_setting('t7.a')::uuid), 'subscription expired';
  assert (public.analytics_report(current_setting('t7.a')::uuid, '2026-03-01', '2026-03-31') ->> 'room_nights')::int = 6,
    'expired subscription: report still readable';
end $$;
select tests.login('00000000-0000-0000-0000-0000000007b1', 'owner7b@example.kz');
do $$
begin
  perform public.analytics_report(current_setting('t7.b')::uuid, '2026-03-01', '2026-03-31');
  raise exception 'FAIL: Start plan has analytics';
exception when insufficient_privilege then
  raise notice 'ok  19d  expired subscription reads analytics; Start plan has none';
end $$;
reset role;

\echo 'ALL TESTS PASSED'
