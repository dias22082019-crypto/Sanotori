-- Sanatorium OS · 0009 · Аналитика
-- Принципы:
--  * отчёт считает сервер одним вызовом analytics_report; клиент только рисует;
--  * доступ — право reports.read и модуль analytics в тарифе; при истёкшей подписке отчёт читается
--    (чтение и выгрузка не блокируются), поэтому проверяется тариф, а не возможность записи;
--  * в отчёте нет персональных данных гостей: только количества и суммы;
--  * загрузка и начисления по проживанию считаются по ночам: стоимость брони делится поровну на её ночи,
--    ночь относится к дате заезда в эту ночь; поступления — по дате оплаты в часовом поясе санатория.

-- Есть ли модуль в тарифе (без проверки, открыта ли запись): для отчётов, которые читаются всегда
create or replace function app.plan_has_feature(p_tenant uuid, p_feature text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.organization_subscriptions s
    join public.plan_features f on f.plan_id = s.plan_id
    where s.tenant_id = p_tenant and s.status <> 'cancelled' and f.feature_code = p_feature
  )
$$;
revoke execute on function app.plan_has_feature(uuid, text) from public, anon;
grant execute on function app.plan_has_feature(uuid, text) to authenticated;

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
    select b.id, b.guest_id, b.room_type_id, b.check_in, b.check_out, b.total_amount / b.nights as per_night
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
    select b.source, b.status, b.nights, b.total_amount,
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

revoke execute on function public.analytics_report(uuid, date, date) from public, anon;
grant execute on function public.analytics_report(uuid, date, date) to authenticated;
