-- Sanatorium OS · 0005 · Номерной фонд, гости, бронирования (этап 3)
-- Принципы:
--  * каждая таблица несёт tenant_id; связи между таблицами санатория — составными ключами
--    (tenant_id, id), поэтому бронь не может сослаться на номер или гостя чужого санатория;
--  * цену брони считает только сервер (app.calc_booking_price), клиент её не передаёт;
--  * двойная бронь одного номера невозможна на уровне БД (exclusion constraint);
--  * бронирования меняются только через функции ниже: они проверяют права, статусы и подписку.

-- ---------------------------------------------------------------------------
-- Типы
-- ---------------------------------------------------------------------------

create type public.room_status as enum ('available', 'occupied', 'cleaning', 'maintenance');
create type public.booking_status as enum (
  'new_request',  -- заявка (с сайта или вручную), номер ещё не закреплён
  'confirmed',    -- подтверждена, номер закреплён
  'checked_in',   -- гость проживает
  'checked_out',  -- выехал
  'cancelled',
  'no_show'
);
create type public.booking_source as enum ('walk_in', 'phone', 'whatsapp', 'website', 'agent', 'other');

-- ---------------------------------------------------------------------------
-- Категории номеров и цены
-- ---------------------------------------------------------------------------

create table public.room_types (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.organizations(id) on delete cascade,
  name              text not null check (char_length(trim(name)) between 1 and 120),
  description       text check (char_length(description) <= 2000),
  base_occupancy    integer not null default 2 check (base_occupancy between 1 and 20),
  max_occupancy     integer not null default 2 check (max_occupancy between 1 and 30),
  -- цена за номер за ночь при размещении до base_occupancy человек, ₸
  base_price        numeric(14,2) not null check (base_price >= 0),
  -- доплата за каждого гостя сверх base_occupancy за ночь, ₸
  extra_guest_price numeric(14,2) not null default 0 check (extra_guest_price >= 0),
  is_public         boolean not null default true,   -- показывать на публичной странице
  is_active         boolean not null default true,
  sort_order        integer not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (tenant_id, id),
  constraint occupancy_order check (max_occupancy >= base_occupancy)
);
create index room_types_tenant_idx on public.room_types (tenant_id, sort_order);

-- Сезонные цены: на даты периода (включительно) действует своя цена за ночь
create table public.room_rates (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.organizations(id) on delete cascade,
  room_type_id      uuid not null,
  name              text not null check (char_length(trim(name)) between 1 and 120),
  starts_on         date not null,
  ends_on           date not null,
  price_per_night   numeric(14,2) not null check (price_per_night >= 0),
  extra_guest_price numeric(14,2) check (extra_guest_price >= 0),  -- null = как в категории
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  foreign key (tenant_id, room_type_id) references public.room_types (tenant_id, id) on delete cascade,
  constraint rate_period_order check (ends_on >= starts_on),
  constraint rate_period_length check (ends_on - starts_on <= 366),
  -- периоды одной категории не пересекаются, иначе цена ночи неоднозначна
  constraint room_rates_no_overlap exclude using gist (
    room_type_id with =, daterange(starts_on, ends_on, '[]') with &&
  )
);
create index room_rates_type_idx on public.room_rates (room_type_id, starts_on);

create table public.rooms (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.organizations(id) on delete cascade,
  room_type_id uuid not null,
  number       text not null check (char_length(trim(number)) between 1 and 20),
  floor        text check (char_length(floor) <= 20),
  building     text check (char_length(building) <= 60),
  status       public.room_status not null default 'available',
  notes        text check (char_length(notes) <= 1000),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, number),
  foreign key (tenant_id, room_type_id) references public.room_types (tenant_id, id)
);
create index rooms_tenant_idx on public.rooms (tenant_id, number);

-- ---------------------------------------------------------------------------
-- Гости
-- ---------------------------------------------------------------------------

create table public.guests (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.organizations(id) on delete cascade,
  full_name   text not null check (char_length(trim(full_name)) between 2 and 200),
  phone       text check (phone ~ '^\+[1-9][0-9]{6,14}$'),
  email       text check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 254),
  birth_date  date check (birth_date > date '1900-01-01'),
  city        text check (char_length(city) <= 120),
  notes       text check (char_length(notes) <= 2000),
  consent_at  timestamptz,                -- согласие на обработку персональных данных
  archived_at timestamptz,
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, id)
);
-- один активный гость на номер телефона в санатории (заявки с сайта находят его по телефону)
create unique index guests_tenant_phone_uidx on public.guests (tenant_id, phone)
  where phone is not null and archived_at is null;
create index guests_tenant_name_idx on public.guests using gin (full_name extensions.gin_trgm_ops);
create index guests_tenant_idx on public.guests (tenant_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Бронирования
-- ---------------------------------------------------------------------------

create table public.booking_counters (
  tenant_id uuid primary key references public.organizations(id) on delete cascade,
  last_number integer not null default 0
);

create table public.bookings (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.organizations(id) on delete cascade,
  number          integer not null,             -- номер брони внутри санатория: 1, 2, 3…
  guest_id        uuid not null,
  room_type_id    uuid not null,
  room_id         uuid,
  check_in        date not null,
  check_out       date not null,
  nights          integer generated always as (check_out - check_in) stored,
  adults          integer not null default 1 check (adults between 1 and 30),
  children        integer not null default 0 check (children between 0 and 30),
  status          public.booking_status not null default 'confirmed',
  source          public.booking_source not null default 'phone',
  total_amount    numeric(14,2) not null check (total_amount >= 0),
  price_breakdown jsonb not null default '[]'::jsonb,
  guest_comment   text check (char_length(guest_comment) <= 2000),
  internal_notes  text check (char_length(internal_notes) <= 2000),
  cancel_reason   text check (char_length(cancel_reason) <= 500),
  checked_in_at   timestamptz,
  checked_out_at  timestamptz,
  cancelled_at    timestamptz,
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (tenant_id, number),
  foreign key (tenant_id, guest_id)     references public.guests (tenant_id, id),
  foreign key (tenant_id, room_type_id) references public.room_types (tenant_id, id),
  foreign key (tenant_id, room_id)      references public.rooms (tenant_id, id),
  constraint stay_order  check (check_out > check_in),
  constraint stay_length check (check_out - check_in <= 365),
  constraint room_required check (status in ('new_request', 'cancelled', 'no_show') or room_id is not null),
  -- Защита от двойной брони: один номер не может быть занят двумя активными бронями
  -- на пересекающиеся ночи. Интервал [заезд, выезд): выезд 10-го и заезд 10-го не конфликтуют.
  constraint bookings_no_double_booking exclude using gist (
    room_id with =, daterange(check_in, check_out, '[)') with &&
  ) where (room_id is not null and status in ('confirmed', 'checked_in', 'checked_out'))
);
create index bookings_tenant_dates_idx on public.bookings (tenant_id, check_in, check_out);
create index bookings_tenant_status_idx on public.bookings (tenant_id, status);
create index bookings_guest_idx on public.bookings (guest_id);

-- ---------------------------------------------------------------------------
-- Триггеры
-- ---------------------------------------------------------------------------

create trigger room_types_touch before update on public.room_types
  for each row execute function app.touch_updated_at();
create trigger room_types_tenant before update on public.room_types
  for each row execute function app.forbid_tenant_change();
create trigger room_rates_touch before update on public.room_rates
  for each row execute function app.touch_updated_at();
create trigger room_rates_tenant before update on public.room_rates
  for each row execute function app.forbid_tenant_change();
create trigger rooms_touch before update on public.rooms
  for each row execute function app.touch_updated_at();
create trigger rooms_tenant before update on public.rooms
  for each row execute function app.forbid_tenant_change();
create trigger guests_touch before update on public.guests
  for each row execute function app.touch_updated_at();
create trigger guests_tenant before update on public.guests
  for each row execute function app.forbid_tenant_change();
create trigger bookings_touch before update on public.bookings
  for each row execute function app.touch_updated_at();
create trigger bookings_tenant before update on public.bookings
  for each row execute function app.forbid_tenant_change();

-- Лимит номеров по тарифу (max_rooms; null = без ограничений)
create or replace function app.enforce_room_limit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_max integer;
begin
  select p.max_rooms into v_max
  from public.organization_subscriptions s join public.subscription_plans p on p.id = s.plan_id
  where s.tenant_id = new.tenant_id and s.status <> 'cancelled'
  limit 1;
  if v_max is not null and (select count(*) from public.rooms where tenant_id = new.tenant_id) >= v_max then
    raise exception 'room limit of the plan reached' using errcode = '54000';
  end if;
  return new;
end $$;
create trigger rooms_limit before insert on public.rooms
  for each row execute function app.enforce_room_limit();

-- Архивировать гостя может только guests.archive; вернуть из архива — тоже
create or replace function app.protect_guest_archive() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.archived_at is distinct from old.archived_at
     and current_user in ('authenticated', 'anon')
     and not app.has_permission(new.tenant_id, 'guests.archive') then
    raise exception 'archiving guests requires guests.archive' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger guests_archive_guard before update on public.guests
  for each row execute function app.protect_guest_archive();

-- ---------------------------------------------------------------------------
-- Вспомогательные функции
-- ---------------------------------------------------------------------------

-- Сегодняшняя дата в часовом поясе санатория (по умолчанию Asia/Almaty)
create or replace function app.tenant_today(p_tenant uuid) returns date
language sql stable security definer set search_path = '' as $$
  select (now() at time zone coalesce(
    (select timezone from public.organizations where id = p_tenant), 'Asia/Almaty'))::date
$$;

-- Расчёт стоимости: для каждой ночи берётся сезонная цена, если дата попадает в период,
-- иначе базовая цена категории; за гостей сверх base_occupancy — доплата за ночь.
-- Дети учитываются как гости при подсчёте вместимости и доплаты.
create or replace function app.calc_booking_price(
  p_tenant uuid, p_room_type_id uuid, p_check_in date, p_check_out date, p_adults integer, p_children integer
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_type   public.room_types;
  v_guests integer := coalesce(p_adults, 0) + coalesce(p_children, 0);
  v_extra  integer;
  v_total  numeric(14,2) := 0;
  v_lines  jsonb := '[]'::jsonb;
  v_day    date;
  v_rate   public.room_rates;
  v_price  numeric(14,2);
  v_extra_price numeric(14,2);
begin
  if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then
    raise exception 'check-out must be after check-in' using errcode = '22023';
  end if;
  if p_check_out - p_check_in > 365 then
    raise exception 'stay is too long' using errcode = '22023';
  end if;
  select * into v_type from public.room_types where id = p_room_type_id and tenant_id = p_tenant;
  if not found then
    raise exception 'room type not found' using errcode = 'P0002';
  end if;
  if coalesce(p_adults, 0) < 1 then
    raise exception 'at least one adult is required' using errcode = '22023';
  end if;
  if v_guests > v_type.max_occupancy then
    raise exception 'too many guests for this room type' using errcode = '22023';
  end if;
  v_extra := greatest(v_guests - v_type.base_occupancy, 0);

  v_day := p_check_in;
  while v_day < p_check_out loop
    select * into v_rate from public.room_rates r
    where r.room_type_id = p_room_type_id and v_day between r.starts_on and r.ends_on;
    if found then
      v_price := v_rate.price_per_night;
      v_extra_price := coalesce(v_rate.extra_guest_price, v_type.extra_guest_price);
    else
      v_price := v_type.base_price;
      v_extra_price := v_type.extra_guest_price;
    end if;
    v_price := v_price + v_extra * v_extra_price;
    v_total := v_total + v_price;
    v_lines := v_lines || jsonb_build_object(
      'date', v_day, 'amount', v_price, 'rate', case when v_rate.id is not null then v_rate.name end);
    v_rate := null;
    v_day := v_day + 1;
  end loop;

  return jsonb_build_object(
    'total', v_total, 'nights', p_check_out - p_check_in, 'extra_guests', v_extra, 'nights_detail', v_lines);
end $$;

-- Может ли пользователь менять бронирования (право + подписка + функция тарифа)
create or replace function app.can_write_bookings(p_tenant uuid, p_permission text) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.has_permission(p_tenant, p_permission) and app.feature_enabled(p_tenant, 'bookings')
$$;

create or replace function app.next_booking_number(p_tenant uuid) returns integer
language sql security definer set search_path = '' as $$
  insert into public.booking_counters as c (tenant_id, last_number) values (p_tenant, 1)
  on conflict (tenant_id) do update set last_number = c.last_number + 1
  returning last_number
$$;

-- Номер подходит для брони: свой санаторий, нужная категория, активен, не на обслуживании
create or replace function app.check_room_for_booking(p_tenant uuid, p_room_id uuid, p_room_type_id uuid)
returns void
language plpgsql stable security definer set search_path = '' as $$
declare v_room public.rooms;
begin
  select * into v_room from public.rooms where id = p_room_id and tenant_id = p_tenant;
  if not found then
    raise exception 'room not found' using errcode = 'P0002';
  end if;
  if v_room.room_type_id <> p_room_type_id then
    raise exception 'room does not belong to the selected room type' using errcode = '22023';
  end if;
  if not v_room.is_active or v_room.status = 'maintenance' then
    raise exception 'room is not available for booking' using errcode = '22023';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.room_types       enable row level security;
alter table public.room_rates       enable row level security;
alter table public.rooms            enable row level security;
alter table public.guests           enable row level security;
alter table public.booking_counters enable row level security;
alter table public.bookings         enable row level security;

-- Категории, цены и номера: читать — rooms.read, менять — rooms.write при активной подписке
create policy room_types_select on public.room_types for select to authenticated
  using (app.has_permission(tenant_id, 'rooms.read') or app.has_permission(tenant_id, 'bookings.read'));
create policy room_types_insert on public.room_types for insert to authenticated
  with check (app.has_permission(tenant_id, 'rooms.write') and app.feature_enabled(tenant_id, 'rooms'));
create policy room_types_update on public.room_types for update to authenticated
  using (app.has_permission(tenant_id, 'rooms.write'))
  with check (app.has_permission(tenant_id, 'rooms.write') and app.feature_enabled(tenant_id, 'rooms'));
create policy room_types_delete on public.room_types for delete to authenticated
  using (app.has_permission(tenant_id, 'rooms.delete') and app.feature_enabled(tenant_id, 'rooms'));

create policy room_rates_select on public.room_rates for select to authenticated
  using (app.has_permission(tenant_id, 'rooms.read') or app.has_permission(tenant_id, 'bookings.read'));
create policy room_rates_insert on public.room_rates for insert to authenticated
  with check (app.has_permission(tenant_id, 'rooms.write') and app.feature_enabled(tenant_id, 'rooms'));
create policy room_rates_update on public.room_rates for update to authenticated
  using (app.has_permission(tenant_id, 'rooms.write'))
  with check (app.has_permission(tenant_id, 'rooms.write') and app.feature_enabled(tenant_id, 'rooms'));
create policy room_rates_delete on public.room_rates for delete to authenticated
  using (app.has_permission(tenant_id, 'rooms.write') and app.feature_enabled(tenant_id, 'rooms'));

create policy rooms_select on public.rooms for select to authenticated
  using (app.has_permission(tenant_id, 'rooms.read') or app.has_permission(tenant_id, 'bookings.read'));
create policy rooms_insert on public.rooms for insert to authenticated
  with check (app.has_permission(tenant_id, 'rooms.write') and app.feature_enabled(tenant_id, 'rooms'));
create policy rooms_update on public.rooms for update to authenticated
  using (app.has_permission(tenant_id, 'rooms.write'))
  with check (app.has_permission(tenant_id, 'rooms.write') and app.feature_enabled(tenant_id, 'rooms'));
create policy rooms_delete on public.rooms for delete to authenticated
  using (app.has_permission(tenant_id, 'rooms.delete') and app.feature_enabled(tenant_id, 'rooms'));

-- Гости: персональные данные. Читать — guests.read, создавать и менять — guests.write.
-- Удаления нет: гостя архивируют (guests.archive), история броней сохраняется.
create policy guests_select on public.guests for select to authenticated
  using (app.has_permission(tenant_id, 'guests.read'));
create policy guests_insert on public.guests for insert to authenticated
  with check (app.has_permission(tenant_id, 'guests.write') and app.feature_enabled(tenant_id, 'guests'));
create policy guests_update on public.guests for update to authenticated
  using (app.has_permission(tenant_id, 'guests.write'))
  with check (app.has_permission(tenant_id, 'guests.write') and app.feature_enabled(tenant_id, 'guests'));

-- Бронирования: только чтение через RLS; все изменения — функциями ниже
create policy bookings_select on public.bookings for select to authenticated
  using (app.has_permission(tenant_id, 'bookings.read'));
-- booking_counters: политик нет, доступ только из функций

-- ---------------------------------------------------------------------------
-- Серверные операции с бронированиями
-- ---------------------------------------------------------------------------

-- Предварительный расчёт цены для формы брони
create or replace function public.quote_booking(
  p_tenant uuid, p_room_type_id uuid, p_check_in date, p_check_out date,
  p_adults integer default 1, p_children integer default 0
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.has_permission(p_tenant, 'bookings.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  return app.calc_booking_price(p_tenant, p_room_type_id, p_check_in, p_check_out, p_adults, p_children);
end $$;

-- Свободные номера на период (по желанию — одной категории; p_exclude_booking — при переносе брони)
create or replace function public.available_rooms(
  p_tenant uuid, p_check_in date, p_check_out date,
  p_room_type_id uuid default null, p_exclude_booking uuid default null
) returns table (id uuid, number text, floor text, room_type_id uuid, status public.room_status)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.has_permission(p_tenant, 'bookings.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_check_out <= p_check_in then
    raise exception 'check-out must be after check-in' using errcode = '22023';
  end if;
  return query
  select r.id, r.number, r.floor, r.room_type_id, r.status
  from public.rooms r
  where r.tenant_id = p_tenant and r.is_active and r.status <> 'maintenance'
    and (p_room_type_id is null or r.room_type_id = p_room_type_id)
    and not exists (
      select 1 from public.bookings b
      where b.room_id = r.id
        and b.status in ('confirmed', 'checked_in', 'checked_out')
        and daterange(b.check_in, b.check_out, '[)') && daterange(p_check_in, p_check_out, '[)')
        and (p_exclude_booking is null or b.id <> p_exclude_booking)
    )
  order by r.number;
end $$;

-- Создание брони сотрудником. Цена считается здесь, а не на клиенте.
create or replace function public.create_booking(
  p_tenant uuid, p_guest_id uuid, p_room_type_id uuid, p_room_id uuid,
  p_check_in date, p_check_out date, p_adults integer default 1, p_children integer default 0,
  p_source public.booking_source default 'phone', p_comment text default null,
  p_status public.booking_status default 'confirmed'
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_price jsonb;
  v_id    uuid;
begin
  if not app.can_write_bookings(p_tenant, 'bookings.write') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_status not in ('new_request', 'confirmed') then
    raise exception 'a booking can only be created as a request or confirmed' using errcode = '22023';
  end if;
  if p_check_out <= app.tenant_today(p_tenant) then
    raise exception 'stay must not be entirely in the past' using errcode = '22023';
  end if;
  if not exists (select 1 from public.guests g where g.id = p_guest_id and g.tenant_id = p_tenant) then
    raise exception 'guest not found' using errcode = 'P0002';
  end if;
  if p_room_id is not null then
    perform app.check_room_for_booking(p_tenant, p_room_id, p_room_type_id);
  end if;

  v_price := app.calc_booking_price(p_tenant, p_room_type_id, p_check_in, p_check_out, p_adults, p_children);

  insert into public.bookings (
    tenant_id, number, guest_id, room_type_id, room_id, check_in, check_out, adults, children,
    status, source, total_amount, price_breakdown, guest_comment, created_by)
  values (
    p_tenant, app.next_booking_number(p_tenant), p_guest_id, p_room_type_id, p_room_id,
    p_check_in, p_check_out, p_adults, coalesce(p_children, 0),
    p_status, p_source, (v_price ->> 'total')::numeric, v_price -> 'nights_detail',
    nullif(trim(p_comment), ''), auth.uid())
  returning id into v_id;

  perform app.log_audit(p_tenant, 'booking.create', 'booking', v_id, 'success',
    jsonb_build_object('status', p_status, 'check_in', p_check_in, 'check_out', p_check_out));
  return v_id;
end $$;

-- Изменение дат, номера или числа гостей. Цена пересчитывается.
-- У проживающего гостя нельзя менять дату заезда.
create or replace function public.update_booking(
  p_booking_id uuid, p_room_type_id uuid, p_room_id uuid, p_check_in date, p_check_out date,
  p_adults integer, p_children integer, p_comment text default null, p_internal_notes text default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_b     public.bookings;
  v_price jsonb;
begin
  select * into v_b from public.bookings where id = p_booking_id for update;
  if not found or not app.can_write_bookings(v_b.tenant_id, 'bookings.write') then
    raise exception 'booking not found or permission denied' using errcode = '42501';
  end if;
  if v_b.status not in ('new_request', 'confirmed', 'checked_in') then
    raise exception 'booking in status % cannot be changed', v_b.status using errcode = '22023';
  end if;
  if v_b.status = 'checked_in' and p_check_in <> v_b.check_in then
    raise exception 'check-in date of an in-house guest cannot be changed' using errcode = '22023';
  end if;
  if v_b.status <> 'new_request' and p_room_id is null then
    raise exception 'room is required' using errcode = '22023';
  end if;
  if p_room_id is not null then
    perform app.check_room_for_booking(v_b.tenant_id, p_room_id, p_room_type_id);
  end if;

  v_price := app.calc_booking_price(v_b.tenant_id, p_room_type_id, p_check_in, p_check_out, p_adults, p_children);

  update public.bookings set
    room_type_id = p_room_type_id, room_id = p_room_id,
    check_in = p_check_in, check_out = p_check_out,
    adults = p_adults, children = coalesce(p_children, 0),
    total_amount = (v_price ->> 'total')::numeric, price_breakdown = v_price -> 'nights_detail',
    guest_comment = nullif(trim(p_comment), ''), internal_notes = nullif(trim(p_internal_notes), '')
  where id = p_booking_id;

  -- номер проживающего гостя сменился: старый на уборку, новый занят
  if v_b.status = 'checked_in' and p_room_id <> v_b.room_id then
    update public.rooms set status = 'cleaning' where id = v_b.room_id;
    update public.rooms set status = 'occupied' where id = p_room_id;
  end if;

  perform app.log_audit(v_b.tenant_id, 'booking.update', 'booking', p_booking_id, 'success',
    jsonb_build_object('check_in', p_check_in, 'check_out', p_check_out, 'room_id', p_room_id,
                       'total', (v_price ->> 'total')::numeric));
end $$;

-- Смена статуса брони. Разрешённые переходы и нужные права:
--   new_request → confirmed   bookings.write (нужен номер)
--   new_request → cancelled   bookings.cancel или leads.write
--   confirmed   → checked_in  bookings.checkin (не раньше даты заезда)
--   confirmed   → cancelled   bookings.cancel (с причиной)
--   confirmed   → no_show     bookings.checkin (не раньше даты заезда)
--   checked_in  → checked_out bookings.checkin (номер уходит на уборку)
create or replace function public.set_booking_status(
  p_booking_id uuid, p_status public.booking_status, p_reason text default null, p_room_id uuid default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_b     public.bookings;
  v_today date;
  v_perm  text;
  v_room  uuid;
begin
  select * into v_b from public.bookings where id = p_booking_id for update;
  if not found or not app.has_permission(v_b.tenant_id, 'bookings.read') then
    raise exception 'booking not found' using errcode = 'P0002';
  end if;
  v_today := app.tenant_today(v_b.tenant_id);

  v_perm := case
    when v_b.status = 'new_request' and p_status = 'confirmed'   then 'bookings.write'
    when v_b.status = 'new_request' and p_status = 'cancelled'   then
      case when app.has_permission(v_b.tenant_id, 'leads.write') then 'leads.write' else 'bookings.cancel' end
    when v_b.status = 'confirmed'   and p_status = 'checked_in'  then 'bookings.checkin'
    when v_b.status = 'confirmed'   and p_status = 'cancelled'   then 'bookings.cancel'
    when v_b.status = 'confirmed'   and p_status = 'no_show'     then 'bookings.checkin'
    when v_b.status = 'checked_in'  and p_status = 'checked_out' then 'bookings.checkin'
  end;
  if v_perm is null then
    raise exception 'status change % -> % is not allowed', v_b.status, p_status using errcode = '22023';
  end if;
  if not app.can_write_bookings(v_b.tenant_id, v_perm) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  if p_status = 'confirmed' then
    v_room := coalesce(p_room_id, v_b.room_id);
    if v_room is null then
      raise exception 'room is required to confirm a booking' using errcode = '22023';
    end if;
    perform app.check_room_for_booking(v_b.tenant_id, v_room, v_b.room_type_id);
    update public.bookings set status = 'confirmed', room_id = v_room where id = p_booking_id;

  elsif p_status = 'checked_in' then
    if v_b.check_in > v_today then
      raise exception 'check-in is not possible before the arrival date' using errcode = '22023';
    end if;
    if v_b.check_out <= v_today then
      raise exception 'stay has already ended' using errcode = '22023';
    end if;
    update public.bookings set status = 'checked_in', checked_in_at = now() where id = p_booking_id;
    update public.rooms set status = 'occupied' where id = v_b.room_id;

  elsif p_status = 'checked_out' then
    -- ранний выезд освобождает оставшиеся ночи; сумма брони не меняется автоматически
    update public.bookings set
      status = 'checked_out', checked_out_at = now(),
      check_out = case when v_today < v_b.check_out then greatest(v_today, v_b.check_in + 1) else v_b.check_out end
    where id = p_booking_id;
    update public.rooms set status = 'cleaning' where id = v_b.room_id;

  elsif p_status = 'no_show' then
    if v_b.check_in > v_today then
      raise exception 'no-show is possible only from the arrival date' using errcode = '22023';
    end if;
    update public.bookings set status = 'no_show', cancelled_at = now(),
      cancel_reason = nullif(trim(p_reason), '') where id = p_booking_id;

  elsif p_status = 'cancelled' then
    if v_b.status = 'confirmed' and coalesce(trim(p_reason), '') = '' then
      raise exception 'cancellation reason is required' using errcode = '22023';
    end if;
    update public.bookings set status = 'cancelled', cancelled_at = now(),
      cancel_reason = nullif(trim(p_reason), '') where id = p_booking_id;
  end if;

  perform app.log_audit(v_b.tenant_id, 'booking.status', 'booking', p_booking_id, 'success',
    jsonb_build_object('from', v_b.status, 'to', p_status, 'reason', nullif(trim(p_reason), '')));
end $$;

-- Статус номера (уборка, обслуживание). Горничная (rooms.status) не может пометить
-- свободным номер, в котором проживает гость, и не может поставить «занят» вручную.
create or replace function public.set_room_status(p_room_id uuid, p_status public.room_status) returns void
language plpgsql security definer set search_path = '' as $$
declare v_room public.rooms;
begin
  select * into v_room from public.rooms where id = p_room_id for update;
  if not found or not (app.has_permission(v_room.tenant_id, 'rooms.status')
                       or app.has_permission(v_room.tenant_id, 'rooms.write')) then
    raise exception 'room not found or permission denied' using errcode = '42501';
  end if;
  if not app.subscription_writable(v_room.tenant_id) then
    raise exception 'subscription is read-only' using errcode = '42501';
  end if;
  if p_status = 'occupied' then
    raise exception 'occupied is set by check-in only' using errcode = '22023';
  end if;
  if exists (select 1 from public.bookings b where b.room_id = p_room_id and b.status = 'checked_in') then
    raise exception 'a guest is checked in to this room' using errcode = '22023';
  end if;
  update public.rooms set status = p_status where id = p_room_id;
  perform app.log_audit(v_room.tenant_id, 'room.status', 'room', p_room_id, 'success',
    jsonb_build_object('from', v_room.status, 'to', p_status));
end $$;

-- Сводка на сегодня для главной страницы (реальные данные, без оценок)
create or replace function public.today_summary(p_tenant uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_today date;
begin
  if not app.has_permission(p_tenant, 'bookings.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  v_today := app.tenant_today(p_tenant);
  return jsonb_build_object(
    'date', v_today,
    'arrivals', (select count(*) from public.bookings
                 where tenant_id = p_tenant and check_in = v_today and status = 'confirmed'),
    'departures', (select count(*) from public.bookings
                   where tenant_id = p_tenant and check_out = v_today and status = 'checked_in'),
    'in_house', (select count(*) from public.bookings where tenant_id = p_tenant and status = 'checked_in'),
    'requests', (select count(*) from public.bookings where tenant_id = p_tenant and status = 'new_request'),
    'rooms_total', (select count(*) from public.rooms where tenant_id = p_tenant and is_active),
    'rooms_occupied', (select count(distinct room_id) from public.bookings
                       where tenant_id = p_tenant and status = 'checked_in')
  );
end $$;

-- ---------------------------------------------------------------------------
-- Публичная страница: категории номеров и заявка на бронирование
-- ---------------------------------------------------------------------------

create or replace function public.get_public_room_types(p_slug text)
returns table (id uuid, name text, description text, base_occupancy integer, max_occupancy integer,
               price_from numeric)
language sql stable security definer set search_path = '' as $$
  select t.id, t.name, t.description, t.base_occupancy, t.max_occupancy,
         least(t.base_price, coalesce((select min(r.price_per_night) from public.room_rates r
                                       where r.room_type_id = t.id and r.ends_on >= current_date), t.base_price))
  from public.room_types t
  join public.organizations o on o.id = t.tenant_id
  where o.slug = lower(p_slug) and o.is_published and t.is_active and t.is_public
  order by t.sort_order, t.base_price
$$;

-- Ориентировочная стоимость для гостя на сайте (без проверки наличия номеров)
create or replace function public.public_quote(
  p_slug text, p_room_type_id uuid, p_check_in date, p_check_out date, p_adults integer, p_children integer
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_tenant uuid; v_price jsonb;
begin
  select t.tenant_id into v_tenant
  from public.room_types t join public.organizations o on o.id = t.tenant_id
  where t.id = p_room_type_id and o.slug = lower(p_slug) and o.is_published and t.is_active and t.is_public;
  if v_tenant is null then
    raise exception 'room type not found' using errcode = 'P0002';
  end if;
  if p_check_out - p_check_in > 60 then
    raise exception 'stay is too long for an online request' using errcode = '22023';
  end if;
  v_price := app.calc_booking_price(v_tenant, p_room_type_id, p_check_in, p_check_out, p_adults, p_children);
  return jsonb_build_object('total', v_price -> 'total', 'nights', v_price -> 'nights');
end $$;

-- Заявка с публичной страницы. Создаёт бронь в статусе new_request без номера;
-- администратор подтверждает её и выбирает номер. Гость находится по телефону или создаётся.
-- Антиспам: не больше 3 открытых заявок с одного телефона и 30 заявок в час на санаторий.
create or replace function public.submit_booking_request(
  p_slug text, p_room_type_id uuid, p_check_in date, p_check_out date,
  p_adults integer, p_children integer, p_full_name text, p_phone text,
  p_comment text default null, p_consent boolean default false
) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_tenant uuid;
  v_today  date;
  v_guest  uuid;
  v_price  jsonb;
  v_number integer;
  v_id     uuid;
begin
  if not coalesce(p_consent, false) then
    raise exception 'consent to personal data processing is required' using errcode = '22023';
  end if;
  if p_phone is null or p_phone !~ '^\+7[0-9]{10}$' then
    raise exception 'phone must be in +7XXXXXXXXXX format' using errcode = '22023';
  end if;
  if char_length(trim(coalesce(p_full_name, ''))) not between 2 and 200 then
    raise exception 'name is required' using errcode = '22023';
  end if;
  if char_length(coalesce(p_comment, '')) > 1000 then
    raise exception 'comment is too long' using errcode = '22023';
  end if;

  select t.tenant_id into v_tenant
  from public.room_types t join public.organizations o on o.id = t.tenant_id
  where t.id = p_room_type_id and o.slug = lower(p_slug) and o.is_published and t.is_active and t.is_public;
  if v_tenant is null then
    raise exception 'room type not found' using errcode = 'P0002';
  end if;
  if not (app.feature_enabled(v_tenant, 'public_site') and app.feature_enabled(v_tenant, 'bookings')) then
    raise exception 'online requests are not available' using errcode = '42501';
  end if;

  v_today := app.tenant_today(v_tenant);
  if p_check_in < v_today or p_check_in > v_today + 730 then
    raise exception 'check-in date is out of range' using errcode = '22023';
  end if;
  if p_check_out - p_check_in > 60 then
    raise exception 'stay is too long for an online request' using errcode = '22023';
  end if;

  if (select count(*) from public.bookings b
      where b.tenant_id = v_tenant and b.source = 'website' and b.created_at > now() - interval '1 hour') >= 30
     or (select count(*) from public.bookings b join public.guests g on g.id = b.guest_id
         where b.tenant_id = v_tenant and g.phone = p_phone and b.status = 'new_request') >= 3 then
    raise exception 'too many requests, please call the sanatorium' using errcode = '54000';
  end if;

  v_price := app.calc_booking_price(v_tenant, p_room_type_id, p_check_in, p_check_out, p_adults, p_children);

  -- существующего гостя не меняем (аноним не может перезаписать чужие данные)
  select id into v_guest from public.guests
  where tenant_id = v_tenant and phone = p_phone and archived_at is null;
  if v_guest is null then
    insert into public.guests (tenant_id, full_name, phone, consent_at)
    values (v_tenant, trim(p_full_name), p_phone, now())
    returning id into v_guest;
  end if;

  v_number := app.next_booking_number(v_tenant);
  insert into public.bookings (
    tenant_id, number, guest_id, room_type_id, check_in, check_out, adults, children,
    status, source, total_amount, price_breakdown, guest_comment, internal_notes)
  values (
    v_tenant, v_number, v_guest, p_room_type_id, p_check_in, p_check_out, p_adults, coalesce(p_children, 0),
    'new_request', 'website', (v_price ->> 'total')::numeric, v_price -> 'nights_detail',
    nullif(trim(p_comment), ''),
    -- имя из заявки может отличаться от карточки найденного гостя
    'Имя в заявке: ' || trim(p_full_name))
  returning id into v_id;

  perform app.log_audit(v_tenant, 'booking.request', 'booking', v_id);
  return v_number;
end $$;

-- ---------------------------------------------------------------------------
-- Доступ к функциям
-- ---------------------------------------------------------------------------

revoke all on function
  app.tenant_today(uuid),
  app.calc_booking_price(uuid, uuid, date, date, integer, integer),
  app.can_write_bookings(uuid, text),
  app.next_booking_number(uuid),
  app.check_room_for_booking(uuid, uuid, uuid),
  app.enforce_room_limit(),
  app.protect_guest_archive()
  from public, anon, authenticated;

revoke execute on function
  public.quote_booking(uuid, uuid, date, date, integer, integer),
  public.available_rooms(uuid, date, date, uuid, uuid),
  public.create_booking(uuid, uuid, uuid, uuid, date, date, integer, integer, public.booking_source, text, public.booking_status),
  public.update_booking(uuid, uuid, uuid, date, date, integer, integer, text, text),
  public.set_booking_status(uuid, public.booking_status, text, uuid),
  public.set_room_status(uuid, public.room_status),
  public.today_summary(uuid),
  public.get_public_room_types(text),
  public.public_quote(text, uuid, date, date, integer, integer),
  public.submit_booking_request(text, uuid, date, date, integer, integer, text, text, text, boolean)
  from public, anon;

grant execute on function
  public.quote_booking(uuid, uuid, date, date, integer, integer),
  public.available_rooms(uuid, date, date, uuid, uuid),
  public.create_booking(uuid, uuid, uuid, uuid, date, date, integer, integer, public.booking_source, text, public.booking_status),
  public.update_booking(uuid, uuid, uuid, date, date, integer, integer, text, text),
  public.set_booking_status(uuid, public.booking_status, text, uuid),
  public.set_room_status(uuid, public.room_status),
  public.today_summary(uuid)
  to authenticated;

grant execute on function
  public.get_public_room_types(text),
  public.public_quote(text, uuid, date, date, integer, integer),
  public.submit_booking_request(text, uuid, date, date, integer, integer, text, text, text, boolean)
  to anon, authenticated;
