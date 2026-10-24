-- Sanatorium OS · 0007 · Процедуры и задачи сотрудников
-- Принципы:
--  * процедуры — это расписание и счёт, а не медицинская карта: в записи нет диагнозов и назначений врача,
--    только вид процедуры, время, кабинет, специалист и короткая служебная заметка;
--  * цену процедуры берёт сервер из справочника в момент записи; «входит в путёвку» — цена 0;
--  * один кабинет, один специалист и один гость не могут быть заняты двумя процедурами одновременно
--    (exclusion constraints в БД);
--  * стоимость процедур по брони попадает в баланс брони (booking_balances);
--  * задачи видят исполнитель и те, кто назначает задачи; уборка после выезда создаётся автоматически.

create type public.procedure_status as enum ('scheduled', 'done', 'no_show', 'cancelled');
create type public.task_status as enum ('open', 'in_progress', 'done', 'cancelled');
create type public.task_priority as enum ('low', 'normal', 'high');
create type public.task_category as enum ('cleaning', 'maintenance', 'reception', 'medical', 'other');

-- ---------------------------------------------------------------------------
-- Справочник процедур и кабинеты
-- ---------------------------------------------------------------------------

create table public.procedure_types (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.organizations(id) on delete cascade,
  name         text not null check (char_length(trim(name)) between 1 and 200),
  duration_min integer not null check (duration_min between 5 and 480),
  price        numeric(14,2) not null default 0 check (price >= 0 and price <= 10000000),
  description  text check (char_length(description) <= 1000),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, name)
);

create table public.treatment_rooms (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.organizations(id) on delete cascade,
  name       text not null check (char_length(trim(name)) between 1 and 100),
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, name)
);

-- ---------------------------------------------------------------------------
-- Записи на процедуры
-- ---------------------------------------------------------------------------

create table public.procedure_appointments (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.organizations(id) on delete cascade,
  guest_id          uuid not null,
  booking_id        uuid,
  procedure_type_id uuid not null,
  treatment_room_id uuid,
  specialist_id     uuid,
  starts_at         timestamptz not null,
  ends_at           timestamptz not null,
  status            public.procedure_status not null default 'scheduled',
  price             numeric(14,2) not null default 0 check (price >= 0),
  included          boolean not null default false,
  note              text check (char_length(note) <= 500),
  cancel_reason     text check (char_length(cancel_reason) <= 500),
  created_by        uuid references auth.users(id) on delete set null,
  completed_by      uuid references auth.users(id) on delete set null,
  completed_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id),
  foreign key (tenant_id, procedure_type_id) references public.procedure_types (tenant_id, id),
  foreign key (tenant_id, treatment_room_id) references public.treatment_rooms (tenant_id, id),
  foreign key (tenant_id, specialist_id) references public.organization_members (tenant_id, user_id),
  constraint procedure_time_order check (ends_at > starts_at),
  constraint procedure_room_busy exclude using gist (
    treatment_room_id with =, tstzrange(starts_at, ends_at, '[)') with &&
  ) where (treatment_room_id is not null and status in ('scheduled', 'done')),
  constraint procedure_specialist_busy exclude using gist (
    specialist_id with =, tstzrange(starts_at, ends_at, '[)') with &&
  ) where (specialist_id is not null and status in ('scheduled', 'done')),
  constraint procedure_guest_busy exclude using gist (
    guest_id with =, tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status in ('scheduled', 'done'))
);
create index procedure_appointments_tenant_time_idx on public.procedure_appointments (tenant_id, starts_at);
create index procedure_appointments_booking_idx on public.procedure_appointments (booking_id) where booking_id is not null;

-- ---------------------------------------------------------------------------
-- Задачи сотрудников
-- ---------------------------------------------------------------------------

create table public.tasks (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.organizations(id) on delete cascade,
  title        text not null check (char_length(trim(title)) between 1 and 200),
  description  text check (char_length(description) <= 2000),
  category     public.task_category not null default 'other',
  priority     public.task_priority not null default 'normal',
  status       public.task_status not null default 'open',
  -- manual — создана сотрудником; room_cleaning — создана автоматически, когда номер ушёл на уборку
  source       text not null default 'manual' check (source in ('manual', 'room_cleaning')),
  assignee_id  uuid,
  room_id      uuid,
  due_at       timestamptz,
  created_by   uuid references auth.users(id) on delete set null,
  completed_by uuid references auth.users(id) on delete set null,
  completed_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  foreign key (tenant_id, assignee_id) references public.organization_members (tenant_id, user_id),
  foreign key (tenant_id, room_id) references public.rooms (tenant_id, id)
);
create index tasks_tenant_status_idx on public.tasks (tenant_id, status, due_at);
create index tasks_assignee_idx on public.tasks (assignee_id) where status in ('open', 'in_progress');

create trigger procedure_types_tenant before update on public.procedure_types
  for each row execute function app.forbid_tenant_change();
create trigger procedure_types_updated_at before update on public.procedure_types
  for each row execute function app.touch_updated_at();
create trigger treatment_rooms_tenant before update on public.treatment_rooms
  for each row execute function app.forbid_tenant_change();
create trigger procedure_appointments_tenant before update on public.procedure_appointments
  for each row execute function app.forbid_tenant_change();
create trigger procedure_appointments_updated_at before update on public.procedure_appointments
  for each row execute function app.touch_updated_at();
create trigger tasks_tenant before update on public.tasks
  for each row execute function app.forbid_tenant_change();
create trigger tasks_updated_at before update on public.tasks
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.procedure_types        enable row level security;
alter table public.treatment_rooms        enable row level security;
alter table public.procedure_appointments enable row level security;
alter table public.tasks                  enable row level security;

-- Справочник процедур нужен расписанию и карточке брони; правят врач, директор, владелец
create policy procedure_types_select on public.procedure_types for select to authenticated
  using (app.has_permission(tenant_id, 'procedures.read') or app.has_permission(tenant_id, 'bookings.read'));
create policy procedure_types_insert on public.procedure_types for insert to authenticated
  with check (app.has_permission(tenant_id, 'procedures.write') and app.feature_enabled(tenant_id, 'procedures'));
create policy procedure_types_update on public.procedure_types for update to authenticated
  using (app.has_permission(tenant_id, 'procedures.write'))
  with check (app.has_permission(tenant_id, 'procedures.write') and app.feature_enabled(tenant_id, 'procedures'));

create policy treatment_rooms_select on public.treatment_rooms for select to authenticated
  using (app.has_permission(tenant_id, 'procedures.read'));
create policy treatment_rooms_insert on public.treatment_rooms for insert to authenticated
  with check (app.has_permission(tenant_id, 'procedures.write') and app.feature_enabled(tenant_id, 'procedures'));
create policy treatment_rooms_update on public.treatment_rooms for update to authenticated
  using (app.has_permission(tenant_id, 'procedures.write'))
  with check (app.has_permission(tenant_id, 'procedures.write') and app.feature_enabled(tenant_id, 'procedures'));

-- Записи видят расписание (procedures.read) и касса/финансы — иначе баланс брони считался бы неверно.
-- Запись — только функциями.
create policy procedure_appointments_select on public.procedure_appointments for select to authenticated
  using (app.has_permission(tenant_id, 'procedures.read') or app.has_permission(tenant_id, 'finance.read')
         or app.has_permission(tenant_id, 'payments.accept'));

-- Задачи: назначающий (tasks.write) видит все; остальные — свои, общие (без исполнителя) и созданные ими
create policy tasks_select on public.tasks for select to authenticated
  using (app.has_permission(tenant_id, 'tasks.write')
         or (app.has_permission(tenant_id, 'tasks.read')
             and (assignee_id = auth.uid() or assignee_id is null or created_by = auth.uid())));

-- ---------------------------------------------------------------------------
-- Баланс брони теперь включает процедуры (запланированные и проведённые)
-- ---------------------------------------------------------------------------

create or replace view public.booking_balances with (security_invoker = true) as
select
  b.id as booking_id,
  b.tenant_id,
  b.total_amount as accommodation,
  coalesce(x.extras, 0)::numeric(14,2) as extras,
  (case when b.status in ('cancelled', 'no_show') then 0
        else b.total_amount + coalesce(x.extras, 0) + coalesce(pr.procedures, 0) end)::numeric(14,2) as charges,
  coalesce(p.paid, 0)::numeric(14,2) as paid,
  coalesce(p.refunded, 0)::numeric(14,2) as refunded,
  (coalesce(p.paid, 0) - coalesce(p.refunded, 0))::numeric(14,2) as paid_net,
  ((case when b.status in ('cancelled', 'no_show') then 0
         else b.total_amount + coalesce(x.extras, 0) + coalesce(pr.procedures, 0) end)
    - coalesce(p.paid, 0) + coalesce(p.refunded, 0))::numeric(14,2) as balance,
  coalesce(pr.procedures, 0)::numeric(14,2) as procedures
from public.bookings b
left join (
  select booking_id, sum(amount) as extras from public.booking_extras group by booking_id
) x on x.booking_id = b.id
left join (
  select booking_id, sum(price) as procedures from public.procedure_appointments
  where booking_id is not null and status in ('scheduled', 'done') group by booking_id
) pr on pr.booking_id = b.id
left join (
  select booking_id,
         sum(amount) filter (where kind = 'payment') as paid,
         sum(amount) filter (where kind = 'refund') as refunded
  from public.booking_payments where voided_at is null group by booking_id
) p on p.booking_id = b.id;

-- ---------------------------------------------------------------------------
-- Вспомогательные проверки
-- ---------------------------------------------------------------------------

-- Есть ли у сотрудника (не у текущего пользователя) право в организации
create or replace function app.member_has_permission(p_tenant uuid, p_user uuid, p_code text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.organization_members m
    join public.role_permissions rp on rp.role_id = m.role_id
    join public.permissions p on p.id = rp.permission_id
    where m.tenant_id = p_tenant and m.user_id = p_user and m.status = 'active' and p.code = p_code
  )
$$;

-- Проверка места и времени процедуры; возвращает ends_at
create or replace function app.check_procedure_slot(
  p_tenant uuid, p_guest uuid, p_booking uuid, p_starts timestamptz, p_duration interval,
  p_room uuid, p_specialist uuid
) returns timestamptz
language plpgsql stable security definer set search_path = '' as $$
declare
  v_tz  text;
  v_day date;
  v_b   public.bookings;
begin
  if p_starts is null then
    raise exception 'start time is required' using errcode = '22023';
  end if;
  if p_starts < now() - interval '1 day' then
    raise exception 'procedure time is in the past' using errcode = '22023';
  end if;
  select coalesce(timezone, 'Asia/Almaty') into v_tz from public.organizations where id = p_tenant;
  v_day := (p_starts at time zone v_tz)::date;

  if p_booking is not null then
    select * into v_b from public.bookings where id = p_booking and tenant_id = p_tenant;
    if not found or v_b.guest_id <> p_guest then
      raise exception 'booking does not belong to the guest' using errcode = '22023';
    end if;
    if v_b.status not in ('confirmed', 'checked_in') then
      raise exception 'booking is not active' using errcode = '22023';
    end if;
    if v_day < v_b.check_in or v_day > v_b.check_out then
      raise exception 'procedure is outside the stay dates' using errcode = '22023';
    end if;
  end if;

  if p_room is not null and not exists (
    select 1 from public.treatment_rooms where id = p_room and tenant_id = p_tenant and is_active
  ) then
    raise exception 'treatment room is not available' using errcode = '22023';
  end if;
  if p_specialist is not null and not app.member_has_permission(p_tenant, p_specialist, 'procedures.status') then
    raise exception 'specialist is not available' using errcode = '22023';
  end if;
  return p_starts + p_duration;
end $$;

-- ---------------------------------------------------------------------------
-- Серверные операции: процедуры
-- ---------------------------------------------------------------------------

-- Запись гостя на процедуру (procedures.write). Цена — из справочника; included = входит в путёвку (0 ₸).
-- Без явной брони процедура привязывается к активной брони гостя на этот день.
create or replace function public.schedule_procedure(
  p_guest_id uuid, p_procedure_type_id uuid, p_starts_at timestamptz,
  p_booking_id uuid default null, p_room_id uuid default null, p_specialist_id uuid default null,
  p_included boolean default false, p_note text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_g    public.guests;
  v_t    public.procedure_types;
  v_ends timestamptz;
  v_booking uuid;
  v_id   uuid;
begin
  select * into v_g from public.guests where id = p_guest_id;
  if not found or not (app.has_permission(v_g.tenant_id, 'procedures.read') or app.has_permission(v_g.tenant_id, 'guests.read')) then
    raise exception 'guest not found' using errcode = 'P0002';
  end if;
  if not (app.has_permission(v_g.tenant_id, 'procedures.write') and app.feature_enabled(v_g.tenant_id, 'procedures')) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_g.archived_at is not null then
    raise exception 'guest is archived' using errcode = '22023';
  end if;
  select * into v_t from public.procedure_types where id = p_procedure_type_id and tenant_id = v_g.tenant_id and is_active;
  if not found then
    raise exception 'procedure is not available' using errcode = '22023';
  end if;

  -- Без явной брони процедура привязывается к активной брони гостя на этот день,
  -- чтобы стоимость попала в счёт (врач не видит брони, но записывает гостя).
  v_booking := p_booking_id;
  if v_booking is null and p_starts_at is not null then
    select b.id into v_booking
    from public.bookings b
    join public.organizations o on o.id = b.tenant_id
    where b.tenant_id = v_g.tenant_id and b.guest_id = p_guest_id and b.status in ('confirmed', 'checked_in')
      and (p_starts_at at time zone coalesce(o.timezone, 'Asia/Almaty'))::date between b.check_in and b.check_out
    order by (b.status = 'checked_in') desc, b.check_in
    limit 1;
  end if;

  v_ends := app.check_procedure_slot(v_g.tenant_id, p_guest_id, v_booking, p_starts_at,
                                     make_interval(mins => v_t.duration_min), p_room_id, p_specialist_id);

  insert into public.procedure_appointments (
    tenant_id, guest_id, booking_id, procedure_type_id, treatment_room_id, specialist_id,
    starts_at, ends_at, price, included, note, created_by
  ) values (
    v_g.tenant_id, p_guest_id, v_booking, p_procedure_type_id, p_room_id, p_specialist_id,
    p_starts_at, v_ends, case when coalesce(p_included, false) then 0 else v_t.price end,
    coalesce(p_included, false), nullif(trim(p_note), ''), auth.uid()
  ) returning id into v_id;

  perform app.log_audit(v_g.tenant_id, 'procedure.schedule', 'procedure_appointment', v_id, 'success',
    jsonb_build_object('procedure', v_t.name, 'starts_at', p_starts_at, 'booking_id', v_booking));
  return v_id;
end $$;

-- Перенос записи (procedures.write): время, кабинет, специалист. Длительность сохраняется.
create or replace function public.reschedule_procedure(
  p_appointment_id uuid, p_starts_at timestamptz, p_room_id uuid default null, p_specialist_id uuid default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare v_a public.procedure_appointments; v_ends timestamptz;
begin
  select * into v_a from public.procedure_appointments where id = p_appointment_id for update;
  if not found or not (app.has_permission(v_a.tenant_id, 'procedures.write') and app.feature_enabled(v_a.tenant_id, 'procedures')) then
    raise exception 'appointment not found or permission denied' using errcode = '42501';
  end if;
  if v_a.status <> 'scheduled' then
    raise exception 'only scheduled procedures can be moved' using errcode = '22023';
  end if;
  v_ends := app.check_procedure_slot(v_a.tenant_id, v_a.guest_id, v_a.booking_id, p_starts_at,
                                     v_a.ends_at - v_a.starts_at, p_room_id, p_specialist_id);
  update public.procedure_appointments
  set starts_at = p_starts_at, ends_at = v_ends, treatment_room_id = p_room_id, specialist_id = p_specialist_id
  where id = p_appointment_id;
  perform app.log_audit(v_a.tenant_id, 'procedure.reschedule', 'procedure_appointment', p_appointment_id, 'success',
    jsonb_build_object('from', v_a.starts_at, 'to', p_starts_at));
end $$;

-- Статус записи.
--  done / no_show — procedures.status (врач, медсестра), не раньше дня процедуры;
--  cancelled — procedures.write; scheduled (отмена ошибочной отметки) — procedures.write.
create or replace function public.set_procedure_status(
  p_appointment_id uuid, p_status public.procedure_status, p_reason text default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_a   public.procedure_appointments;
  v_tz  text;
  v_perm text := case when p_status in ('done', 'no_show') then 'procedures.status' else 'procedures.write' end;
begin
  select * into v_a from public.procedure_appointments where id = p_appointment_id for update;
  if not found or not app.has_permission(v_a.tenant_id, 'procedures.read') then
    raise exception 'appointment not found' using errcode = 'P0002';
  end if;
  if not (app.has_permission(v_a.tenant_id, v_perm) and app.feature_enabled(v_a.tenant_id, 'procedures')) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not ((v_a.status = 'scheduled' and p_status in ('done', 'no_show', 'cancelled'))
          or (v_a.status in ('done', 'no_show') and p_status = 'scheduled')) then
    raise exception 'invalid status transition' using errcode = '22023';
  end if;
  if p_status in ('done', 'no_show') then
    select coalesce(timezone, 'Asia/Almaty') into v_tz from public.organizations where id = v_a.tenant_id;
    if (v_a.starts_at at time zone v_tz)::date > app.tenant_today(v_a.tenant_id) then
      raise exception 'procedure has not started yet' using errcode = '22023';
    end if;
  end if;

  update public.procedure_appointments
  set status = p_status,
      completed_at = case when p_status in ('done', 'no_show') then now() end,
      completed_by = case when p_status in ('done', 'no_show') then auth.uid() end,
      cancel_reason = case when p_status = 'cancelled' then nullif(trim(p_reason), '') end
  where id = p_appointment_id;
  perform app.log_audit(v_a.tenant_id, 'procedure.' || p_status::text, 'procedure_appointment', p_appointment_id, 'success',
    jsonb_build_object('from', v_a.status, 'reason', nullif(trim(p_reason), '')));
end $$;

-- Отмена брони или незаезд снимают запланированные процедуры этой брони
create or replace function app.cancel_booking_procedures() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.procedure_appointments
  set status = 'cancelled', cancel_reason = 'booking ' || new.status::text
  where booking_id = new.id and status = 'scheduled';
  return null;
end $$;

create trigger bookings_cancel_procedures after update of status on public.bookings
  for each row when (new.status in ('cancelled', 'no_show') and old.status is distinct from new.status)
  execute function app.cancel_booking_procedures();

-- Сотрудники организации с правом: специалисты (procedures.status) или исполнители задач (tasks.read)
create or replace function public.staff_directory(p_tenant uuid, p_permission text)
returns table (user_id uuid, full_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_permission not in ('procedures.status', 'tasks.read') or not app.is_member(p_tenant) then
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
-- Серверные операции: задачи
-- ---------------------------------------------------------------------------

create or replace function app.check_task_refs(p_tenant uuid, p_assignee uuid, p_room uuid) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_assignee is not null and not app.member_has_permission(p_tenant, p_assignee, 'tasks.read') then
    raise exception 'assignee is not available' using errcode = '22023';
  end if;
  if p_room is not null and not exists (select 1 from public.rooms where id = p_room and tenant_id = p_tenant) then
    raise exception 'room not found' using errcode = '22023';
  end if;
end $$;

create or replace function public.create_task(
  p_tenant uuid, p_title text, p_description text default null,
  p_category public.task_category default 'other', p_priority public.task_priority default 'normal',
  p_assignee_id uuid default null, p_room_id uuid default null, p_due_at timestamptz default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not (app.has_permission(p_tenant, 'tasks.write') and app.feature_enabled(p_tenant, 'tasks')) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  perform app.check_task_refs(p_tenant, p_assignee_id, p_room_id);
  insert into public.tasks (tenant_id, title, description, category, priority, assignee_id, room_id, due_at, created_by)
  values (p_tenant, trim(p_title), nullif(trim(p_description), ''), coalesce(p_category, 'other'),
          coalesce(p_priority, 'normal'), p_assignee_id, p_room_id, p_due_at, auth.uid())
  returning id into v_id;
  perform app.log_audit(p_tenant, 'task.create', 'task', v_id, 'success',
    jsonb_build_object('title', trim(p_title), 'assignee_id', p_assignee_id));
  return v_id;
end $$;

create or replace function public.update_task(
  p_task_id uuid, p_title text, p_description text, p_category public.task_category,
  p_priority public.task_priority, p_assignee_id uuid, p_room_id uuid, p_due_at timestamptz
) returns void
language plpgsql security definer set search_path = '' as $$
declare v_t public.tasks;
begin
  select * into v_t from public.tasks where id = p_task_id for update;
  if not found or not (app.has_permission(v_t.tenant_id, 'tasks.write') and app.feature_enabled(v_t.tenant_id, 'tasks')) then
    raise exception 'task not found or permission denied' using errcode = '42501';
  end if;
  if v_t.status in ('done', 'cancelled') then
    raise exception 'task is closed' using errcode = '22023';
  end if;
  perform app.check_task_refs(v_t.tenant_id, p_assignee_id, p_room_id);
  update public.tasks
  set title = trim(p_title), description = nullif(trim(p_description), ''), category = p_category,
      priority = p_priority, assignee_id = p_assignee_id, room_id = p_room_id, due_at = p_due_at
  where id = p_task_id;
  perform app.log_audit(v_t.tenant_id, 'task.update', 'task', p_task_id, 'success',
    jsonb_build_object('assignee_id', p_assignee_id));
end $$;

-- Статус задачи.
--  tasks.write: любые переходы, включая отмену и повторное открытие;
--  исполнитель (tasks.read): своя или общая задача — взять в работу, вернуть, выполнить.
--  Общую задачу берёт тот, кто начал её выполнять. Выполненная уборка освобождает номер.
create or replace function public.set_task_status(p_task_id uuid, p_status public.task_status)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_t       public.tasks;
  v_manager boolean;
begin
  select * into v_t from public.tasks where id = p_task_id for update;
  if not found or not app.has_permission(v_t.tenant_id, 'tasks.read') and not app.has_permission(v_t.tenant_id, 'tasks.write') then
    raise exception 'task not found' using errcode = 'P0002';
  end if;
  v_manager := app.has_permission(v_t.tenant_id, 'tasks.write');
  if not v_manager and not (v_t.assignee_id is null or v_t.assignee_id = auth.uid()) then
    raise exception 'task not found' using errcode = 'P0002';
  end if;
  if not app.feature_enabled(v_t.tenant_id, 'tasks') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_t.status = p_status then
    return;
  end if;
  if not v_manager and (p_status = 'cancelled' or v_t.status in ('done', 'cancelled')) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  update public.tasks
  set status = p_status,
      assignee_id = coalesce(assignee_id, case when p_status in ('in_progress', 'done') then auth.uid() end),
      completed_at = case when p_status = 'done' then now() end,
      completed_by = case when p_status = 'done' then auth.uid() end
  where id = p_task_id;

  if p_status = 'done' and v_t.source = 'room_cleaning' and v_t.room_id is not null then
    update public.rooms set status = 'available' where id = v_t.room_id and status = 'cleaning';
  end if;

  perform app.log_audit(v_t.tenant_id, 'task.' || p_status::text, 'task', p_task_id, 'success',
    jsonb_build_object('from', v_t.status));
end $$;

-- Номер ушёл на уборку → задача горничным; номер снова свободен → открытая уборка закрывается
create or replace function app.room_cleaning_task() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'cleaning' and old.status <> 'cleaning' and app.feature_enabled(new.tenant_id, 'tasks')
     and not exists (select 1 from public.tasks where room_id = new.id and source = 'room_cleaning'
                     and status in ('open', 'in_progress')) then
    insert into public.tasks (tenant_id, title, category, priority, source, room_id, created_by)
    values (new.tenant_id, 'Уборка номера ' || new.number, 'cleaning', 'normal', 'room_cleaning', new.id, auth.uid());
  elsif new.status = 'available' and old.status = 'cleaning' then
    update public.tasks set status = 'done', completed_at = now(), completed_by = auth.uid()
    where room_id = new.id and source = 'room_cleaning' and status in ('open', 'in_progress');
  end if;
  return null;
end $$;

create trigger rooms_cleaning_task after update of status on public.rooms
  for each row execute function app.room_cleaning_task();

-- ---------------------------------------------------------------------------
-- Доступ к функциям
-- ---------------------------------------------------------------------------

revoke execute on function
  app.member_has_permission(uuid, uuid, text),
  app.check_procedure_slot(uuid, uuid, uuid, timestamptz, interval, uuid, uuid),
  app.check_task_refs(uuid, uuid, uuid),
  app.cancel_booking_procedures(),
  app.room_cleaning_task()
  from public, anon, authenticated;

revoke execute on function
  public.schedule_procedure(uuid, uuid, timestamptz, uuid, uuid, uuid, boolean, text),
  public.reschedule_procedure(uuid, timestamptz, uuid, uuid),
  public.set_procedure_status(uuid, public.procedure_status, text),
  public.staff_directory(uuid, text),
  public.create_task(uuid, text, text, public.task_category, public.task_priority, uuid, uuid, timestamptz),
  public.update_task(uuid, text, text, public.task_category, public.task_priority, uuid, uuid, timestamptz),
  public.set_task_status(uuid, public.task_status)
  from public, anon;
grant execute on function
  public.schedule_procedure(uuid, uuid, timestamptz, uuid, uuid, uuid, boolean, text),
  public.reschedule_procedure(uuid, timestamptz, uuid, uuid),
  public.set_procedure_status(uuid, public.procedure_status, text),
  public.staff_directory(uuid, text),
  public.create_task(uuid, text, text, public.task_category, public.task_priority, uuid, uuid, timestamptz),
  public.update_task(uuid, text, text, public.task_category, public.task_priority, uuid, uuid, timestamptz),
  public.set_task_status(uuid, public.task_status)
  to authenticated;

revoke all on public.booking_balances from anon;
grant select on public.booking_balances to authenticated;
