-- Sanatorium OS: обновление базы, миграция 20261029000011_reviews_promos.sql.
-- Supabase → SQL Editor → New query → вставить весь файл → Run. Каждое обновление применяется один раз.
-- Не редактируйте вручную: файл пересобирается скриптом scripts/build-setup-sql.sh
begin;

-- Sanatorium OS · 0011 · Отзывы и акции
-- Принципы:
--  * отзыв оставляет только гость, который действительно жил: после выезда сотрудник получает одноразовую ссылку
--    и отправляет её гостю сам (WhatsApp, SMS). Сервис рассылки не изображается;
--  * по ссылке гость видит только название санатория и даты проживания — без своих персональных данных;
--  * на публичной странице показываются только отзывы, которые гость разрешил публиковать и сотрудник опубликовал;
--    имя — только то, что гость сам указал для публикации;
--  * промокод применяет сотрудник к брони; размер скидки считает сервер и пересчитывает при изменении брони;
--    скидка уменьшает стоимость проживания в балансе брони, в отчётах и аналитике;
--  * модуль тарифа «marketing»: при истёкшей подписке отзывы и промокоды читаются, но не меняются.

create type public.review_status as enum ('new', 'published', 'hidden');
create type public.promo_kind as enum ('percent', 'fixed');

-- ---------------------------------------------------------------------------
-- Промокоды
-- ---------------------------------------------------------------------------

create table public.promo_codes (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.organizations(id) on delete cascade,
  code        text not null check (code ~ '^[A-Z0-9][A-Z0-9_-]{2,29}$'),
  description text check (char_length(description) <= 300),
  kind        public.promo_kind not null,
  value       numeric(14,2) not null check (value > 0),
  valid_from  date,
  valid_to    date,
  min_nights  integer not null default 1 check (min_nights between 1 and 365),
  max_uses    integer check (max_uses between 1 and 100000),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, code),
  constraint promo_percent_range check (kind <> 'percent' or value <= 100),
  constraint promo_fixed_range check (kind <> 'fixed' or value <= 100000000),
  constraint promo_dates check (valid_to is null or valid_from is null or valid_to >= valid_from)
);

create trigger promo_codes_tenant before update on public.promo_codes
  for each row execute function app.forbid_tenant_change();
create trigger promo_codes_touch before update on public.promo_codes
  for each row execute function app.touch_updated_at();

alter table public.bookings
  add column promo_code_id   uuid,
  add column discount_amount numeric(14,2) not null default 0 check (discount_amount >= 0),
  add constraint bookings_promo_fk foreign key (tenant_id, promo_code_id) references public.promo_codes (tenant_id, id),
  add constraint bookings_discount_le_total check (discount_amount <= total_amount);

-- Скидка всегда считается от текущей стоимости проживания: при переносе дат и смене номера пересчитывается
create or replace function app.apply_booking_discount() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_promo public.promo_codes;
begin
  if new.promo_code_id is null then
    new.discount_amount := 0;
  else
    select * into v_promo from public.promo_codes where id = new.promo_code_id;
    new.discount_amount := least(new.total_amount,
      case v_promo.kind when 'percent' then round(new.total_amount * v_promo.value / 100, 0) else v_promo.value end);
  end if;
  return new;
end $$;

create trigger bookings_discount before insert or update of total_amount, promo_code_id on public.bookings
  for each row execute function app.apply_booking_discount();

alter table public.promo_codes enable row level security;

create policy promo_codes_select on public.promo_codes for select to authenticated
  using (app.has_permission(tenant_id, 'marketing.read') or app.has_permission(tenant_id, 'bookings.write'));
create policy promo_codes_insert on public.promo_codes for insert to authenticated
  with check (app.has_permission(tenant_id, 'marketing.write') and app.feature_enabled(tenant_id, 'marketing'));
create policy promo_codes_update on public.promo_codes for update to authenticated
  using (app.has_permission(tenant_id, 'marketing.write'))
  with check (app.has_permission(tenant_id, 'marketing.write') and app.feature_enabled(tenant_id, 'marketing'));
revoke all on public.promo_codes from anon;
revoke delete on public.promo_codes from authenticated;

-- Применить промокод к брони (или снять его, p_code = null).
-- Условия: код активен, заезд в сроке действия, ночей не меньше минимума, лимит применений не исчерпан.
create or replace function public.apply_promo_code(p_booking_id uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_b     public.bookings;
  v_promo public.promo_codes;
  v_used  integer;
  v_code  text := upper(trim(coalesce(p_code, '')));
begin
  select * into v_b from public.bookings where id = p_booking_id for update;
  if not found or not app.has_permission(v_b.tenant_id, 'bookings.write')
     or not app.feature_enabled(v_b.tenant_id, 'marketing') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_b.status not in ('new_request', 'confirmed', 'checked_in') then
    raise exception 'booking is closed' using errcode = '22023';
  end if;

  if v_code = '' then
    update public.bookings set promo_code_id = null where id = p_booking_id;
    perform app.log_audit(v_b.tenant_id, 'booking.promo_remove', 'booking', p_booking_id);
    return jsonb_build_object('discount', 0);
  end if;

  select * into v_promo from public.promo_codes where tenant_id = v_b.tenant_id and code = v_code;
  if not found or not v_promo.is_active then
    raise exception 'promo code not found' using errcode = 'P0002';
  end if;
  if (v_promo.valid_from is not null and v_b.check_in < v_promo.valid_from)
     or (v_promo.valid_to is not null and v_b.check_in > v_promo.valid_to) then
    raise exception 'promo code is not valid for these dates' using errcode = '22023';
  end if;
  if v_b.nights < v_promo.min_nights then
    raise exception 'stay is too short for this promo code' using errcode = '22023';
  end if;
  if v_promo.max_uses is not null then
    select count(*) into v_used from public.bookings
    where promo_code_id = v_promo.id and id <> p_booking_id and status not in ('cancelled', 'no_show');
    if v_used >= v_promo.max_uses then
      raise exception 'promo code usage limit reached' using errcode = '22023';
    end if;
  end if;

  update public.bookings set promo_code_id = v_promo.id where id = p_booking_id returning * into v_b;
  perform app.log_audit(v_b.tenant_id, 'booking.promo_apply', 'booking', p_booking_id, 'success',
    jsonb_build_object('code', v_promo.code, 'amount', v_b.discount_amount));
  return jsonb_build_object('discount', v_b.discount_amount, 'code', v_promo.code);
end $$;

-- Сколько раз применён каждый промокод (без отменённых броней)
create or replace function public.promo_code_usage(p_tenant uuid) returns table (promo_code_id uuid, uses bigint, discount numeric)
language sql stable security definer set search_path = '' as $$
  select b.promo_code_id, count(*), coalesce(sum(b.discount_amount), 0)
  from public.bookings b
  where b.tenant_id = p_tenant and b.promo_code_id is not null and b.status not in ('cancelled', 'no_show')
    and app.has_permission(p_tenant, 'marketing.read')
  group by b.promo_code_id
$$;

-- ---------------------------------------------------------------------------
-- Баланс брони: проживание за вычетом скидки
-- ---------------------------------------------------------------------------

create or replace view public.booking_balances with (security_invoker = true) as
select
  b.id as booking_id,
  b.tenant_id,
  (b.total_amount - b.discount_amount)::numeric(14,2) as accommodation,
  coalesce(x.extras, 0)::numeric(14,2) as extras,
  (case when b.status in ('cancelled', 'no_show') then 0
        else b.total_amount - b.discount_amount + coalesce(x.extras, 0) + coalesce(pr.procedures, 0) end)::numeric(14,2) as charges,
  coalesce(p.paid, 0)::numeric(14,2) as paid,
  coalesce(p.refunded, 0)::numeric(14,2) as refunded,
  (coalesce(p.paid, 0) - coalesce(p.refunded, 0))::numeric(14,2) as paid_net,
  ((case when b.status in ('cancelled', 'no_show') then 0
         else b.total_amount - b.discount_amount + coalesce(x.extras, 0) + coalesce(pr.procedures, 0) end)
    - coalesce(p.paid, 0) + coalesce(p.refunded, 0))::numeric(14,2) as balance,
  coalesce(pr.procedures, 0)::numeric(14,2) as procedures,
  b.discount_amount as discount
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

revoke all on public.booking_balances from anon;
grant select on public.booking_balances to authenticated;

-- Аналитика считает начисления за проживание с учётом скидки
create or replace function public.analytics_report(p_tenant uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_tz text;
  v_from timestamptz;
  v_to timestamptz;
  v_days integer;
  v_rooms integer;
  v_result jsonb;
begin
  if not app.has_permission(p_tenant, 'reports.read') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not app.plan_has_feature(p_tenant, 'analytics') then
    raise exception 'analytics is not in the plan' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'invalid period' using errcode = '22023';
  end if;

  select coalesce(timezone, 'Asia/Almaty') into v_tz from public.organizations where id = p_tenant;
  v_from := (p_from::timestamp at time zone v_tz);
  v_to := ((p_to + 1)::timestamp at time zone v_tz);
  v_days := p_to - p_from + 1;
  select count(*) into v_rooms from public.rooms where tenant_id = p_tenant and is_active;

  with days as (
    select d::date as day from generate_series(p_from, p_to, interval '1 day') d
  ),
  stays as (
    select b.id, b.guest_id, b.room_type_id, b.check_in, b.check_out, (b.total_amount - b.discount_amount) / b.nights as per_night
    from public.bookings b
    where b.tenant_id = p_tenant and b.room_id is not null
      and b.status in ('confirmed', 'checked_in', 'checked_out')
      and b.check_in <= p_to and b.check_out > p_from
  ),
  nights as (
    select d.day, s.id, s.guest_id, s.room_type_id, s.check_in, s.per_night
    from days d join stays s on d.day >= s.check_in and d.day < s.check_out
  ),
  created as (
    select b.source, b.status, b.nights, b.total_amount - b.discount_amount as total_amount,
           b.check_in - (b.created_at at time zone v_tz)::date as lead_days
    from public.bookings b
    where b.tenant_id = p_tenant and b.created_at >= v_from and b.created_at < v_to
  ),
  pays as (
    select (p.paid_at at time zone v_tz)::date as day,
           case when p.kind = 'payment' then p.amount else -p.amount end as net
    from public.booking_payments p
    where p.tenant_id = p_tenant and p.voided_at is null and p.paid_at >= v_from and p.paid_at < v_to
  ),
  months as (
    select distinct date_trunc('month', day)::date as month from days
  ),
  procs as (
    select a.procedure_type_id, a.status, a.price
    from public.procedure_appointments a
    where a.tenant_id = p_tenant and a.starts_at >= v_from and a.starts_at < v_to
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'days', v_days, 'rooms', v_rooms,
    'room_nights', (select count(*) from nights),
    'accommodation', (select coalesce(round(sum(per_night), 2), 0) from nights),
    'received', (select coalesce(sum(net), 0) from pays),
    'expenses', (select coalesce(sum(e.amount), 0) from public.expenses e
                 where e.tenant_id = p_tenant and e.voided_at is null and e.spent_on between p_from and p_to),
    'guests', (select count(distinct guest_id) from nights),
    'returning_guests', (select count(distinct n.guest_id) from nights n
                         where exists (select 1 from public.bookings o
                                       where o.tenant_id = p_tenant and o.guest_id = n.guest_id and o.id <> n.id
                                         and o.status in ('confirmed', 'checked_in', 'checked_out')
                                         and o.check_in < n.check_in)),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'occupied',
                (select count(*) from nights n where n.day = d.day)) order by d.day), '[]'::jsonb)
              from days d),
    'monthly', (select coalesce(jsonb_agg(jsonb_build_object(
                  'month', m.month,
                  'room_nights', (select count(*) from nights n where date_trunc('month', n.day) = m.month),
                  'days', (select count(*) from days d where date_trunc('month', d.day) = m.month),
                  'accommodation', (select coalesce(round(sum(per_night), 2), 0) from nights n where date_trunc('month', n.day) = m.month),
                  'received', (select coalesce(sum(net), 0) from pays p where date_trunc('month', p.day) = m.month),
                  'expenses', (select coalesce(sum(e.amount), 0) from public.expenses e
                               where e.tenant_id = p_tenant and e.voided_at is null and e.spent_on between p_from and p_to
                                 and date_trunc('month', e.spent_on) = m.month)
                ) order by m.month), '[]'::jsonb)
                from months m),
    'bookings', (select jsonb_build_object(
                   'created', count(*),
                   'cancelled', count(*) filter (where status = 'cancelled'),
                   'no_show', count(*) filter (where status = 'no_show'),
                   'requests', count(*) filter (where status = 'new_request'),
                   'avg_nights', coalesce(round(avg(nights) filter (where status not in ('cancelled', 'no_show')), 1), 0),
                   'avg_lead_days', coalesce(round(avg(greatest(lead_days, 0)) filter (where status not in ('cancelled', 'no_show')), 1), 0))
                 from created),
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('source', source, 'bookings', cnt, 'cancelled', cancelled, 'amount', amount)
                  order by cnt desc, source), '[]'::jsonb)
                from (select source, count(*) as cnt,
                             count(*) filter (where status in ('cancelled', 'no_show')) as cancelled,
                             coalesce(sum(total_amount) filter (where status not in ('cancelled', 'no_show')), 0) as amount
                      from created group by source) s),
    'room_types', (select coalesce(jsonb_agg(jsonb_build_object('name', rt.name, 'rooms', rt.rooms,
                     'room_nights', coalesce(n.cnt, 0), 'accommodation', coalesce(n.amount, 0))
                     order by coalesce(n.cnt, 0) desc, rt.name), '[]'::jsonb)
                   from (select t.id, t.name, (select count(*) from public.rooms r where r.room_type_id = t.id and r.is_active) as rooms
                         from public.room_types t where t.tenant_id = p_tenant and t.is_active) rt
                   left join (select room_type_id, count(*) as cnt, round(sum(per_night), 2) as amount
                              from nights group by room_type_id) n on n.room_type_id = rt.id),
    'procedures', (select coalesce(jsonb_agg(jsonb_build_object('name', pt.name, 'done', s.done, 'no_show', s.no_show, 'amount', s.amount)
                     order by s.done desc, pt.name), '[]'::jsonb)
                   from (select procedure_type_id,
                                count(*) filter (where status = 'done') as done,
                                count(*) filter (where status = 'no_show') as no_show,
                                coalesce(sum(price) filter (where status = 'done'), 0) as amount
                         from procs group by procedure_type_id) s
                   join public.procedure_types pt on pt.id = s.procedure_type_id
                   where s.done > 0 or s.no_show > 0)
  ) into v_result;
  return v_result;
end $$;

-- ---------------------------------------------------------------------------
-- Отзывы
-- ---------------------------------------------------------------------------

create table public.review_requests (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.organizations(id) on delete cascade,
  booking_id uuid not null unique,
  token      text not null unique check (char_length(token) = 64),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '60 days',
  used_at    timestamptz,
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id)
);

create table public.reviews (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.organizations(id) on delete cascade,
  booking_id      uuid not null unique,
  guest_id        uuid not null,
  rating          smallint not null check (rating between 1 and 5),
  comment         text check (char_length(comment) <= 2000),
  author_name     text check (char_length(author_name) <= 60),
  publish_consent boolean not null default false,
  status          public.review_status not null default 'new',
  reply           text check (char_length(reply) <= 2000),
  replied_at      timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id),
  constraint review_publish_needs_consent check (status <> 'published' or publish_consent)
);
create index reviews_tenant_created_idx on public.reviews (tenant_id, created_at desc);

create trigger reviews_touch before update on public.reviews
  for each row execute function app.touch_updated_at();

alter table public.review_requests enable row level security;
alter table public.reviews         enable row level security;

-- Читать отзывы — marketing.read; менять — только функциями
create policy reviews_select on public.reviews for select to authenticated
  using (app.has_permission(tenant_id, 'marketing.read'));
create policy review_requests_select on public.review_requests for select to authenticated
  using (app.has_permission(tenant_id, 'marketing.read'));
revoke all on public.reviews, public.review_requests from anon;
revoke insert, update, delete on public.reviews, public.review_requests from authenticated;

-- Ссылка на отзыв для завершённого проживания. Повторный вызов возвращает ту же ссылку (и продлевает срок).
create or replace function public.create_review_request(p_booking_id uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_b     public.bookings;
  v_req   public.review_requests;
begin
  select * into v_b from public.bookings where id = p_booking_id;
  if not found
     or not (app.has_permission(v_b.tenant_id, 'bookings.checkin') or app.has_permission(v_b.tenant_id, 'marketing.write'))
     or not app.feature_enabled(v_b.tenant_id, 'marketing') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_b.status <> 'checked_out' then
    raise exception 'review is available after check-out' using errcode = '22023';
  end if;

  select * into v_req from public.review_requests where booking_id = p_booking_id;
  if found then
    if v_req.used_at is not null then
      raise exception 'review already received' using errcode = '22023';
    end if;
    update public.review_requests set expires_at = now() + interval '60 days' where id = v_req.id;
    return v_req.token;
  end if;

  insert into public.review_requests (tenant_id, booking_id, token, created_by)
  values (v_b.tenant_id, p_booking_id,
          replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), auth.uid())
  returning * into v_req;
  perform app.log_audit(v_b.tenant_id, 'review.request', 'booking', p_booking_id);
  return v_req.token;
end $$;

-- Форма отзыва для гостя (аноним): только название санатория и даты, без персональных данных
create or replace function public.get_review_form(p_token text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_req public.review_requests;
  v_b   public.bookings;
  v_o   public.organizations;
begin
  select * into v_req from public.review_requests where token = p_token;
  if not found then
    return jsonb_build_object('state', 'not_found');
  end if;
  select * into v_b from public.bookings where id = v_req.booking_id;
  select * into v_o from public.organizations where id = v_req.tenant_id;
  return jsonb_build_object(
    'state', case when v_req.used_at is not null then 'used'
                  when v_req.expires_at < now() then 'expired'
                  when not app.plan_has_feature(v_req.tenant_id, 'marketing') then 'unavailable'
                  else 'open' end,
    'sanatorium', v_o.name, 'slug', case when v_o.is_published then v_o.slug end,
    'default_language', v_o.default_language,
    'check_in', v_b.check_in, 'check_out', v_b.check_out);
end $$;

-- Отзыв гостя по одноразовой ссылке (аноним)
create or replace function public.submit_review(
  p_token text, p_rating integer, p_comment text default null, p_author_name text default null, p_publish_consent boolean default false
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_req public.review_requests;
  v_b   public.bookings;
begin
  select * into v_req from public.review_requests where token = p_token for update;
  if not found or v_req.expires_at < now() or not app.plan_has_feature(v_req.tenant_id, 'marketing') then
    raise exception 'review link is not valid' using errcode = 'P0002';
  end if;
  if v_req.used_at is not null then
    raise exception 'review already received' using errcode = '22023';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then
    raise exception 'rating must be from 1 to 5' using errcode = '22023';
  end if;
  if char_length(coalesce(p_comment, '')) > 2000 or char_length(coalesce(p_author_name, '')) > 60 then
    raise exception 'text is too long' using errcode = '22023';
  end if;

  select * into v_b from public.bookings where id = v_req.booking_id;
  insert into public.reviews (tenant_id, booking_id, guest_id, rating, comment, author_name, publish_consent)
  values (v_req.tenant_id, v_req.booking_id, v_b.guest_id, p_rating, nullif(trim(p_comment), ''),
          nullif(trim(p_author_name), ''), coalesce(p_publish_consent, false));
  update public.review_requests set used_at = now() where id = v_req.id;
  perform app.log_audit(v_req.tenant_id, 'review.received', 'booking', v_req.booking_id, 'success',
    jsonb_build_object('rating', p_rating));
end $$;

-- Модерация: опубликовать (только с согласия гостя), скрыть, ответить
create or replace function public.moderate_review(p_review_id uuid, p_status public.review_status, p_reply text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_r public.reviews;
  v_reply text := nullif(trim(p_reply), '');
begin
  select * into v_r from public.reviews where id = p_review_id for update;
  if not found or not app.has_permission(v_r.tenant_id, 'marketing.write')
     or not app.feature_enabled(v_r.tenant_id, 'marketing') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_status = 'published' and not v_r.publish_consent then
    raise exception 'guest did not allow publishing' using errcode = '22023';
  end if;
  if char_length(coalesce(v_reply, '')) > 2000 then
    raise exception 'text is too long' using errcode = '22023';
  end if;
  update public.reviews
  set status = p_status, reply = v_reply,
      replied_at = case when v_reply is distinct from v_r.reply then case when v_reply is null then null else now() end
                        else v_r.replied_at end
  where id = p_review_id;
  perform app.log_audit(v_r.tenant_id, 'review.' || p_status::text, 'review', p_review_id, 'success',
    jsonb_build_object('rating', v_r.rating) || case when v_reply is distinct from v_r.reply then jsonb_build_object('replied', v_reply is not null) else '{}'::jsonb end);
end $$;

-- Опубликованные отзывы для публичной страницы (аноним)
create or replace function public.get_public_reviews(p_slug text) returns jsonb
language sql stable security definer set search_path = '' as $$
  with o as (
    select id from public.organizations
    where slug = lower(p_slug) and is_published and app.plan_has_feature(id, 'marketing')
  ), r as (
    select rv.rating, rv.comment, rv.author_name, rv.reply, rv.created_at
    from public.reviews rv join o on o.id = rv.tenant_id
    where rv.status = 'published'
  )
  select jsonb_build_object(
    'count', (select count(*) from r),
    'average', (select round(avg(rating), 1) from r),
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
                'rating', rating, 'comment', comment, 'author_name', author_name, 'reply', reply,
                'month', to_char(created_at, 'YYYY-MM')) order by created_at desc), '[]'::jsonb)
              from (select * from r order by created_at desc limit 30) last))
$$;

-- Сводка отзывов для сотрудников
create or replace function public.review_summary(p_tenant uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when app.has_permission(p_tenant, 'marketing.read') then jsonb_build_object(
    'count', count(*), 'average', round(avg(rating), 1),
    'new', count(*) filter (where status = 'new'),
    'by_rating', jsonb_build_object('5', count(*) filter (where rating = 5), '4', count(*) filter (where rating = 4),
                                    '3', count(*) filter (where rating = 3), '2', count(*) filter (where rating = 2),
                                    '1', count(*) filter (where rating = 1)))
  end
  from public.reviews where tenant_id = p_tenant
$$;

-- ---------------------------------------------------------------------------
-- Журнал: изменения промокодов
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
                            'unit', 'category', 'min_quantity',
                            'code', 'kind', 'value', 'valid_from', 'valid_to', 'min_nights', 'max_uses'];
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
    when 'promo_codes' then 'promo_code'
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

create trigger promo_codes_audit after insert or update on public.promo_codes
  for each row execute function app.audit_row_change();

-- ---------------------------------------------------------------------------
-- Доступ к функциям
-- ---------------------------------------------------------------------------

revoke all on function app.apply_booking_discount() from public, anon, authenticated;
revoke execute on function
  public.apply_promo_code(uuid, text),
  public.promo_code_usage(uuid),
  public.create_review_request(uuid),
  public.moderate_review(uuid, public.review_status, text),
  public.review_summary(uuid)
  from public, anon;
grant execute on function
  public.apply_promo_code(uuid, text),
  public.promo_code_usage(uuid),
  public.create_review_request(uuid),
  public.moderate_review(uuid, public.review_status, text),
  public.review_summary(uuid)
  to authenticated;
revoke all on function
  public.get_review_form(text),
  public.submit_review(text, integer, text, text, boolean),
  public.get_public_reviews(text)
  from public;
grant execute on function
  public.get_review_form(text),
  public.submit_review(text, integer, text, text, boolean),
  public.get_public_reviews(text)
  to anon, authenticated;

commit;
