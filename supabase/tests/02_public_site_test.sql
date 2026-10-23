-- Публичная страница: аноним видит только опубликованные санатории и только безопасные поля (сценарии 9, 11)
\set ON_ERROR_STOP on
\set QUIET on

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000c1', 'owner.c@example.kz');
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c1","email":"owner.c@example.kz"}', false);
select public.create_organization('Жаркент Арасан', 'arasan', 'Жаркент') as org_c \gset
update public.organizations set bin = '123456789012', legal_name = 'ТОО Арасан', phone = '+77282000000';
reset role;

set role anon;
select set_config('request.jwt.claims', '', false);
do $$ begin
  assert (select count(*) from public.get_public_sanatorium('arasan')) = 0, 'unpublished page must not be visible';
end $$;
reset role;

update public.organizations set is_published = true where slug = 'arasan';

set role anon;
do $$
declare r record;
begin
  select * into r from public.get_public_sanatorium('ARASAN');
  assert r.name = 'Жаркент Арасан', 'published page must be visible (slug case-insensitive)';
  assert r.phone = '+77282000000', 'public contacts must be visible';
  assert to_jsonb(r) ? 'name' and not (to_jsonb(r) ? 'bin') and not (to_jsonb(r) ? 'legal_name'),
    'BIN and legal name must never be returned publicly';
  assert (select count(*) from public.organizations) = 0, 'anon still cannot read the organizations table';
  raise notice 'ok  9/11 public page shows only published, safe fields';
end $$;
reset role;
\echo 'ALL TESTS PASSED'
