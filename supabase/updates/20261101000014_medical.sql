-- Sanatorium OS: обновление базы, миграция 20261101000014_medical.sql.
-- Supabase → SQL Editor → New query → вставить весь файл → Run. Каждое обновление применяется один раз.
-- Не редактируйте вручную: файл пересобирается скриптом scripts/build-setup-sql.sh
begin;

-- Sanatorium OS · 0014 · Медицинская карта гостя
-- Принципы:
--  * медицинские сведения — особая категория персональных данных: таблицы закрыты для прямого чтения,
--    карту отдаёт только функция get_medical_card, и каждый просмотр пишется в журнал (кто и чью карту открыл);
--  * доступ только по медицинским правам: medical.read (врач, медсестра), medical.write (врач).
--    Владелец и директор медицинских прав по умолчанию не имеют, в свои роли их выдать нельзя (0003);
--  * карту заводят после согласия гостя на обработку медицинских данных (отметка и время согласия);
--  * осмотр может исправить только его автор и только в течение 24 часов; дальше запись неизменна;
--  * назначение — процедура на курс (сколько сеансов); выполнено столько, сколько отмеченных процедур
--    этого вида у гостя после назначения; записывать на процедуры по-прежнему через schedule_procedure;
--  * медкарта входит в модуль «procedures» (тариф Business и выше); при истёкшей подписке карта читается,
--    но не меняется;
--  * в журнал пишутся действие, гость и названия изменённых полей — без диагнозов, жалоб и других значений.

create type public.medical_visit_kind as enum ('initial', 'follow_up', 'final');
create type public.prescription_status as enum ('active', 'completed', 'cancelled');

create table public.medical_records (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.organizations(id) on delete cascade,
  guest_id           uuid not null,
  allergies          text check (char_length(allergies) <= 2000),
  contraindications  text check (char_length(contraindications) <= 2000),
  chronic_conditions text check (char_length(chronic_conditions) <= 2000),
  medications        text check (char_length(medications) <= 2000),
  notes              text check (char_length(notes) <= 4000),
  consent_at         timestamptz not null,
  created_by         uuid references auth.users(id) on delete set null,
  updated_by         uuid references auth.users(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (tenant_id, guest_id),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id)
);

create table public.medical_visits (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.organizations(id) on delete cascade,
  guest_id        uuid not null,
  booking_id      uuid,
  kind            public.medical_visit_kind not null default 'follow_up',
  visit_at        timestamptz not null default now(),
  complaints      text check (char_length(complaints) <= 4000),
  examination     text check (char_length(examination) <= 4000),
  diagnosis       text check (char_length(diagnosis) <= 2000),
  recommendations text check (char_length(recommendations) <= 4000),
  blood_pressure  text check (blood_pressure ~ '^[0-9]{2,3}/[0-9]{2,3}$'),
  pulse           smallint check (pulse between 20 and 250),
  temperature     numeric(4,1) check (temperature between 30 and 45),
  weight          numeric(5,1) check (weight between 1 and 400),
  doctor_id       uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id),
  constraint medical_visit_content check (coalesce(complaints, examination, diagnosis, recommendations, blood_pressure) is not null
    or pulse is not null or temperature is not null or weight is not null)
);
create index medical_visits_guest_idx on public.medical_visits (tenant_id, guest_id, visit_at desc);

create table public.medical_prescriptions (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.organizations(id) on delete cascade,
  guest_id          uuid not null,
  booking_id        uuid,
  procedure_type_id uuid not null,
  sessions          smallint not null check (sessions between 1 and 60),
  frequency         text check (char_length(frequency) <= 100),
  note              text check (char_length(note) <= 1000),
  status            public.prescription_status not null default 'active',
  prescribed_by     uuid references auth.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id),
  foreign key (tenant_id, procedure_type_id) references public.procedure_types (tenant_id, id)
);
create index medical_prescriptions_guest_idx on public.medical_prescriptions (tenant_id, guest_id, created_at desc);

create trigger medical_records_tenant before update on public.medical_records
  for each row execute function app.forbid_tenant_change();
create trigger medical_records_touch before update on public.medical_records
  for each row execute function app.touch_updated_at();
create trigger medical_visits_tenant before update on public.medical_visits
  for each row execute function app.forbid_tenant_change();
create trigger medical_visits_touch before update on public.medical_visits
  for each row execute function app.touch_updated_at();
create trigger medical_prescriptions_tenant before update on public.medical_prescriptions
  for each row execute function app.forbid_tenant_change();
create trigger medical_prescriptions_touch before update on public.medical_prescriptions
  for each row execute function app.touch_updated_at();

-- Прямого доступа нет ни у кого из клиентов: только функции ниже (каждое чтение журналируется)
alter table public.medical_records enable row level security;
alter table public.medical_visits enable row level security;
alter table public.medical_prescriptions enable row level security;
revoke all on public.medical_records, public.medical_visits, public.medical_prescriptions from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Вспомогательные функции
-- ---------------------------------------------------------------------------

create or replace function app.can_write_medical(p_tenant uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.has_permission(p_tenant, 'medical.write') and app.feature_enabled(p_tenant, 'procedures')
$$;

-- Пустая строка → null, лишние пробелы по краям убираются
create or replace function app.clean_text(p_value text) returns text
language sql immutable set search_path = '' as $$
  select nullif(btrim(coalesce(p_value, '')), '')
$$;

-- Сколько процедур назначения уже выполнено: проведённые процедуры этого вида у гостя
-- начиная с дня назначения (по времени санатория), в рамках той же брони, если она указана
create or replace function app.prescription_done(p_rx public.medical_prescriptions) returns integer
language sql stable security definer set search_path = '' as $$
  select count(*)::integer from public.procedure_appointments a
  cross join lateral (select coalesce((select timezone from public.organizations where id = p_rx.tenant_id), 'Asia/Almaty') as tz) z
  where a.tenant_id = p_rx.tenant_id and a.guest_id = p_rx.guest_id and a.procedure_type_id = p_rx.procedure_type_id
    and a.status = 'done' and (a.starts_at at time zone z.tz)::date >= (p_rx.created_at at time zone z.tz)::date
    and (p_rx.booking_id is null or a.booking_id = p_rx.booking_id)
$$;

-- ---------------------------------------------------------------------------
-- Чтение
-- ---------------------------------------------------------------------------

-- Медкарта гостя целиком и текущее проживание (для привязки осмотров и назначений).
-- Каждый вызов — запись medical.view в журнале.
create or replace function public.get_medical_card(p_guest_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_g public.guests;
  v_r public.medical_records;
  v_out jsonb;
begin
  select * into v_g from public.guests where id = p_guest_id;
  if not found or not app.has_permission(v_g.tenant_id, 'medical.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  select * into v_r from public.medical_records where tenant_id = v_g.tenant_id and guest_id = p_guest_id;

  v_out := jsonb_build_object(
    'guest', jsonb_build_object('id', v_g.id, 'full_name', v_g.full_name, 'birth_date', v_g.birth_date, 'city', v_g.city),
    'record', case when v_r.id is null then null else jsonb_build_object(
      'allergies', v_r.allergies, 'contraindications', v_r.contraindications, 'chronic_conditions', v_r.chronic_conditions,
      'medications', v_r.medications, 'notes', v_r.notes, 'consent_at', v_r.consent_at, 'updated_at', v_r.updated_at,
      'updated_by_name', (select full_name from public.user_profiles where id = v_r.updated_by)) end,
    'visits', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', v.id, 'booking_id', v.booking_id, 'kind', v.kind, 'visit_at', v.visit_at,
        'complaints', v.complaints, 'examination', v.examination, 'diagnosis', v.diagnosis, 'recommendations', v.recommendations,
        'blood_pressure', v.blood_pressure, 'pulse', v.pulse, 'temperature', v.temperature, 'weight', v.weight,
        'doctor_name', u.full_name, 'created_at', v.created_at,
        'editable', v.doctor_id = auth.uid() and v.created_at > now() - interval '24 hours')
        order by v.visit_at desc)
      from public.medical_visits v left join public.user_profiles u on u.id = v.doctor_id
      where v.tenant_id = v_g.tenant_id and v.guest_id = p_guest_id), '[]'::jsonb),
    'prescriptions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'booking_id', p.booking_id, 'procedure_type_id', p.procedure_type_id, 'procedure', t.name,
        'sessions', p.sessions, 'done', app.prescription_done(p), 'frequency', p.frequency, 'note', p.note,
        'status', p.status, 'prescribed_by_name', u.full_name, 'created_at', p.created_at)
        order by (p.status = 'active') desc, p.created_at desc)
      from public.medical_prescriptions p
      join public.procedure_types t on t.id = p.procedure_type_id
      left join public.user_profiles u on u.id = p.prescribed_by
      where p.tenant_id = v_g.tenant_id and p.guest_id = p_guest_id), '[]'::jsonb),
    'stay', (
      select jsonb_build_object('id', b.id, 'number', b.number, 'check_in', b.check_in, 'check_out', b.check_out, 'status', b.status)
      from public.bookings b
      where b.tenant_id = v_g.tenant_id and b.guest_id = p_guest_id and b.status in ('checked_in', 'confirmed')
        and b.check_out >= app.tenant_today(v_g.tenant_id)
      order by b.status = 'checked_in' desc, b.check_in limit 1),
    'can_write', app.can_write_medical(v_g.tenant_id));

  perform app.log_audit(v_g.tenant_id, 'medical.view', 'guest', p_guest_id);
  return v_out;
end $$;

-- Гости в санатории и сегодняшние заезды для врача: только отметки, без медицинского содержимого
create or replace function public.medical_overview(p_tenant uuid)
returns table (guest_id uuid, full_name text, booking_id uuid, booking_number integer, room_number text,
               check_in date, check_out date, status public.booking_status, has_card boolean, has_initial boolean,
               active_prescriptions integer)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_today date := app.tenant_today(p_tenant);
begin
  if not app.has_permission(p_tenant, 'medical.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  return query
    select g.id, g.full_name, b.id, b.number, r.number, b.check_in, b.check_out, b.status,
      exists (select 1 from public.medical_records m where m.tenant_id = p_tenant and m.guest_id = g.id),
      exists (select 1 from public.medical_visits v where v.tenant_id = p_tenant and v.guest_id = g.id
              and v.kind = 'initial' and v.visit_at >= b.check_in::timestamp - interval '1 day'),
      (select count(*)::integer from public.medical_prescriptions p where p.tenant_id = p_tenant and p.guest_id = g.id
       and p.status = 'active')
    from public.bookings b
    join public.guests g on g.id = b.guest_id
    left join public.rooms r on r.id = b.room_id
    where b.tenant_id = p_tenant
      and (b.status = 'checked_in' or (b.status = 'confirmed' and b.check_in between v_today and v_today + 1))
    order by b.status = 'checked_in' desc, b.check_in, g.full_name;
end $$;

-- ---------------------------------------------------------------------------
-- Изменения
-- ---------------------------------------------------------------------------

create or replace function public.save_medical_record(
  p_guest_id uuid, p_allergies text, p_contraindications text, p_chronic_conditions text,
  p_medications text, p_notes text, p_consent boolean default false
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_g public.guests;
  v_r public.medical_records;
  v_changed text[] := '{}';
begin
  select * into v_g from public.guests where id = p_guest_id;
  if not found or not app.can_write_medical(v_g.tenant_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if greatest(char_length(coalesce(p_allergies, '')), char_length(coalesce(p_contraindications, '')),
              char_length(coalesce(p_chronic_conditions, '')), char_length(coalesce(p_medications, ''))) > 2000
     or char_length(coalesce(p_notes, '')) > 4000 then
    raise exception 'text is too long' using errcode = '22023';
  end if;

  select * into v_r from public.medical_records where tenant_id = v_g.tenant_id and guest_id = p_guest_id for update;
  if not found then
    if not coalesce(p_consent, false) then
      raise exception 'medical consent is required' using errcode = '22023';
    end if;
    insert into public.medical_records (tenant_id, guest_id, allergies, contraindications, chronic_conditions, medications, notes,
      consent_at, created_by, updated_by)
    values (v_g.tenant_id, p_guest_id, app.clean_text(p_allergies), app.clean_text(p_contraindications),
      app.clean_text(p_chronic_conditions), app.clean_text(p_medications), app.clean_text(p_notes), now(), auth.uid(), auth.uid());
    perform app.log_audit(v_g.tenant_id, 'medical.card_create', 'guest', p_guest_id);
    return;
  end if;

  if v_r.allergies is distinct from app.clean_text(p_allergies) then v_changed := v_changed || 'allergies'::text; end if;
  if v_r.contraindications is distinct from app.clean_text(p_contraindications) then v_changed := v_changed || 'contraindications'::text; end if;
  if v_r.chronic_conditions is distinct from app.clean_text(p_chronic_conditions) then v_changed := v_changed || 'chronic_conditions'::text; end if;
  if v_r.medications is distinct from app.clean_text(p_medications) then v_changed := v_changed || 'medications'::text; end if;
  if v_r.notes is distinct from app.clean_text(p_notes) then v_changed := v_changed || 'notes'::text; end if;
  if cardinality(v_changed) = 0 then
    return;
  end if;
  update public.medical_records set allergies = app.clean_text(p_allergies), contraindications = app.clean_text(p_contraindications),
    chronic_conditions = app.clean_text(p_chronic_conditions), medications = app.clean_text(p_medications),
    notes = app.clean_text(p_notes), updated_by = auth.uid()
  where id = v_r.id;
  perform app.log_audit(v_g.tenant_id, 'medical.card_update', 'guest', p_guest_id, 'success', jsonb_build_object('changed', to_jsonb(v_changed)));
end $$;

-- Проверка полей осмотра
create or replace function app.check_medical_visit(
  p_tenant uuid, p_guest uuid, p_booking uuid, p_visit_at timestamptz, p_complaints text, p_examination text,
  p_diagnosis text, p_recommendations text, p_bp text, p_pulse integer, p_temperature numeric, p_weight numeric
) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if coalesce(app.clean_text(p_complaints), app.clean_text(p_examination), app.clean_text(p_diagnosis),
              app.clean_text(p_recommendations), app.clean_text(p_bp)) is null
     and p_pulse is null and p_temperature is null and p_weight is null then
    raise exception 'visit is empty' using errcode = '22023';
  end if;
  if greatest(char_length(coalesce(p_complaints, '')), char_length(coalesce(p_examination, '')),
              char_length(coalesce(p_recommendations, ''))) > 4000 or char_length(coalesce(p_diagnosis, '')) > 2000 then
    raise exception 'text is too long' using errcode = '22023';
  end if;
  if (app.clean_text(p_bp) is not null and app.clean_text(p_bp) !~ '^[0-9]{2,3}/[0-9]{2,3}$')
     or (p_pulse is not null and p_pulse not between 20 and 250)
     or (p_temperature is not null and p_temperature not between 30 and 45)
     or (p_weight is not null and p_weight not between 1 and 400) then
    raise exception 'invalid vitals' using errcode = '22023';
  end if;
  if p_visit_at is null or p_visit_at > now() + interval '1 hour' or p_visit_at < now() - interval '30 days' then
    raise exception 'invalid visit time' using errcode = '22023';
  end if;
  if p_booking is not null and not exists (select 1 from public.bookings where id = p_booking and tenant_id = p_tenant and guest_id = p_guest) then
    raise exception 'booking not found' using errcode = 'P0002';
  end if;
end $$;

create or replace function public.add_medical_visit(
  p_guest_id uuid, p_booking_id uuid, p_kind public.medical_visit_kind, p_visit_at timestamptz,
  p_complaints text, p_examination text, p_diagnosis text, p_recommendations text,
  p_blood_pressure text default null, p_pulse integer default null, p_temperature numeric default null, p_weight numeric default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_g public.guests;
  v_id uuid;
begin
  select * into v_g from public.guests where id = p_guest_id;
  if not found or not app.can_write_medical(v_g.tenant_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not exists (select 1 from public.medical_records where tenant_id = v_g.tenant_id and guest_id = p_guest_id) then
    raise exception 'medical card is required' using errcode = '22023';
  end if;
  perform app.check_medical_visit(v_g.tenant_id, p_guest_id, p_booking_id, coalesce(p_visit_at, now()), p_complaints, p_examination,
    p_diagnosis, p_recommendations, p_blood_pressure, p_pulse, p_temperature, p_weight);
  insert into public.medical_visits (tenant_id, guest_id, booking_id, kind, visit_at, complaints, examination, diagnosis,
    recommendations, blood_pressure, pulse, temperature, weight, doctor_id)
  values (v_g.tenant_id, p_guest_id, p_booking_id, coalesce(p_kind, 'follow_up'), coalesce(p_visit_at, now()),
    app.clean_text(p_complaints), app.clean_text(p_examination), app.clean_text(p_diagnosis), app.clean_text(p_recommendations),
    app.clean_text(p_blood_pressure), p_pulse, p_temperature, p_weight, auth.uid())
  returning id into v_id;
  perform app.log_audit(v_g.tenant_id, 'medical.visit_create', 'guest', p_guest_id, 'success',
    jsonb_build_object('visit_kind', coalesce(p_kind, 'follow_up')));
  return v_id;
end $$;

-- Исправить осмотр может только автор и только в первые 24 часа
create or replace function public.update_medical_visit(
  p_visit_id uuid, p_kind public.medical_visit_kind, p_visit_at timestamptz,
  p_complaints text, p_examination text, p_diagnosis text, p_recommendations text,
  p_blood_pressure text, p_pulse integer, p_temperature numeric, p_weight numeric
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_v public.medical_visits;
begin
  select * into v_v from public.medical_visits where id = p_visit_id for update;
  if not found or not app.can_write_medical(v_v.tenant_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_v.doctor_id is distinct from auth.uid() or v_v.created_at < now() - interval '24 hours' then
    raise exception 'visit is locked' using errcode = '42501';
  end if;
  perform app.check_medical_visit(v_v.tenant_id, v_v.guest_id, v_v.booking_id, p_visit_at, p_complaints, p_examination,
    p_diagnosis, p_recommendations, p_blood_pressure, p_pulse, p_temperature, p_weight);
  update public.medical_visits set kind = coalesce(p_kind, kind), visit_at = p_visit_at,
    complaints = app.clean_text(p_complaints), examination = app.clean_text(p_examination), diagnosis = app.clean_text(p_diagnosis),
    recommendations = app.clean_text(p_recommendations), blood_pressure = app.clean_text(p_blood_pressure),
    pulse = p_pulse, temperature = p_temperature, weight = p_weight
  where id = p_visit_id;
  perform app.log_audit(v_v.tenant_id, 'medical.visit_update', 'guest', v_v.guest_id);
end $$;

create or replace function public.add_prescription(
  p_guest_id uuid, p_booking_id uuid, p_procedure_type_id uuid, p_sessions integer,
  p_frequency text default null, p_note text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_g public.guests;
  v_id uuid;
  v_name text;
begin
  select * into v_g from public.guests where id = p_guest_id;
  if not found or not app.can_write_medical(v_g.tenant_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not exists (select 1 from public.medical_records where tenant_id = v_g.tenant_id and guest_id = p_guest_id) then
    raise exception 'medical card is required' using errcode = '22023';
  end if;
  select name into v_name from public.procedure_types where id = p_procedure_type_id and tenant_id = v_g.tenant_id and is_active;
  if v_name is null then
    raise exception 'procedure type not found' using errcode = 'P0002';
  end if;
  if p_sessions is null or p_sessions not between 1 and 60 then
    raise exception 'invalid sessions' using errcode = '22023';
  end if;
  if char_length(coalesce(p_frequency, '')) > 100 or char_length(coalesce(p_note, '')) > 1000 then
    raise exception 'text is too long' using errcode = '22023';
  end if;
  if p_booking_id is not null and not exists (select 1 from public.bookings where id = p_booking_id and tenant_id = v_g.tenant_id and guest_id = p_guest_id) then
    raise exception 'booking not found' using errcode = 'P0002';
  end if;
  insert into public.medical_prescriptions (tenant_id, guest_id, booking_id, procedure_type_id, sessions, frequency, note, prescribed_by)
  values (v_g.tenant_id, p_guest_id, p_booking_id, p_procedure_type_id, p_sessions, app.clean_text(p_frequency), app.clean_text(p_note), auth.uid())
  returning id into v_id;
  perform app.log_audit(v_g.tenant_id, 'medical.prescription_create', 'guest', p_guest_id, 'success',
    jsonb_build_object('procedure', v_name, 'sessions', p_sessions));
  return v_id;
end $$;

create or replace function public.set_prescription_status(p_prescription_id uuid, p_status public.prescription_status) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_p public.medical_prescriptions;
begin
  select * into v_p from public.medical_prescriptions where id = p_prescription_id for update;
  if not found or not app.can_write_medical(v_p.tenant_id) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_p.status = p_status then
    return;
  end if;
  if v_p.status <> 'active' and p_status <> 'active' then
    raise exception 'status change is not allowed' using errcode = '22023';
  end if;
  update public.medical_prescriptions set status = p_status where id = p_prescription_id;
  perform app.log_audit(v_p.tenant_id, 'medical.prescription_status', 'guest', v_p.guest_id, 'success',
    jsonb_build_object('from', v_p.status, 'to', p_status));
end $$;

-- ---------------------------------------------------------------------------
-- Доступ к функциям
-- ---------------------------------------------------------------------------

revoke all on function
  app.can_write_medical(uuid),
  app.clean_text(text),
  app.prescription_done(public.medical_prescriptions),
  app.check_medical_visit(uuid, uuid, uuid, timestamptz, text, text, text, text, text, integer, numeric, numeric)
  from public, anon, authenticated;

revoke execute on function
  public.get_medical_card(uuid),
  public.medical_overview(uuid),
  public.save_medical_record(uuid, text, text, text, text, text, boolean),
  public.add_medical_visit(uuid, uuid, public.medical_visit_kind, timestamptz, text, text, text, text, text, integer, numeric, numeric),
  public.update_medical_visit(uuid, public.medical_visit_kind, timestamptz, text, text, text, text, text, integer, numeric, numeric),
  public.add_prescription(uuid, uuid, uuid, integer, text, text),
  public.set_prescription_status(uuid, public.prescription_status)
  from public, anon;
grant execute on function
  public.get_medical_card(uuid),
  public.medical_overview(uuid),
  public.save_medical_record(uuid, text, text, text, text, text, boolean),
  public.add_medical_visit(uuid, uuid, public.medical_visit_kind, timestamptz, text, text, text, text, text, integer, numeric, numeric),
  public.update_medical_visit(uuid, public.medical_visit_kind, timestamptz, text, text, text, text, text, integer, numeric, numeric),
  public.add_prescription(uuid, uuid, uuid, integer, text, text),
  public.set_prescription_status(uuid, public.prescription_status)
  to authenticated;

commit;
