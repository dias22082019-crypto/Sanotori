-- Sanatorium OS: обновление базы, миграция 20261028000010_inventory.sql.
-- Supabase → SQL Editor → New query → вставить весь файл → Run. Каждое обновление применяется один раз.
-- Не редактируйте вручную: файл пересобирается скриптом scripts/build-setup-sql.sh
begin;

-- Sanatorium OS · 0010 · Склад
-- Принципы:
--  * остаток товара хранится в inventory_items.quantity, но меняется только функцией record_inventory_move:
--    каждое изменение — строка в inventory_movements с остатком после операции (история не правится и не удаляется);
--  * виды движений: приход, выдача (в номер или службе), списание (порча, брак — с причиной),
--    инвентаризация (вводится фактический остаток, разница записывается движением);
--  * уйти в минус нельзя: выдача и списание больше остатка отклоняются;
--  * склад — модуль тарифа «inventory»; при истёкшей подписке остатки и история читаются, но не меняются;
--  * права по умолчанию: смотреть — владелец, директор, бухгалтер, горничная; вести движения — владелец,
--    директор и бухгалтер (inventory.write).

create type public.inventory_category as enum ('linen', 'amenities', 'cleaning', 'food', 'medical', 'office', 'other');
create type public.inventory_move_kind as enum ('receipt', 'issue', 'writeoff', 'adjustment');

create table public.inventory_items (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.organizations(id) on delete cascade,
  name         text not null check (char_length(trim(name)) between 1 and 200),
  category     public.inventory_category not null default 'other',
  unit         text not null default 'шт' check (char_length(trim(unit)) between 1 and 20),
  quantity     numeric(14,3) not null default 0 check (quantity >= 0),
  min_quantity numeric(14,3) not null default 0 check (min_quantity >= 0 and min_quantity <= 100000000),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, name)
);

create table public.inventory_movements (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.organizations(id) on delete cascade,
  item_id       uuid not null,
  kind          public.inventory_move_kind not null,
  quantity      numeric(14,3) not null,           -- изменение остатка: плюс — приход, минус — расход
  balance_after numeric(14,3) not null check (balance_after >= 0),
  unit_cost     numeric(14,2) check (unit_cost >= 0 and unit_cost <= 100000000),
  room_id       uuid,
  note          text check (char_length(note) <= 500),
  created_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now(),
  foreign key (tenant_id, item_id) references public.inventory_items (tenant_id, id),
  foreign key (tenant_id, room_id) references public.rooms (tenant_id, id),
  constraint inventory_move_sign check (
    (kind = 'receipt' and quantity > 0) or (kind in ('issue', 'writeoff') and quantity < 0) or kind = 'adjustment'),
  constraint inventory_writeoff_reason check (kind <> 'writeoff' or char_length(trim(note)) > 0),
  constraint inventory_cost_on_receipt check (unit_cost is null or kind = 'receipt'),
  constraint inventory_room_on_issue check (room_id is null or kind = 'issue')
);
create index inventory_movements_item_idx on public.inventory_movements (tenant_id, item_id, created_at desc);
create index inventory_movements_tenant_date_idx on public.inventory_movements (tenant_id, created_at desc);

create trigger inventory_items_tenant before update on public.inventory_items
  for each row execute function app.forbid_tenant_change();
create trigger inventory_items_touch before update on public.inventory_items
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------------------
-- RLS и права на столбцы
-- ---------------------------------------------------------------------------

alter table public.inventory_items     enable row level security;
alter table public.inventory_movements enable row level security;

create policy inventory_items_select on public.inventory_items for select to authenticated
  using (app.has_permission(tenant_id, 'inventory.read'));
create policy inventory_items_insert on public.inventory_items for insert to authenticated
  with check (app.has_permission(tenant_id, 'inventory.write') and app.feature_enabled(tenant_id, 'inventory'));
create policy inventory_items_update on public.inventory_items for update to authenticated
  using (app.has_permission(tenant_id, 'inventory.write'))
  with check (app.has_permission(tenant_id, 'inventory.write') and app.feature_enabled(tenant_id, 'inventory'));

create policy inventory_movements_select on public.inventory_movements for select to authenticated
  using (app.has_permission(tenant_id, 'inventory.read'));

-- Остаток нельзя задать или поправить напрямую: только через движения
revoke all on public.inventory_items from anon;
revoke insert, update, delete on public.inventory_items from authenticated;
grant select on public.inventory_items to authenticated;
grant insert (tenant_id, name, category, unit, min_quantity, is_active) on public.inventory_items to authenticated;
grant update (name, category, unit, min_quantity, is_active) on public.inventory_items to authenticated;
revoke all on public.inventory_movements from anon;
revoke insert, update, delete on public.inventory_movements from authenticated;
grant select on public.inventory_movements to authenticated;

-- ---------------------------------------------------------------------------
-- Права по умолчанию для системных ролей
-- ---------------------------------------------------------------------------

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from (values ('director', 'inventory.write'), ('accountant', 'inventory.write'), ('housekeeping', 'inventory.read')) v(role_code, perm_code)
join public.roles r on r.code = v.role_code and r.tenant_id is null
join public.permissions p on p.code = v.perm_code
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Журнал: изменения карточек товаров (остаток пишет функция движения)
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
                            'amount', 'spent_on', 'timezone', 'default_language', 'slug', 'max_occupancy', 'base_occupancy',
                            'unit', 'category', 'min_quantity'];
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
    when 'inventory_items' then 'inventory_item'
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
    -- остаток товара меняет record_inventory_move(), он пишет своё событие
    if tg_table_name = 'inventory_items' and v_changed <@ array['quantity'] then
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

create trigger inventory_items_audit after insert or update on public.inventory_items
  for each row execute function app.audit_row_change();

-- ---------------------------------------------------------------------------
-- Движение по складу
-- ---------------------------------------------------------------------------

-- p_quantity: для прихода, выдачи и списания — количество (больше нуля);
-- для инвентаризации — фактический остаток (ноль и больше), записывается разница.
create or replace function public.record_inventory_move(
  p_item uuid, p_kind public.inventory_move_kind, p_quantity numeric,
  p_note text default null, p_unit_cost numeric default null, p_room uuid default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_item  public.inventory_items;
  v_delta numeric(14,3);
  v_bal   numeric(14,3);
  v_id    uuid;
  v_note  text := nullif(trim(p_note), '');
begin
  select * into v_item from public.inventory_items where id = p_item for update;
  if not found or not app.has_permission(v_item.tenant_id, 'inventory.write')
     or not app.feature_enabled(v_item.tenant_id, 'inventory') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_quantity is null or p_quantity < 0 or p_quantity > 100000000 or p_quantity <> round(p_quantity, 3)
     or (p_kind <> 'adjustment' and p_quantity = 0) then
    raise exception 'invalid quantity' using errcode = '22023';
  end if;
  if p_kind <> 'adjustment' and not v_item.is_active then
    raise exception 'item is archived' using errcode = '22023';
  end if;
  if p_kind = 'writeoff' and v_note is null then
    raise exception 'writeoff reason required' using errcode = '22023';
  end if;
  if p_unit_cost is not null and (p_kind <> 'receipt' or p_unit_cost < 0 or p_unit_cost <> round(p_unit_cost, 2)) then
    raise exception 'invalid unit cost' using errcode = '22023';
  end if;
  if p_room is not null and (p_kind <> 'issue'
     or not exists (select 1 from public.rooms where id = p_room and tenant_id = v_item.tenant_id)) then
    raise exception 'invalid room' using errcode = '22023';
  end if;

  v_delta := case p_kind when 'receipt' then p_quantity
                         when 'adjustment' then p_quantity - v_item.quantity
                         else -p_quantity end;
  v_bal := v_item.quantity + v_delta;
  if v_bal < 0 then
    raise exception 'not enough stock' using errcode = '22023';
  end if;

  update public.inventory_items set quantity = v_bal where id = p_item;
  insert into public.inventory_movements (tenant_id, item_id, kind, quantity, balance_after, unit_cost, room_id, note, created_by)
  values (v_item.tenant_id, p_item, p_kind, v_delta, v_bal, p_unit_cost, p_room, v_note, auth.uid())
  returning id into v_id;

  perform app.log_audit(v_item.tenant_id, 'inventory.' || p_kind::text, 'inventory_item', p_item, 'success',
    jsonb_build_object('name', v_item.name, 'quantity', v_delta, 'balance', v_bal, 'unit', v_item.unit)
    || case when v_note is not null and p_kind = 'writeoff' then jsonb_build_object('reason', v_note) else '{}'::jsonb end);
  return jsonb_build_object('id', v_id, 'balance', v_bal);
end $$;

revoke execute on function public.record_inventory_move(uuid, public.inventory_move_kind, numeric, text, numeric, uuid) from public, anon;
grant execute on function public.record_inventory_move(uuid, public.inventory_move_kind, numeric, text, numeric, uuid) to authenticated;

commit;
