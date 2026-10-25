-- Тесты документов по брони: договор, счёт, акт
\set ON_ERROR_STOP on
\set QUIET on

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-000000000da1', 'owner13a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000da2', 'reception13a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000da3', 'maid13a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000da4', 'doctor13a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000db1', 'owner13b@example.kz', now());

set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000da1', 'owner13a@example.kz') \gset
select public.create_organization('Сарыагаш Документы', 'docs-13', 'Сарыагаш') as org13a \gset
select tests.login('00000000-0000-0000-0000-000000000db1', 'owner13b@example.kz') \gset
select public.create_organization('Боровое Документы', 'docs-13b', 'Боровое') as org13b \gset
reset role;
select set_config('t13.a', :'org13a', false) \gset

insert into public.organization_members (tenant_id, user_id, role_id, status)
select :'org13a', u, r.id, 'active'
from (values ('00000000-0000-0000-0000-000000000da2'::uuid, 'receptionist'),
             ('00000000-0000-0000-0000-000000000da3'::uuid, 'housekeeping'),
             ('00000000-0000-0000-0000-000000000da4'::uuid, 'doctor')) v(u, code)
join public.roles r on r.code = v.code and r.tenant_id is null;

-- Реквизиты: владелец заполняет, неверный ИИК не сохраняется
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000da1', 'owner13a@example.kz') \gset
update public.organizations set legal_name = 'ТОО «Сарыагаш Шипажайы»', bin = '123456789012', legal_address = 'г. Сарыагаш, ул. Курортная, 1',
  bank_name = 'АО «Kaspi Bank»', iik = 'KZ12722S000012345678', bik = 'CASPKZKA', director_name = 'Ахметов А. А.', vat_rate = 16,
  contract_terms = 'Гость соблюдает правила проживания.'
where id = :'org13a';
do $$
begin
  begin
    update public.organizations set iik = 'KZ123' where id = current_setting('t13.a')::uuid;
    raise exception 'FAIL: bad IIK saved';
  exception when check_violation then null;
  end;
end $$;

insert into public.room_types (tenant_id, name, base_occupancy, max_occupancy, base_price)
values (:'org13a', 'Люкс', 2, 3, 30000) returning id as type13 \gset
insert into public.rooms (tenant_id, room_type_id, number) values (:'org13a', :'type13', '301') returning id as room13 \gset
insert into public.guests (tenant_id, full_name, phone) values (:'org13a', 'Гость Документов', '+77015551301') returning id as guest13 \gset
insert into public.procedure_types (tenant_id, name, duration_min, price) values (:'org13a', 'Массаж', 30, 7000) returning id as massage13 \gset
reset role;

insert into public.bookings (tenant_id, number, guest_id, room_type_id, room_id, check_in, check_out, status, total_amount)
values (:'org13a', 1, :'guest13', :'type13', :'room13', current_date + 1, current_date + 6, 'confirmed', 150000) returning id as b13 \gset
insert into public.bookings (tenant_id, number, guest_id, room_type_id, room_id, check_in, check_out, status, total_amount)
values (:'org13a', 2, :'guest13', :'type13', :'room13', current_date - 10, current_date - 5, 'checked_out', 100000) returning id as b13done \gset
insert into public.bookings (tenant_id, number, guest_id, room_type_id, check_in, check_out, status, total_amount)
values (:'org13a', 3, :'guest13', :'type13', current_date + 20, current_date + 25, 'new_request', 100000) returning id as b13req \gset
insert into public.booking_extras (tenant_id, booking_id, name, quantity, unit_price) values (:'org13a', :'b13', 'Трансфер', 2, 5000);
insert into public.procedure_appointments (tenant_id, guest_id, booking_id, procedure_type_id, starts_at, ends_at, status, price) values
  (:'org13a', :'guest13', :'b13', :'massage13', now() + interval '1 day', now() + interval '1 day 30 minutes', 'scheduled', 7000),
  (:'org13a', :'guest13', :'b13', :'massage13', now() + interval '2 day', now() + interval '2 day 30 minutes', 'scheduled', 7000),
  (:'org13a', :'guest13', :'b13', :'massage13', now() + interval '3 day', now() + interval '3 day 30 minutes', 'cancelled', 7000),
  (:'org13a', :'guest13', :'b13done', :'massage13', now() - interval '8 day', now() - interval '8 day' + interval '30 minutes', 'done', 7000),
  (:'org13a', :'guest13', :'b13done', :'massage13', now() - interval '7 day', now() - interval '7 day' + interval '30 minutes', 'scheduled', 7000);
insert into public.booking_payments (tenant_id, booking_id, kind, method, amount) values
  (:'org13a', :'b13', 'payment', 'kaspi_transfer', 50000),
  (:'org13a', :'b13', 'refund', 'kaspi_transfer', 5000);
select set_config('t13.b', :'b13', false), set_config('t13.done', :'b13done', false), set_config('t13.req', :'b13req', false) \gset

-- ============================================================================
-- 25a. Счёт и договор: суммы от сервера, номера раздельные и не меняются при повторной печати
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000da2', 'reception13a@example.kz') \gset
do $$
declare d jsonb; d2 jsonb; c jsonb;
begin
  d := public.booking_document(current_setting('t13.b')::uuid, 'invoice');
  assert (d ->> 'total')::numeric = 150000 + 10000 + 14000, format('invoice total: %s', d -> 'lines');
  assert (d ->> 'paid')::numeric = 45000 and (d ->> 'due')::numeric = 129000, format('paid/due: %s %s', d ->> 'paid', d ->> 'due');
  assert jsonb_array_length(d -> 'lines') = 3, 'lines: stay, extra, procedures';
  assert d -> 'lines' -> 0 ->> 'name' = 'Люкс · №301' and (d -> 'lines' -> 0 ->> 'amount')::numeric = 150000 and (d -> 'lines' -> 0 ->> 'quantity')::int = 5, 'stay line';
  assert (d -> 'lines' -> 2 ->> 'quantity')::numeric = 2, 'cancelled procedure excluded';
  assert (d -> 'document' ->> 'number')::int = 1, 'invoice number 1';
  assert d -> 'organization' ->> 'iik' = 'KZ12722S000012345678' and (d -> 'organization' ->> 'vat_rate')::numeric = 16, 'requisites';

  c := public.booking_document(current_setting('t13.b')::uuid, 'contract');
  assert (c -> 'document' ->> 'number')::int = 1, 'contract numbered separately';
  assert c -> 'guest' ->> 'full_name' = 'Гость Документов', 'guest in contract';

  d2 := public.booking_document(current_setting('t13.b')::uuid, 'invoice');
  assert d2 -> 'document' = d -> 'document', 'reprint keeps number and date';

  begin
    perform public.booking_document(current_setting('t13.req')::uuid, 'contract');
    raise exception 'FAIL: document for unconfirmed request';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.booking_document(current_setting('t13.b')::uuid, 'act');
    raise exception 'FAIL: act before check-out';
  exception when invalid_parameter_value then null;
  end;
  raise notice 'ok  25a  invoice and contract: server totals, separate numbering, stable on reprint';
end $$;

-- сумма счёта обновляется по брони, номер остаётся
reset role;
insert into public.booking_extras (tenant_id, booking_id, name, quantity, unit_price) values (current_setting('t13.a')::uuid, current_setting('t13.b')::uuid, 'Экскурсия', 1, 8000);
set role authenticated;
do $$
declare d jsonb;
begin
  d := public.booking_document(current_setting('t13.b')::uuid, 'invoice');
  assert (d ->> 'total')::numeric = 182000 and (d -> 'document' ->> 'number')::int = 1, 'amount follows booking, number kept';
  assert (select amount from public.booking_documents where booking_id = current_setting('t13.b')::uuid and kind = 'invoice') = 182000, 'stored amount updated';
end $$;

-- ============================================================================
-- 25b. Акт: только после выезда и только проведённые процедуры
-- ============================================================================
do $$
declare d jsonb;
begin
  d := public.booking_document(current_setting('t13.done')::uuid, 'act');
  assert (d ->> 'total')::numeric = 107000, format('act total: %s', d -> 'lines');
  assert (d -> 'document' ->> 'number')::int = 1, 'act number 1';
  d := public.booking_document(current_setting('t13.done')::uuid, 'invoice');
  assert (d -> 'document' ->> 'number')::int = 2, 'second invoice number 2';
  assert (d ->> 'total')::numeric = 114000, 'invoice includes scheduled procedure';
  raise notice 'ok  25b  act after check-out with done procedures only';
end $$;
reset role;

-- ============================================================================
-- 25c. Журнал и права
-- ============================================================================
do $$
declare d text;
begin
  assert (select count(*) from public.audit_logs where tenant_id = current_setting('t13.a')::uuid and action = 'document.issue') = 4,
    'one audit entry per issued document';
  select string_agg(details::text, ' ') into d from public.audit_logs where tenant_id = current_setting('t13.a')::uuid and action = 'document.issue';
  assert d !~ 'Гость|7015551301', 'no guest data in audit';
end $$;

set role authenticated;
do $$
declare u record;
begin
  for u in select * from (values ('00000000-0000-0000-0000-000000000da3'::uuid, 'maid13a@example.kz'),
                                 ('00000000-0000-0000-0000-000000000da4'::uuid, 'doctor13a@example.kz'),
                                 ('00000000-0000-0000-0000-000000000db1'::uuid, 'owner13b@example.kz')) v(id, email) loop
    perform tests.login(u.id, u.email);
    begin
      perform public.booking_document(current_setting('t13.b')::uuid, 'contract');
      raise exception 'FAIL: % prints contract', u.email;
    exception when insufficient_privilege then null;
    end;
    begin
      perform public.booking_document(current_setting('t13.b')::uuid, 'invoice');
      raise exception 'FAIL: % prints invoice', u.email;
    exception when insufficient_privilege then null;
    end;
    assert (select count(*) from public.booking_documents) = 0, format('%s sees documents', u.email);
  end loop;

  perform tests.login('00000000-0000-0000-0000-000000000da2', 'reception13a@example.kz');
  assert (select count(*) from public.booking_documents) = 4, 'reception sees documents';
  begin
    insert into public.booking_documents (tenant_id, booking_id, kind, number, issued_on, amount)
    values (current_setting('t13.a')::uuid, current_setting('t13.b')::uuid, 'act', 99, current_date, 1);
    raise exception 'FAIL: direct insert';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  25c  audit without guest data; housekeeping, doctor, other tenant denied; no direct writes';
end $$;
reset role;

set role anon;
do $$
begin
  begin
    perform public.booking_document(current_setting('t13.b')::uuid, 'contract');
    raise exception 'FAIL: anon prints';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- ============================================================================
-- 25d. Истёкшая подписка: печать доступна (выгрузка своих данных)
-- ============================================================================
update public.organizations set vat_rate = null where id = current_setting('t13.a')::uuid;
update public.organization_subscriptions set trial_ends_at = now() - interval '30 days', current_period_end = null
where tenant_id = current_setting('t13.a')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000da1', 'owner13a@example.kz') \gset
do $$
declare d jsonb;
begin
  d := public.booking_document(current_setting('t13.done')::uuid, 'contract');
  assert (d -> 'document' ->> 'number')::int = 2, 'contract on expired subscription';
  assert d -> 'organization' -> 'vat_rate' = 'null'::jsonb, 'no VAT';
  raise notice 'ok  25d  expired subscription: documents still print';
end $$;
reset role;

\echo 'ALL TESTS PASSED'
