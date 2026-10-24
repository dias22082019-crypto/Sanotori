-- Тесты отзывов и промокодов (сценарии ТЗ 3, 9, 10, 12, 14, 21)
\set ON_ERROR_STOP on
\set QUIET on

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000009a1', 'owner9a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000009a2', 'reception9a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000009a3', 'maid9a@example.kz', now()),
  ('00000000-0000-0000-0000-0000000009b1', 'owner9b@example.kz', now());

set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000009a1', 'owner9a@example.kz');
select public.create_organization('Сарыагаш Отзывы', 'otzyvy-9', 'Сарыагаш') as org9a \gset
select tests.login('00000000-0000-0000-0000-0000000009b1', 'owner9b@example.kz');
select public.create_organization('Мерке Жайлау', 'zhailau-9', 'Мерке') as org9b \gset
reset role;
select set_config('t9.a', :'org9a', false), set_config('t9.b', :'org9b', false) \gset
update public.organizations set is_published = true where id = :'org9a';

insert into public.organization_members (tenant_id, user_id, role_id, status)
select :'org9a', u, r.id, 'active'
from (values ('00000000-0000-0000-0000-0000000009a2'::uuid, 'receptionist'),
             ('00000000-0000-0000-0000-0000000009a3'::uuid, 'housekeeping')) v(u, code)
join public.roles r on r.code = v.code and r.tenant_id is null;

set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000009a1', 'owner9a@example.kz');
insert into public.room_types (tenant_id, name, base_price) values (:'org9a', 'Стандарт', 20000) returning id as rt9 \gset
insert into public.rooms (tenant_id, room_type_id, number) values (:'org9a', :'rt9', '1') returning id as room9 \gset
insert into public.rooms (tenant_id, room_type_id, number) values (:'org9a', :'rt9', '2') returning id as room9b \gset
insert into public.guests (tenant_id, full_name, phone) values (:'org9a', 'Гость Отзыва', '+77015550909') returning id as guest9 \gset
select public.create_booking(:'org9a', :'guest9', :'rt9', :'room9', current_date + 10, current_date + 15, 1, 0) as bk9 \gset
select public.create_booking(:'org9a', :'guest9', :'rt9', :'room9b', current_date + 30, current_date + 32, 1, 0) as bk9b \gset
insert into public.promo_codes (tenant_id, code, kind, value, min_nights, max_uses)
values (:'org9a', 'LETO10', 'percent', 10, 3, 1) returning id as promo9 \gset
insert into public.promo_codes (tenant_id, code, kind, value) values (:'org9a', 'MINUS5000', 'fixed', 5000);
reset role;
select set_config('t9.bk', :'bk9', false), set_config('t9.bk2', :'bk9b', false), set_config('t9.room', :'room9', false), set_config('t9.rt', :'rt9', false) \gset

-- ============================================================================
-- Промокод: сервер считает скидку, пересчитывает при переносе, учитывает условия и лимит
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000009a2', 'reception9a@example.kz');
do $$
declare b uuid := current_setting('t9.bk')::uuid; b2 uuid := current_setting('t9.bk2')::uuid; r jsonb; bal record;
begin
  r := public.apply_promo_code(b, ' leto10 ');
  assert (r ->> 'discount')::numeric = 10000, format('10%% of 100000: %s', r);
  select * into bal from public.booking_balances where booking_id = b;
  assert bal.accommodation = 90000 and bal.discount = 10000 and bal.balance = 90000, format('balance: %s', to_jsonb(bal));
  begin
    perform public.apply_promo_code(b2, 'LETO10');
    raise exception 'FAIL: short stay accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.apply_promo_code(b2, 'NOPE');
    raise exception 'FAIL: unknown code accepted';
  exception when no_data_found then null;
  end;
  perform public.update_booking(b, current_setting('t9.rt')::uuid, current_setting('t9.room')::uuid, current_date + 10, current_date + 17, 1, 0);
  assert (select discount_amount from public.bookings where id = b) = 14000, 'discount recalculated after date change';
  r := public.apply_promo_code(b2, 'MINUS5000');
  assert (r ->> 'discount')::numeric = 5000, 'fixed discount';
  r := public.apply_promo_code(b2, null);
  assert (select discount_amount from public.bookings where id = b2) = 0, 'promo removed';
  begin
    update public.bookings set discount_amount = 99999 where id = b2;
    if found then raise exception 'FAIL: discount edited directly'; end if;
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  21a  promo: server-side discount, recalculation, conditions, removal';
end $$;
reset role;
-- лимит применений: второй бронь с тем же кодом при max_uses = 1
update public.bookings set check_out = check_in + 4 where id = current_setting('t9.bk2')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000009a2', 'reception9a@example.kz');
do $$
begin
  perform public.apply_promo_code(current_setting('t9.bk2')::uuid, 'LETO10');
  raise exception 'FAIL: usage limit ignored';
exception when invalid_parameter_value then
  null;
end $$;
-- отменённая бронь не занимает лимит
reset role;
update public.bookings set status = 'cancelled' where id = current_setting('t9.bk')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000009a2', 'reception9a@example.kz');
do $$
begin
  assert (public.apply_promo_code(current_setting('t9.bk2')::uuid, 'LETO10') ->> 'code') = 'LETO10', 'cancelled booking frees the limit';
  perform public.apply_promo_code(current_setting('t9.bk2')::uuid, null);
  raise notice 'ok  21b  promo usage limit, cancelled bookings do not count';
end $$;
reset role;
update public.bookings set status = 'confirmed' where id = current_setting('t9.bk')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000009a2', 'reception9a@example.kz');

-- ============================================================================
-- Отзыв: ссылка только после выезда, одноразовая, без персональных данных; публикация с согласия
-- ============================================================================
do $$
begin
  perform public.create_review_request(current_setting('t9.bk')::uuid);
  raise exception 'FAIL: review link before check-out';
exception when invalid_parameter_value then null;
end $$;
reset role;
update public.bookings set status = 'checked_out', check_in = current_date - 7, check_out = current_date - 2,
  checked_in_at = now() - interval '7 days', checked_out_at = now() - interval '2 days'
where id = current_setting('t9.bk')::uuid;
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000009a2', 'reception9a@example.kz');
select public.create_review_request(:'bk9') as token9 \gset
reset role;
select set_config('t9.token', :'token9', false) \gset

insert into public.review_requests (tenant_id, booking_id, token, expires_at)
values (current_setting('t9.a')::uuid, current_setting('t9.bk2')::uuid, repeat('ab', 32), now() - interval '1 day');

set role anon;
do $$
declare t text := current_setting('t9.token'); f jsonb;
begin
  f := public.get_review_form(t);
  assert f ->> 'state' = 'open' and f ->> 'sanatorium' = 'Сарыагаш Отзывы', format('form: %s', f);
  assert position('Гость' in f::text) = 0 and position('+7701' in f::text) = 0, 'no guest personal data in the form';
  assert (public.get_review_form('x') ->> 'state') = 'not_found', 'unknown token';
  assert (public.get_review_form(repeat('ab', 32)) ->> 'state') = 'expired', 'expired link';
  begin
    perform public.submit_review(repeat('ab', 32), 5);
    raise exception 'FAIL: expired link accepted';
  exception when no_data_found or invalid_parameter_value then null;
  end;
  begin
    perform public.submit_review(t, 6);
    raise exception 'FAIL: rating 6 accepted';
  exception when invalid_parameter_value then null;
  end;
  perform public.submit_review(t, 5, 'Отличное лечение и вода', 'Айгуль', true);
  begin
    perform public.submit_review(t, 1, 'второй раз');
    raise exception 'FAIL: link used twice';
  exception when invalid_parameter_value then null;
  end;
  assert (public.get_review_form(t) ->> 'state') = 'used', 'link marked used';
  assert (public.get_public_reviews('otzyvy-9') ->> 'count')::int = 0, 'not published before moderation';
  begin
    perform count(*) from public.reviews;
    raise exception 'FAIL: anon read reviews table';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  21c  review link: after check-out, one-time, no personal data, anon cannot read reviews';
end $$;
reset role;

set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000009a2', 'reception9a@example.kz');
do $$
begin
  assert (select count(*) from public.reviews) = 0, 'reception has no marketing.read';
  begin
    perform public.moderate_review((select id from public.reviews limit 1), 'published');
    raise exception 'FAIL: reception moderated';
  exception when insufficient_privilege then null;
  end;
end $$;
select tests.login('00000000-0000-0000-0000-0000000009a1', 'owner9a@example.kz');
do $$
declare r uuid := (select id from public.reviews where tenant_id = current_setting('t9.a')::uuid); p jsonb;
begin
  perform public.moderate_review(r, 'published', 'Спасибо, ждём снова!');
  p := public.get_public_reviews('otzyvy-9');
  assert (p ->> 'count')::int = 1 and (p ->> 'average')::numeric = 5 and p -> 'items' -> 0 ->> 'author_name' = 'Айгуль'
     and p -> 'items' -> 0 ->> 'reply' = 'Спасибо, ждём снова!', format('public: %s', p);
  assert position('Гость Отзыва' in p::text) = 0 and position('+7701' in p::text) = 0, 'no personal data on the public page';
  assert (public.review_summary(current_setting('t9.a')::uuid) ->> 'average')::numeric = 5, 'summary';
  raise notice 'ok  21d  moderation and public reviews without personal data';
end $$;
reset role;
-- без согласия гостя опубликовать нельзя
do $$
declare rq uuid;
begin
  update public.reviews set publish_consent = false where tenant_id = current_setting('t9.a')::uuid;
  update public.reviews set status = 'published' where tenant_id = current_setting('t9.a')::uuid;
  raise exception 'FAIL: published without consent';
exception when check_violation then null;
end $$;

-- ============================================================================
-- Изоляция и тариф
-- ============================================================================
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000009b1', 'owner9b@example.kz');
do $$
begin
  assert (select count(*) from public.reviews) = 0 and (select count(*) from public.promo_codes) = 0, 'B sees nothing of A';
  begin
    perform public.apply_promo_code(current_setting('t9.bk2')::uuid, 'MINUS5000');
    raise exception 'FAIL: B applied promo to A booking';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.create_review_request(current_setting('t9.bk')::uuid);
    raise exception 'FAIL: B created A review link';
  exception when insufficient_privilege then null;
  end;
  assert public.review_summary(current_setting('t9.a')::uuid) is null, 'B gets no A summary';
end $$;
reset role;
update public.organization_subscriptions set plan_id = (select id from public.subscription_plans where code = 'start')
where tenant_id = current_setting('t9.a')::uuid;
set role anon;
do $$
begin
  assert (public.get_public_reviews('otzyvy-9') ->> 'count')::int = 0, 'Start plan: reviews hidden';
  assert (public.get_review_form(current_setting('t9.token')) ->> 'state') <> 'open', 'Start plan: form closed';
end $$;
reset role;
set role authenticated;
select tests.login('00000000-0000-0000-0000-0000000009a1', 'owner9a@example.kz');
do $$
begin
  assert (select count(*) from public.reviews) = 1, 'owner still reads reviews on Start';
  begin
    insert into public.promo_codes (tenant_id, code, kind, value) values (current_setting('t9.a')::uuid, 'NEW1', 'fixed', 1000);
    raise exception 'FAIL: Start plan created promo';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  21e  tenant isolation; Start plan: no marketing, data stays readable';
end $$;
reset role;

\echo 'ALL TESTS PASSED'
