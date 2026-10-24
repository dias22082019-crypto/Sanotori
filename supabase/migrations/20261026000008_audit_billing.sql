-- Sanatorium OS · 0008 · Журнал действий и подписка
-- Принципы:
--  * журнал пополняется не только серверными функциями, но и триггерами на справочниках и настройках:
--    видно, кто и когда изменил цену номера, процедуры или настройки санатория;
--  * по гостям в журнал попадают только названия изменённых полей, без значений (персональные данные);
--  * онлайн-оплаты подписки нет: владелец санатория оставляет заявку на тариф, владелец платформы
--    получает оплату вне системы и включает тариф вручную (admin_set_plan). Счёт или «успешную оплату»
--    система не изображает;
--  * заявку можно оставить и при истёкшей подписке — иначе из неё не выбраться.

-- ---------------------------------------------------------------------------
-- Журнал изменений справочников и настроек
-- ---------------------------------------------------------------------------

create or replace function app.audit_row_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_new     jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_old     jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_row     jsonb := coalesce(v_new, v_old);
  v_tenant  uuid;
  v_entity  text;
  v_changed text[];
  v_values  jsonb := '{}'::jsonb;
  v_key     text;
  -- поля, значения которых не являются персональными данными и полезны в журнале
  v_tracked text[] := array['name', 'number', 'base_price', 'extra_guest_price', 'price_per_night', 'price',
                            'duration_min', 'starts_on', 'ends_on', 'is_active', 'is_public', 'is_published',
                            'amount', 'spent_on', 'timezone', 'default_language', 'slug', 'max_occupancy', 'base_occupancy'];
begin
  v_entity := case tg_table_name
    when 'organizations' then 'settings'
    when 'room_types' then 'room_type'
    when 'room_rates' then 'room_rate'
    when 'rooms' then 'room'
    when 'procedure_types' then 'procedure_type'
    when 'treatment_rooms' then 'treatment_room'
    when 'expense_categories' then 'expense_category'
    when 'expenses' then 'expense'
    when 'guests' then 'guest'
    else tg_table_name end;
  v_tenant := case when tg_table_name = 'organizations' then (v_row ->> 'id')::uuid else (v_row ->> 'tenant_id')::uuid end;
  -- удаление санатория целиком (каскад) в журнал не пишем: строка организации уже удалена
  if tg_op = 'DELETE' and not exists (select 1 from public.organizations where id = v_tenant) then
    return null;
  end if;

  if tg_op = 'UPDATE' then
    select coalesce(array_agg(k order by k), '{}') into v_changed
    from jsonb_object_keys(v_new) k
    where k not in ('updated_at', 'created_at') and v_new -> k is distinct from v_old -> k;
    if cardinality(v_changed) = 0 then
      return null;
    end if;
    -- статус номера пишет set_room_status(), дубль не нужен
    if tg_table_name = 'rooms' and v_changed <@ array['status'] then
      return null;
    end if;
    if tg_table_name <> 'guests' then
      foreach v_key in array v_changed loop
        if v_key = any (v_tracked) then
          v_values := v_values || jsonb_build_object(v_key, jsonb_build_object('from', v_old -> v_key, 'to', v_new -> v_key));
        end if;
      end loop;
    end if;
    perform app.log_audit(v_tenant, v_entity || '.update', v_entity, (v_row ->> 'id')::uuid, 'success',
      jsonb_build_object('changed', to_jsonb(v_changed)) || case when v_values = '{}'::jsonb then '{}'::jsonb
                                                                  else jsonb_build_object('values', v_values) end);
  else
    if tg_table_name <> 'guests' then
      foreach v_key in array v_tracked loop
        if v_row ? v_key and v_row -> v_key <> 'null'::jsonb then
          v_values := v_values || jsonb_build_object(v_key, v_row -> v_key);
        end if;
      end loop;
    end if;
    perform app.log_audit(v_tenant, v_entity || case when tg_op = 'INSERT' then '.create' else '.delete' end,
      v_entity, (v_row ->> 'id')::uuid, 'success', v_values);
  end if;
  return null;
end $$;

create trigger organizations_audit after update on public.organizations
  for each row execute function app.audit_row_change();
create trigger room_types_audit after insert or update or delete on public.room_types
  for each row execute function app.audit_row_change();
create trigger room_rates_audit after insert or update or delete on public.room_rates
  for each row execute function app.audit_row_change();
create trigger rooms_audit after insert or update or delete on public.rooms
  for each row execute function app.audit_row_change();
create trigger procedure_types_audit after insert or update on public.procedure_types
  for each row execute function app.audit_row_change();
create trigger treatment_rooms_audit after insert or update on public.treatment_rooms
  for each row execute function app.audit_row_change();
create trigger expense_categories_audit after insert or update on public.expense_categories
  for each row execute function app.audit_row_change();
create trigger expenses_audit after insert on public.expenses
  for each row execute function app.audit_row_change();
create trigger guests_audit after insert or update on public.guests
  for each row execute function app.audit_row_change();

revoke execute on function app.audit_row_change() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Подписка: сводка для владельца, заявка на тариф, ручное включение тарифа владельцем платформы
-- ---------------------------------------------------------------------------

create type public.plan_request_status as enum ('open', 'done', 'cancelled');

create table public.plan_change_requests (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.organizations(id) on delete cascade,
  plan_id        uuid not null references public.subscription_plans(id),
  billing_period public.billing_period not null default 'monthly',
  note           text check (char_length(note) <= 1000),
  status         public.plan_request_status not null default 'open',
  requested_by   uuid references auth.users(id) on delete set null,
  resolved_by    uuid references auth.users(id) on delete set null,
  resolved_at    timestamptz,
  created_at     timestamptz not null default now()
);
create unique index plan_change_requests_one_open on public.plan_change_requests (tenant_id) where status = 'open';
create index plan_change_requests_status_idx on public.plan_change_requests (status, created_at desc);

alter table public.plan_change_requests enable row level security;
create policy plan_change_requests_select on public.plan_change_requests for select to authenticated
  using (app.has_permission(tenant_id, 'billing.manage') or app.is_platform_admin());

-- Сводка подписки: тариф, сроки, лимиты и их использование, модули тарифа (billing.manage).
-- Работает и при истёкшей подписке.
create or replace function public.subscription_overview(p_tenant uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_s public.organization_subscriptions;
  v_p public.subscription_plans;
begin
  if not app.has_permission(p_tenant, 'billing.manage') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  select * into v_s from public.organization_subscriptions where tenant_id = p_tenant and status <> 'cancelled';
  if not found then
    raise exception 'subscription not found' using errcode = 'P0002';
  end if;
  select * into v_p from public.subscription_plans where id = v_s.plan_id;
  return jsonb_build_object(
    'plan_code', v_p.code, 'plan_name_ru', v_p.name_ru, 'plan_name_kk', v_p.name_kk,
    'status', v_s.status, 'billing_period', v_s.billing_period,
    'trial_ends_at', v_s.trial_ends_at, 'current_period_end', v_s.current_period_end, 'grace_days', v_s.grace_days,
    'writable', app.subscription_writable(p_tenant),
    'staff_count', (select count(*) from public.organization_members where tenant_id = p_tenant and status = 'active'),
    'max_staff', v_p.max_staff,
    'rooms_count', (select count(*) from public.rooms where tenant_id = p_tenant and is_active),
    'max_rooms', v_p.max_rooms,
    'features', (select coalesce(jsonb_agg(feature_code order by feature_code), '[]'::jsonb)
                 from public.plan_features where plan_id = v_p.id),
    'open_request', (select jsonb_build_object('id', r.id, 'plan_code', p.code, 'billing_period', r.billing_period, 'created_at', r.created_at)
                     from public.plan_change_requests r join public.subscription_plans p on p.id = r.plan_id
                     where r.tenant_id = p_tenant and r.status = 'open')
  );
end $$;

-- Заявка на тариф (billing.manage). Новая заявка заменяет открытую. Доступна и при истёкшей подписке.
create or replace function public.request_plan_change(
  p_tenant uuid, p_plan_code text, p_period public.billing_period default 'monthly', p_note text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_plan public.subscription_plans; v_id uuid;
begin
  if not app.has_permission(p_tenant, 'billing.manage') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  select * into v_plan from public.subscription_plans where code = p_plan_code and is_active and is_public;
  if not found then
    raise exception 'plan not found' using errcode = '22023';
  end if;
  update public.plan_change_requests set status = 'cancelled', resolved_at = now(), resolved_by = auth.uid()
  where tenant_id = p_tenant and status = 'open';
  insert into public.plan_change_requests (tenant_id, plan_id, billing_period, note, requested_by)
  values (p_tenant, v_plan.id, coalesce(p_period, 'monthly'), nullif(trim(p_note), ''), auth.uid())
  returning id into v_id;
  perform app.log_audit(p_tenant, 'billing.request', 'plan_change_request', v_id, 'success',
    jsonb_build_object('plan', v_plan.code, 'period', p_period));
  return v_id;
end $$;

create or replace function public.cancel_plan_request(p_request_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_r public.plan_change_requests;
begin
  select * into v_r from public.plan_change_requests where id = p_request_id for update;
  if not found or not app.has_permission(v_r.tenant_id, 'billing.manage') or v_r.status <> 'open' then
    raise exception 'request not found' using errcode = 'P0002';
  end if;
  update public.plan_change_requests set status = 'cancelled', resolved_at = now(), resolved_by = auth.uid()
  where id = p_request_id;
  perform app.log_audit(v_r.tenant_id, 'billing.request_cancel', 'plan_change_request', p_request_id, 'success', '{}'::jsonb);
end $$;

-- Владелец платформы включает тариф после оплаты вне системы. Открытая заявка закрывается.
-- Событие пишется в журнал санатория, чтобы владелец видел, кто и когда сменил тариф.
create or replace function public.admin_set_plan(
  p_tenant uuid, p_plan_code text, p_period public.billing_period, p_period_end timestamptz
) returns void
language plpgsql security definer set search_path = '' as $$
declare v_plan public.subscription_plans; v_old text;
begin
  if not app.is_platform_admin() then
    raise exception 'platform admin only' using errcode = '42501';
  end if;
  select * into v_plan from public.subscription_plans where code = p_plan_code and is_active;
  if not found then
    raise exception 'plan not found' using errcode = '22023';
  end if;
  if p_period_end is null or p_period_end <= now() then
    raise exception 'period end must be in the future' using errcode = '22023';
  end if;
  select p.code into v_old from public.organization_subscriptions s join public.subscription_plans p on p.id = s.plan_id
  where s.tenant_id = p_tenant and s.status <> 'cancelled';
  update public.organization_subscriptions
  set plan_id = v_plan.id, billing_period = coalesce(p_period, 'monthly'), status = 'active',
      current_period_start = now(), current_period_end = p_period_end
  where tenant_id = p_tenant and status <> 'cancelled';
  if not found then
    raise exception 'subscription not found' using errcode = 'P0002';
  end if;
  update public.plan_change_requests set status = 'done', resolved_at = now(), resolved_by = auth.uid()
  where tenant_id = p_tenant and status = 'open';
  perform app.log_audit(p_tenant, 'billing.plan_set', 'organization', p_tenant, 'success',
    jsonb_build_object('from', v_old, 'plan', v_plan.code, 'period', p_period, 'until', p_period_end));
end $$;

revoke execute on function
  public.subscription_overview(uuid),
  public.request_plan_change(uuid, text, public.billing_period, text),
  public.cancel_plan_request(uuid),
  public.admin_set_plan(uuid, text, public.billing_period, timestamptz)
  from public, anon;
grant execute on function
  public.subscription_overview(uuid),
  public.request_plan_change(uuid, text, public.billing_period, text),
  public.cancel_plan_request(uuid),
  public.admin_set_plan(uuid, text, public.billing_period, timestamptz)
  to authenticated;
