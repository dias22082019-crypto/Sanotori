-- Sanatorium OS · 0015 · Документы по брони: договор, счёт на оплату, акт оказанных услуг
-- Принципы:
--  * суммы в документах берёт сервер из брони, доп. услуг, процедур и оплат — браузер только печатает;
--  * номер документу присваивается один раз на бронь (договор, счёт и акт нумеруются отдельно, подряд
--    внутри санатория); при повторной печати номер и дата не меняются, сумма обновляется по брони;
--  * печать — это выгрузка своих данных, поэтому при истёкшей подписке документы печатаются;
--  * договор печатают те, кто видит брони (bookings.read); счёт и акт — те, кто видит финансы
--    или принимает оплату (finance.read или payments.accept: бухгалтер, ресепшен, менеджер);
--  * реквизиты санатория (банк, ИИК, БИК, руководитель, ставка НДС, условия договора) хранятся
--    в organizations и меняются в настройках (settings.manage);
--  * выдача номера пишется в журнал (вид и номер документа, без данных гостя).

alter table public.organizations
  add column legal_address  text check (char_length(legal_address) <= 300),
  add column bank_name      text check (char_length(bank_name) <= 200),
  add column iik            text check (iik ~ '^KZ[0-9A-Z]{18}$'),
  add column bik            text check (bik ~ '^[A-Z0-9]{8}$'),
  add column director_name  text check (char_length(director_name) <= 200),
  add column vat_rate       numeric(4,2) check (vat_rate > 0 and vat_rate <= 30),
  add column contract_terms text check (char_length(contract_terms) <= 20000);

create type public.document_kind as enum ('contract', 'invoice', 'act');

create table public.document_counters (
  tenant_id uuid not null references public.organizations(id) on delete cascade,
  kind      public.document_kind not null,
  last      integer not null default 0,
  primary key (tenant_id, kind)
);

create table public.booking_documents (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.organizations(id) on delete cascade,
  booking_id uuid not null,
  kind       public.document_kind not null,
  number     integer not null check (number > 0),
  issued_on  date not null,
  amount     numeric(14,2) not null check (amount >= 0),
  issued_by  uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, kind, number),
  unique (tenant_id, booking_id, kind),
  foreign key (tenant_id, booking_id) references public.bookings (tenant_id, id) on delete cascade
);

create trigger booking_documents_tenant before update on public.booking_documents
  for each row execute function app.forbid_tenant_change();
create trigger booking_documents_touch before update on public.booking_documents
  for each row execute function app.touch_updated_at();

alter table public.document_counters enable row level security;
alter table public.booking_documents enable row level security;
revoke all on public.document_counters from anon, authenticated;
revoke all on public.booking_documents from anon, authenticated;
grant select on public.booking_documents to authenticated;

create or replace function app.can_print_document(p_tenant uuid, p_kind public.document_kind) returns boolean
language sql stable security definer set search_path = '' as $$
  select case when p_kind = 'contract' then app.has_permission(p_tenant, 'bookings.read')
              else app.has_permission(p_tenant, 'finance.read') or app.has_permission(p_tenant, 'payments.accept') end
$$;
revoke all on function app.can_print_document(uuid, public.document_kind) from public, anon;
grant execute on function app.can_print_document(uuid, public.document_kind) to authenticated;

create policy booking_documents_select on public.booking_documents for select to authenticated
  using (app.can_print_document(tenant_id, kind));

-- ---------------------------------------------------------------------------
-- Данные документа для печати
-- ---------------------------------------------------------------------------

create or replace function public.booking_document(p_booking_id uuid, p_kind public.document_kind) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_b public.bookings;
  v_o public.organizations;
  v_d public.booking_documents;
  v_today date;
  v_number integer;
  v_lines jsonb;
  v_total numeric(14,2);
  v_paid numeric(14,2);
begin
  select * into v_b from public.bookings where id = p_booking_id;
  if not found or not app.can_print_document(v_b.tenant_id, p_kind) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_b.status in ('new_request', 'cancelled', 'no_show') then
    raise exception 'booking is not confirmed' using errcode = '22023';
  end if;
  if p_kind = 'act' and v_b.status <> 'checked_out' then
    raise exception 'act requires check-out' using errcode = '22023';
  end if;
  select * into v_o from public.organizations where id = v_b.tenant_id;
  v_today := app.tenant_today(v_b.tenant_id);

  -- Строки: проживание (со скидкой), доп. услуги, платные процедуры по видам.
  -- В счёт и договор входят и запланированные процедуры, в акт — только проведённые.
  select coalesce(jsonb_agg(to_jsonb(l) - 'ord' order by l.ord, l.name), '[]'::jsonb), coalesce(sum((l.amount)), 0)
  into v_lines, v_total
  from (
    select 1 as ord, rt.name || coalesce(' · №' || r.number, '') as name, 'night' as unit, v_b.nights::numeric as quantity,
      round((v_b.total_amount - v_b.discount_amount) / greatest(v_b.nights, 1), 2) as price,
      (v_b.total_amount - v_b.discount_amount) as amount
    from public.room_types rt left join public.rooms r on r.id = v_b.room_id
    where rt.id = v_b.room_type_id
    union all
    select 2, e.name, 'pcs', e.quantity, e.unit_price, e.amount
    from public.booking_extras e where e.booking_id = v_b.id
    union all
    select 3, t.name, 'session', count(*)::numeric, min(a.price), sum(a.price)
    from public.procedure_appointments a join public.procedure_types t on t.id = a.procedure_type_id
    where a.booking_id = v_b.id and a.price > 0
      and a.status = any (case when p_kind = 'act' then array['done']::public.procedure_status[]
                               else array['scheduled', 'done']::public.procedure_status[] end)
    group by t.name, a.price
  ) l
  where l.amount > 0;

  select coalesce(sum(amount) filter (where kind = 'payment'), 0) - coalesce(sum(amount) filter (where kind = 'refund'), 0)
  into v_paid from public.booking_payments where booking_id = v_b.id and voided_at is null;

  -- Номер: один раз на бронь и вид документа; сумма обновляется по текущей брони
  select * into v_d from public.booking_documents where tenant_id = v_b.tenant_id and booking_id = v_b.id and kind = p_kind for update;
  if not found then
    insert into public.document_counters (tenant_id, kind, last) values (v_b.tenant_id, p_kind, 1)
    on conflict (tenant_id, kind) do update set last = public.document_counters.last + 1
    returning last into v_number;
    insert into public.booking_documents (tenant_id, booking_id, kind, number, issued_on, amount, issued_by)
    values (v_b.tenant_id, v_b.id, p_kind, v_number, v_today, v_total, auth.uid())
    returning * into v_d;
    perform app.log_audit(v_b.tenant_id, 'document.issue', 'booking', v_b.id, 'success',
      jsonb_build_object('document', p_kind, 'document_number', v_number, 'booking_number', v_b.number));
  elsif v_d.amount <> v_total then
    update public.booking_documents set amount = v_total where id = v_d.id returning * into v_d;
  end if;

  return jsonb_build_object(
    'document', jsonb_build_object('kind', v_d.kind, 'number', v_d.number, 'issued_on', v_d.issued_on),
    'organization', jsonb_build_object(
      'name', v_o.name, 'legal_name', v_o.legal_name, 'bin', v_o.bin, 'legal_address', coalesce(v_o.legal_address, v_o.address),
      'city', v_o.city, 'phone', v_o.phone, 'email', v_o.email, 'bank_name', v_o.bank_name, 'iik', v_o.iik, 'bik', v_o.bik,
      'director_name', v_o.director_name, 'vat_rate', v_o.vat_rate, 'contract_terms', v_o.contract_terms,
      'check_in_time', v_o.booking_settings ->> 'check_in_time', 'check_out_time', v_o.booking_settings ->> 'check_out_time'),
    'guest', (select jsonb_build_object('full_name', g.full_name, 'phone', g.phone, 'email', g.email, 'birth_date', g.birth_date, 'city', g.city)
              from public.guests g where g.id = v_b.guest_id),
    'booking', jsonb_build_object('number', v_b.number, 'check_in', v_b.check_in, 'check_out', v_b.check_out, 'nights', v_b.nights,
      'adults', v_b.adults, 'children', v_b.children, 'status', v_b.status, 'discount', v_b.discount_amount,
      'room_type', (select name from public.room_types where id = v_b.room_type_id),
      'room', (select number from public.rooms where id = v_b.room_id)),
    'lines', v_lines,
    'total', v_total,
    'paid', v_paid,
    'due', greatest(v_total - v_paid, 0));
end $$;

revoke execute on function public.booking_document(uuid, public.document_kind) from public, anon;
grant execute on function public.booking_document(uuid, public.document_kind) to authenticated;
