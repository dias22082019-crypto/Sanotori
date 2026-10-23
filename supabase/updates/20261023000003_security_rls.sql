-- Sanatorium OS: обновление базы, миграция 20261023000003_security_rls.sql.
-- Supabase → SQL Editor → New query → вставить весь файл → Run. Каждое обновление применяется один раз.
-- Не редактируйте вручную: файл пересобирается скриптом scripts/build-setup-sql.sh
begin;

-- Sanatorium OS · 0003 · Функции проверки доступа, RLS и серверные операции
-- Принцип: клиент не пишет напрямую в таблицы членства, ролей и подписок.
-- Все изменения прав идут через функции ниже, которые сами проверяют права вызывающего.
-- Отказ (exception) откатывает транзакцию целиком, поэтому отклонённые попытки в audit_logs
-- не попадают: их фиксируют логи API Supabase и Edge Functions.

-- ---------------------------------------------------------------------------
-- Функции проверки доступа (security definer: читают таблицы прав в обход RLS,
-- чтобы политики не вызывали друг друга рекурсивно)
-- ---------------------------------------------------------------------------

create or replace function app.is_platform_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid())
$$;

create or replace function app.is_member(p_tenant uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.organization_members m
    where m.tenant_id = p_tenant and m.user_id = auth.uid() and m.status = 'active'
  )
$$;

create or replace function app.has_permission(p_tenant uuid, p_code text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.organization_members m
    join public.role_permissions rp on rp.role_id = m.role_id
    join public.permissions p on p.id = rp.permission_id
    where m.tenant_id = p_tenant and m.user_id = auth.uid()
      and m.status = 'active' and p.code = p_code
  )
$$;

create or replace function app.member_role_code(p_tenant uuid) returns text
language sql stable security definer set search_path = '' as $$
  select r.code
  from public.organization_members m join public.roles r on r.id = m.role_id
  where m.tenant_id = p_tenant and m.user_id = auth.uid() and m.status = 'active'
$$;

-- Текущая подписка позволяет изменять данные (просмотр и экспорт не ограничиваются никогда)
create or replace function app.subscription_writable(p_tenant uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.organization_subscriptions s
    where s.tenant_id = p_tenant
      and (
        (s.status = 'trialing' and s.trial_ends_at > now())
        or (s.status = 'active' and (s.current_period_end is null or s.current_period_end > now()))
        or (s.status = 'past_due'
            and coalesce(s.current_period_end, s.trial_ends_at) + make_interval(days => s.grace_days) > now())
      )
  )
$$;

-- Функция тарифа включена и подписка позволяет изменения
create or replace function app.feature_enabled(p_tenant uuid, p_feature text) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.subscription_writable(p_tenant) and exists (
    select 1
    from public.organization_subscriptions s
    join public.plan_features f on f.plan_id = s.plan_id
    where s.tenant_id = p_tenant and s.status <> 'cancelled' and f.feature_code = p_feature
  )
$$;

-- Может ли текущий пользователь выдать роль (защита от повышения прав):
-- владелец может выдать любую роль; остальные — только роль, все права которой есть у них самих,
-- и никто, кроме владельца, не выдаёт роль owner.
create or replace function app.can_grant_role(p_tenant uuid, p_role_id uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_role public.roles;
  v_caller_role text := app.member_role_code(p_tenant);
begin
  select * into v_role from public.roles where id = p_role_id;
  if not found or (v_role.tenant_id is not null and v_role.tenant_id <> p_tenant) then
    return false;
  end if;
  if v_caller_role is null or not app.has_permission(p_tenant, 'members.manage') then
    return false;
  end if;
  if v_caller_role = 'owner' then
    return true;
  end if;
  if v_role.code = 'owner' then
    return false;
  end if;
  return not exists (
    select 1 from public.role_permissions rp
    join public.permissions p on p.id = rp.permission_id
    where rp.role_id = p_role_id and not app.has_permission(p_tenant, p.code)
  );
end $$;

-- Запись в журнал: только из серверных функций
create or replace function app.log_audit(
  p_tenant uuid, p_action text, p_entity_type text, p_entity_id uuid,
  p_result public.audit_result default 'success', p_details jsonb default '{}'::jsonb
) returns void
language sql security definer set search_path = '' as $$
  insert into public.audit_logs (tenant_id, actor_user_id, action, entity_type, entity_id, result, details)
  values (p_tenant, auth.uid(), p_action, p_entity_type, p_entity_id, p_result, coalesce(p_details, '{}'::jsonb))
$$;

grant usage on schema app to anon, authenticated, service_role;
revoke all on all functions in schema app from public;
grant execute on function
  app.is_platform_admin(), app.is_member(uuid), app.has_permission(uuid, text),
  app.member_role_code(uuid), app.subscription_writable(uuid), app.feature_enabled(uuid, text),
  app.can_grant_role(uuid, uuid)
  to anon, authenticated, service_role;
-- log_audit вызывают только серверные функции (они выполняются от владельца схемы)

-- ---------------------------------------------------------------------------
-- RLS: включаем на всех таблицах. Нет политики на операцию = операция запрещена.
-- ---------------------------------------------------------------------------

alter table public.organizations              enable row level security;
alter table public.user_profiles              enable row level security;
alter table public.platform_admins            enable row level security;
alter table public.permissions                enable row level security;
alter table public.roles                      enable row level security;
alter table public.role_permissions           enable row level security;
alter table public.departments                enable row level security;
alter table public.organization_members       enable row level security;
alter table public.invitations                enable row level security;
alter table public.support_access_grants      enable row level security;
alter table public.audit_logs                 enable row level security;
alter table public.subscription_plans         enable row level security;
alter table public.plan_features              enable row level security;
alter table public.organization_subscriptions enable row level security;
alter table public.subscription_invoices      enable row level security;

-- organizations: читать могут участники и админ платформы; менять — settings.manage.
-- Создание только через create_organization(), удаление не предусмотрено.
create policy organizations_select on public.organizations for select to authenticated
  using (app.is_member(id) or app.is_platform_admin());
create policy organizations_update on public.organizations for update to authenticated
  using (app.has_permission(id, 'settings.manage'))
  with check (app.has_permission(id, 'settings.manage'));

-- Защищённые поля организации меняются только серверными функциями
create or replace function app.protect_org_columns() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon')
     and (new.slug is distinct from old.slug
          or new.created_by is distinct from old.created_by
          or new.parent_org_id is distinct from old.parent_org_id) then
    raise exception 'protected organization fields' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger organizations_protect before update on public.organizations
  for each row execute function app.protect_org_columns();

-- user_profiles: свой профиль + профили коллег по организации (имя для списков сотрудников)
create policy user_profiles_select on public.user_profiles for select to authenticated
  using (
    id = auth.uid()
    or exists (
      select 1 from public.organization_members them
      where them.user_id = user_profiles.id and app.is_member(them.tenant_id)
    )
  );
create policy user_profiles_update on public.user_profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- platform_admins: пользователь видит только свою запись (чтобы UI знал, показывать ли /admin)
create policy platform_admins_select on public.platform_admins for select to authenticated
  using (user_id = auth.uid());

-- Справочники прав и ролей: только чтение
create policy permissions_select on public.permissions for select to authenticated using (true);
create policy roles_select on public.roles for select to authenticated
  using (tenant_id is null or app.is_member(tenant_id));
create policy role_permissions_select on public.role_permissions for select to authenticated
  using (exists (select 1 from public.roles r
                 where r.id = role_id and (r.tenant_id is null or app.is_member(r.tenant_id))));

-- departments
create policy departments_select on public.departments for select to authenticated
  using (app.is_member(tenant_id));
create policy departments_insert on public.departments for insert to authenticated
  with check (app.has_permission(tenant_id, 'members.manage') and app.subscription_writable(tenant_id));
create policy departments_update on public.departments for update to authenticated
  using (app.has_permission(tenant_id, 'members.manage'))
  with check (app.has_permission(tenant_id, 'members.manage'));
create policy departments_delete on public.departments for delete to authenticated
  using (app.has_permission(tenant_id, 'members.manage'));

-- organization_members: участники видят коллег; запись только через функции
create policy organization_members_select on public.organization_members for select to authenticated
  using (app.is_member(tenant_id) or user_id = auth.uid());

-- invitations: видят те, кто управляет сотрудниками
create policy invitations_select on public.invitations for select to authenticated
  using (app.has_permission(tenant_id, 'members.manage'));

-- support_access_grants: владелец видит выданные доступы, админ платформы — свои
create policy support_access_grants_select on public.support_access_grants for select to authenticated
  using (app.has_permission(tenant_id, 'settings.manage') or grantee_user_id = auth.uid());

-- audit_logs: только чтение по праву audit.read; события платформы (tenant_id is null) — админу
create policy audit_logs_select on public.audit_logs for select to authenticated
  using ((tenant_id is not null and app.has_permission(tenant_id, 'audit.read'))
         or (tenant_id is null and app.is_platform_admin()));

-- Тарифы: публичные активные видны всем (для страницы цен), все — админу платформы
create policy subscription_plans_select_public on public.subscription_plans for select to anon, authenticated
  using ((is_active and is_public) or app.is_platform_admin());
create policy subscription_plans_admin_insert on public.subscription_plans for insert to authenticated
  with check (app.is_platform_admin());
create policy subscription_plans_admin_update on public.subscription_plans for update to authenticated
  using (app.is_platform_admin()) with check (app.is_platform_admin());

create policy plan_features_select on public.plan_features for select to anon, authenticated
  using (exists (select 1 from public.subscription_plans p
                 where p.id = plan_id and ((p.is_active and p.is_public) or app.is_platform_admin())));
create policy plan_features_admin_insert on public.plan_features for insert to authenticated
  with check (app.is_platform_admin());
create policy plan_features_admin_delete on public.plan_features for delete to authenticated
  using (app.is_platform_admin());

-- Подписки: участники видят статус своей; админ платформы — все. Изменение — только функциями.
create policy organization_subscriptions_select on public.organization_subscriptions for select to authenticated
  using (app.is_member(tenant_id) or app.is_platform_admin());

create policy subscription_invoices_select on public.subscription_invoices for select to authenticated
  using (app.has_permission(tenant_id, 'billing.manage') or app.is_platform_admin());

-- ---------------------------------------------------------------------------
-- Серверные операции (RPC). Каждая сама проверяет права и пишет журнал.
-- ---------------------------------------------------------------------------

-- Регистрация санатория: вызывающий становится owner, стартует пробный период
create or replace function public.create_organization(
  p_name text, p_slug text, p_city text default null, p_language public.app_language default 'ru'
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid    uuid := auth.uid();
  v_org_id uuid;
  v_plan   public.subscription_plans;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if (select count(*) from public.organizations where created_by = v_uid) >= 5 then
    raise exception 'organization limit reached' using errcode = '54000';
  end if;

  insert into public.organizations (name, slug, city, default_language, created_by)
  values (trim(p_name), lower(trim(p_slug)), nullif(trim(p_city), ''), p_language, v_uid)
  returning id into v_org_id;

  insert into public.organization_members (tenant_id, user_id, role_id, status)
  select v_org_id, v_uid, r.id, 'active' from public.roles r where r.code = 'owner' and r.tenant_id is null;

  select * into v_plan from public.subscription_plans where code = 'business' and is_active;
  if found then
    insert into public.organization_subscriptions (tenant_id, plan_id, status, trial_ends_at)
    values (v_org_id, v_plan.id, 'trialing', now() + make_interval(days => v_plan.trial_days));
  end if;

  perform app.log_audit(v_org_id, 'organization.create', 'organization', v_org_id);
  return v_org_id;
end $$;

-- Приглашение сотрудника. Возвращает токен один раз; в базе хранится только хэш.
create or replace function public.invite_member(p_tenant uuid, p_email text, p_role_id uuid)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_token text;
  v_email text := lower(trim(p_email));
  v_staff_count integer;
  v_max_staff integer;
begin
  if not app.can_grant_role(p_tenant, p_role_id) then
    raise exception 'not allowed to grant this role' using errcode = '42501';
  end if;
  if not app.subscription_writable(p_tenant) then
    raise exception 'subscription does not allow changes' using errcode = '42501';
  end if;

  select count(*) into v_staff_count from public.organization_members
   where tenant_id = p_tenant and status = 'active';
  select p.max_staff into v_max_staff
    from public.organization_subscriptions s join public.subscription_plans p on p.id = s.plan_id
   where s.tenant_id = p_tenant and s.status <> 'cancelled';
  if v_max_staff is not null and v_staff_count >= v_max_staff then
    raise exception 'staff limit of the plan reached' using errcode = '54000';
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  -- закрываем прежнее открытое приглашение на этот email
  update public.invitations set revoked_at = now()
   where tenant_id = p_tenant and email = v_email and accepted_at is null and revoked_at is null;

  insert into public.invitations (tenant_id, email, role_id, token_hash, invited_by)
  values (p_tenant, v_email, p_role_id, sha256(convert_to(v_token, 'UTF8')), auth.uid());

  perform app.log_audit(p_tenant, 'member.invite', 'role', p_role_id, 'success',
                        jsonb_build_object('email_domain', split_part(v_email, '@', 2)));
  return v_token;
end $$;

-- Принятие приглашения: email в токене Supabase должен совпадать с адресом приглашения
create or replace function public.accept_invitation(p_token text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(auth.jwt() ->> 'email');
  v_inv   public.invitations;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select * into v_inv from public.invitations
   where token_hash = sha256(convert_to(p_token, 'UTF8'))
     and accepted_at is null and revoked_at is null and expires_at > now()
   for update;
  if not found then
    raise exception 'invitation is invalid or expired' using errcode = 'P0002';
  end if;
  if v_inv.email <> v_email then
    raise exception 'invitation was sent to another email' using errcode = '42501';
  end if;

  insert into public.organization_members (tenant_id, user_id, role_id, status, invited_by)
  values (v_inv.tenant_id, v_uid, v_inv.role_id, 'active', v_inv.invited_by)
  on conflict (tenant_id, user_id) do update set role_id = excluded.role_id, status = 'active';

  update public.invitations set accepted_at = now(), accepted_by = v_uid where id = v_inv.id;
  perform app.log_audit(v_inv.tenant_id, 'member.accept', 'invitation', v_inv.id);
  return v_inv.tenant_id;
end $$;

-- Смена роли сотрудника
create or replace function public.assign_member_role(p_member_id uuid, p_role_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_member public.organization_members;
  v_old_code text;
begin
  select * into v_member from public.organization_members where id = p_member_id for update;
  if not found then
    raise exception 'member not found' using errcode = 'P0002';
  end if;
  if v_member.user_id = auth.uid() then
    raise exception 'cannot change own role' using errcode = '42501';
  end if;
  if not app.can_grant_role(v_member.tenant_id, p_role_id) then
    raise exception 'not allowed to grant this role' using errcode = '42501';
  end if;

  select code into v_old_code from public.roles where id = v_member.role_id;
  if v_old_code = 'owner' and app.member_role_code(v_member.tenant_id) <> 'owner' then
    raise exception 'only an owner can change another owner' using errcode = '42501';
  end if;

  update public.organization_members set role_id = p_role_id where id = p_member_id;
  perform app.log_audit(v_member.tenant_id, 'member.role_change', 'member', p_member_id, 'success',
                        jsonb_build_object('from', v_old_code,
                                           'to', (select code from public.roles where id = p_role_id)));
end $$;

-- Приостановка / возобновление доступа сотрудника
create or replace function public.set_member_status(p_member_id uuid, p_status public.member_status)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_member public.organization_members;
  v_code text;
begin
  select * into v_member from public.organization_members where id = p_member_id for update;
  if not found then
    raise exception 'member not found' using errcode = 'P0002';
  end if;
  if v_member.user_id = auth.uid() or not app.has_permission(v_member.tenant_id, 'members.manage') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select code into v_code from public.roles where id = v_member.role_id;
  if v_code = 'owner' and app.member_role_code(v_member.tenant_id) <> 'owner' then
    raise exception 'only an owner can suspend another owner' using errcode = '42501';
  end if;

  update public.organization_members set status = p_status where id = p_member_id;
  perform app.log_audit(v_member.tenant_id, 'member.status_change', 'member', p_member_id, 'success',
                        jsonb_build_object('status', p_status));
end $$;

-- В организации всегда остаётся хотя бы один активный владелец
create or replace function app.keep_one_owner() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_owner_role uuid := (select id from public.roles where code = 'owner' and tenant_id is null);
begin
  if old.role_id = v_owner_role and old.status = 'active'
     and (tg_op = 'DELETE' or new.role_id <> v_owner_role or new.status <> 'active')
     and not exists (
       select 1 from public.organization_members m
       where m.tenant_id = old.tenant_id and m.id <> old.id
         and m.role_id = v_owner_role and m.status = 'active')
  then
    raise exception 'organization must keep at least one active owner' using errcode = '23514';
  end if;
  return coalesce(new, old);
end $$;

create trigger organization_members_keep_owner before update or delete on public.organization_members
  for each row execute function app.keep_one_owner();

-- Пользовательская роль (custom): только права, которые есть у создателя; медицинские — нельзя
create or replace function public.upsert_custom_role(
  p_tenant uuid, p_code text, p_name_ru text, p_name_kk text, p_permission_codes text[]
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_role_id uuid;
  v_bad text;
begin
  if not app.has_permission(p_tenant, 'roles.manage') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not app.feature_enabled(p_tenant, 'custom_roles') then
    raise exception 'custom roles are not included in the plan' using errcode = '42501';
  end if;

  select c into v_bad from unnest(p_permission_codes) c
   where not exists (select 1 from public.permissions p where p.code = c)
      or exists (select 1 from public.permissions p where p.code = c and p.is_medical)
      or not app.has_permission(p_tenant, c)
   limit 1;
  if v_bad is not null then
    raise exception 'permission % cannot be granted', v_bad using errcode = '42501';
  end if;

  insert into public.roles (tenant_id, code, name_ru, name_kk, is_system)
  values (p_tenant, p_code, p_name_ru, p_name_kk, false)
  on conflict (tenant_id, code) do update set name_ru = excluded.name_ru, name_kk = excluded.name_kk
  returning id into v_role_id;

  delete from public.role_permissions where role_id = v_role_id;
  insert into public.role_permissions (role_id, permission_id)
  select v_role_id, p.id from public.permissions p where p.code = any (p_permission_codes);

  perform app.log_audit(p_tenant, 'role.upsert', 'role', v_role_id, 'success',
                        jsonb_build_object('permissions', p_permission_codes));
  return v_role_id;
end $$;

-- Список организаций текущего пользователя (для экрана выбора организации)
create or replace function public.my_organizations()
returns table (tenant_id uuid, slug text, name text, role_code text, logo_path text)
language sql stable security definer set search_path = '' as $$
  select o.id, o.slug, o.name, r.code, o.logo_path
  from public.organization_members m
  join public.organizations o on o.id = m.tenant_id
  join public.roles r on r.id = m.role_id
  where m.user_id = auth.uid() and m.status = 'active'
  order by o.name
$$;

-- Права текущего пользователя в организации (UI скрывает недоступное; решает всё равно RLS)
create or replace function public.my_permissions(p_tenant uuid) returns text[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(p.code order by p.code), '{}')
  from public.organization_members m
  join public.role_permissions rp on rp.role_id = m.role_id
  join public.permissions p on p.id = rp.permission_id
  where m.tenant_id = p_tenant and m.user_id = auth.uid() and m.status = 'active'
$$;

-- Супер-админ: приостановка / возобновление подписки организации
create or replace function public.admin_set_subscription_status(p_tenant uuid, p_status public.subscription_status)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not app.is_platform_admin() then
    raise exception 'platform admin only' using errcode = '42501';
  end if;
  update public.organization_subscriptions set status = p_status
   where tenant_id = p_tenant and status <> 'cancelled';
  if not found then
    raise exception 'subscription not found' using errcode = 'P0002';
  end if;
  perform app.log_audit(null, 'admin.subscription_status', 'organization', p_tenant, 'success',
                        jsonb_build_object('status', p_status));
end $$;

-- Доступ к функциям: только вошедшим пользователям
revoke execute on function
  public.create_organization(text, text, text, public.app_language),
  public.invite_member(uuid, text, uuid),
  public.accept_invitation(text),
  public.assign_member_role(uuid, uuid),
  public.set_member_status(uuid, public.member_status),
  public.upsert_custom_role(uuid, text, text, text, text[]),
  public.my_organizations(),
  public.my_permissions(uuid),
  public.admin_set_subscription_status(uuid, public.subscription_status)
  from public, anon;
grant execute on function
  public.create_organization(text, text, text, public.app_language),
  public.invite_member(uuid, text, uuid),
  public.accept_invitation(text),
  public.assign_member_role(uuid, uuid),
  public.set_member_status(uuid, public.member_status),
  public.upsert_custom_role(uuid, text, text, text, text[]),
  public.my_organizations(),
  public.my_permissions(uuid),
  public.admin_set_subscription_status(uuid, public.subscription_status)
  to authenticated;

commit;
