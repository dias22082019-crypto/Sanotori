-- Тесты склада: движения и остатки, запрет минуса и прямой правки, права, изоляция, подписка (сценарии ТЗ 3, 10, 14, 20)
\set ON_ERROR_STOP on
\set QUIET on

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000008a1', 'owner8a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000008a2', 'reception8a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000008a3', 'accountant8a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000008a4', 'maid8a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000008b1', 'owner8b@example.kz', now());

set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000008a1', 'owner8a@example.kz');
select public.create_organization('Сарыагаш Склад', 'sklad-8', 'Сарыагаш') as org8a \gset
select tests.login('00000000-0000-0000-0000-0000000008b1', 'owner8b@example.kz');
select public.create_organization('Алматы Тау', 'tau-8', 'Алматы') as org8b \gset
reset role;
select set_config('t8.a', :'org8a', false), set_config('t8.b', :'org8b', false) \gset

insert into public.organization_members (tenant_id, user_id, role_id, status)
select :'org8a', u, r.id, 'active'
from (values ('00000000-0000-0000-0000-0000000008a2'::uuid, 'receptionist'),
             ('00000000-0000-0000-0000-0000000008a3'::uuid, 'accountant'),
             ('00000000-0000-0000-0000-0000000008a4'::uuid, 'housekeeping')) v(u, code)
join public.roles r on r.code = v.code and r.tenant_id is null;

set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000008a1', 'owner8a@example.kz');
insert into public.inventory_items (tenant_id, name, category, unit, min_quantity)
values (:'org8a', 'Полотенце банное', 'linen', 'шт', 40) returning id as item8 \gset
insert into public.room_types (tenant_id, name, base_price) values (:'org8a', 'Стандарт', 20000) returning id as rt8 \gset
insert into public.rooms (tenant_id, room_type_id, number) values (:'org8a', :'rt8', '101') returning id as room8 \gset
reset role;
select set_config('t8.item', :'item8', false), set_config('t8.room', :'room8', false) \gset

-- ============================================================================
-- Движения: приход, выдача в номер, списание с причиной, инвентаризация; остаток не уходит в минус
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000008a3', 'accountant8a@example.kz');
do $$
declare i uuid := current_setting('t8.item')::uuid; r jsonb;
begin
  r := public.record_inventory_move(i, 'receipt', 100, 'накладная 15', 1800);
  assert (r ->> 'balance')::numeric = 100, format('after receipt: %s', r);
  r := public.record_inventory_move(i, 'issue', 12, null, null, current_setting('t8.room')::uuid);
  assert (r ->> 'balance')::numeric = 88, 'after issue';
  begin
    perform public.record_inventory_move(i, 'writeoff', 3, '  ');
    raise exception 'FAIL: writeoff without reason';
  exception when invalid_parameter_value then null;
  end;
  r := public.record_inventory_move(i, 'writeoff', 3, 'порваны');
  begin
    perform public.record_inventory_move(i, 'issue', 86);
    raise exception 'FAIL: stock went negative';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.record_inventory_move(i, 'issue', 0);
    raise exception 'FAIL: zero issue accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.record_inventory_move(i, 'issue', 1, null, 500);
    raise exception 'FAIL: cost on issue accepted';
  exception when invalid_parameter_value then null;
  end;
  r := public.record_inventory_move(i, 'adjustment', 80, 'пересчёт');
  assert (r ->> 'balance')::numeric = 80, 'adjustment sets counted stock';
  assert (select quantity from public.inventory_items where id = i) = 80, 'item quantity follows movements';
  assert (select array_agg(quantity order by created_at, balance_after desc) from public.inventory_movements where item_id = i)
         = array[100, -12, -3, -5]::numeric[], 'movement deltas';
  assert (select sum(quantity) from public.inventory_movements where item_id = i) = 80, 'history sums to stock';
  raise notice 'ok  20a  receipt, issue to room, writeoff with reason, stock count; never negative';
end $$;

-- ============================================================================
-- Остаток и история не правятся напрямую
-- ============================================================================
do $$
declare i uuid := current_setting('t8.item')::uuid;
begin
  begin
    update public.inventory_items set quantity = 1000 where id = i;
    raise exception 'FAIL: quantity edited directly';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.inventory_items (tenant_id, name, quantity) values (current_setting('t8.a')::uuid, 'Мыло', 500);
    raise exception 'FAIL: item created with stock';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.inventory_movements (tenant_id, item_id, kind, quantity, balance_after)
    values (current_setting('t8.a')::uuid, i, 'receipt', 5, 85);
    raise exception 'FAIL: movement inserted directly';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.inventory_movements where item_id = i;
    if found then raise exception 'FAIL: history deleted'; end if;
  exception when insufficient_privilege then null;
  end;
  update public.inventory_items set min_quantity = 50, unit = 'шт.' where id = i;
  assert (select min_quantity from public.inventory_items where id = i) = 50, 'card fields editable';
  raise notice 'ok  20b  stock and history only through record_inventory_move';
end $$;

-- ============================================================================
-- Права: горничная видит, но не двигает; ресепшен не видит; другой санаторий не видит
-- ============================================================================
select tests.login('00000000-0000-0000-0000-0000000008a4', 'maid8a@example.kz');
do $$
begin
  assert (select count(*) from public.inventory_items) = 1, 'maid sees stock';
  begin
    perform public.record_inventory_move(current_setting('t8.item')::uuid, 'issue', 1);
    raise exception 'FAIL: maid moved stock';
  exception when insufficient_privilege then null;
  end;
end $$;
select tests.login('00000000-0000-0000-0000-0000000008a2', 'reception8a@example.kz');
do $$
begin
  assert (select count(*) from public.inventory_items) = 0 and (select count(*) from public.inventory_movements) = 0,
    'reception must not see stock';
end $$;
select tests.login('00000000-0000-0000-0000-0000000008b1', 'owner8b@example.kz');
do $$
begin
  assert (select count(*) from public.inventory_items where tenant_id = current_setting('t8.a')::uuid) = 0, 'B must not see A items';
  begin
    perform public.record_inventory_move(current_setting('t8.item')::uuid, 'receipt', 10);
    raise exception 'FAIL: B moved A stock';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.inventory_items (tenant_id, name) values (current_setting('t8.a')::uuid, 'Чужой товар');
    raise exception 'FAIL: B created item in A';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  20c  maid reads only, reception none, tenant isolation';
end $$;
reset role;

-- ============================================================================
-- Подписка: истёкшая — читается, но не меняется; тариф Start — модуля нет
-- ============================================================================
update public.organization_subscriptions set trial_ends_at = now() - interval '30 days'
where tenant_id = current_setting('t8.a')::uuid;
update public.organization_subscriptions set plan_id = (select id from public.subscription_plans where code = 'start')
where tenant_id = current_setting('t8.b')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000008a1', 'owner8a@example.kz');
do $$
begin
  assert (select count(*) from public.inventory_movements) = 4, 'expired: history readable';
  begin
    perform public.record_inventory_move(current_setting('t8.item')::uuid, 'receipt', 10);
    raise exception 'FAIL: move on expired subscription';
  exception when insufficient_privilege then null;
  end;
end $$;
select tests.login('00000000-0000-0000-0000-0000000008b1', 'owner8b@example.kz');
do $$
begin
  insert into public.inventory_items (tenant_id, name) values (current_setting('t8.b')::uuid, 'Шампунь');
  raise exception 'FAIL: Start plan created an item';
exception when insufficient_privilege then
  raise notice 'ok  20d  expired subscription reads stock only; Start plan has no inventory';
end $$;
reset role;
do $$
declare i uuid := current_setting('t8.item')::uuid;
begin
  assert exists (select 1 from public.audit_logs where entity_id = i and action = 'inventory.writeoff'
                 and details ->> 'reason' = 'порваны'), 'writeoff journaled with reason';
  assert exists (select 1 from public.audit_logs where entity_id = i and action = 'inventory_item.update'
                 and (details -> 'values' -> 'min_quantity' ->> 'to')::numeric = 50), 'card change journaled';
  assert not exists (select 1 from public.audit_logs where entity_id = i and action = 'inventory_item.update'
                     and details -> 'changed' = '["quantity"]'::jsonb), 'stock change not duplicated in the journal';
end $$;

\echo 'ALL TESTS PASSED'
