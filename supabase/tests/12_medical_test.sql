-- Тесты медкарты (особая категория персональных данных)
\set ON_ERROR_STOP on
\set QUIET on

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-000000000ca1', 'owner12a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000ca2', 'doctor12a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000ca3', 'nurse12a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000ca4', 'reception12a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000ca5', 'director12a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000ca6', 'doctor2-12a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000cb1', 'owner12b@example.kz', now()),
  ('00000000-0000-0000-0000-000000000cb2', 'doctor12b@example.kz', now());

set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ca1', 'owner12a@example.kz') \gset
select public.create_organization('Сарыагаш Медкарты', 'medical-12', 'Сарыагаш') as org12a \gset
select tests.login('00000000-0000-0000-0000-000000000cb1', 'owner12b@example.kz') \gset
select public.create_organization('Боровое Медкарты', 'medical-12b', 'Боровое') as org12b \gset
reset role;
select set_config('t12.a', :'org12a', false), set_config('t12.b', :'org12b', false) \gset

insert into public.organization_members (tenant_id, user_id, role_id, status)
select v.t, v.u, r.id, 'active'
from (values (:'org12a'::uuid, '00000000-0000-0000-0000-000000000ca2'::uuid, 'doctor'),
             (:'org12a'::uuid, '00000000-0000-0000-0000-000000000ca3'::uuid, 'nurse'),
             (:'org12a'::uuid, '00000000-0000-0000-0000-000000000ca4'::uuid, 'receptionist'),
             (:'org12a'::uuid, '00000000-0000-0000-0000-000000000ca5'::uuid, 'director'),
             (:'org12a'::uuid, '00000000-0000-0000-0000-000000000ca6'::uuid, 'doctor'),
             (:'org12b'::uuid, '00000000-0000-0000-0000-000000000cb2'::uuid, 'doctor')) v(t, u, code)
join public.roles r on r.code = v.code and r.tenant_id is null;

set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ca1', 'owner12a@example.kz') \gset
insert into public.room_types (tenant_id, name, base_occupancy, max_occupancy, base_price)
values (:'org12a', 'Стандарт', 2, 3, 20000) returning id as type12 \gset
insert into public.rooms (tenant_id, room_type_id, number) values (:'org12a', :'type12', '201') returning id as room12 \gset
insert into public.guests (tenant_id, full_name, phone) values (:'org12a', 'Пациент Первый', '+77015551201') returning id as guest12 \gset
insert into public.guests (tenant_id, full_name, phone) values (:'org12a', 'Пациент Второй', '+77015551202') returning id as guest12b \gset
insert into public.procedure_types (tenant_id, name, duration_min, price) values (:'org12a', 'Грязелечение', 30, 6000) returning id as mud12 \gset
reset role;
insert into public.bookings (tenant_id, number, guest_id, room_type_id, room_id, check_in, check_out, status, total_amount)
values (:'org12a', 1, :'guest12', :'type12', :'room12', current_date - 2, current_date + 8, 'checked_in', 200000) returning id as booking12 \gset
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000cb1', 'owner12b@example.kz') \gset
insert into public.guests (tenant_id, full_name, phone) values (:'org12b', 'Чужой Пациент', '+77015551299') returning id as guest12x \gset
reset role;
select set_config('t12.guest', :'guest12', false), set_config('t12.guest2', :'guest12b', false),
       set_config('t12.mud', :'mud12', false), set_config('t12.booking', :'booking12', false),
       set_config('t12.guestx', :'guest12x', false) \gset

-- ============================================================================
-- 24a. Врач заводит карту (только с согласием), пишет осмотр и назначение
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ca2', 'doctor12a@example.kz') \gset
do $$
declare g uuid := current_setting('t12.guest')::uuid; v uuid; rx uuid; c jsonb;
begin
  begin
    perform public.save_medical_record(g, 'пенициллин', null, null, null, null, false);
    raise exception 'FAIL: card without consent';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.add_medical_visit(g, null, 'initial', now(), 'головная боль', null, null, null);
    raise exception 'FAIL: visit before card';
  exception when invalid_parameter_value then null;
  end;

  perform public.save_medical_record(g, '  пенициллин ', 'беременность', '', null, null, true);
  c := public.get_medical_card(g);
  assert c -> 'record' ->> 'allergies' = 'пенициллин', format('trimmed allergies: %s', c -> 'record');
  assert c -> 'record' ->> 'chronic_conditions' is null, 'empty string stored as null';
  assert (c ->> 'can_write')::boolean, 'doctor can write';
  assert (c -> 'stay' ->> 'id')::uuid = current_setting('t12.booking')::uuid, 'current stay';

  -- повторное сохранение без изменений — без записи в журнал
  perform public.save_medical_record(g, 'пенициллин', 'беременность', null, null, null, false);
  perform public.save_medical_record(g, 'пенициллин', 'беременность', 'гипертония', null, null, false);

  v := public.add_medical_visit(g, current_setting('t12.booking')::uuid, 'initial', now(),
    'головная боль', 'состояние удовлетворительное', 'Гипертония I ст.', 'грязелечение', '130/85', 72, 36.6, 81.5);
  begin
    perform public.add_medical_visit(g, null, 'follow_up', now(), null, null, null, null, null, null, null, null);
    raise exception 'FAIL: empty visit';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.add_medical_visit(g, null, 'follow_up', now(), 'x', null, null, null, '130-85', null, null, null);
    raise exception 'FAIL: bad blood pressure';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.add_medical_visit(g, null, 'follow_up', now(), 'x', null, null, null, null, 300, null, null);
    raise exception 'FAIL: bad pulse';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.add_medical_visit(g, null, 'follow_up', now() + interval '1 day', 'x', null, null, null);
    raise exception 'FAIL: visit in the future';
  exception when invalid_parameter_value then null;
  end;

  rx := public.add_prescription(g, current_setting('t12.booking')::uuid, current_setting('t12.mud')::uuid, 5, 'через день', null);
  begin
    perform public.add_prescription(g, null, current_setting('t12.mud')::uuid, 0);
    raise exception 'FAIL: zero sessions';
  exception when invalid_parameter_value then null;
  end;
  perform set_config('t12.visit', v::text, false);
  perform set_config('t12.rx', rx::text, false);
  raise notice 'ok  24a  doctor: consent required, card, visit with vitals checks, prescription';
end $$;

-- запись на процедуру по назначению и отметка «проведена» — выполнено 1 из 5
do $$
declare a uuid; c jsonb;
begin
  a := public.schedule_procedure(current_setting('t12.guest')::uuid, current_setting('t12.mud')::uuid, now() + interval '1 minute',
    current_setting('t12.booking')::uuid);
  reset role;
  update public.procedure_appointments set starts_at = now() - interval '1 minute', ends_at = now() + interval '29 minute' where id = a;
  set role authenticated;
  perform public.set_procedure_status(a, 'done');
  c := public.get_medical_card(current_setting('t12.guest')::uuid);
  assert (c -> 'prescriptions' -> 0 ->> 'done')::int = 1, format('rx progress: %s', c -> 'prescriptions');
  assert c -> 'prescriptions' -> 0 ->> 'procedure' = 'Грязелечение', 'rx procedure name';
  assert (c -> 'visits' -> 0 ->> 'editable')::boolean, 'own fresh visit editable';
  assert c -> 'visits' -> 0 ->> 'pulse' = '72', 'vitals stored';

  perform public.set_prescription_status(current_setting('t12.rx')::uuid, 'completed');
  begin
    perform public.set_prescription_status(current_setting('t12.rx')::uuid, 'cancelled');
    raise exception 'FAIL: completed -> cancelled';
  exception when invalid_parameter_value then null;
  end;
  perform public.set_prescription_status(current_setting('t12.rx')::uuid, 'active');
  raise notice 'ok  24a  prescription progress counts done procedures; status rules';
end $$;
reset role;

-- ============================================================================
-- 24b. Журнал: каждый просмотр записан, без медицинского содержимого
-- ============================================================================
do $$
declare d text;
begin
  assert (select count(*) from public.audit_logs where tenant_id = current_setting('t12.a')::uuid
          and action = 'medical.view' and entity_id = current_setting('t12.guest')::uuid
          and actor_user_id = '00000000-0000-0000-0000-000000000ca2') = 2, 'each view logged';
  assert (select count(*) from public.audit_logs where tenant_id = current_setting('t12.a')::uuid and action = 'medical.card_update') = 1,
    'unchanged save not logged';
  assert (select details -> 'changed' from public.audit_logs where action = 'medical.card_update'
          and tenant_id = current_setting('t12.a')::uuid) = '["chronic_conditions"]'::jsonb, 'changed field names';
  select string_agg(details::text, ' ') into d from public.audit_logs where tenant_id = current_setting('t12.a')::uuid and action like 'medical.%';
  assert d !~ '(пенициллин|беременность|гипертония|Гипертония|головная|130/85)', format('no medical content in audit: %s', d);
  raise notice 'ok  24b  each view logged; audit holds field names only';
end $$;

-- ============================================================================
-- 24c. Кто что может: медсестра читает, владелец/директор/ресепшен — нет, второй врач не правит чужой осмотр
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ca3', 'nurse12a@example.kz') \gset
do $$
declare g uuid := current_setting('t12.guest')::uuid; c jsonb;
begin
  c := public.get_medical_card(g);
  assert c -> 'record' ->> 'allergies' = 'пенициллин', 'nurse reads card';
  assert not (c ->> 'can_write')::boolean, 'nurse cannot write';
  assert not (c -> 'visits' -> 0 ->> 'editable')::boolean, 'nurse cannot edit visit';
  assert (select count(*) from public.medical_overview(current_setting('t12.a')::uuid) o where o.guest_id = g and o.has_card and o.has_initial) = 1,
    'overview flags';
  begin
    perform public.save_medical_record(g, 'x', null, null, null, null, true);
    raise exception 'FAIL: nurse writes card';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.medical_records;
    raise exception 'FAIL: direct select on medical_records';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.medical_visits;
    raise exception 'FAIL: direct select on medical_visits';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  24c  nurse: read only, no direct table access';
end $$;

select tests.login('00000000-0000-0000-0000-000000000ca6', 'doctor2-12a@example.kz') \gset
do $$
begin
  begin
    perform public.update_medical_visit(current_setting('t12.visit')::uuid, 'initial', now(), 'чужое', null, null, null, null, null, null, null);
    raise exception 'FAIL: other doctor edits visit';
  exception when insufficient_privilege then null;
  end;
end $$;

select tests.login('00000000-0000-0000-0000-000000000ca2', 'doctor12a@example.kz') \gset
do $$
begin
  perform public.update_medical_visit(current_setting('t12.visit')::uuid, 'initial', now(), 'головная боль, слабость',
    null, 'Гипертония I ст.', null, '135/85', 75, 36.7, 81.5);
end $$;
reset role;
update public.medical_visits set created_at = now() - interval '25 hours' where id = current_setting('t12.visit')::uuid;
set role authenticated;
do $$
begin
  begin
    perform public.update_medical_visit(current_setting('t12.visit')::uuid, 'initial', now(), 'поздно', null, null, null, null, null, null, null);
    raise exception 'FAIL: visit edited after 24h';
  exception when insufficient_privilege then null;
  end;
end $$;

do $$
declare u record; g uuid := current_setting('t12.guest')::uuid;
begin
  for u in select * from (values ('00000000-0000-0000-0000-000000000ca1'::uuid, 'owner12a@example.kz'),
                                 ('00000000-0000-0000-0000-000000000ca4'::uuid, 'reception12a@example.kz'),
                                 ('00000000-0000-0000-0000-000000000ca5'::uuid, 'director12a@example.kz')) v(id, email) loop
    perform tests.login(u.id, u.email);
    begin
      perform public.get_medical_card(g);
      raise exception 'FAIL: % reads medical card', u.email;
    exception when insufficient_privilege then null;
    end;
    begin
      perform public.medical_overview(current_setting('t12.a')::uuid);
      raise exception 'FAIL: % reads medical overview', u.email;
    exception when insufficient_privilege then null;
    end;
    begin
      perform public.save_medical_record(g, 'x', null, null, null, null, true);
      raise exception 'FAIL: % writes medical card', u.email;
    exception when insufficient_privilege then null;
    end;
  end loop;
  raise notice 'ok  24c  owner, director, reception: no access; visit editable by author for 24h only';
end $$;
reset role;

-- владелец не может выдать себе медицинские права через свою роль
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ca1', 'owner12a@example.kz') \gset
do $$
begin
  begin
    perform public.upsert_custom_role(current_setting('t12.a')::uuid, null, 'Псевдоврач', 'Псевдоврач', array['medical.read']);
    raise exception 'FAIL: custom role with medical permission';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
end $$;
reset role;

-- анониму функции недоступны
set role anon;
do $$
begin
  begin
    perform public.get_medical_card(current_setting('t12.guest')::uuid);
    raise exception 'FAIL: anon reads card';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- ============================================================================
-- 24d. Изоляция и подписка
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000cb2', 'doctor12b@example.kz') \gset
do $$
begin
  begin
    perform public.get_medical_card(current_setting('t12.guest')::uuid);
    raise exception 'FAIL: other tenant doctor reads card';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.add_prescription(current_setting('t12.guestx')::uuid, null, current_setting('t12.mud')::uuid, 3);
    raise exception 'FAIL: prescription with other tenant procedure';
  exception when no_data_found or insufficient_privilege or invalid_parameter_value then null;
  end;
  assert (select count(*) from public.medical_overview(current_setting('t12.b')::uuid)) = 0, 'own overview empty';
end $$;
reset role;

update public.organization_subscriptions set trial_ends_at = now() - interval '30 days', current_period_end = null
where tenant_id = current_setting('t12.a')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ca2', 'doctor12a@example.kz') \gset
do $$
declare c jsonb;
begin
  c := public.get_medical_card(current_setting('t12.guest')::uuid);
  assert c -> 'record' is not null and not (c ->> 'can_write')::boolean, 'expired: readable, not writable';
  begin
    perform public.add_medical_visit(current_setting('t12.guest')::uuid, null, 'follow_up', now(), 'x', null, null, null);
    raise exception 'FAIL: visit on expired subscription';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  24d  tenant isolation; expired subscription: card readable, not writable';
end $$;
reset role;

\echo 'ALL TESTS PASSED'
