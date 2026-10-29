-- Sanatorium OS · 0016 · Питание: столы (диеты), диета гостя на проживание, меню на день, подсчёт порций
-- Принципы:
--  * стол назначается на проживание (бронь): врач (medical.write) или кухня/администрация (kitchen.write);
--    основному гостю брони — назначенный стол, остальным гостям брони — стол по умолчанию;
--  * питание трёхразовое: в день заезда — обед и ужин, в день выезда — завтрак, в остальные дни — всё;
--    питаются подтверждённые, проживающие и выехавшие брони (заявки, отмены и незаезды не считаются);
--  * кухня видит номер, имя, стол и заметку для кухни — без диагнозов и медкарты;
--  * модуль «kitchen» входит в тарифы Business и Enterprise; при истёкшей подписке всё читается, но не меняется;
--  * все изменения — только функциями, с записью в журнал (без заметок и без привязки стола к гостю).

-- ---------------------------------------------------------------------------
-- Права, роль «Повар», тарифы
-- ---------------------------------------------------------------------------

insert into public.permissions (code, module, is_medical, description) values
  ('kitchen.read',  'kitchen', false, 'Питание: порции, меню, столы гостей'),
  ('kitchen.write', 'kitchen', false, 'Питание: столы, меню, диета гостя')
on conflict (code) do nothing;

insert into public.roles (tenant_id, code, name_ru, name_kk, is_system)
select null, 'cook', 'Повар', 'Аспаз', true
where not exists (select 1 from public.roles where tenant_id is null and code = 'cook');

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from (values ('owner', 'kitchen.read'), ('owner', 'kitchen.write'),
             ('director', 'kitchen.read'), ('director', 'kitchen.write'),
             ('manager', 'kitchen.read'), ('receptionist', 'kitchen.read'),
             ('doctor', 'kitchen.read'), ('nurse', 'kitchen.read'),
             ('cook', 'kitchen.read'), ('cook', 'kitchen.write'), ('cook', 'tasks.read'),
             ('cook', 'inventory.read')) v(role_code, perm_code)
join public.roles r on r.code = v.role_code and r.tenant_id is null
join public.permissions p on p.code = v.perm_code
on conflict do nothing;

insert into public.plan_features (plan_id, feature_code)
select p.id, 'kitchen' from public.subscription_plans p where p.code in ('business', 'enterprise')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Таблицы
-- ---------------------------------------------------------------------------

create type public.meal_kind as enum ('breakfast', 'lunch', 'dinner');

create table public.diet_types (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.organizations(id) on delete cascade,
  code        text not null check (char_length(trim(code)) between 1 and 10),
  name        text not null check (char_length(trim(name)) between 1 and 120),
  description text check (char_length(description) <= 1000),
  is_default  boolean not null default false,
  is_active   boolean not null default true,
  sort        integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, code)
);
create unique index diet_types_one_default on public.diet_types (tenant_id) where is_default;

create table public.booking_diets (
  tenant_id    uuid not null references public.organizations(id) on delete cascade,
  booking_id   uuid not null,
  diet_type_id uuid not null,
  kitchen_note text check (char_length(kitchen_note) <= 300),
  set_by       uuid references auth.users(id) on delete set null,
  updated_at   timestamptz not null default now(),
  primary key (tenant_id, booking_id),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id) on delete cascade,
  foreign key (tenant_id, diet_type_id) references public.diet_types (tenant_id, id)
);

create table public.diet_menus (
  tenant_id    uuid not null references public.organizations(id) on delete cascade,
  menu_date    date not null,
  meal         public.meal_kind not null,
  diet_type_id uuid not null,
  dishes       text not null check (char_length(trim(dishes)) between 1 and 1000),
  updated_by   uuid references auth.users(id) on delete set null,
  updated_at   timestamptz not null default now(),
  primary key (tenant_id, menu_date, meal, diet_type_id),
  foreign key (tenant_id, diet_type_id) references public.diet_types (tenant_id, id) on delete cascade
);

create trigger diet_types_tenant before update on public.diet_types
  for each row execute function app.forbid_tenant_change();
create trigger diet_types_touch before update on public.diet_types
  for each row execute function app.touch_updated_at();

alter table public.diet_types enable row level security;
alter table public.booking_diets enable row level security;
alter table public.diet_menus enable row level security;
revoke all on public.diet_types, public.booking_diets, public.diet_menus from anon, authenticated;
grant select on public.diet_types, public.diet_menus to authenticated;

-- Справочник столов и меню видят кухня и медики; кто какой стол получил — только через kitchen_day / booking_diet
create policy diet_types_select on public.diet_types for select to authenticated
  using (app.has_permission(tenant_id, 'kitchen.read') or app.has_permission(tenant_id, 'medical.read'));
create policy diet_menus_select on public.diet_menus for select to authenticated
  using (app.has_permission(tenant_id, 'kitchen.read'));

-- ---------------------------------------------------------------------------
-- Вспомогательные функции
-- ---------------------------------------------------------------------------

create or replace function app.can_write_kitchen(p_tenant uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.has_permission(p_tenant, 'kitchen.write') and app.feature_enabled(p_tenant, 'kitchen')
$$;

-- Стол назначает врач или кухня
create or replace function app.can_set_diet(p_tenant uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select (app.has_permission(p_tenant, 'kitchen.write') or app.has_permission(p_tenant, 'medical.write'))
     and app.feature_enabled(p_tenant, 'kitchen')
$$;

-- Какие приёмы пищи положены по брони в этот день
create or replace function app.booking_meals(p_check_in date, p_check_out date, p_date date) returns public.meal_kind[]
language sql immutable set search_path = '' as $$
  select case
    when p_date < p_check_in or p_date > p_check_out then '{}'::public.meal_kind[]
    when p_date = p_check_in then array['lunch', 'dinner']::public.meal_kind[]
    when p_date = p_check_out then array['breakfast']::public.meal_kind[]
    else array['breakfast', 'lunch', 'dinner']::public.meal_kind[] end
$$;

-- ---------------------------------------------------------------------------
-- Столы
-- ---------------------------------------------------------------------------

create or replace function public.save_diet_type(
  p_tenant uuid, p_id uuid, p_code text, p_name text, p_description text default null,
  p_is_default boolean default false, p_is_active boolean default true, p_sort integer default 0
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  if not app.can_write_kitchen(p_tenant) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if char_length(trim(coalesce(p_code, ''))) not between 1 and 10 or char_length(trim(coalesce(p_name, ''))) not between 1 and 120 then
    raise exception 'code and name are required' using errcode = '22023';
  end if;
  if coalesce(p_is_default, false) and not coalesce(p_is_active, true) then
    raise exception 'default diet must be active' using errcode = '22023';
  end if;
  if exists (select 1 from public.diet_types where tenant_id = p_tenant and lower(code) = lower(trim(p_code)) and id is distinct from p_id) then
    raise exception 'diet code already exists' using errcode = '23505';
  end if;
  if coalesce(p_is_default, false) then
    update public.diet_types set is_default = false where tenant_id = p_tenant and is_default and id is distinct from p_id;
  end if;
  if p_id is null then
    insert into public.diet_types (tenant_id, code, name, description, is_default, is_active, sort)
    values (p_tenant, trim(p_code), trim(p_name), app.clean_text(p_description), coalesce(p_is_default, false), coalesce(p_is_active, true), coalesce(p_sort, 0))
    returning id into v_id;
    perform app.log_audit(p_tenant, 'diet_type.create', 'diet_type', v_id, 'success', jsonb_build_object('code', trim(p_code), 'name', trim(p_name)));
  else
    update public.diet_types set code = trim(p_code), name = trim(p_name), description = app.clean_text(p_description),
      is_default = coalesce(p_is_default, false), is_active = coalesce(p_is_active, true), sort = coalesce(p_sort, 0)
    where id = p_id and tenant_id = p_tenant
    returning id into v_id;
    if v_id is null then
      raise exception 'diet type not found' using errcode = 'P0002';
    end if;
    perform app.log_audit(p_tenant, 'diet_type.update', 'diet_type', v_id, 'success', jsonb_build_object('code', trim(p_code), 'name', trim(p_name)));
  end if;
  return v_id;
end $$;

-- Типовые столы (нумерация по Певзнеру); существующие коды не трогает
create or replace function public.add_standard_diets(p_tenant uuid, p_lang public.app_language default 'ru') returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
  v_has_default boolean;
begin
  if not app.can_write_kitchen(p_tenant) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  v_has_default := exists (select 1 from public.diet_types where tenant_id = p_tenant and is_default);
  insert into public.diet_types (tenant_id, code, name, description, is_default, sort)
  select p_tenant, s.code, case when p_lang = 'kk' then s.name_kk else s.name_ru end, null,
         s.code = '15' and not v_has_default, s.sort
  from (values
    ('1',  'Щадящий (желудок)',            'Аяулы (асқазан)',               10),
    ('5',  'Печень и желчный пузырь',      'Бауыр және өт қабы',            20),
    ('7',  'Почки',                        'Бүйрек',                        30),
    ('9',  'Диабетический',                'Диабеттік',                     40),
    ('10', 'Сердце и сосуды',              'Жүрек және тамырлар',           50),
    ('15', 'Общий',                        'Жалпы',                         60)
  ) s(code, name_ru, name_kk, sort)
  where not exists (select 1 from public.diet_types d where d.tenant_id = p_tenant and lower(d.code) = s.code);
  get diagnostics v_count = row_count;
  if v_count > 0 then
    perform app.log_audit(p_tenant, 'diet_type.standard', 'diet_type', null, 'success', jsonb_build_object('count', v_count));
  end if;
  return v_count;
end $$;

-- ---------------------------------------------------------------------------
-- Стол гостя на проживание
-- ---------------------------------------------------------------------------

create or replace function public.booking_diet(p_booking_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_b public.bookings;
begin
  select * into v_b from public.bookings where id = p_booking_id;
  if not found or not (app.has_permission(v_b.tenant_id, 'kitchen.read') or app.has_permission(v_b.tenant_id, 'medical.read')) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'diet', (select jsonb_build_object('diet_type_id', d.diet_type_id, 'code', t.code, 'name', t.name, 'kitchen_note', d.kitchen_note,
                                       'updated_at', d.updated_at, 'set_by_name', u.full_name)
             from public.booking_diets d join public.diet_types t on t.id = d.diet_type_id
             left join public.user_profiles u on u.id = d.set_by
             where d.tenant_id = v_b.tenant_id and d.booking_id = v_b.id),
    'default', (select jsonb_build_object('diet_type_id', t.id, 'code', t.code, 'name', t.name)
                from public.diet_types t where t.tenant_id = v_b.tenant_id and t.is_default),
    'can_set', app.can_set_diet(v_b.tenant_id));
end $$;

-- p_diet_type_id = null снимает назначение (гость питается по столу по умолчанию)
create or replace function public.set_booking_diet(p_booking_id uuid, p_diet_type_id uuid, p_kitchen_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_b public.bookings;
begin
  select * into v_b from public.bookings where id = p_booking_id;
  if not found or not app.can_set_diet(v_b.tenant_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_b.status in ('cancelled', 'no_show') then
    raise exception 'booking is closed' using errcode = '22023';
  end if;
  if char_length(coalesce(p_kitchen_note, '')) > 300 then
    raise exception 'text is too long' using errcode = '22023';
  end if;
  if p_diet_type_id is null then
    delete from public.booking_diets where tenant_id = v_b.tenant_id and booking_id = v_b.id;
  else
    if not exists (select 1 from public.diet_types where id = p_diet_type_id and tenant_id = v_b.tenant_id and is_active) then
      raise exception 'diet type not found' using errcode = 'P0002';
    end if;
    insert into public.booking_diets (tenant_id, booking_id, diet_type_id, kitchen_note, set_by)
    values (v_b.tenant_id, v_b.id, p_diet_type_id, app.clean_text(p_kitchen_note), auth.uid())
    on conflict (tenant_id, booking_id) do update
      set diet_type_id = excluded.diet_type_id, kitchen_note = excluded.kitchen_note, set_by = excluded.set_by, updated_at = now();
  end if;
  -- в журнале только факт и номер брони: стол гостя — сведения о здоровье
  perform app.log_audit(v_b.tenant_id, 'diet.set', 'booking', v_b.id, 'success', jsonb_build_object('booking_number', v_b.number));
end $$;

-- ---------------------------------------------------------------------------
-- Меню
-- ---------------------------------------------------------------------------

-- Пустой текст удаляет блюда этого стола на этот приём пищи
create or replace function public.set_diet_menu(p_tenant uuid, p_date date, p_meal public.meal_kind, p_diet_type_id uuid, p_dishes text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not app.can_write_kitchen(p_tenant) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_date is null or p_meal is null or not exists (select 1 from public.diet_types where id = p_diet_type_id and tenant_id = p_tenant) then
    raise exception 'diet type not found' using errcode = 'P0002';
  end if;
  if char_length(coalesce(p_dishes, '')) > 1000 then
    raise exception 'text is too long' using errcode = '22023';
  end if;
  if app.clean_text(p_dishes) is null then
    delete from public.diet_menus where tenant_id = p_tenant and menu_date = p_date and meal = p_meal and diet_type_id = p_diet_type_id;
  else
    insert into public.diet_menus (tenant_id, menu_date, meal, diet_type_id, dishes, updated_by)
    values (p_tenant, p_date, p_meal, p_diet_type_id, app.clean_text(p_dishes), auth.uid())
    on conflict (tenant_id, menu_date, meal, diet_type_id) do update
      set dishes = excluded.dishes, updated_by = excluded.updated_by, updated_at = now();
  end if;
  perform app.log_audit(p_tenant, 'menu.update', 'menu', null, 'success', jsonb_build_object('date', p_date, 'meal', p_meal));
end $$;

-- Скопировать меню дня на другой день (меню в санаториях повторяется по циклу); заменяет меню целевого дня
create or replace function public.copy_diet_menu(p_tenant uuid, p_from date, p_to date) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
begin
  if not app.can_write_kitchen(p_tenant) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from = p_to then
    raise exception 'invalid dates' using errcode = '22023';
  end if;
  if not exists (select 1 from public.diet_menus where tenant_id = p_tenant and menu_date = p_from) then
    raise exception 'source menu is empty' using errcode = '22023';
  end if;
  delete from public.diet_menus where tenant_id = p_tenant and menu_date = p_to;
  insert into public.diet_menus (tenant_id, menu_date, meal, diet_type_id, dishes, updated_by)
  select tenant_id, p_to, meal, diet_type_id, dishes, auth.uid() from public.diet_menus where tenant_id = p_tenant and menu_date = p_from;
  get diagnostics v_count = row_count;
  perform app.log_audit(p_tenant, 'menu.copy', 'menu', null, 'success', jsonb_build_object('from', p_from, 'to', p_to));
  return v_count;
end $$;

-- ---------------------------------------------------------------------------
-- День кухни: кто питается, сколько порций по столам, меню
-- ---------------------------------------------------------------------------

create or replace function public.kitchen_day(p_tenant uuid, p_date date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_default uuid;
  v_guests jsonb;
  v_portions jsonb;
begin
  if not app.has_permission(p_tenant, 'kitchen.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_date is null then
    raise exception 'invalid dates' using errcode = '22023';
  end if;
  select id into v_default from public.diet_types where tenant_id = p_tenant and is_default;

  with eaters as (
    select b.id as booking_id, b.number, b.status, g.full_name, r.number as room, b.adults + b.children as persons,
      app.booking_meals(b.check_in, b.check_out, p_date) as meals,
      d.diet_type_id, d.kitchen_note
    from public.bookings b
    join public.guests g on g.id = b.guest_id
    left join public.rooms r on r.id = b.room_id
    left join public.booking_diets d on d.tenant_id = b.tenant_id and d.booking_id = b.id
    where b.tenant_id = p_tenant and b.status in ('confirmed', 'checked_in', 'checked_out')
      and p_date between b.check_in and b.check_out
  ),
  -- порции: основной гость — его стол, остальные — стол по умолчанию; null — «без стола»
  portions as (
    select m.meal, coalesce(e.diet_type_id, v_default) as diet_type_id, 1 as n from eaters e, unnest(e.meals) m(meal)
    union all
    select m.meal, v_default, e.persons - 1 from eaters e, unnest(e.meals) m(meal) where e.persons > 1
  )
  select
    (select coalesce(jsonb_agg(jsonb_build_object('booking_id', e.booking_id, 'booking_number', e.number, 'status', e.status,
       'full_name', e.full_name, 'room', e.room, 'persons', e.persons, 'meals', to_jsonb(e.meals),
       'diet_type_id', e.diet_type_id, 'kitchen_note', e.kitchen_note) order by e.room nulls last, e.full_name), '[]'::jsonb)
     from eaters e where cardinality(e.meals) > 0),
    (select coalesce(jsonb_agg(jsonb_build_object('meal', x.meal, 'diet_type_id', x.diet_type_id, 'portions', x.n)), '[]'::jsonb)
     from (select meal, diet_type_id, sum(n)::integer as n from portions group by meal, diet_type_id) x where x.n > 0)
  into v_guests, v_portions;

  return jsonb_build_object(
    'date', p_date,
    'guests', v_guests,
    'portions', v_portions,
    'menus', (select coalesce(jsonb_agg(jsonb_build_object('meal', m.meal, 'diet_type_id', m.diet_type_id, 'dishes', m.dishes)), '[]'::jsonb)
              from public.diet_menus m where m.tenant_id = p_tenant and m.menu_date = p_date),
    'can_write', app.can_write_kitchen(p_tenant),
    'can_set_diet', app.can_set_diet(p_tenant));
end $$;

-- ---------------------------------------------------------------------------
-- Доступ к функциям
-- ---------------------------------------------------------------------------

revoke all on function app.can_write_kitchen(uuid), app.can_set_diet(uuid), app.booking_meals(date, date, date)
  from public, anon, authenticated;

revoke execute on function
  public.save_diet_type(uuid, uuid, text, text, text, boolean, boolean, integer),
  public.add_standard_diets(uuid, public.app_language),
  public.booking_diet(uuid),
  public.set_booking_diet(uuid, uuid, text),
  public.set_diet_menu(uuid, date, public.meal_kind, uuid, text),
  public.copy_diet_menu(uuid, date, date),
  public.kitchen_day(uuid, date)
  from public, anon;
grant execute on function
  public.save_diet_type(uuid, uuid, text, text, text, boolean, boolean, integer),
  public.add_standard_diets(uuid, public.app_language),
  public.booking_diet(uuid),
  public.set_booking_diet(uuid, uuid, text),
  public.set_diet_menu(uuid, date, public.meal_kind, uuid, text),
  public.copy_diet_menu(uuid, date, date),
  public.kitchen_day(uuid, date)
  to authenticated;
