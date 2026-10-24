-- Sanatorium OS: обновление базы, миграция 20261031000013_leads.sql.
-- Supabase → SQL Editor → New query → вставить весь файл → Run. Каждое обновление применяется один раз.
-- Не редактируйте вручную: файл пересобирается скриптом scripts/build-setup-sql.sh
begin;

-- Sanatorium OS · 0013 · Заявки (лиды)
-- Принципы:
--  * заявка — обращение до брони: звонок, сообщение WhatsApp, заявка с сайта, визит, агент;
--    у неё есть статус (новая → в работе → бронь / отказ), ответственный и дата следующего контакта;
--  * заявка с сайта (submit_booking_request) по-прежнему создаёт бронь «заявка» без номера, а рядом —
--    заявку со ссылкой на эту бронь; когда бронь подтверждают, заявка закрывается как «бронь»,
--    когда отменяют — как «отказ»;
--  * входящее WhatsApp с незнакомого номера (нет гостя и открытой заявки) создаёт новую заявку;
--  * бронь из заявки создаёт функция create_booking_from_lead: внутри обычный create_booking,
--    поэтому цену по-прежнему считает сервер;
--  * записи меняются только функциями; читать — leads.read, работать — leads.write; заявки входят в модуль
--    «bookings» (все тарифы); при истёкшей подписке всё читается, но не меняется;
--  * в журнал пишутся действия и названия изменённых полей, без телефонов и текста заметок.

create type public.lead_status as enum ('new', 'in_progress', 'won', 'lost');
create type public.lead_lost_reason as enum ('price', 'no_dates', 'no_answer', 'competitor', 'not_relevant', 'booking_cancelled', 'other');

create table public.lead_counters (
  tenant_id   uuid primary key references public.organizations(id) on delete cascade,
  last_number integer not null default 0
);
alter table public.lead_counters enable row level security;
revoke all on public.lead_counters from anon, authenticated;

create table public.leads (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.organizations(id) on delete cascade,
  number          integer not null,
  status          public.lead_status not null default 'new',
  source          public.booking_source not null default 'phone',
  full_name       text check (char_length(full_name) between 1 and 200),
  phone           text check (phone ~ '^\+[1-9][0-9]{6,14}$'),
  guest_id        uuid,
  booking_id      uuid,
  room_type_id    uuid,
  check_in        date,
  check_out       date,
  adults          smallint check (adults between 1 and 50),
  children        smallint check (children between 0 and 50),
  interest        text check (char_length(interest) <= 500),
  comment         text check (char_length(comment) <= 2000),
  assignee_id     uuid references auth.users(id) on delete set null,
  next_contact_at timestamptz,
  lost_reason     public.lead_lost_reason,
  lost_note       text check (char_length(lost_note) <= 500),
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  closed_at       timestamptz,
  unique (tenant_id, id),
  unique (tenant_id, number),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id) on delete set null (guest_id),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id) on delete set null (booking_id),
  foreign key (tenant_id, room_type_id) references public.room_types (tenant_id, id) on delete set null (room_type_id),
  constraint lead_contact check (full_name is not null or phone is not null),
  constraint lead_dates check (check_out is null or (check_in is not null and check_out > check_in and check_out - check_in <= 365)),
  constraint lead_lost check ((status = 'lost') = (lost_reason is not null)),
  constraint lead_closed check ((status in ('won', 'lost')) = (closed_at is not null))
);
create index leads_tenant_status_idx on public.leads (tenant_id, status, created_at desc);
create index leads_phone_idx on public.leads (tenant_id, phone) where phone is not null;
create index leads_booking_idx on public.leads (booking_id) where booking_id is not null;

create table public.lead_notes (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.organizations(id) on delete cascade,
  lead_id    uuid not null,
  body       text not null check (char_length(trim(body)) between 1 and 2000),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (tenant_id, lead_id) references public.leads (tenant_id, id) on delete cascade
);
create index lead_notes_lead_idx on public.lead_notes (tenant_id, lead_id, created_at);

create trigger leads_tenant before update on public.leads
  for each row execute function app.forbid_tenant_change();
create trigger leads_touch before update on public.leads
  for each row execute function app.touch_updated_at();

alter table public.leads enable row level security;
alter table public.lead_notes enable row level security;
create policy leads_select on public.leads for select to authenticated
  using (app.has_permission(tenant_id, 'leads.read'));
create policy lead_notes_select on public.lead_notes for select to authenticated
  using (app.has_permission(tenant_id, 'leads.read'));
revoke insert, update, delete on public.leads, public.lead_notes from authenticated;
revoke all on public.leads, public.lead_notes from anon;

-- ---------------------------------------------------------------------------
-- Вспомогательные функции
-- ---------------------------------------------------------------------------

create or replace function app.next_lead_number(p_tenant uuid) returns integer
language sql security definer set search_path = '' as $$
  insert into public.lead_counters as c (tenant_id, last_number) values (p_tenant, 1)
  on conflict (tenant_id) do update set last_number = c.last_number + 1
  returning last_number
$$;

-- Проверка полей заявки (общая для создания и изменения)
create or replace function app.check_lead_fields(
  p_tenant uuid, p_full_name text, p_phone text, p_room_type_id uuid, p_check_in date, p_check_out date,
  p_adults integer, p_children integer, p_interest text, p_comment text, p_assignee uuid
) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if nullif(btrim(coalesce(p_full_name, '')), '') is null and p_phone is null then
    raise exception 'name or phone is required' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_full_name, ''))) > 200 or char_length(coalesce(p_interest, '')) > 500
     or char_length(coalesce(p_comment, '')) > 2000 then
    raise exception 'text is too long' using errcode = '22023';
  end if;
  if p_phone is not null and p_phone !~ '^\+[1-9][0-9]{6,14}$' then
    raise exception 'invalid phone' using errcode = '22023';
  end if;
  if (p_check_out is not null and (p_check_in is null or p_check_out <= p_check_in or p_check_out - p_check_in > 365)) then
    raise exception 'invalid dates' using errcode = '22023';
  end if;
  if (p_adults is not null and p_adults not between 1 and 50) or (p_children is not null and p_children not between 0 and 50) then
    raise exception 'invalid guests count' using errcode = '22023';
  end if;
  if p_room_type_id is not null and not exists (select 1 from public.room_types where id = p_room_type_id and tenant_id = p_tenant) then
    raise exception 'room type not found' using errcode = 'P0002';
  end if;
  if p_assignee is not null and not app.member_has_permission(p_tenant, p_assignee, 'leads.write') then
    raise exception 'assignee is not available' using errcode = '22023';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Операции сотрудников
-- ---------------------------------------------------------------------------

create or replace function public.create_lead(
  p_tenant uuid, p_source public.booking_source, p_full_name text, p_phone text,
  p_room_type_id uuid default null, p_check_in date default null, p_check_out date default null,
  p_adults integer default null, p_children integer default null, p_interest text default null,
  p_comment text default null, p_assignee_id uuid default null, p_next_contact_at timestamptz default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_guest uuid;
begin
  if not app.can_write_bookings(p_tenant, 'leads.write') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  perform app.check_lead_fields(p_tenant, p_full_name, p_phone, p_room_type_id, p_check_in, p_check_out,
    p_adults, p_children, p_interest, p_comment, p_assignee_id);
  if p_phone is not null then
    select id into v_guest from public.guests where tenant_id = p_tenant and phone = p_phone and archived_at is null;
  end if;

  insert into public.leads (tenant_id, number, source, full_name, phone, guest_id, room_type_id, check_in, check_out,
    adults, children, interest, comment, assignee_id, next_contact_at, created_by)
  values (p_tenant, app.next_lead_number(p_tenant), coalesce(p_source, 'phone'), nullif(btrim(p_full_name), ''), p_phone, v_guest,
    p_room_type_id, p_check_in, p_check_out, p_adults, p_children, nullif(btrim(p_interest), ''), nullif(btrim(p_comment), ''),
    p_assignee_id, p_next_contact_at, auth.uid())
  returning id into v_id;

  perform app.log_audit(p_tenant, 'lead.create', 'lead', v_id, 'success',
    jsonb_build_object('source', coalesce(p_source, 'phone'), 'assignee_id', p_assignee_id));
  return v_id;
end $$;

create or replace function public.update_lead(
  p_lead_id uuid, p_source public.booking_source, p_full_name text, p_phone text,
  p_room_type_id uuid, p_check_in date, p_check_out date, p_adults integer, p_children integer,
  p_interest text, p_comment text, p_assignee_id uuid, p_next_contact_at timestamptz
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_l public.leads;
  v_n public.leads;
  v_changed text[] := '{}';
begin
  select * into v_l from public.leads where id = p_lead_id for update;
  if not found or not app.can_write_bookings(v_l.tenant_id, 'leads.write') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_l.status in ('won', 'lost') then
    raise exception 'lead is closed' using errcode = '22023';
  end if;
  perform app.check_lead_fields(v_l.tenant_id, p_full_name, p_phone, p_room_type_id, p_check_in, p_check_out,
    p_adults, p_children, p_interest, p_comment, p_assignee_id);

  update public.leads set
    source = coalesce(p_source, source),
    full_name = nullif(btrim(p_full_name), ''),
    phone = p_phone,
    guest_id = case when p_phone is distinct from v_l.phone
                    then (select id from public.guests where tenant_id = v_l.tenant_id and phone = p_phone and archived_at is null)
                    else guest_id end,
    room_type_id = p_room_type_id, check_in = p_check_in, check_out = p_check_out,
    adults = p_adults, children = p_children,
    interest = nullif(btrim(p_interest), ''), comment = nullif(btrim(p_comment), ''),
    assignee_id = p_assignee_id, next_contact_at = p_next_contact_at
  where id = p_lead_id
  returning * into v_n;

  if v_n.source is distinct from v_l.source then v_changed := v_changed || 'source'::text; end if;
  if v_n.full_name is distinct from v_l.full_name then v_changed := v_changed || 'full_name'::text; end if;
  if v_n.phone is distinct from v_l.phone then v_changed := v_changed || 'phone'::text; end if;
  if v_n.room_type_id is distinct from v_l.room_type_id then v_changed := v_changed || 'room_type'::text; end if;
  if v_n.check_in is distinct from v_l.check_in or v_n.check_out is distinct from v_l.check_out then v_changed := v_changed || 'dates'::text; end if;
  if v_n.adults is distinct from v_l.adults or v_n.children is distinct from v_l.children then v_changed := v_changed || 'guests'::text; end if;
  if v_n.interest is distinct from v_l.interest then v_changed := v_changed || 'interest'::text; end if;
  if v_n.comment is distinct from v_l.comment then v_changed := v_changed || 'comment'::text; end if;
  if v_n.next_contact_at is distinct from v_l.next_contact_at then v_changed := v_changed || 'next_contact_at'::text; end if;
  if v_n.assignee_id is distinct from v_l.assignee_id then v_changed := v_changed || 'assignee'::text; end if;
  if cardinality(v_changed) > 0 then
    perform app.log_audit(v_l.tenant_id, 'lead.update', 'lead', p_lead_id, 'success',
      jsonb_build_object('changed', to_jsonb(v_changed), 'number', v_l.number));
  end if;
end $$;

-- Смена статуса вручную: в работу (в том числе вернуть из отказа) или отказ с причиной.
-- «Бронь» ставится только созданием или подтверждением брони.
create or replace function public.set_lead_status(
  p_lead_id uuid, p_status public.lead_status, p_lost_reason public.lead_lost_reason default null, p_note text default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_l public.leads;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  select * into v_l from public.leads where id = p_lead_id for update;
  if not found or not app.can_write_bookings(v_l.tenant_id, 'leads.write') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if char_length(coalesce(v_note, '')) > 500 then
    raise exception 'text is too long' using errcode = '22023';
  end if;
  if p_status = 'in_progress' and v_l.status in ('new', 'lost') then
    update public.leads set status = 'in_progress', lost_reason = null, lost_note = null, closed_at = null,
      assignee_id = coalesce(assignee_id, case when app.member_has_permission(v_l.tenant_id, auth.uid(), 'leads.write') then auth.uid() end)
    where id = p_lead_id;
  elsif p_status = 'lost' and v_l.status in ('new', 'in_progress') then
    if p_lost_reason is null or p_lost_reason = 'booking_cancelled' then
      raise exception 'lost reason is required' using errcode = '22023';
    end if;
    update public.leads set status = 'lost', lost_reason = p_lost_reason, lost_note = v_note, closed_at = now()
    where id = p_lead_id;
  else
    raise exception 'status change is not allowed' using errcode = '22023';
  end if;
  perform app.log_audit(v_l.tenant_id, 'lead.status', 'lead', p_lead_id, 'success',
    jsonb_build_object('from', v_l.status, 'to', p_status, 'number', v_l.number)
    || case when p_status = 'lost' then jsonb_build_object('reason', p_lost_reason) else '{}'::jsonb end);
end $$;

create or replace function public.add_lead_note(p_lead_id uuid, p_body text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_l public.leads;
  v_id uuid;
begin
  select * into v_l from public.leads where id = p_lead_id;
  if not found or not app.can_write_bookings(v_l.tenant_id, 'leads.write') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if char_length(btrim(coalesce(p_body, ''))) not between 1 and 2000 then
    raise exception 'note is required' using errcode = '22023';
  end if;
  insert into public.lead_notes (tenant_id, lead_id, body, created_by)
  values (v_l.tenant_id, p_lead_id, btrim(p_body), auth.uid())
  returning id into v_id;
  -- заметка — это контакт с гостем: заявка уходит из «новых»
  if v_l.status = 'new' then
    update public.leads set status = 'in_progress',
      assignee_id = coalesce(assignee_id, case when app.member_has_permission(v_l.tenant_id, auth.uid(), 'leads.write') then auth.uid() end)
    where id = p_lead_id;
  end if;
  return v_id;
end $$;

-- Бронь из заявки: обычный create_booking (права bookings.write, цена на сервере) + связь с заявкой.
-- С номером бронь подтверждена и заявка закрывается как «бронь»; без номера — бронь-заявка, заявка остаётся в работе.
create or replace function public.create_booking_from_lead(
  p_lead_id uuid, p_guest_id uuid, p_room_type_id uuid, p_room_id uuid,
  p_check_in date, p_check_out date, p_adults integer default 1, p_children integer default 0, p_comment text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_l public.leads;
  v_id uuid;
  v_number integer;
begin
  select * into v_l from public.leads where id = p_lead_id for update;
  if not found or not app.can_write_bookings(v_l.tenant_id, 'leads.write') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_l.status in ('won', 'lost') then
    raise exception 'lead is closed' using errcode = '22023';
  end if;
  if v_l.booking_id is not null then
    raise exception 'lead already has a booking' using errcode = '22023';
  end if;

  v_id := public.create_booking(v_l.tenant_id, p_guest_id, p_room_type_id, p_room_id, p_check_in, p_check_out,
    p_adults, p_children, v_l.source, p_comment,
    case when p_room_id is null then 'new_request'::public.booking_status else 'confirmed'::public.booking_status end);
  select number into v_number from public.bookings where id = v_id;

  update public.leads set booking_id = v_id, guest_id = p_guest_id,
    status = case when p_room_id is null then 'in_progress'::public.lead_status else 'won'::public.lead_status end,
    closed_at = case when p_room_id is null then null else now() end
  where id = p_lead_id;
  perform app.log_audit(v_l.tenant_id, 'lead.convert', 'lead', p_lead_id, 'success',
    jsonb_build_object('number', v_l.number, 'booking', v_number));
  return v_id;
end $$;

-- Счётчики для меню и обзора
create or replace function public.lead_counts(p_tenant uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.has_permission(p_tenant, 'leads.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  return (
    select jsonb_build_object(
      'new', count(*) filter (where status = 'new'),
      'open', count(*) filter (where status in ('new', 'in_progress')),
      'overdue', count(*) filter (where status in ('new', 'in_progress') and next_contact_at < now()),
      'mine', count(*) filter (where status in ('new', 'in_progress') and assignee_id = auth.uid()))
    from public.leads where tenant_id = p_tenant);
end $$;

-- Ответственные за заявки: сотрудники с leads.write (добавлено к прежним вариантам)
create or replace function public.staff_directory(p_tenant uuid, p_permission text)
returns table (user_id uuid, full_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_permission not in ('procedures.status', 'tasks.read', 'leads.write') or not app.is_member(p_tenant) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  return query
    select m.user_id, coalesce(nullif(trim(u.full_name), ''), '—')
    from public.organization_members m
    left join public.user_profiles u on u.id = m.user_id
    where m.tenant_id = p_tenant and m.status = 'active'
      and app.member_has_permission(p_tenant, m.user_id, p_permission)
    order by 2;
end $$;

-- ---------------------------------------------------------------------------
-- Автоматические заявки
-- ---------------------------------------------------------------------------

-- Заявка с сайта: бронь без номера, созданная анонимом через submit_booking_request
create or replace function app.lead_from_website_booking() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_g public.guests;
begin
  select * into v_g from public.guests where id = new.guest_id;
  insert into public.leads (tenant_id, number, source, full_name, phone, guest_id, booking_id, room_type_id,
    check_in, check_out, adults, children, comment)
  values (new.tenant_id, app.next_lead_number(new.tenant_id), 'website',
    -- имя из формы (submit_booking_request кладёт его в служебную заметку брони), иначе из карточки гостя
    coalesce(nullif(left(btrim(substring(new.internal_notes from '^Имя в заявке: (.*)$')), 200), ''), left(v_g.full_name, 200)),
    v_g.phone, new.guest_id, new.id, new.room_type_id, new.check_in, new.check_out, new.adults, new.children, new.guest_comment);
  return null;
end $$;

create trigger bookings_website_lead after insert on public.bookings
  for each row when (new.source = 'website' and new.status = 'new_request' and auth.uid() is null)
  execute function app.lead_from_website_booking();

-- Судьба брони закрывает заявку: подтверждение — «бронь», отмена — «отказ»
create or replace function app.sync_lead_with_booking() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_l public.leads;
  v_to public.lead_status;
begin
  v_to := case when new.status in ('confirmed', 'checked_in', 'checked_out') then 'won'::public.lead_status
               when new.status in ('cancelled', 'no_show') then 'lost'::public.lead_status end;
  if v_to is null then
    return null;
  end if;
  for v_l in select * from public.leads where booking_id = new.id and status in ('new', 'in_progress') for update loop
    update public.leads set status = v_to, closed_at = now(),
      lost_reason = case when v_to = 'lost' then 'booking_cancelled'::public.lead_lost_reason end
    where id = v_l.id;
    perform app.log_audit(v_l.tenant_id, 'lead.status', 'lead', v_l.id, 'success',
      jsonb_build_object('from', v_l.status, 'to', v_to, 'number', v_l.number));
  end loop;
  return null;
end $$;

create trigger bookings_sync_lead after update of status on public.bookings
  for each row when (old.status is distinct from new.status)
  execute function app.sync_lead_with_booking();

-- Входящее WhatsApp с незнакомого номера: нет гостя и нет открытой заявки → новая заявка
create or replace function app.lead_from_whatsapp() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.guest_id is not null
     or exists (select 1 from public.guests where tenant_id = new.tenant_id and phone = new.phone and archived_at is null)
     or exists (select 1 from public.leads where tenant_id = new.tenant_id and phone = new.phone and status in ('new', 'in_progress')) then
    return null;
  end if;
  insert into public.leads (tenant_id, number, source, full_name, phone, comment)
  values (new.tenant_id, app.next_lead_number(new.tenant_id), 'whatsapp',
    nullif(left(btrim(coalesce(new.contact_name, '')), 200), ''), new.phone, nullif(left(btrim(coalesce(new.body, '')), 2000), ''));
  return null;
end $$;

create trigger messages_whatsapp_lead after insert on public.messages
  for each row when (new.direction = 'in')
  execute function app.lead_from_whatsapp();

-- Открытые заявки с сайта, пришедшие до этого обновления
do $$
declare
  b record;
begin
  for b in select bk.* from public.bookings bk
           where bk.source = 'website' and bk.status = 'new_request'
             and not exists (select 1 from public.leads l where l.booking_id = bk.id)
           order by bk.created_at loop
    insert into public.leads (tenant_id, number, source, full_name, phone, guest_id, booking_id, room_type_id,
      check_in, check_out, adults, children, comment, created_at)
    select b.tenant_id, app.next_lead_number(b.tenant_id), 'website',
      coalesce(nullif(left(btrim(substring(b.internal_notes from '^Имя в заявке: (.*)$')), 200), ''), left(g.full_name, 200)),
      g.phone, b.guest_id, b.id, b.room_type_id, b.check_in, b.check_out, b.adults, b.children, b.guest_comment, b.created_at
    from public.guests g where g.id = b.guest_id;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Доступ к функциям
-- ---------------------------------------------------------------------------

revoke all on function
  app.next_lead_number(uuid),
  app.check_lead_fields(uuid, text, text, uuid, date, date, integer, integer, text, text, uuid),
  app.lead_from_website_booking(),
  app.sync_lead_with_booking(),
  app.lead_from_whatsapp()
  from public, anon, authenticated;

revoke execute on function
  public.create_lead(uuid, public.booking_source, text, text, uuid, date, date, integer, integer, text, text, uuid, timestamptz),
  public.update_lead(uuid, public.booking_source, text, text, uuid, date, date, integer, integer, text, text, uuid, timestamptz),
  public.set_lead_status(uuid, public.lead_status, public.lead_lost_reason, text),
  public.add_lead_note(uuid, text),
  public.create_booking_from_lead(uuid, uuid, uuid, uuid, date, date, integer, integer, text),
  public.lead_counts(uuid),
  public.staff_directory(uuid, text)
  from public, anon;
grant execute on function
  public.create_lead(uuid, public.booking_source, text, text, uuid, date, date, integer, integer, text, text, uuid, timestamptz),
  public.update_lead(uuid, public.booking_source, text, text, uuid, date, date, integer, integer, text, text, uuid, timestamptz),
  public.set_lead_status(uuid, public.lead_status, public.lead_lost_reason, text),
  public.add_lead_note(uuid, text),
  public.create_booking_from_lead(uuid, uuid, uuid, uuid, date, date, integer, integer, text),
  public.lead_counts(uuid),
  public.staff_directory(uuid, text)
  to authenticated;

commit;
