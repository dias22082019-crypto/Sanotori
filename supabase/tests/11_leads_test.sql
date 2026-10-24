-- Тесты заявок (сценарии ТЗ 3, 10, 12, 14, 23)
\set ON_ERROR_STOP on
\set QUIET on

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-000000000ba1', 'owner11a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000ba2', 'reception11a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000ba3', 'maid11a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000bb1', 'owner11b@example.kz', now());

set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ba1', 'owner11a@example.kz');
select public.create_organization('Сарыагаш Заявки', 'leads-11', 'Сарыагаш') as org11a \gset
select tests.login('00000000-0000-0000-0000-000000000bb1', 'owner11b@example.kz');
select public.create_organization('Боровое Заявки', 'leads-11b', 'Боровое') as org11b \gset
reset role;
select set_config('t11.a', :'org11a', false), set_config('t11.b', :'org11b', false) \gset

insert into public.organization_members (tenant_id, user_id, role_id, status)
select :'org11a', u, r.id, 'active'
from (values ('00000000-0000-0000-0000-000000000ba2'::uuid, 'receptionist'),
             ('00000000-0000-0000-0000-000000000ba3'::uuid, 'housekeeping')) v(u, code)
join public.roles r on r.code = v.code and r.tenant_id is null;

set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ba1', 'owner11a@example.kz');
insert into public.room_types (tenant_id, name, base_occupancy, max_occupancy, base_price)
values (:'org11a', 'Стандарт', 2, 3, 20000) returning id as type11 \gset
insert into public.rooms (tenant_id, room_type_id, number) values (:'org11a', :'type11', '101') returning id as room11 \gset
insert into public.guests (tenant_id, full_name, phone) values (:'org11a', 'Гость Знакомый', '+77015550001') returning id as guest11 \gset
reset role;
select set_config('t11.type', :'type11', false), set_config('t11.room', :'room11', false), set_config('t11.guest', :'guest11', false) \gset
update public.organizations set is_published = true where id = :'org11a';

-- ============================================================================
-- Ручная заявка: ресепшен создаёт, ведёт, закрывает отказом; горничная не видит
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ba2', 'reception11a@example.kz');
do $$
declare t uuid := current_setting('t11.a')::uuid; l uuid; l2 uuid; c jsonb;
begin
  l := public.create_lead(t, 'phone', 'Асель', '+77775550011', current_setting('t11.type')::uuid,
    current_date + 30, current_date + 40, 2, 1, 'грязелечение', 'звонила по рекламе',
    '00000000-0000-0000-0000-000000000ba2', now() - interval '1 hour');
  assert (select status from public.leads where id = l) = 'new', 'new lead';
  assert (select number from public.leads where id = l) = 1, 'numbering starts at 1';
  c := public.lead_counts(t);
  assert (c ->> 'new')::int = 1 and (c ->> 'overdue')::int = 1 and (c ->> 'mine')::int = 1, format('counts: %s', c);

  begin
    perform public.create_lead(t, 'phone', null, null);
    raise exception 'FAIL: lead without contact';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.create_lead(t, 'phone', 'Х', '87011234567');
    raise exception 'FAIL: phone not in E.164';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.create_lead(t, 'phone', 'Х', null, null, current_date + 5, current_date + 5);
    raise exception 'FAIL: zero nights';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.create_lead(t, 'phone', 'Х', null, null, null, null, null, null, null, null,
      '00000000-0000-0000-0000-000000000ba3');
    raise exception 'FAIL: housekeeping assigned to a lead';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.create_lead(current_setting('t11.b')::uuid, 'phone', 'Чужая', null);
    raise exception 'FAIL: lead created in another sanatorium';
  exception when insufficient_privilege then null;
  end;

  -- заметка переводит новую заявку в работу
  perform public.add_lead_note(l, 'Перезвонить после 18:00');
  assert (select status from public.leads where id = l) = 'in_progress', 'note moves lead in progress';
  assert (select count(*) from public.lead_notes where lead_id = l) = 1, 'note stored';

  perform public.update_lead(l, 'whatsapp', 'Асель Нурова', '+77775550011', current_setting('t11.type')::uuid,
    current_date + 31, current_date + 41, 2, 1, 'грязелечение', 'звонила по рекламе', null, now() + interval '1 day');
  assert (select source from public.leads where id = l) = 'whatsapp', 'updated';

  begin
    perform public.set_lead_status(l, 'lost');
    raise exception 'FAIL: lost without reason';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.set_lead_status(l, 'won');
    raise exception 'FAIL: won set by hand';
  exception when invalid_parameter_value then null;
  end;
  perform public.set_lead_status(l, 'lost', 'price', 'дорого для семьи');
  assert (select status = 'lost' and closed_at is not null from public.leads where id = l), 'lost';
  begin
    perform public.update_lead(l, 'phone', 'Асель', null, null, null, null, null, null, null, null, null, null);
    raise exception 'FAIL: closed lead edited';
  exception when invalid_parameter_value then null;
  end;
  -- вернуть из отказа можно
  perform public.set_lead_status(l, 'in_progress');
  assert (select status = 'in_progress' and lost_reason is null and closed_at is null from public.leads where id = l), 'reopened';

  begin
    insert into public.leads (tenant_id, number, full_name) values (t, 99, 'Напрямую');
    raise exception 'FAIL: direct insert';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.leads set status = 'won' where id = l;
    raise exception 'FAIL: direct update';
  exception when insufficient_privilege then null;
  end;

  -- заявка от знакомого гостя связывается с его карточкой
  l2 := public.create_lead(t, 'walk_in', null, '+77015550001');
  assert (select guest_id from public.leads where id = l2) = current_setting('t11.guest')::uuid, 'linked to guest';
  perform set_config('t11.lead', l::text, false);
  perform set_config('t11.lead2', l2::text, false);
end $$;
reset role;
do $$
begin
  assert (select count(*) from public.audit_logs where tenant_id = current_setting('t11.a')::uuid and action like 'lead.%') >= 5, 'lead actions audited';
  assert (select count(*) from public.audit_logs where tenant_id = current_setting('t11.a')::uuid and action like 'lead.%'
          and (details::text like '%77775550011%' or details::text like '%18:00%')) = 0, 'no phone or note text in audit';
end $$;

set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ba3', 'maid11a@example.kz');
do $$
begin
  assert (select count(*) from public.leads) = 0, 'housekeeping does not see leads';
  assert (select count(*) from public.lead_notes) = 0, 'housekeeping does not see notes';
  begin
    perform public.lead_counts(current_setting('t11.a')::uuid);
    raise exception 'FAIL: housekeeping got counts';
  exception when insufficient_privilege then null;
  end;
end $$;
select tests.login('00000000-0000-0000-0000-000000000bb1', 'owner11b@example.kz');
do $$
begin
  assert (select count(*) from public.leads) = 0, 'other sanatorium sees no leads';
  begin
    perform public.add_lead_note(current_setting('t11.lead')::uuid, 'чужая заметка');
    raise exception 'FAIL: note on another sanatorium lead';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  23a  manual leads: create, note, edit, lost with reason, reopen; isolation, no direct writes, no PD in audit';
end $$;
reset role;

-- ============================================================================
-- Бронь из заявки: цена на сервере, заявка закрывается
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ba2', 'reception11a@example.kz');
do $$
declare l uuid := current_setting('t11.lead')::uuid; g uuid; b uuid; bk public.bookings;
begin
  insert into public.guests (tenant_id, full_name, phone) values (current_setting('t11.a')::uuid, 'Асель Нурова', '+77775550011')
  returning id into g;
  b := public.create_booking_from_lead(l, g, current_setting('t11.type')::uuid, current_setting('t11.room')::uuid,
    current_date + 31, current_date + 34, 2, 0, null);
  select * into bk from public.bookings where id = b;
  assert bk.status = 'confirmed' and bk.source = 'whatsapp' and bk.total_amount = 60000, format('booking from lead: %s %s %s', bk.status, bk.source, bk.total_amount);
  assert (select status = 'won' and booking_id = b and guest_id = g from public.leads where id = l), 'lead won';
  begin
    perform public.create_booking_from_lead(l, g, current_setting('t11.type')::uuid, null, current_date + 50, current_date + 52, 1, 0, null);
    raise exception 'FAIL: second booking from closed lead';
  exception when invalid_parameter_value then null;
  end;

  -- без номера: бронь-заявка, заявка остаётся в работе и закрывается при подтверждении брони
  b := public.create_booking_from_lead(current_setting('t11.lead2')::uuid, current_setting('t11.guest')::uuid,
    current_setting('t11.type')::uuid, null, current_date + 60, current_date + 62, 1, 0, null);
  assert (select status = 'in_progress' and booking_id = b from public.leads where id = current_setting('t11.lead2')::uuid), 'lead waits for confirmation';
  perform public.update_booking(b, current_setting('t11.type')::uuid, current_setting('t11.room')::uuid,
    current_date + 60, current_date + 62, 1, 0, null, null);
  perform public.set_booking_status(b, 'confirmed');
  assert (select status from public.leads where id = current_setting('t11.lead2')::uuid) = 'won', 'confirmation closes lead';
  -- бронь «с сайта», которую завёл сотрудник, отдельной заявки не создаёт
  perform public.create_booking(current_setting('t11.a')::uuid, current_setting('t11.guest')::uuid, current_setting('t11.type')::uuid, null,
    current_date + 70, current_date + 72, 1, 0, 'website', null, 'new_request');
  raise notice 'ok  23b  booking from lead: server price, lead won now or on confirmation, closed lead cannot be converted';
end $$;
reset role;

-- ============================================================================
-- Заявка с сайта и входящее WhatsApp создают заявки сами
-- ============================================================================
set role anon;
select set_config('request.jwt.claims', '', false);
do $$
begin
  perform public.submit_booking_request('leads-11', current_setting('t11.type')::uuid, current_date + 20,
    current_date + 23, 2, 0, 'Дана с сайта', '+77011112233', 'хотим с видом на горы', true);
end $$;
reset role;
do $$
declare l public.leads; b uuid;
begin
  select * into l from public.leads where tenant_id = current_setting('t11.a')::uuid and source = 'website';
  assert l.full_name = 'Дана с сайта' and l.phone = '+77011112233' and l.booking_id is not null and l.status = 'new'
    and l.comment = 'хотим с видом на горы' and l.check_in = current_date + 20, format('website lead: %s', row_to_json(l));
  perform set_config('t11.web', l.id::text, false);
  perform set_config('t11.webbooking', l.booking_id::text, false);

  -- входящее с незнакомого номера → заявка; повторное — нет; от знакомого гостя — нет
  insert into public.messages (tenant_id, direction, phone, contact_name, kind, body, status)
  values (current_setting('t11.a')::uuid, 'in', '+77479998877', 'Ербол', 'text', 'Сколько стоит путёвка?', 'received');
  insert into public.messages (tenant_id, direction, phone, kind, body, status)
  values (current_setting('t11.a')::uuid, 'in', '+77479998877', 'text', 'Алло?', 'received');
  insert into public.messages (tenant_id, direction, phone, guest_id, kind, body, status)
  values (current_setting('t11.a')::uuid, 'in', '+77015550001', current_setting('t11.guest')::uuid, 'text', 'Здравствуйте', 'received');
  assert (select count(*) from public.leads where tenant_id = current_setting('t11.a')::uuid and source = 'whatsapp' and phone = '+77479998877') = 1,
    'one lead per unknown number';
  assert (select full_name || '|' || comment from public.leads where phone = '+77479998877') = 'Ербол|Сколько стоит путёвка?', 'lead from message';
  assert (select count(*) from public.leads where phone = '+77015550001' and source = 'whatsapp') = 0, 'known guest makes no lead';
  -- сотрудник, создавший бронь с источником «сайт», заявку-дубль не получает
  assert (select count(*) from public.leads where tenant_id = current_setting('t11.a')::uuid and source = 'website') = 1, 'only anonymous website requests';
end $$;

set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ba2', 'reception11a@example.kz');
do $$
begin
  begin
    perform public.create_booking_from_lead(current_setting('t11.web')::uuid, current_setting('t11.guest')::uuid,
      current_setting('t11.type')::uuid, null, current_date + 20, current_date + 23, 2, 0, null);
    raise exception 'FAIL: second booking for website lead';
  exception when invalid_parameter_value then null;
  end;
  perform public.set_booking_status(current_setting('t11.webbooking')::uuid, 'cancelled', 'гость передумал');
  assert (select status = 'lost' and lost_reason = 'booking_cancelled' from public.leads where id = current_setting('t11.web')::uuid),
    'cancelled request closes lead';
  raise notice 'ok  23c  website request and unknown WhatsApp number create leads; booking cancel closes lead';
end $$;
reset role;

-- ============================================================================
-- Истёкшая подписка: заявки читаются, но не меняются
-- ============================================================================
update public.organization_subscriptions set trial_ends_at = now() - interval '30 days', current_period_end = null
where tenant_id = current_setting('t11.a')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ba2', 'reception11a@example.kz');
do $$
begin
  assert (select count(*) from public.leads) >= 4, 'expired: leads readable';
  begin
    perform public.create_lead(current_setting('t11.a')::uuid, 'phone', 'Поздно', null);
    raise exception 'FAIL: lead on expired subscription';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.add_lead_note(current_setting('t11.lead2')::uuid, 'заметка');
    raise exception 'FAIL: note on expired subscription';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  23d  expired subscription: leads readable, not writable';
end $$;
reset role;

\echo 'ALL TESTS PASSED'
