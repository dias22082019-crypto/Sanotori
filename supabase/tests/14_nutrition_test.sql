-- Тесты питания: столы, стол гостя, меню, подсчёт порций
\set ON_ERROR_STOP on
\set QUIET on

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-000000000ea1', 'owner14a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000ea2', 'cook14a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000ea3', 'doctor14a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000ea4', 'reception14a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000ea5', 'maid14a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000eb1', 'owner14b@example.kz', now());

set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ea1', 'owner14a@example.kz') \gset
select public.create_organization('Сарыагаш Питание', 'food-14', 'Сарыагаш') as org14a \gset
select tests.login('00000000-0000-0000-0000-000000000eb1', 'owner14b@example.kz') \gset
select public.create_organization('Боровое Питание', 'food-14b', 'Боровое') as org14b \gset
reset role;
select set_config('t14.a', :'org14a', false), set_config('t14.b', :'org14b', false) \gset

insert into public.organization_members (tenant_id, user_id, role_id, status)
select :'org14a', u, r.id, 'active'
from (values ('00000000-0000-0000-0000-000000000ea2'::uuid, 'cook'),
             ('00000000-0000-0000-0000-000000000ea3'::uuid, 'doctor'),
             ('00000000-0000-0000-0000-000000000ea4'::uuid, 'receptionist'),
             ('00000000-0000-0000-0000-000000000ea5'::uuid, 'housekeeping')) v(u, code)
join public.roles r on r.code = v.code and r.tenant_id is null;

set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ea1', 'owner14a@example.kz') \gset
insert into public.room_types (tenant_id, name, base_occupancy, max_occupancy, base_price)
values (:'org14a', 'Стандарт', 2, 3, 20000) returning id as type14 \gset
insert into public.rooms (tenant_id, room_type_id, number) values (:'org14a', :'type14', '101') returning id as r101 \gset
insert into public.rooms (tenant_id, room_type_id, number) values (:'org14a', :'type14', '102') returning id as r102 \gset
insert into public.rooms (tenant_id, room_type_id, number) values (:'org14a', :'type14', '103') returning id as r103 \gset
insert into public.guests (tenant_id, full_name) values (:'org14a', 'Гость Один') returning id as g1 \gset
insert into public.guests (tenant_id, full_name) values (:'org14a', 'Гость Два') returning id as g2 \gset
insert into public.guests (tenant_id, full_name) values (:'org14a', 'Гость Три') returning id as g3 \gset
reset role;
-- день D = завтра: бронь 1 живёт (2 человека), бронь 2 заезжает в D, бронь 3 выезжает в D, бронь 4 отменена
insert into public.bookings (tenant_id, number, guest_id, room_type_id, room_id, check_in, check_out, status, adults, total_amount)
values (:'org14a', 1, :'g1', :'type14', :'r101', current_date - 2, current_date + 5, 'checked_in', 2, 1) returning id as b1 \gset
insert into public.bookings (tenant_id, number, guest_id, room_type_id, room_id, check_in, check_out, status, adults, total_amount)
values (:'org14a', 2, :'g2', :'type14', :'r102', current_date + 1, current_date + 8, 'confirmed', 1, 1) returning id as b2 \gset
insert into public.bookings (tenant_id, number, guest_id, room_type_id, room_id, check_in, check_out, status, adults, total_amount)
values (:'org14a', 3, :'g3', :'type14', :'r103', current_date - 6, current_date + 1, 'checked_in', 1, 1) returning id as b3 \gset
insert into public.bookings (tenant_id, number, guest_id, room_type_id, check_in, check_out, status, adults, total_amount, cancel_reason)
values (:'org14a', 4, :'g3', :'type14', current_date - 1, current_date + 3, 'cancelled', 1, 1, 'передумал') returning id as b4 \gset
select set_config('t14.b1', :'b1', false), set_config('t14.b2', :'b2', false), set_config('t14.b3', :'b3', false),
       set_config('t14.b4', :'b4', false) \gset

-- ============================================================================
-- 26a. Столы: типовой набор, свой стол, один стол по умолчанию
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ea2', 'cook14a@example.kz') \gset
do $$
declare t uuid := current_setting('t14.a')::uuid; n integer; d uuid;
begin
  n := public.add_standard_diets(t);
  assert n = 6, format('standard diets: %s', n);
  assert public.add_standard_diets(t) = 0, 'standard diets are not duplicated';
  assert (select code from public.diet_types where tenant_id = t and is_default) = '15', 'table 15 is default';
  d := public.save_diet_type(t, null, '5п', 'Пятый протёртый', null, true);
  assert (select count(*) from public.diet_types where tenant_id = t and is_default) = 1, 'single default';
  assert (select code from public.diet_types where tenant_id = t and is_default) = '5п', 'new default';
  begin
    perform public.save_diet_type(t, null, '5П', 'Дубль');
    raise exception 'FAIL: duplicate code';
  exception when unique_violation then null;
  end;
  -- вернуть общий стол по умолчанию
  perform public.save_diet_type(t, (select id from public.diet_types where tenant_id = t and code = '15'), '15', 'Общий', null, true);
  perform set_config('t14.d5', (select id::text from public.diet_types where tenant_id = t and code = '5'), false);
  perform set_config('t14.d9', (select id::text from public.diet_types where tenant_id = t and code = '9'), false);
  perform set_config('t14.d15', (select id::text from public.diet_types where tenant_id = t and code = '15'), false);
  raise notice 'ok  26a  standard diets, own diet, single default';
end $$;
reset role;

-- ============================================================================
-- 26b. Стол гостю: врач и повар назначают, ресепшен нет; отменённой брони нельзя
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ea3', 'doctor14a@example.kz') \gset
do $$
declare j jsonb;
begin
  perform public.set_booking_diet(current_setting('t14.b1')::uuid, current_setting('t14.d9')::uuid, 'без сахара, хлеб ржаной');
  j := public.booking_diet(current_setting('t14.b1')::uuid);
  assert j -> 'diet' ->> 'code' = '9' and j -> 'diet' ->> 'kitchen_note' = 'без сахара, хлеб ржаной', format('doctor sets diet: %s', j);
  assert j -> 'default' ->> 'code' = '15' and (j ->> 'can_set')::boolean, 'default and can_set';
  begin
    perform public.set_booking_diet(current_setting('t14.b4')::uuid, current_setting('t14.d9')::uuid);
    raise exception 'FAIL: diet for cancelled booking';
  exception when invalid_parameter_value then null;
  end;
end $$;
select tests.login('00000000-0000-0000-0000-000000000ea2', 'cook14a@example.kz') \gset
do $$
begin
  perform public.set_booking_diet(current_setting('t14.b2')::uuid, current_setting('t14.d5')::uuid);
end $$;
select tests.login('00000000-0000-0000-0000-000000000ea4', 'reception14a@example.kz') \gset
do $$
begin
  assert not (public.booking_diet(current_setting('t14.b1')::uuid) ->> 'can_set')::boolean, 'reception reads but cannot set';
  begin
    perform public.set_booking_diet(current_setting('t14.b1')::uuid, null);
    raise exception 'FAIL: reception sets diet';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.booking_diets;
    raise exception 'FAIL: direct select booking_diets';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  26b  doctor and cook set diet, reception reads only, no direct table access';
end $$;
reset role;

-- ============================================================================
-- 26c. Порции на завтра и меню
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ea2', 'cook14a@example.kz') \gset
do $$
declare t uuid := current_setting('t14.a')::uuid; k jsonb; d date := current_date + 1;
  p_b9 int; p_b15 int; p_l15 int; p_l5 int; p_l9 int; p_b5 int;
begin
  perform public.set_diet_menu(t, d, 'lunch', current_setting('t14.d9')::uuid, 'Суп овощной, рыба на пару');
  perform public.set_diet_menu(t, d, 'lunch', current_setting('t14.d15')::uuid, '  ');
  k := public.kitchen_day(t, d);
  -- брони: 1 (живёт, 2 чел., стол 9) — все приёмы; 2 (заезд, стол 5) — обед и ужин; 3 (выезд, стол по умолчанию) — завтрак; 4 отменена
  assert jsonb_array_length(k -> 'guests') = 3, format('eaters: %s', k -> 'guests');
  select coalesce(sum((x ->> 'portions')::int) filter (where x ->> 'meal' = 'breakfast' and x ->> 'diet_type_id' = current_setting('t14.d9')), 0),
         coalesce(sum((x ->> 'portions')::int) filter (where x ->> 'meal' = 'breakfast' and x ->> 'diet_type_id' = current_setting('t14.d15')), 0),
         coalesce(sum((x ->> 'portions')::int) filter (where x ->> 'meal' = 'breakfast' and x ->> 'diet_type_id' = current_setting('t14.d5')), 0),
         coalesce(sum((x ->> 'portions')::int) filter (where x ->> 'meal' = 'lunch' and x ->> 'diet_type_id' = current_setting('t14.d15')), 0),
         coalesce(sum((x ->> 'portions')::int) filter (where x ->> 'meal' = 'lunch' and x ->> 'diet_type_id' = current_setting('t14.d5')), 0),
         coalesce(sum((x ->> 'portions')::int) filter (where x ->> 'meal' = 'lunch' and x ->> 'diet_type_id' = current_setting('t14.d9')), 0)
  into p_b9, p_b15, p_b5, p_l15, p_l5, p_l9
  from jsonb_array_elements(k -> 'portions') x;
  assert p_b9 = 1 and p_b15 = 2 and p_b5 = 0, format('breakfast: 9=%s 15=%s 5=%s', p_b9, p_b15, p_b5);
  assert p_l9 = 1 and p_l15 = 1 and p_l5 = 1, format('lunch: 9=%s 15=%s 5=%s', p_l9, p_l15, p_l5);
  assert jsonb_array_length(k -> 'menus') = 1 and k -> 'menus' -> 0 ->> 'dishes' = 'Суп овощной, рыба на пару', 'menu saved, empty skipped';

  assert public.copy_diet_menu(t, d, d + 1) = 1, 'menu copied';
  begin
    perform public.copy_diet_menu(t, d + 5, d + 6);
    raise exception 'FAIL: copy empty menu';
  exception when invalid_parameter_value then null;
  end;
  raise notice 'ok  26c  portions by meal and diet with arrival/departure rules, menu and copy';
end $$;
reset role;

-- ============================================================================
-- 26d. Права, изоляция, журнал, тариф и подписка
-- ============================================================================
do $$
declare d text;
begin
  select string_agg(details::text, ' ') into d from public.audit_logs
  where tenant_id = current_setting('t14.a')::uuid and action = 'diet.set';
  assert (select count(*) from public.audit_logs where tenant_id = current_setting('t14.a')::uuid and action = 'diet.set') = 2, 'diet.set logged';
  assert d !~ 'сахар|"9"|diet_type', format('no diet content in audit: %s', d);
end $$;

set role authenticated;
do $$
declare u record;
begin
  for u in select * from (values ('00000000-0000-0000-0000-000000000ea5'::uuid, 'maid14a@example.kz'),
                                 ('00000000-0000-0000-0000-000000000eb1'::uuid, 'owner14b@example.kz')) v(id, email) loop
    perform tests.login(u.id, u.email);
    begin
      perform public.kitchen_day(current_setting('t14.a')::uuid, current_date + 1);
      raise exception 'FAIL: % reads kitchen', u.email;
    exception when insufficient_privilege then null;
    end;
    begin
      perform public.booking_diet(current_setting('t14.b1')::uuid);
      raise exception 'FAIL: % reads diet', u.email;
    exception when insufficient_privilege then null;
    end;
    assert (select count(*) from public.diet_types where tenant_id = current_setting('t14.a')::uuid) = 0, format('%s sees diets', u.email);
  end loop;
  perform tests.login('00000000-0000-0000-0000-000000000eb1', 'owner14b@example.kz');
  begin
    perform public.set_booking_diet(current_setting('t14.b1')::uuid, null);
    raise exception 'FAIL: other tenant sets diet';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.set_diet_menu(current_setting('t14.b')::uuid, current_date, 'lunch', current_setting('t14.d9')::uuid, 'чужой стол');
    raise exception 'FAIL: menu with other tenant diet';
  exception when no_data_found then null;
  end;
end $$;
reset role;

-- Тариф Start: питание недоступно для изменений
update public.organization_subscriptions s set plan_id = (select id from public.subscription_plans where code = 'start')
where tenant_id = current_setting('t14.a')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ea2', 'cook14a@example.kz') \gset
do $$
begin
  begin
    perform public.set_diet_menu(current_setting('t14.a')::uuid, current_date, 'lunch', current_setting('t14.d9')::uuid, 'Каша');
    raise exception 'FAIL: menu on Start plan';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- Истёкшая подписка: читается, не меняется
update public.organization_subscriptions s set plan_id = (select id from public.subscription_plans where code = 'business'),
  trial_ends_at = now() - interval '30 days', current_period_end = null
where tenant_id = current_setting('t14.a')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ea2', 'cook14a@example.kz') \gset
do $$
declare k jsonb;
begin
  k := public.kitchen_day(current_setting('t14.a')::uuid, current_date + 1);
  assert jsonb_array_length(k -> 'guests') = 3 and not (k ->> 'can_write')::boolean, 'expired: readable';
  begin
    perform public.set_booking_diet(current_setting('t14.b1')::uuid, null);
    raise exception 'FAIL: diet on expired subscription';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  26d  maid and other tenant denied, audit without diets, Start plan and expired subscription read-only';
end $$;
reset role;

\echo 'ALL TESTS PASSED'
