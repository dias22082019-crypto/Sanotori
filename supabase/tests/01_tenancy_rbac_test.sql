-- Тесты изоляции организаций и защиты от повышения прав (сценарии ТЗ 1–4, 9).
-- Запуск: supabase/tests/run_local.sh  (поднимает чистый PostgreSQL, применяет миграции и тесты)
-- Каждая проверка падает с понятным сообщением; при успехе в конце печатается ALL TESTS PASSED.

\set ON_ERROR_STOP on
\set QUIET on

-- Пользователи (в Supabase их создаёт Auth)
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'owner.a@example.kz', now(), '{"full_name":"Айгерим А"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'owner.b@example.kz', now(), '{"full_name":"Болат Б"}'),
  ('00000000-0000-0000-0000-0000000000a2', 'manager.a@example.kz', now(), '{}'),
  ('00000000-0000-0000-0000-0000000000a3', 'maid.a@example.kz', now(), '{}'),
  ('00000000-0000-0000-0000-0000000000a4', 'director.a@example.kz', now(), '{}'),
  ('00000000-0000-0000-0000-0000000000ff', 'stranger@example.kz', now(), '{}');

create schema tests;
grant usage on schema tests to authenticated, anon;

-- Переключение «текущего пользователя» так, как это делает PostgREST в Supabase
create function tests.login(p_uid uuid, p_email text) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_uid, 'email', p_email, 'role', 'authenticated')::text, false)
$$;
grant execute on function tests.login(uuid, text) to authenticated, anon;

create function tests.role_id(p_code text) returns uuid language sql stable as $$
  select id from public.roles where code = p_code and tenant_id is null
$$;
grant execute on function tests.role_id(text) to authenticated, anon;

-- ============================================================================
-- Сценарий 1–2: два санатория регистрируются независимо
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000000a1', 'owner.a@example.kz');
select public.create_organization('Санаторий Алатау', 'alatau', 'Алматы', 'ru') as org_a \gset
select tests.login('00000000-0000-0000-0000-0000000000b1', 'owner.b@example.kz');
select public.create_organization('Сарыагаш Шипа', 'saryagash', 'Сарыагаш', 'kk') as org_b \gset
reset role;
select set_config('test.org_a', :'org_a', false), set_config('test.org_b', :'org_b', false) \gset

do $$ begin
  assert (select count(*) from public.organization_subscriptions where status = 'trialing') = 2,
    'both organizations must start with a trial';
  assert (select count(*) from public.audit_logs where action = 'organization.create') = 2,
    'organization creation must be audited';
  raise notice 'ok  1-2  two organizations registered with owners and trial';
end $$;

-- ============================================================================
-- Сценарий 3: пользователь A не видит и не меняет данные B
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000000a1', 'owner.a@example.kz');
do $$
declare n int;
begin
  assert (select count(*) from public.organizations) = 1, 'A must see exactly one organization';
  assert not exists (select 1 from public.organizations where id = current_setting('test.org_b')::uuid),
    'A must not see organization B';
  assert not exists (select 1 from public.organization_members where tenant_id = current_setting('test.org_b')::uuid),
    'A must not see members of B';
  assert not exists (select 1 from public.organization_subscriptions where tenant_id = current_setting('test.org_b')::uuid),
    'A must not see subscription of B';

  update public.organizations set name = 'hacked' where id = current_setting('test.org_b')::uuid;
  get diagnostics n = row_count;
  assert n = 0, 'A must not update organization B';

  -- A может менять свою организацию
  update public.organizations set description = 'Лечебные воды' where id = current_setting('test.org_a')::uuid;
  get diagnostics n = row_count;
  assert n = 1, 'owner A must be able to update own organization';

  -- Нельзя подменить tenant_id в запросе, чтобы создать отдел в чужой организации
  begin
    insert into public.departments (tenant_id, name) values (current_setting('test.org_b')::uuid, 'Чужой отдел');
    raise exception 'FAIL: A inserted a department into B';
  exception when insufficient_privilege then null;
  end;

  -- Нельзя перенести свою строку в чужую организацию
  insert into public.departments (tenant_id, name) values (current_setting('test.org_a')::uuid, 'Ресепшен');
  begin
    update public.departments set tenant_id = current_setting('test.org_b')::uuid where name = 'Ресепшен';
    raise exception 'FAIL: A moved a row to B';
  exception when insufficient_privilege then null;
  end;

  -- Нельзя пригласить сотрудника в чужую организацию
  begin
    perform public.invite_member(current_setting('test.org_b')::uuid, 'spy@example.kz', tests.role_id('manager'));
    raise exception 'FAIL: A invited into B';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  3    owner A cannot read or change organization B';
end $$;

-- ============================================================================
-- Сценарий 4: нельзя повысить свою роль клиентским запросом
-- ============================================================================
-- Owner A приглашает менеджера, горничную и директора
select public.invite_member(:'org_a', 'manager.a@example.kz', tests.role_id('manager')) as tok_manager \gset
select public.invite_member(:'org_a', 'maid.a@example.kz', tests.role_id('housekeeping')) as tok_maid \gset
select public.invite_member(:'org_a', 'director.a@example.kz', tests.role_id('director')) as tok_director \gset

-- Чужой пользователь не может принять приглашение, отправленное на другой адрес
select tests.login('00000000-0000-0000-0000-0000000000ff', 'stranger@example.kz');
select set_config('test.tok_manager', :'tok_manager', false) \gset
do $$ begin
  begin
    perform public.accept_invitation(current_setting('test.tok_manager'));
    raise exception 'FAIL: stranger accepted an invitation for another email';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  4a   invitation bound to its email';
end $$;

select tests.login('00000000-0000-0000-0000-0000000000a2', 'manager.a@example.kz');
select public.accept_invitation(:'tok_manager') \gset
select tests.login('00000000-0000-0000-0000-0000000000a3', 'maid.a@example.kz');
select public.accept_invitation(:'tok_maid') \gset
select tests.login('00000000-0000-0000-0000-0000000000a4', 'director.a@example.kz');
select public.accept_invitation(:'tok_director') \gset

-- Повторно использовать токен нельзя
select tests.login('00000000-0000-0000-0000-0000000000a2', 'manager.a@example.kz');
do $$
declare n int; v_self uuid;
begin
  begin
    perform public.accept_invitation(current_setting('test.tok_manager'));
    raise exception 'FAIL: invitation token reused';
  exception when no_data_found then null;
  end;

  select id into v_self from public.organization_members where user_id = auth.uid();

  -- Прямое изменение своей роли: политики UPDATE нет, строка не меняется
  update public.organization_members set role_id = tests.role_id('owner') where id = v_self;
  get diagnostics n = row_count;
  assert n = 0, 'manager must not update own membership row';

  -- Прямая вставка членства в чужую организацию
  begin
    insert into public.organization_members (tenant_id, user_id, role_id)
    values (current_setting('test.org_b')::uuid, auth.uid(), tests.role_id('owner'));
    raise exception 'FAIL: manager inserted membership';
  exception when insufficient_privilege then null;
  end;

  -- Через RPC себе роль поменять нельзя
  begin
    perform public.assign_member_role(v_self, tests.role_id('owner'));
    raise exception 'FAIL: manager changed own role via RPC';
  exception when insufficient_privilege then null;
  end;

  -- Менеджер не управляет сотрудниками
  begin
    perform public.invite_member(current_setting('test.org_a')::uuid, 'x@example.kz', tests.role_id('owner'));
    raise exception 'FAIL: manager invited an owner';
  exception when insufficient_privilege then null;
  end;

  -- Нельзя добавить себе разрешение в роль
  begin
    insert into public.role_permissions (role_id, permission_id)
    select tests.role_id('manager'), id from public.permissions where code = 'billing.manage';
    raise exception 'FAIL: manager added a permission to a role';
  exception when insufficient_privilege then null;
  end;

  -- Нельзя стать super_admin
  begin
    insert into public.platform_admins (user_id) values (auth.uid());
    raise exception 'FAIL: user made themselves platform admin';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.admin_set_subscription_status(current_setting('test.org_a')::uuid, 'active');
    raise exception 'FAIL: non-admin called admin RPC';
  exception when insufficient_privilege then null;
  end;

  -- Менеджер не меняет тариф и не трогает защищённые поля организации
  update public.organizations set slug = 'hijack' where id = current_setting('test.org_a')::uuid;
  get diagnostics n = row_count;
  assert n = 0, 'manager must not update organization settings';

  assert not public.my_permissions(current_setting('test.org_a')::uuid) @> array['billing.manage'],
    'manager must not have billing.manage';
  raise notice 'ok  4b   manager cannot escalate role by direct writes or RPC';
end $$;

-- Директор может управлять сотрудниками? По матрице — нет (members.read только)
select tests.login('00000000-0000-0000-0000-0000000000a4', 'director.a@example.kz');
do $$ begin
  begin
    perform public.invite_member(current_setting('test.org_a')::uuid, 'y@example.kz', tests.role_id('owner'));
    raise exception 'FAIL: director invited an owner';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  4c   director cannot grant owner';
end $$;

-- Владелец не может понизить сам себя и оставить организацию без владельца
select tests.login('00000000-0000-0000-0000-0000000000a1', 'owner.a@example.kz');
do $$
declare v_self uuid; v_manager uuid;
begin
  select id into v_self from public.organization_members where user_id = auth.uid();
  begin
    perform public.assign_member_role(v_self, tests.role_id('manager'));
    raise exception 'FAIL: owner demoted self';
  exception when insufficient_privilege then null;
  end;

  -- Владелец меняет роль менеджера на ресепшен — разрешено и попадает в журнал
  select id into v_manager from public.organization_members
   where user_id = '00000000-0000-0000-0000-0000000000a2';
  perform public.assign_member_role(v_manager, tests.role_id('receptionist'));
  assert exists (select 1 from public.audit_logs where action = 'member.role_change' and result = 'success'),
    'role change must be audited';

  -- Пользовательская роль не может содержать медицинские права
  begin
    perform public.upsert_custom_role(current_setting('test.org_a')::uuid, 'med_helper', 'Помощник', 'Көмекші',
                                      array['rooms.read', 'medical.read']);
    raise exception 'FAIL: custom role with medical permission';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  4d   owner rules: no self-demotion, audited changes, no medical in custom roles';
end $$;

-- ============================================================================
-- Горничная видит только своё: нет журналов, приглашений, медицинских прав
-- ============================================================================
select tests.login('00000000-0000-0000-0000-0000000000a3', 'maid.a@example.kz');
do $$ begin
  assert (select count(*) from public.audit_logs) = 0, 'housekeeping must not read audit log';
  assert (select count(*) from public.invitations) = 0, 'housekeeping must not read invitations';
  assert not (public.my_permissions(current_setting('test.org_a')::uuid) && array['medical.read', 'finance.read', 'guests.read']),
    'housekeeping must not have medical, finance or guest access';
  raise notice 'ok  10a  housekeeping has no medical, finance or guest permissions';
end $$;

-- ============================================================================
-- Сценарий 9: аноним не видит приватные данные
-- ============================================================================
reset role;
select set_config('request.jwt.claims', '', false);
set role anon;
do $$ begin
  assert (select count(*) from public.organizations) = 0, 'anon must not read organizations';
  assert (select count(*) from public.organization_members) = 0, 'anon must not read members';
  assert (select count(*) from public.user_profiles) = 0, 'anon must not read profiles';
  assert (select count(*) from public.audit_logs) = 0, 'anon must not read audit log';
  assert (select count(*) from public.subscription_plans) = 3, 'anon may read public plans';
  begin
    perform public.create_organization('Spam', 'spam-org');
    raise exception 'FAIL: anon called create_organization';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  9    anonymous visitor sees only public plans';
end $$;

-- ============================================================================
-- Сценарий 14 (часть): истёкшая подписка запрещает изменения, но не просмотр
-- ============================================================================
reset role;
update public.organization_subscriptions set trial_ends_at = now() - interval '1 day'
 where tenant_id = current_setting('test.org_a')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000000a1', 'owner.a@example.kz');
do $$ begin
  assert (select count(*) from public.organizations) = 1, 'expired trial must keep read access';
  assert (select count(*) from public.departments) = 1, 'expired trial must keep read access to data';
  begin
    insert into public.departments (tenant_id, name) values (current_setting('test.org_a')::uuid, 'Новый отдел');
    raise exception 'FAIL: write allowed on expired trial';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  14a  expired trial: read allowed, writes blocked';
end $$;

-- ============================================================================
-- Super admin видит организации и подписки, но не профили гостей/сотрудников чужих организаций
-- ============================================================================
reset role;
insert into public.platform_admins (user_id, note) values ('00000000-0000-0000-0000-0000000000ff', 'test');
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000000ff', 'stranger@example.kz');
do $$ begin
  assert (select count(*) from public.organizations) = 2, 'platform admin sees organizations';
  assert (select count(*) from public.organization_subscriptions) = 2, 'platform admin sees subscriptions';
  assert (select count(*) from public.organization_members) = 0, 'platform admin must not see staff lists';
  assert (select count(*) from public.user_profiles) = 1, 'platform admin sees only own profile';
  assert (select count(*) from public.audit_logs where tenant_id is not null) = 0,
    'platform admin must not read organization audit logs';
  perform public.admin_set_subscription_status(current_setting('test.org_b')::uuid, 'suspended');
  raise notice 'ok  SA   platform admin: organizations and subscriptions only';
end $$;

reset role;
\echo 'ALL TESTS PASSED'
