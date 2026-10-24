-- Тесты журнала действий и подписки (сценарии ТЗ 3, 14, 17, 18)
\set ON_ERROR_STOP on
\set QUIET on

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000006a1', 'owner6a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000006a2', 'reception6a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000006a3', 'director6a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000006b1', 'owner6b@example.kz', now()),
  ('00000000-0000-0000-0000-0000000006f1', 'platform6@example.kz', now());
insert into public.platform_admins (user_id, note) values ('00000000-0000-0000-0000-0000000006f1', 'test');

set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000006a1', 'owner6a@example.kz');
select public.create_organization('Сарыагаш Береке', 'bereke-6', 'Сарыагаш') as org6a \gset
select tests.login('00000000-0000-0000-0000-0000000006b1', 'owner6b@example.kz');
select public.create_organization('Боровое Жасыл', 'zhasyl-6', 'Бурабай') as org6b \gset
reset role;
select set_config('t6.a', :'org6a', false), set_config('t6.b', :'org6b', false) \gset

insert into public.organization_members (tenant_id, user_id, role_id, status)
select :'org6a', u, r.id, 'active'
from (values ('00000000-0000-0000-0000-0000000006a2'::uuid, 'receptionist'),
             ('00000000-0000-0000-0000-0000000006a3'::uuid, 'director')) v(u, code)
join public.roles r on r.code = v.code and r.tenant_id is null;

-- ============================================================================
-- Изменения справочников попадают в журнал; по гостям — только названия полей
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000006a1', 'owner6a@example.kz');
insert into public.room_types (tenant_id, name, base_price) values (:'org6a', 'Полулюкс', 30000) returning id as rt6 \gset
insert into public.rooms (tenant_id, room_type_id, number) values (:'org6a', :'rt6', '12') returning id as room6 \gset
insert into public.guests (tenant_id, full_name, phone) values (:'org6a', 'Гость Журнала', '+77015556677') returning id as guest6 \gset
reset role;
select set_config('t6.rt', :'rt6', false), set_config('t6.room', :'room6', false), set_config('t6.guest', :'guest6', false) \gset
set role authenticated;

do $$
declare a uuid := current_setting('t6.a')::uuid; r record;
begin
  update public.room_types set base_price = 34000 where id = current_setting('t6.rt')::uuid;
  update public.guests set phone = '+77019998877' where id = current_setting('t6.guest')::uuid;
  update public.organizations set phone = '+77253100000' where id = a;
  perform public.set_room_status(current_setting('t6.room')::uuid, 'cleaning');

  select * into r from public.audit_logs where tenant_id = a and action = 'room_type.update';
  assert r.details -> 'values' -> 'base_price' = '{"from": 30000.00, "to": 34000.00}'::jsonb,
    format('price change must be recorded with old and new value: %s', r.details);
  assert r.actor_user_id = auth.uid(), 'actor recorded';

  select * into r from public.audit_logs where tenant_id = a and action = 'guest.update';
  assert r.details -> 'changed' = '["phone"]'::jsonb, 'guest change lists the field';
  assert position('9998877' in r.details::text) = 0 and position('5556677' in r.details::text) = 0,
    'guest values must not be copied into the journal';
  assert not exists (select 1 from public.audit_logs where tenant_id = a and action = 'guest.create'
                     and position('Гость' in details::text) > 0), 'guest name must not be in the journal';

  assert exists (select 1 from public.audit_logs where tenant_id = a and action = 'settings.update'
                 and details -> 'changed' ? 'phone'), 'settings change recorded';
  assert (select count(*) from public.audit_logs where tenant_id = a and action = 'room.update') = 0,
    'room status change must not be logged twice';
  assert (select count(*) from public.audit_logs where tenant_id = a and action = 'room.status') = 1, 'room status logged once';
  assert exists (select 1 from public.audit_logs where tenant_id = a and action = 'room.create'
                 and details ->> 'number' = '12'), 'room creation recorded';
  raise notice 'ok  17a  catalog and settings changes journaled, guest values kept out';
end $$;

-- ============================================================================
-- Журнал видят только с audit.read; другой санаторий не видит; записи не меняются
-- ============================================================================
select tests.login('00000000-0000-0000-0000-0000000006a3', 'director6a@example.kz');
do $$
begin
  assert (select count(*) from public.audit_logs where tenant_id = current_setting('t6.a')::uuid) > 3, 'director reads the journal';
  begin
    update public.audit_logs set action = 'x' where tenant_id = current_setting('t6.a')::uuid;
    if found then raise exception 'FAIL: journal changed'; end if;
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.audit_logs where tenant_id = current_setting('t6.a')::uuid;
    if found then raise exception 'FAIL: journal deleted'; end if;
  exception when insufficient_privilege then null;
  end;
end $$;
select tests.login('00000000-0000-0000-0000-0000000006a2', 'reception6a@example.kz');
do $$
begin
  assert (select count(*) from public.audit_logs) = 0, 'reception must not read the journal';
end $$;
select tests.login('00000000-0000-0000-0000-0000000006b1', 'owner6b@example.kz');
do $$
begin
  assert (select count(*) from public.audit_logs where tenant_id = current_setting('t6.a')::uuid) = 0, 'B must not read A journal';
  raise notice 'ok  17b  journal: audit.read only, tenant isolation, append-only';
end $$;
reset role;

-- ============================================================================
-- Подписка: сводка и заявка на тариф только владельцу; заявка работает при истёкшей подписке
-- ============================================================================
update public.organization_subscriptions set trial_ends_at = now() - interval '1 day'
where tenant_id = current_setting('t6.a')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000006a1', 'owner6a@example.kz');
do $$
declare a uuid := current_setting('t6.a')::uuid; o jsonb; r1 uuid; r2 uuid;
begin
  o := public.subscription_overview(a);
  assert o ->> 'plan_code' = 'business' and (o ->> 'writable')::boolean = false, format('overview wrong: %s', o);
  assert (o ->> 'rooms_count')::int = 1 and (o ->> 'staff_count')::int = 3 and (o ->> 'max_rooms')::int = 300,
    format('usage wrong: %s', o);
  assert o -> 'features' ? 'procedures', 'features listed';

  r1 := public.request_plan_change(a, 'start', 'monthly', 'Нам хватит Start');
  r2 := public.request_plan_change(a, 'business', 'yearly', null);
  assert (select status from public.plan_change_requests where id = r1) = 'cancelled', 'new request replaces the open one';
  assert (public.subscription_overview(a) -> 'open_request' ->> 'plan_code') = 'business', 'open request shown';
  begin
    perform public.request_plan_change(a, 'no_such_plan');
    raise exception 'FAIL: unknown plan accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.admin_set_plan(a, 'enterprise', 'yearly', now() + interval '1 year');
    raise exception 'FAIL: owner switched plan without the platform';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  18a  owner: overview and plan request, also on expired subscription; no self-activation';
end $$;

select tests.login('00000000-0000-0000-0000-0000000006a2', 'reception6a@example.kz');
do $$
begin
  begin
    perform public.subscription_overview(current_setting('t6.a')::uuid);
    raise exception 'FAIL: reception read billing';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.request_plan_change(current_setting('t6.a')::uuid, 'start');
    raise exception 'FAIL: reception requested a plan';
  exception when insufficient_privilege then null;
  end;
  assert (select count(*) from public.plan_change_requests) = 0, 'reception must not see requests';
end $$;
select tests.login('00000000-0000-0000-0000-0000000006b1', 'owner6b@example.kz');
do $$
begin
  assert (select count(*) from public.plan_change_requests) = 0, 'B must not see A requests';
  begin
    perform public.subscription_overview(current_setting('t6.a')::uuid);
    raise exception 'FAIL: B read A billing';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  18b  billing: owner only, tenant isolation';
end $$;

-- ============================================================================
-- Владелец платформы включает тариф: подписка активна, заявка закрыта, событие в журнале санатория
-- ============================================================================
select tests.login('00000000-0000-0000-0000-0000000006f1', 'platform6@example.kz');
do $$
declare a uuid := current_setting('t6.a')::uuid;
begin
  assert (select count(*) from public.plan_change_requests where tenant_id = a and status = 'open') = 1, 'admin sees requests';
  begin
    perform public.admin_set_plan(a, 'business', 'yearly', now() - interval '1 day');
    raise exception 'FAIL: period end in the past accepted';
  exception when invalid_parameter_value then null;
  end;
  perform public.admin_set_plan(a, 'business', 'yearly', now() + interval '1 year');
  assert app.subscription_writable(a), 'subscription must be writable after activation';
  assert (select count(*) from public.plan_change_requests where tenant_id = a and status = 'open') = 0
     and (select count(*) from public.plan_change_requests where tenant_id = a and status = 'done') = 1, 'request closed';
  assert (select count(*) from public.guests) = 0, 'platform admin must not see guests';
  raise notice 'ok  18c  platform admin activates a plan manually; no access to guests';
end $$;
reset role;
do $$ begin
  assert exists (select 1 from public.audit_logs where tenant_id = current_setting('t6.a')::uuid and action = 'billing.plan_set'
                 and actor_user_id = '00000000-0000-0000-0000-0000000006f1'), 'plan change journaled for the sanatorium';
end $$;

\echo 'ALL TESTS PASSED'
