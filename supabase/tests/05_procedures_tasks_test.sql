-- Тесты процедур и задач (сценарии ТЗ 3, 10, 14, 15, 16)
\set ON_ERROR_STOP on
\set QUIET on

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000005a1', 'owner5a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000005a2', 'doctor5a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000005a3', 'nurse5a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000005a4', 'reception5a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000005a5', 'maid5a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000005a6', 'accountant5a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000005b1', 'owner5b@example.kz', now());

set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000005a1', 'owner5a@example.kz');
select public.create_organization('Жаркент Арасан', 'zharkent-arasan', 'Жаркент') as org5a \gset
select tests.login('00000000-0000-0000-0000-0000000005b1', 'owner5b@example.kz');
select public.create_organization('Алатау Санаторий', 'alatau-san', 'Алматы') as org5b \gset
reset role;
select set_config('t5.a', :'org5a', false), set_config('t5.b', :'org5b', false) \gset

insert into public.organization_members (tenant_id, user_id, role_id, status)
select :'org5a', u, r.id, 'active'
from (values ('00000000-0000-0000-0000-0000000005a2'::uuid, 'doctor'),
             ('00000000-0000-0000-0000-0000000005a3'::uuid, 'nurse'),
             ('00000000-0000-0000-0000-0000000005a4'::uuid, 'receptionist'),
             ('00000000-0000-0000-0000-0000000005a5'::uuid, 'housekeeping'),
             ('00000000-0000-0000-0000-0000000005a6'::uuid, 'accountant')) v(u, code)
join public.roles r on r.code = v.code and r.tenant_id is null;

-- Владелец заводит номер, гостей, бронь, процедуры и кабинеты
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000005a1', 'owner5a@example.kz');
insert into public.room_types (tenant_id, name, base_price) values (:'org5a', 'Стандарт', 20000) returning id as rt5 \gset
insert into public.rooms (tenant_id, room_type_id, number) values (:'org5a', :'rt5', '7') returning id as room5 \gset
insert into public.guests (tenant_id, full_name) values (:'org5a', 'Гость Процедур') returning id as guest5 \gset
insert into public.guests (tenant_id, full_name) values (:'org5a', 'Гость Без Брони') returning id as guest5b \gset
select public.create_booking(:'org5a', :'guest5', :'rt5', :'room5', current_date + 1, current_date + 4, 1, 0) as booking5 \gset
insert into public.procedure_types (tenant_id, name, duration_min, price) values (:'org5a', 'Массаж спины', 40, 8000) returning id as massage \gset
insert into public.procedure_types (tenant_id, name, duration_min, price) values (:'org5a', 'Грязелечение', 30, 6000) returning id as mud \gset
insert into public.treatment_rooms (tenant_id, name) values (:'org5a', 'Кабинет 1') returning id as cab1 \gset
insert into public.treatment_rooms (tenant_id, name) values (:'org5a', 'Кабинет 2') returning id as cab2 \gset
reset role;
select set_config('t5.room', :'room5', false), set_config('t5.guest', :'guest5', false),
       set_config('t5.guest_b', :'guest5b', false), set_config('t5.booking', :'booking5', false),
       set_config('t5.massage', :'massage', false), set_config('t5.mud', :'mud', false),
       set_config('t5.cab1', :'cab1', false), set_config('t5.cab2', :'cab2', false) \gset

-- ============================================================================
-- Врач записывает гостя: цена с сервера, пересечения кабинета, специалиста и гостя запрещены
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000005a2', 'doctor5a@example.kz');
do $$
declare
  g uuid := current_setting('t5.guest')::uuid;
  b uuid := current_setting('t5.booking')::uuid;
  nurse uuid := '00000000-0000-0000-0000-0000000005a3';
  maid uuid := '00000000-0000-0000-0000-0000000005a5';
  t0 timestamptz := ((current_date + 1)::timestamp + time '10:00') at time zone 'Asia/Almaty';
  a uuid; a2 uuid;
begin
  a := public.schedule_procedure(g, current_setting('t5.massage')::uuid, t0, b, current_setting('t5.cab1')::uuid, nurse);
  assert (select price from public.procedure_appointments where id = a) = 8000, 'price must come from the catalog';
  assert (select ends_at - starts_at from public.procedure_appointments where id = a) = interval '40 minutes', 'duration from catalog';
  perform public.schedule_procedure(g, current_setting('t5.mud')::uuid, t0 + interval '2 hours', b, null, null, true);
  assert (select sum(price) from public.procedure_appointments where booking_id = b) = 8000,
    'included procedure must cost 0';

  begin
    perform public.schedule_procedure(current_setting('t5.guest_b')::uuid, current_setting('t5.mud')::uuid,
      t0 + interval '20 minutes', null, current_setting('t5.cab1')::uuid);
    raise exception 'FAIL: treatment room double-booked';
  exception when exclusion_violation then null;
  end;
  begin
    perform public.schedule_procedure(current_setting('t5.guest_b')::uuid, current_setting('t5.mud')::uuid,
      t0 + interval '10 minutes', null, current_setting('t5.cab2')::uuid, nurse);
    raise exception 'FAIL: specialist double-booked';
  exception when exclusion_violation then null;
  end;
  begin
    perform public.schedule_procedure(g, current_setting('t5.mud')::uuid, t0 + interval '30 minutes', b);
    raise exception 'FAIL: guest double-booked';
  exception when exclusion_violation then null;
  end;
  -- встык (10:40) — можно
  perform public.schedule_procedure(current_setting('t5.guest_b')::uuid, current_setting('t5.mud')::uuid,
    t0 + interval '40 minutes', null, current_setting('t5.cab1')::uuid, nurse);
  begin
    perform public.schedule_procedure(g, current_setting('t5.mud')::uuid, t0 + interval '10 days', b);
    raise exception 'FAIL: procedure outside the stay accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.schedule_procedure(g, current_setting('t5.mud')::uuid, t0 + interval '5 hours', b, null, maid);
    raise exception 'FAIL: housekeeping assigned as specialist';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.schedule_procedure(g, current_setting('t5.mud')::uuid, now() - interval '3 days');
    raise exception 'FAIL: procedure in the past accepted';
  exception when invalid_parameter_value then null;
  end;
  -- без указания брони процедура сама привязывается к брони гостя на этот день
  a2 := public.schedule_procedure(g, current_setting('t5.massage')::uuid, t0 + interval '3 hours', null, null, null, true);
  assert (select booking_id from public.procedure_appointments where id = a2) = b, 'procedure must link to the active booking';
  -- перенос сохраняет длительность и тоже проверяет пересечения
  perform public.reschedule_procedure(a, t0 + interval '4 hours', current_setting('t5.cab2')::uuid, nurse);
  assert (select ends_at from public.procedure_appointments where id = a) = t0 + interval '4 hours 40 minutes', 'reschedule keeps duration';
  raise notice 'ok  15a  doctor: catalog price, no room/specialist/guest overlaps, stay dates, reschedule';
end $$;

-- ============================================================================
-- Медсестра отмечает выполнение, но не записывает и не отменяет; будущее нельзя отметить
-- ============================================================================
select tests.login('00000000-0000-0000-0000-0000000005a2', 'doctor5a@example.kz');
select public.schedule_procedure(:'guest5b', :'massage', now() - interval '1 hour', null, null,
  '00000000-0000-0000-0000-0000000005a3') as today_appt \gset
reset role;
select set_config('t5.today', :'today_appt', false) \gset
set role authenticated;

select tests.login('00000000-0000-0000-0000-0000000005a3', 'nurse5a@example.kz');
do $$
declare future uuid;
begin
  select id into future from public.procedure_appointments where booking_id = current_setting('t5.booking')::uuid limit 1;
  begin
    perform public.schedule_procedure(current_setting('t5.guest')::uuid, current_setting('t5.mud')::uuid, now() + interval '1 day');
    raise exception 'FAIL: nurse scheduled a procedure';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.set_procedure_status(future, 'done');
    raise exception 'FAIL: future procedure marked done';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.set_procedure_status(future, 'cancelled', 'x');
    raise exception 'FAIL: nurse cancelled a procedure';
  exception when insufficient_privilege then null;
  end;
  perform public.set_procedure_status(current_setting('t5.today')::uuid, 'done');
  assert (select status = 'done' and completed_by = auth.uid() from public.procedure_appointments
          where id = current_setting('t5.today')::uuid), 'nurse marks procedure done';
  raise notice 'ok  15b  nurse: marks done, cannot schedule, cancel or close a future procedure';
end $$;

-- ============================================================================
-- Ресепшен видит расписание, но не записывает; бухгалтер видит процедуры в балансе; горничная — ничего
-- ============================================================================
select tests.login('00000000-0000-0000-0000-0000000005a4', 'reception5a@example.kz');
do $$
begin
  assert (select count(*) from public.procedure_appointments) = 5, 'reception sees the schedule';
  begin
    perform public.schedule_procedure(current_setting('t5.guest')::uuid, current_setting('t5.mud')::uuid, now() + interval '1 day');
    raise exception 'FAIL: reception scheduled a procedure';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  15c  reception: reads schedule, cannot schedule';
end $$;

select tests.login('00000000-0000-0000-0000-0000000005a6', 'accountant5a@example.kz');
do $$
begin
  assert (select procedures from public.booking_balances where booking_id = current_setting('t5.booking')::uuid) = 8000,
    'paid procedures go to the bill';
  assert (select balance from public.booking_balances where booking_id = current_setting('t5.booking')::uuid) = 68000,
    'accountant must see procedures in the balance';
end $$;

select tests.login('00000000-0000-0000-0000-0000000005a5', 'maid5a@example.kz');
do $$
begin
  assert (select count(*) from public.procedure_appointments) = 0, 'housekeeping must not see procedures';
  assert (select count(*) from public.procedure_types) = 0, 'housekeeping must not see the catalog';
  raise notice 'ok  10e  housekeeping: no access to procedures; accountant sees them in the bill';
end $$;

-- ============================================================================
-- Другой санаторий не видит и не меняет процедуры и задачи A
-- ============================================================================
select tests.login('00000000-0000-0000-0000-0000000005b1', 'owner5b@example.kz');
do $$
begin
  assert (select count(*) from public.procedure_appointments) = 0 and (select count(*) from public.procedure_types) = 0
     and (select count(*) from public.treatment_rooms) = 0 and (select count(*) from public.tasks) = 0,
    'B must not see A procedures or tasks';
  begin
    perform public.schedule_procedure(current_setting('t5.guest')::uuid, current_setting('t5.massage')::uuid, now() + interval '1 day');
    raise exception 'FAIL: B scheduled for A guest';
  exception when no_data_found then null;
  end;
  begin
    perform public.set_procedure_status(current_setting('t5.today')::uuid, 'scheduled');
    raise exception 'FAIL: B changed A procedure';
  exception when no_data_found then null;
  end;
  begin
    perform public.staff_directory(current_setting('t5.a')::uuid, 'tasks.read');
    raise exception 'FAIL: B listed A staff';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.create_task(current_setting('t5.a')::uuid, 'Чужая задача');
    raise exception 'FAIL: B created a task in A';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  3d   tenant isolation for procedures, catalog, staff and tasks';
end $$;

-- ============================================================================
-- Задачи: исполнитель видит свои и общие, берёт общую, не отменяет; назначать могут только с tasks.write
-- ============================================================================
select tests.login('00000000-0000-0000-0000-0000000005a1', 'owner5a@example.kz');
select public.create_task(:'org5a', 'Заменить лампу в 7', null, 'maintenance', 'high',
  '00000000-0000-0000-0000-0000000005a5', :'room5') as task_maid \gset
select public.create_task(:'org5a', 'Проветрить холл') as task_common \gset
select public.create_task(:'org5a', 'Обзвонить заезды', null, 'reception', 'normal', '00000000-0000-0000-0000-0000000005a4') as task_rec \gset
reset role;
select set_config('t5.task_maid', :'task_maid', false), set_config('t5.task_common', :'task_common', false),
       set_config('t5.task_rec', :'task_rec', false) \gset
set role authenticated;

do $$
begin
  begin
    perform public.create_task(current_setting('t5.a')::uuid, 'Бухгалтеру', null, 'other', 'normal',
      '00000000-0000-0000-0000-0000000005a6');
    raise exception 'FAIL: task assigned to someone without tasks.read';
  exception when invalid_parameter_value then null;
  end;
  assert (select count(*) from public.staff_directory(current_setting('t5.a')::uuid, 'procedures.status')) = 3,
    'specialists: owner, doctor and nurse';
end $$;

select tests.login('00000000-0000-0000-0000-0000000005a5', 'maid5a@example.kz');
do $$
begin
  assert (select count(*) from public.tasks) = 2, 'housekeeping sees own and common tasks only';
  perform public.set_task_status(current_setting('t5.task_maid')::uuid, 'in_progress');
  perform public.set_task_status(current_setting('t5.task_maid')::uuid, 'done');
  perform public.set_task_status(current_setting('t5.task_common')::uuid, 'in_progress');
  assert (select assignee_id = auth.uid() from public.tasks where id = current_setting('t5.task_common')::uuid),
    'taking a common task assigns it';
  begin
    perform public.set_task_status(current_setting('t5.task_common')::uuid, 'cancelled');
    raise exception 'FAIL: housekeeping cancelled a task';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.set_task_status(current_setting('t5.task_maid')::uuid, 'open');
    raise exception 'FAIL: housekeeping reopened a closed task';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.set_task_status(current_setting('t5.task_rec')::uuid, 'done');
    raise exception 'FAIL: housekeeping closed someone else''s task';
  exception when no_data_found then null;
  end;
  begin
    perform public.create_task(current_setting('t5.a')::uuid, 'Своя задача');
    raise exception 'FAIL: housekeeping created a task';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.tasks set title = 'x' where id = current_setting('t5.task_common')::uuid;
    if found then raise exception 'FAIL: direct task update'; end if;
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  16a  tasks: own and common visible, take common, no cancel, no direct writes';
end $$;

select tests.login('00000000-0000-0000-0000-0000000005b1', 'owner5b@example.kz');
do $$
begin
  assert (select count(*) from public.tasks) = 0, 'B must not see A tasks';
  begin
    perform public.set_task_status(current_setting('t5.task_common')::uuid, 'cancelled');
    raise exception 'FAIL: B cancelled A task';
  exception when no_data_found then null;
  end;
end $$;

-- ============================================================================
-- Уборка после выезда: номер на уборке → задача; задача выполнена → номер свободен
-- ============================================================================
select tests.login('00000000-0000-0000-0000-0000000005a4', 'reception5a@example.kz');
select public.set_room_status(:'room5', 'cleaning');
select tests.login('00000000-0000-0000-0000-0000000005a5', 'maid5a@example.kz');
do $$
declare t uuid; r uuid := current_setting('t5.room')::uuid;
begin
  select id into t from public.tasks where room_id = r and source = 'room_cleaning' and status = 'open';
  assert t is not null, 'cleaning task must be created when the room goes to cleaning';
  perform public.set_task_status(t, 'done');
  assert (select status from public.rooms where id = r) = 'available', 'done cleaning frees the room';
  perform public.set_room_status(r, 'cleaning');
  perform public.set_room_status(r, 'available');
  assert (select count(*) from public.tasks where room_id = r and source = 'room_cleaning' and status = 'open') = 0,
    'room marked clean closes the open cleaning task';
  raise notice 'ok  16b  room cleaning tasks created and closed automatically';
end $$;

-- ============================================================================
-- Отмена брони снимает её процедуры; журнал; истёкшая подписка; тариф Start
-- ============================================================================
select tests.login('00000000-0000-0000-0000-0000000005a1', 'owner5a@example.kz');
do $$
declare b uuid := current_setting('t5.booking')::uuid;
begin
  perform public.set_booking_status(b, 'cancelled', 'Гость отказался');
  assert (select count(*) from public.procedure_appointments where booking_id = b and status = 'scheduled') = 0,
    'cancelled booking must cancel its procedures';
  assert (select balance from public.booking_balances where booking_id = b) = 0, 'nothing owed after cancel';
  raise notice 'ok  15d  cancelled booking releases its procedures';
end $$;
reset role;

do $$ begin
  assert (select count(*) from public.audit_logs where tenant_id = current_setting('t5.a')::uuid and action like 'procedure.%') >= 6,
    'procedures must be audited';
  assert (select count(*) from public.audit_logs where tenant_id = current_setting('t5.a')::uuid and action like 'task.%') >= 6,
    'tasks must be audited';
end $$;

update public.organization_subscriptions set trial_ends_at = now() - interval '1 day'
where tenant_id = current_setting('t5.a')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000005a2', 'doctor5a@example.kz');
do $$
begin
  assert (select count(*) from public.procedure_appointments) > 0, 'expired subscription keeps the schedule readable';
  begin
    perform public.schedule_procedure(current_setting('t5.guest_b')::uuid, current_setting('t5.mud')::uuid, now() + interval '1 day');
    raise exception 'FAIL: scheduling on expired subscription';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.set_procedure_status(current_setting('t5.today')::uuid, 'scheduled');
    raise exception 'FAIL: status change on expired subscription';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  14f  expired subscription: schedule readable, writes blocked';
end $$;
reset role;

update public.organization_subscriptions s set trial_ends_at = now() + interval '7 day',
  plan_id = (select id from public.subscription_plans where code = 'start')
where tenant_id = current_setting('t5.a')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000005a1', 'owner5a@example.kz');
do $$
begin
  begin
    perform public.create_task(current_setting('t5.a')::uuid, 'На тарифе Start');
    raise exception 'FAIL: tasks on Start plan';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.procedure_types (tenant_id, name, duration_min) values (current_setting('t5.a')::uuid, 'Ингаляция', 15);
    raise exception 'FAIL: procedures on Start plan';
  exception when insufficient_privilege then null;
  end;
  -- без модуля задач номер уходит на уборку без автозадачи
  perform public.set_room_status(current_setting('t5.room')::uuid, 'cleaning');
  raise notice 'ok  14g  Start plan: procedures and tasks disabled';
end $$;
reset role;

\echo 'ALL TESTS PASSED'
