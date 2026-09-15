-- GSM Master: the governed list of paper GSM values offered by construction
-- layer pickers (Costing layers and the Construction Library editor).
--
-- A value is identity once a construction uses it, so the number itself is
-- never edited in place. Maintenance is add, retire and restore. A retired
-- value stops being offered; saved constructions keep their stored GSM and
-- the frontend shows it as retired rather than blanking or rounding it.
--
-- Reading is open to every authenticated caller, as the Plant Master is:
-- a Maker without Construction Library rights still has to choose a GSM.
-- Writes exist only through the governed functions below and require
-- manage_construction_library.

create table public.paper_gsm_values (
  id              bigint      generated always as identity primary key,
  gsm             integer     not null,
  status          text        not null default 'active',
  content_version integer     not null default 1,
  created_at      timestamptz not null default now(),
  created_by      bigint,     -- null only for the seed rows inserted by this migration
  updated_at      timestamptz not null default now(),
  updated_by      bigint,
  constraint uk_paper_gsm_value unique (gsm),
  constraint ck_paper_gsm_range check (gsm between 1 and 2000),
  constraint ck_paper_gsm_status check (status in ('active', 'retired')),
  constraint fk_pgv_created_by foreign key (created_by)
    references public.app_users(id) on delete restrict,
  constraint fk_pgv_updated_by foreign key (updated_by)
    references public.app_users(id) on delete restrict
);

create index ix_pgv_created_by on public.paper_gsm_values (created_by);
create index ix_pgv_updated_by on public.paper_gsm_values (updated_by);

revoke all on table public.paper_gsm_values from anon, authenticated;
grant select on table public.paper_gsm_values to authenticated;
alter table public.paper_gsm_values enable row level security;
alter table public.paper_gsm_values force row level security;

create policy paper_gsm_values_select
  on public.paper_gsm_values for select to authenticated
  using (true);

-- No client INSERT/UPDATE/DELETE grant or policy exists.

-- Product Owner list, 2026-09-15.
insert into public.paper_gsm_values (gsm)
select v from unnest(array[80, 100, 110, 120, 140, 150, 170, 180, 200, 220, 230, 250]) as v;

create function app_private.add_paper_gsm_value(p_gsm integer)
returns bigint
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_id bigint;
begin
  if not app_private.has_group_cap('manage_construction_library') then
    raise exception 'manage_construction_library required' using errcode = '42501';
  end if;
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if p_gsm is null or p_gsm < 1 or p_gsm > 2000 then
    raise exception 'GSM must be a whole number between 1 and 2000' using errcode = '22023';
  end if;
  if exists (select 1 from public.paper_gsm_values where gsm = p_gsm) then
    raise exception 'that GSM is already in the GSM Master' using errcode = '22023';
  end if;

  insert into public.paper_gsm_values (gsm, created_by, updated_by)
  values (p_gsm, v_me, v_me)
  returning id into v_id;
  return v_id;
end $fn$;

create function app_private.set_paper_gsm_value_status(
  p_id bigint, p_status text, p_expected_content_version integer)
returns void
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_row public.paper_gsm_values%rowtype;
begin
  if not app_private.has_group_cap('manage_construction_library') then
    raise exception 'manage_construction_library required' using errcode = '42501';
  end if;
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if p_status is null or p_status not in ('active', 'retired') then
    raise exception 'status must be active or retired' using errcode = '22023';
  end if;
  if p_expected_content_version is null then
    raise exception 'the GSM content version you read must be supplied' using errcode = '22023';
  end if;

  select * into v_row from public.paper_gsm_values where id = p_id for update;
  if not found then
    raise exception 'GSM value not found' using errcode = 'P0002';
  end if;
  if v_row.content_version <> p_expected_content_version then
    raise exception 'the GSM value changed since you read it (expected content version %) - re-read and retry',
      p_expected_content_version using errcode = 'PT409';
  end if;
  if v_row.status = p_status then
    raise exception 'that GSM value is already %', p_status using errcode = '22023';
  end if;

  update public.paper_gsm_values
     set status = p_status,
         content_version = content_version + 1,
         updated_at = now(),
         updated_by = v_me
   where id = p_id;
end $fn$;

create function public.add_paper_gsm_value(p_gsm integer)
returns bigint language sql security invoker set search_path = '' as $fn$
  select app_private.add_paper_gsm_value(p_gsm);
$fn$;

create function public.set_paper_gsm_value_status(
  p_id bigint, p_status text, p_expected_content_version integer)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.set_paper_gsm_value_status(p_id, p_status, p_expected_content_version);
$fn$;

revoke all on function app_private.add_paper_gsm_value(integer) from public, anon, authenticated;
revoke all on function app_private.set_paper_gsm_value_status(bigint, text, integer) from public, anon, authenticated;

revoke all on function public.add_paper_gsm_value(integer) from public, anon;
grant execute on function public.add_paper_gsm_value(integer) to authenticated;
revoke all on function public.set_paper_gsm_value_status(bigint, text, integer) from public, anon;
grant execute on function public.set_paper_gsm_value_status(bigint, text, integer) to authenticated;
