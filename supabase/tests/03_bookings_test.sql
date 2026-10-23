-- Тесты этапа 3: номера, цены, гости, бронирования (сценарии ТЗ 5–8, 12, 3 и 10 для новых таблиц)
\set ON_ERROR_STOP on
\set QUIET on

create schema if not exists tests;
grant usage on schema tests to authenticated, anon;
create or replace function tests.login(p_uid uuid, p_email text) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_uid, 'email', p_email, 'role', 'authenticated')::text, false)
$$;
grant execute on function tests.login(uuid, text) to authenticated, anon;

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000003a1', 'owner3a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000003a2', 'reception3a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000003a3', 'maid3a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000003b1', 'owner3b@example.kz', now());

set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000003a1', 'owner3a@example.kz');
select public.create_organization('Мойылды', 'moiyldy', 'Павлодар') as org3a \gset
select tests.login('00000000-0000-0000-0000-0000000003b1', 'owner3b@example.kz');
select public.create_organization('Окжетпес', 'okzhetpes', 'Бурабай') as org3b \gset
reset role;
select set_config('t3.a', :'org3a', false), set_config('t3.b', :'org3b', false) \gset

-- сотрудники A: ресепшен и горничная (в Supabase их добавляет приглашение)
insert into public.organization_members (tenant_id, user_id, role_id, status)
select :'org3a', u, r.id, 'active'
from (values ('00000000-0000-0000-0000-0000000003a2'::uuid, 'receptionist'),
             ('00000000-0000-0000-0000-0000000003a3'::uuid, 'housekeeping')) v(u, code)
join public.roles r on r.code = v.code and r.tenant_id is null;

-- ============================================================================
-- Владелец A заводит категории, сезон и номера
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000003a1', 'owner3a@example.kz');
insert into public.room_types (tenant_id, name, base_occupancy, max_occupancy, base_price, extra_guest_price)
values (:'org3a', 'Стандарт', 2, 3, 20000, 5000) returning id as type_std \gset
insert into public.room_types (tenant_id, name, base_occupancy, max_occupancy, base_price, is_public)
values (:'org3a', 'Люкс', 2, 2, 45000, false) returning id as type_lux \gset
insert into public.room_rates (tenant_id, room_type_id, name, starts_on, ends_on, price_per_night)
values (:'org3a', :'type_std', 'Лето', current_date + 10, current_date + 20, 30000);
insert into public.rooms (tenant_id, room_type_id, number, floor) values
  (:'org3a', :'type_std', '101', '1') returning id as room101 \gset
insert into public.rooms (tenant_id, room_type_id, number, floor) values
  (:'org3a', :'type_std', '102', '1') returning id as room102 \gset
insert into public.rooms (tenant_id, room_type_id, number, floor) values
  (:'org3a', :'type_lux', '201', '2') returning id as room201 \gset
insert into public.guests (tenant_id, full_name, phone) values
  (:'org3a', 'Ержан Сапаров', '+77011234567') returning id as guest_a \gset
reset role;
select set_config('t3.type_std', :'type_std', false), set_config('t3.type_lux', :'type_lux', false),
       set_config('t3.room101', :'room101', false), set_config('t3.room102', :'room102', false),
       set_config('t3.room201', :'room201', false), set_config('t3.guest_a', :'guest_a', false) \gset

set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000003a1', 'owner3a@example.kz');
do $$
declare
  a uuid := current_setting('t3.a')::uuid;
  q jsonb;
begin
  -- 3 ночи по базовой цене, 2 гостя: 3 × 20 000
  q := public.quote_booking(a, current_setting('t3.type_std')::uuid, current_date + 1, current_date + 4, 2, 0);
  assert (q ->> 'total')::numeric = 60000, format('base price wrong: %s', q);
  -- третий гость: + 5 000 за ночь
  q := public.quote_booking(a, current_setting('t3.type_std')::uuid, current_date + 1, current_date + 4, 2, 1);
  assert (q ->> 'total')::numeric = 75000, format('extra guest price wrong: %s', q);
  -- ночи 9 и 10: одна по базовой (20 000), одна по сезону (30 000)
  q := public.quote_booking(a, current_setting('t3.type_std')::uuid, current_date + 9, current_date + 11, 1, 0);
  assert (q ->> 'total')::numeric = 50000, format('seasonal price wrong: %s', q);
  begin
    perform public.quote_booking(a, current_setting('t3.type_std')::uuid, current_date + 1, current_date + 2, 3, 1);
    raise exception 'FAIL: over capacity accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    insert into public.room_rates (tenant_id, room_type_id, name, starts_on, ends_on, price_per_night)
    values (a, current_setting('t3.type_std')::uuid, 'Пересечение', current_date + 15, current_date + 25, 1);
    raise exception 'FAIL: overlapping seasons accepted';
  exception when exclusion_violation then null;
  end;
  raise notice 'ok  6    server-side price: base, extra guest, season, capacity';
end $$;

-- ============================================================================
-- Сценарий 5: двойная бронь невозможна
-- ============================================================================
do $$
declare
  a uuid := current_setting('t3.a')::uuid;
  b1 uuid; b2 uuid;
begin
  b1 := public.create_booking(a, current_setting('t3.guest_a')::uuid, current_setting('t3.type_std')::uuid,
                              current_setting('t3.room101')::uuid, current_date + 1, current_date + 4, 2, 0);
  assert (select total_amount from public.bookings where id = b1) = 60000, 'booking price must be computed by server';
  assert (select number from public.bookings where id = b1) = 1, 'first booking number must be 1';

  begin
    perform public.create_booking(a, current_setting('t3.guest_a')::uuid, current_setting('t3.type_std')::uuid,
                                  current_setting('t3.room101')::uuid, current_date + 3, current_date + 5, 1, 0);
    raise exception 'FAIL: double booking accepted';
  exception when exclusion_violation then null;
  end;

  -- выезд и заезд в один день не конфликтуют
  b2 := public.create_booking(a, current_setting('t3.guest_a')::uuid, current_setting('t3.type_std')::uuid,
                              current_setting('t3.room101')::uuid, current_date + 4, current_date + 6, 1, 0);
  assert b2 is not null, 'back-to-back booking must be allowed';

  assert not exists (select 1 from public.available_rooms(a, current_date + 2, current_date + 3)
                     where id = current_setting('t3.room101')::uuid), 'occupied room must not be offered';
  assert exists (select 1 from public.available_rooms(a, current_date + 2, current_date + 3)
                 where id = current_setting('t3.room102')::uuid), 'free room must be offered';

  -- после отмены номер освобождается
  perform public.set_booking_status(b2, 'cancelled', 'Гость передумал');
  perform public.create_booking(a, current_setting('t3.guest_a')::uuid, current_setting('t3.type_std')::uuid,
                                current_setting('t3.room101')::uuid, current_date + 4, current_date + 6, 1, 0);

  -- перенос брони на занятые даты тоже запрещён
  begin
    perform public.update_booking(b1, current_setting('t3.type_std')::uuid, current_setting('t3.room101')::uuid,
                                  current_date + 1, current_date + 5, 2, 0);
    raise exception 'FAIL: update into occupied dates accepted';
  exception when exclusion_violation then null;
  end;

  -- номер не той категории
  begin
    perform public.create_booking(a, current_setting('t3.guest_a')::uuid, current_setting('t3.type_std')::uuid,
                                  current_setting('t3.room201')::uuid, current_date + 1, current_date + 2, 1, 0);
    raise exception 'FAIL: room of another type accepted';
  exception when invalid_parameter_value then null;
  end;

  -- цену и бронь нельзя записать в таблицу напрямую в обход функций
  begin
    insert into public.bookings (tenant_id, number, guest_id, room_type_id, room_id, check_in, check_out, total_amount)
    values (a, 999, current_setting('t3.guest_a')::uuid, current_setting('t3.type_std')::uuid,
            current_setting('t3.room102')::uuid, current_date + 1, current_date + 2, 1);
    raise exception 'FAIL: direct insert into bookings allowed';
  exception when insufficient_privilege then null;
  end;
  update public.bookings set total_amount = 1 where id = b1;
  assert (select total_amount from public.bookings where id = b1) = 60000, 'direct price update must be impossible';
  raise notice 'ok  5    double booking blocked (create, update), cancel frees room, no direct writes';
end $$;

-- ============================================================================
-- Сценарий 7–8: заезд и выезд, статусы номера
-- ============================================================================
do $$
declare
  a uuid := current_setting('t3.a')::uuid;
  b uuid;
  future uuid;
begin
  b := public.create_booking(a, current_setting('t3.guest_a')::uuid, current_setting('t3.type_std')::uuid,
                             current_setting('t3.room102')::uuid, current_date, current_date + 3, 1, 0);
  future := (select id from public.bookings where tenant_id = a and number = 1);
  begin
    perform public.set_booking_status(future, 'checked_in');
    raise exception 'FAIL: check-in before arrival date accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.set_booking_status(future, 'cancelled');
    raise exception 'FAIL: cancellation without reason accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.set_booking_status(b, 'checked_out');
    raise exception 'FAIL: check-out without check-in accepted';
  exception when invalid_parameter_value then null;
  end;

  perform public.set_booking_status(b, 'checked_in');
  assert (select status from public.rooms where id = current_setting('t3.room102')::uuid) = 'occupied',
    'room must become occupied on check-in';
  perform public.set_booking_status(b, 'checked_out');
  assert (select status from public.rooms where id = current_setting('t3.room102')::uuid) = 'cleaning',
    'room must go to cleaning on check-out';
  -- ранний выезд освобождает оставшиеся ночи
  assert (select check_out from public.bookings where id = b) = current_date + 1,
    'early check-out must release remaining nights';
  assert exists (select 1 from public.available_rooms(a, current_date + 1, current_date + 3)
                 where id = current_setting('t3.room102')::uuid), 'released nights must be bookable';
  assert (select count(*) from public.audit_logs where tenant_id = a and action = 'booking.status') >= 3,
    'status changes must be audited';
  raise notice 'ok  7-8  check-in/out rules, room status, early departure, audit';
end $$;
reset role;

-- ============================================================================
-- Сценарий 10: права ресепшена и горничной
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000003a3', 'maid3a@example.kz');
do $$
declare n int;
begin
  assert (select count(*) from public.rooms) = 3, 'housekeeping must see rooms';
  assert (select count(*) from public.guests) = 0, 'housekeeping must not see guests';
  assert (select count(*) from public.bookings) = 0, 'housekeeping must not see bookings';
  perform public.set_room_status(current_setting('t3.room102')::uuid, 'available');
  update public.rooms set number = '999' where id = current_setting('t3.room101')::uuid;
  get diagnostics n = row_count;
  assert n = 0, 'housekeeping must not edit rooms';
  begin
    perform public.today_summary(current_setting('t3.a')::uuid);
    raise exception 'FAIL: housekeeping read booking summary';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  10b  housekeeping: rooms and status only, no guests or bookings';
end $$;

select tests.login('00000000-0000-0000-0000-0000000003a2', 'reception3a@example.kz');
do $$
declare
  a uuid := current_setting('t3.a')::uuid;
  b uuid;
begin
  b := public.create_booking(a, current_setting('t3.guest_a')::uuid, current_setting('t3.type_lux')::uuid,
                             current_setting('t3.room201')::uuid, current_date + 30, current_date + 32, 2, 0);
  begin
    perform public.set_booking_status(b, 'cancelled', 'тест');
    raise exception 'FAIL: receptionist cancelled a confirmed booking';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.room_types (tenant_id, name, base_price) values (a, 'Самовольная', 1);
    raise exception 'FAIL: receptionist created a room type';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  10c  receptionist: books and checks in, cannot cancel or edit prices';
end $$;

-- ============================================================================
-- Сценарий 3: санаторий B не видит и не трогает данные A
-- ============================================================================
select tests.login('00000000-0000-0000-0000-0000000003b1', 'owner3b@example.kz');
do $$
declare
  b uuid := current_setting('t3.b')::uuid;
  n int;
begin
  assert (select count(*) from public.rooms) = 0 and (select count(*) from public.room_types) = 0
     and (select count(*) from public.guests) = 0 and (select count(*) from public.bookings) = 0,
    'B must not see A rooms, guests or bookings';
  update public.guests set full_name = 'hacked' where id = current_setting('t3.guest_a')::uuid;
  get diagnostics n = row_count;
  assert n = 0, 'B must not update A guest';
  begin
    perform public.quote_booking(current_setting('t3.a')::uuid, current_setting('t3.type_std')::uuid,
                                 current_date + 1, current_date + 2, 1, 0);
    raise exception 'FAIL: B quoted A prices';
  exception when insufficient_privilege then null;
  end;
  -- своя категория B + номер и гость A через подмену id: не пройдёт
  insert into public.room_types (tenant_id, name, base_price) values (b, 'Стандарт', 15000);
  begin
    perform public.create_booking(b, current_setting('t3.guest_a')::uuid,
      (select id from public.room_types where tenant_id = b), null, current_date + 1, current_date + 2, 1, 0);
    raise exception 'FAIL: B booked with A guest';
  exception when no_data_found then null;
  end;
  begin
    insert into public.rooms (tenant_id, room_type_id, number) values (b, current_setting('t3.type_std')::uuid, '1');
    raise exception 'FAIL: B created a room in A category';
  exception when foreign_key_violation then null;
  end;
  begin
    perform public.set_booking_status((select id from public.bookings limit 1), 'cancelled', 'x');
    raise exception 'FAIL: B changed status of unknown booking';
  exception when no_data_found then null;
  end;
  begin
    perform public.set_room_status(current_setting('t3.room101')::uuid, 'maintenance');
    raise exception 'FAIL: B changed A room status';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  3b   tenant isolation for rooms, guests, bookings and RPCs';
end $$;
reset role;

-- ============================================================================
-- Сценарий 12: заявка с публичной страницы
-- ============================================================================
set role anon;
select set_config('request.jwt.claims', '', false);
do $$
begin
  assert (select count(*) from public.get_public_room_types('moiyldy')) = 0, 'unpublished org must hide room types';
  begin
    perform public.submit_booking_request('moiyldy', current_setting('t3.type_std')::uuid, current_date + 40,
      current_date + 43, 2, 0, 'Гость', '+77770001122', null, true);
    raise exception 'FAIL: request to unpublished org accepted';
  exception when no_data_found then null;
  end;
end $$;
reset role;
update public.organizations set is_published = true where id = current_setting('t3.a')::uuid;

set role anon;
do $$
declare n int;
begin
  assert (select count(*) from public.get_public_room_types('moiyldy')) = 1, 'only public room types are listed';
  assert (public.public_quote('moiyldy', current_setting('t3.type_std')::uuid, current_date + 40,
          current_date + 43, 2, 0) ->> 'total')::numeric = 60000, 'public quote must match server price';
  begin
    perform public.submit_booking_request('moiyldy', current_setting('t3.type_std')::uuid, current_date + 40,
      current_date + 43, 2, 0, 'Гость', '+77770001122', null, false);
    raise exception 'FAIL: request without consent accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.submit_booking_request('moiyldy', current_setting('t3.type_lux')::uuid, current_date + 40,
      current_date + 43, 2, 0, 'Гость', '+77770001122', null, true);
    raise exception 'FAIL: request for hidden room type accepted';
  exception when no_data_found then null;
  end;
  n := public.submit_booking_request('moiyldy', current_setting('t3.type_std')::uuid, current_date + 40,
    current_date + 43, 2, 0, 'Айжан', '+77770001122', 'Нужна диета', true);
  assert n > 0, 'request number must be returned';
  perform public.submit_booking_request('moiyldy', current_setting('t3.type_std')::uuid, current_date + 50,
    current_date + 52, 1, 0, 'Айжан', '+77770001122', null, true);
  perform public.submit_booking_request('moiyldy', current_setting('t3.type_std')::uuid, current_date + 60,
    current_date + 62, 1, 0, 'Айжан', '+77770001122', null, true);
  begin
    perform public.submit_booking_request('moiyldy', current_setting('t3.type_std')::uuid, current_date + 70,
      current_date + 72, 1, 0, 'Айжан', '+77770001122', null, true);
    raise exception 'FAIL: spam limit not enforced';
  exception when program_limit_exceeded then null;
  end;
  -- запрос на существующий телефон не меняет карточку гостя
  perform public.submit_booking_request('moiyldy', current_setting('t3.type_std')::uuid, current_date + 40,
    current_date + 41, 1, 0, 'Подмена Имени', '+77011234567', null, true);
  assert (select count(*) from public.bookings) = 0 and (select count(*) from public.guests) = 0,
    'anon must not read bookings or guests';
  raise notice 'ok  12   public request: consent, hidden types, spam limit, no data leak';
end $$;
reset role;

do $$
begin
  assert (select count(*) from public.bookings where status = 'new_request' and source = 'website') = 4,
    'website requests must be stored as new_request';
  assert (select full_name from public.guests where id = current_setting('t3.guest_a')::uuid) = 'Ержан Сапаров',
    'public request must not overwrite an existing guest';
  assert (select count(*) from public.guests where phone = '+77770001122') = 1, 'new guest must be created once';
end $$;

-- Подтверждение заявки администратором: нужен номер
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000003a1', 'owner3a@example.kz');
do $$
declare r uuid := (select id from public.bookings where status = 'new_request' order by number limit 1);
begin
  begin
    perform public.set_booking_status(r, 'confirmed');
    raise exception 'FAIL: request confirmed without room';
  exception when invalid_parameter_value then null;
  end;
  perform public.set_booking_status(r, 'confirmed', null, current_setting('t3.room102')::uuid);
  assert (select status from public.bookings where id = r) = 'confirmed', 'request must be confirmed';
  raise notice 'ok  12b  request confirmed with a room';
end $$;
reset role;

-- ============================================================================
-- Сценарий 14: истёкшая подписка — чтение есть, новых броней нет; лимит номеров
-- ============================================================================
update public.organization_subscriptions set trial_ends_at = now() - interval '1 day'
where tenant_id = current_setting('t3.a')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000003a1', 'owner3a@example.kz');
do $$
begin
  assert (select count(*) from public.bookings) > 0, 'expired subscription must keep read access';
  begin
    perform public.create_booking(current_setting('t3.a')::uuid, current_setting('t3.guest_a')::uuid,
      current_setting('t3.type_std')::uuid, current_setting('t3.room102')::uuid, current_date + 90, current_date + 91, 1, 0);
    raise exception 'FAIL: booking created on expired subscription';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.rooms (tenant_id, room_type_id, number)
    values (current_setting('t3.a')::uuid, current_setting('t3.type_std')::uuid, '301');
    raise exception 'FAIL: room created on expired subscription';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  14b  expired subscription: bookings readable, not writable';
end $$;
reset role;

update public.organization_subscriptions set trial_ends_at = now() + interval '7 day'
where tenant_id = current_setting('t3.a')::uuid;
update public.subscription_plans set max_rooms = 3 where code = 'business';
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000003a1', 'owner3a@example.kz');
do $$
begin
  begin
    insert into public.rooms (tenant_id, room_type_id, number)
    values (current_setting('t3.a')::uuid, current_setting('t3.type_std')::uuid, '301');
    raise exception 'FAIL: plan room limit not enforced';
  exception when program_limit_exceeded then null;
  end;
  raise notice 'ok  14c  plan room limit enforced';
end $$;
reset role;
update public.subscription_plans set max_rooms = 300 where code = 'business';

\echo 'ALL TESTS PASSED'
