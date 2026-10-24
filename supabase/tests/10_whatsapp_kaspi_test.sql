-- Тесты WhatsApp (Cloud API) и ссылки Kaspi (сценарии ТЗ 3, 7, 12, 14, 22)
\set ON_ERROR_STOP on
\set QUIET on

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-000000000aa1', 'owner10a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000aa2', 'reception10a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000aa3', 'maid10a@example.kz', now()),
  ('00000000-0000-0000-0000-000000000ab1', 'owner10b@example.kz', now());

set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000aa1', 'owner10a@example.kz');
select public.create_organization('Сарыагаш WhatsApp', 'wa-10', 'Сарыагаш') as org10a \gset
select tests.login('00000000-0000-0000-0000-000000000ab1', 'owner10b@example.kz');
select public.create_organization('Алматы Тау', 'tau-10', 'Алматы') as org10b \gset
reset role;
select set_config('t10.a', :'org10a', false), set_config('t10.b', :'org10b', false) \gset

insert into public.organization_members (tenant_id, user_id, role_id, status)
select :'org10a', u, r.id, 'active'
from (values ('00000000-0000-0000-0000-000000000aa2'::uuid, 'receptionist'),
             ('00000000-0000-0000-0000-000000000aa3'::uuid, 'housekeeping')) v(u, code)
join public.roles r on r.code = v.code and r.tenant_id is null;

set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000aa1', 'owner10a@example.kz');
insert into public.guests (tenant_id, full_name, phone) values (:'org10a', 'Гость Ватсап', '+77015551010') returning id as guest10 \gset
reset role;
select set_config('t10.guest', :'guest10', false) \gset

-- ============================================================================
-- Подключение: токены уходят в Vault и не возвращаются клиенту
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000aa1', 'owner10a@example.kz');
do $$
declare t uuid := current_setting('t10.a')::uuid; s jsonb;
begin
  assert (public.whatsapp_settings(t) ->> 'connected')::boolean = false, 'not connected yet';
  begin
    perform public.save_whatsapp_settings(t, '1234567890');
    raise exception 'FAIL: connected without token';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.save_whatsapp_settings(t, '12ab', null, 'EAAG' || repeat('x', 40));
    raise exception 'FAIL: bad phone number id accepted';
  exception when invalid_parameter_value then null;
  end;
  s := public.save_whatsapp_settings(t, '1234567890', '9876543210', 'EAAG' || repeat('x', 40), 'abcdef0123456789abcdef0123456789');
  assert (s ->> 'connected')::boolean and (s ->> 'has_token')::boolean and (s ->> 'has_app_secret')::boolean, format('saved: %s', s);
  assert s ->> 'status' = 'not_checked' and char_length(s ->> 'verify_token') = 64, format('status/verify: %s', s);
  assert position('EAAG' in s::text) = 0 and position('abcdef0123' in s::text) = 0, 'secrets are not returned';
  -- повторное сохранение без токена оставляет прежний
  s := public.save_whatsapp_settings(t, '1234567890', null, null, null);
  assert (s ->> 'has_token')::boolean and s ->> 'waba_id' is null, format('keep token: %s', s);
  begin
    perform count(*) from public.whatsapp_accounts;
    raise exception 'FAIL: client read whatsapp_accounts';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.whatsapp_credentials(t);
    raise exception 'FAIL: client got credentials';
  exception when insufficient_privilege then null;
  end;
  begin
    perform app.vault_get((select gen_random_uuid()));
    raise exception 'FAIL: client called vault_get';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
do $$
begin
  assert (select count(*) from vault.secrets where secret like 'EAAG%') = 1, 'token stored once in vault';
  assert (select count(*) from public.audit_logs where tenant_id = current_setting('t10.a')::uuid
          and action like 'integration.whatsapp_%' and details::text like '%EAAG%') = 0, 'no secrets in audit';
  assert (select count(*) from public.audit_logs where tenant_id = current_setting('t10.a')::uuid
          and action = 'integration.whatsapp_connect') = 1, 'connect audited';
end $$;

set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000aa2', 'reception10a@example.kz');
do $$
declare s jsonb := public.whatsapp_settings(current_setting('t10.a')::uuid);
begin
  assert (s ->> 'connected')::boolean and s ->> 'verify_token' is null, format('reception sees status only: %s', s);
  begin
    perform public.save_whatsapp_settings(current_setting('t10.a')::uuid, '1111111111', null, 'EAAG' || repeat('y', 40));
    raise exception 'FAIL: reception changed settings';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  22a  whatsapp settings: secrets only in vault, never returned; only settings.manage changes them';
end $$;

-- ============================================================================
-- Отправка: очередь → Edge Function (service_role) → результат Meta
-- ============================================================================
do $$
declare t uuid := current_setting('t10.a')::uuid; m uuid;
begin
  begin
    perform public.whatsapp_queue_message(t, '+77015551010', 'Здравствуйте!');
    raise exception 'FAIL: free text outside 24h window';
  exception when invalid_parameter_value then null;
  end;
  m := public.whatsapp_queue_message(t, '+77015551010', null, 'booking_confirmed', 'ru');
  assert (select status from public.messages where id = m) = 'queued', 'queued';
  assert (select guest_id from public.messages where id = m) = current_setting('t10.guest')::uuid, 'linked to guest';
  perform set_config('t10.msg', m::text, false);
  begin
    perform public.whatsapp_claim_message(m);
    raise exception 'FAIL: client claimed message';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.messages (tenant_id, direction, phone, status) values (t, 'out', '+77015551010', 'sent');
    raise exception 'FAIL: client inserted message directly';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

set role service_role;
do $$
declare c jsonb;
begin
  c := public.whatsapp_claim_message(current_setting('t10.msg')::uuid);
  assert c ->> 'access_token' like 'EAAG%' and c ->> 'to' = '77015551010' and c ->> 'phone_number_id' = '1234567890'
     and c ->> 'kind' = 'template' and c ->> 'template_name' = 'booking_confirmed', format('claim: %s', c);
  begin
    perform public.whatsapp_claim_message(current_setting('t10.msg')::uuid);
    raise exception 'FAIL: claimed twice';
  exception when no_data_found then null;
  end;
  perform public.whatsapp_finish_message(current_setting('t10.msg')::uuid, 'wamid.OUT1', null);
end $$;
reset role;

set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000aa3', 'maid10a@example.kz');
do $$
begin
  assert (select count(*) from public.messages) = 0, 'housekeeping has no messages.read';
  begin
    perform public.whatsapp_queue_message(current_setting('t10.a')::uuid, '+77015551010', null, 'hello_world', 'en_US');
    raise exception 'FAIL: housekeeping sent message';
  exception when insufficient_privilege then null;
  end;
end $$;
select tests.login('00000000-0000-0000-0000-000000000aa2', 'reception10a@example.kz');
do $$
begin
  assert (select status from public.messages where id = current_setting('t10.msg')::uuid) = 'sent', 'sent after Meta answered';
  raise notice 'ok  22b  send: rights, 24h rule, queue, one-time claim by service role, status from Meta';
end $$;
reset role;

-- ============================================================================
-- Вебхук: входящие, статусы, дубли
-- ============================================================================
set role service_role;
do $$
declare r jsonb; v jsonb;
begin
  assert public.whatsapp_app_secret('1234567890') = 'abcdef0123456789abcdef0123456789', 'app secret for signature';
  assert public.whatsapp_app_secret('000000000') is null, 'unknown number';
  assert public.whatsapp_verify_token_valid((select verify_token from public.whatsapp_accounts where tenant_id = current_setting('t10.a')::uuid)), 'verify token';
  assert not public.whatsapp_verify_token_valid('nope'), 'wrong verify token';
  v := jsonb_build_object(
    'messaging_product', 'whatsapp',
    'metadata', jsonb_build_object('phone_number_id', '1234567890'),
    'contacts', jsonb_build_array(jsonb_build_object('wa_id', '77015551010', 'profile', jsonb_build_object('name', 'Айгуль'))),
    'messages', jsonb_build_array(jsonb_build_object('from', '77015551010', 'id', 'wamid.IN1', 'timestamp', extract(epoch from now())::bigint::text,
                                                     'type', 'text', 'text', jsonb_build_object('body', 'Есть места на ноябрь?'))));
  r := public.whatsapp_ingest('1234567890', v);
  assert (r ->> 'received')::int = 1, format('ingest: %s', r);
  r := public.whatsapp_ingest('1234567890', v);
  assert (r ->> 'received')::int = 0, 'duplicate delivery ignored';
  assert (public.whatsapp_ingest('000000000', v) ->> 'ignored')::boolean, 'unknown number ignored';
  -- статусы: delivered → read, назад не откатываются
  perform public.whatsapp_ingest('1234567890', jsonb_build_object('statuses', jsonb_build_array(
    jsonb_build_object('id', 'wamid.OUT1', 'status', 'read', 'recipient_id', '77015551010'))));
  r := public.whatsapp_ingest('1234567890', jsonb_build_object('statuses', jsonb_build_array(
    jsonb_build_object('id', 'wamid.OUT1', 'status', 'delivered', 'recipient_id', '77015551010'))));
  assert (r ->> 'statuses')::int = 0, 'status does not go back';
end $$;
reset role;
do $$
begin
  assert (select status from public.messages where wa_message_id = 'wamid.OUT1') = 'read', 'read status kept';
  assert (select guest_id from public.messages where wa_message_id = 'wamid.IN1') = current_setting('t10.guest')::uuid, 'inbound linked to guest';
  assert (select contact_name from public.messages where wa_message_id = 'wamid.IN1') = 'Айгуль', 'contact name';
end $$;

set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000aa2', 'reception10a@example.kz');
do $$
declare t uuid := current_setting('t10.a')::uuid; th record; m uuid;
begin
  select * into th from public.message_threads(t) where phone = '+77015551010';
  assert th.guest_name = 'Гость Ватсап' and th.unread = 1 and th.window_open, format('thread: %s', to_jsonb(th));
  perform public.mark_thread_seen(t, '+77015551010');
  assert (select unread from public.message_threads(t) where phone = '+77015551010') = 0, 'seen';
  -- окно 24 часа открыто входящим — теперь можно свободный текст
  m := public.whatsapp_queue_message(t, '+77015551010', 'Да, есть. Какие даты?');
  assert (select kind from public.messages where id = m) = 'text', 'free text in window';
  raise notice 'ok  22c  webhook: inbound linked to guest, duplicates ignored, statuses only forward, 24h window opens';
end $$;
reset role;

-- ============================================================================
-- Изоляция, тариф, истёкшая подписка, отключение, Kaspi
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000ab1', 'owner10b@example.kz');
do $$
begin
  assert (select count(*) from public.messages) = 0, 'B sees no A messages';
  begin
    perform public.message_threads(current_setting('t10.a')::uuid);
    raise exception 'FAIL: B listed A threads';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.whatsapp_queue_message(current_setting('t10.a')::uuid, '+77015551010', null, 'hello_world', 'en_US');
    raise exception 'FAIL: B sent from A';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.save_whatsapp_settings(current_setting('t10.b')::uuid, '1234567890', null, 'EAAG' || repeat('z', 40));
    raise exception 'FAIL: same number in two sanatoriums';
  exception when unique_violation then null;
  end;
end $$;
reset role;

-- истёкшая подписка: переписка читается, отправка и настройки закрыты
update public.organization_subscriptions set trial_ends_at = now() - interval '30 days', current_period_end = null
where tenant_id = current_setting('t10.a')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000aa2', 'reception10a@example.kz');
do $$
begin
  assert (select count(*) from public.messages) = 3, 'expired: messages readable';
  begin
    perform public.whatsapp_queue_message(current_setting('t10.a')::uuid, '+77015551010', 'ещё');
    raise exception 'FAIL: expired subscription sent message';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
update public.organization_subscriptions set trial_ends_at = now() + interval '10 days',
  plan_id = (select id from public.subscription_plans where code = 'start')
where tenant_id = current_setting('t10.a')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-000000000aa1', 'owner10a@example.kz');
do $$
declare t uuid := current_setting('t10.a')::uuid;
begin
  assert (public.whatsapp_settings(t) ->> 'feature')::boolean = false, 'Start plan: no integrations';
  begin
    perform public.save_whatsapp_settings(t, '1234567890', null, null, null);
    raise exception 'FAIL: Start plan changed whatsapp';
  exception when insufficient_privilege then null;
  end;
  -- отключить можно на любом тарифе: секреты удаляются
  perform public.disconnect_whatsapp(t);
  assert (public.whatsapp_settings(t) ->> 'connected')::boolean = false, 'disconnected';
  -- Kaspi: только https-ссылка на домен kaspi.kz
  update public.organizations set kaspi_pay_url = 'https://pay.kaspi.kz/pay/abc123' where id = t;
  begin
    update public.organizations set kaspi_pay_url = 'https://kaspi.kz.evil.com/pay' where id = t;
    raise exception 'FAIL: foreign domain accepted';
  exception when check_violation then null;
  end;
  begin
    update public.organizations set kaspi_pay_url = 'http://pay.kaspi.kz/pay/abc' where id = t;
    raise exception 'FAIL: http accepted';
  exception when check_violation then null;
  end;
end $$;
reset role;
do $$
begin
  assert (select count(*) from vault.secrets where secret like 'EAAG%' or secret like 'abcdef0123%') = 0, 'secrets removed from vault';
  assert (select count(*) from public.messages where tenant_id = current_setting('t10.a')::uuid) = 3, 'history kept after disconnect';
  raise notice 'ok  22d  tenant isolation, one number per sanatorium, expired/Start rules, disconnect wipes secrets, Kaspi link check';
end $$;

\echo 'ALL TESTS PASSED'
