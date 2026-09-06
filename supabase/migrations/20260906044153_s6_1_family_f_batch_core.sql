-- S6-1: Family F, part one - Batch identity, profile history, collaborators and
-- the edit lock, plus the two access predicates every other Family F table
-- delegates to.
--
-- CDM-14: a Batch belongs to exactly one Customer Family and one Producing
-- Plant. Its reference is allocated at creation as Plant/BAT/Indian-FY/sequence,
-- is permanent and is never reused.
--
-- THE REFERENCE IS ALLOCATED BY A TRIGGER, not by the client and not by an RPC
-- alone. §7.5 gives batches an ordinary INSERT policy, so a client can insert;
-- if the reference came from the client it could be chosen, duplicated or
-- guessed. A BEFORE INSERT trigger overwrites whatever arrives with a value from
-- the accepted ref_private allocator, exactly as approval attribution is written
-- by the trigger rather than accepted from the caller (CDM-34).
--
-- The FY is taken from now(), never from a business date: CDM-34 is explicit
-- that Pricing and Quote dates never control permanent-reference FY allocation.
--
-- A-23 IS STRUCTURAL HERE. batch_edit_locks is a separate table from
-- batches.content_version, and the heartbeat touches only heartbeat_at. Nothing
-- in this migration lets a heartbeat reach content_version - they are different
-- tables, so the separation is not a convention that could be forgotten.

-- ------------------------------------------------------------- batches
create table public.batches (
  id                  bigint      generated always as identity primary key,
  batch_reference     text        not null,
  family_id           bigint      not null,
  plant_id            bigint      not null,
  owner_user_id       bigint      not null,
  sector_id           bigint      null,
  status              text        not null default 'working',
  price_validity_from date        null,
  price_validity_to   date        null,
  content_version     integer     not null default 1,
  created_at          timestamptz not null default now(),
  created_by          bigint      not null,
  constraint fk_batch_family     foreign key (family_id)     references public.customer_families(id) on delete restrict,
  constraint fk_batch_plant      foreign key (plant_id)      references public.plants(id)            on delete restrict,
  constraint fk_batch_owner      foreign key (owner_user_id) references public.app_users(id)         on delete restrict,
  constraint fk_batch_sector     foreign key (sector_id)     references public.sectors(id)           on delete restrict,
  constraint fk_batch_created_by foreign key (created_by)    references public.app_users(id)         on delete restrict,
  constraint uk_batch_reference unique (batch_reference),
  constraint uk_batch_id_plant  unique (id, plant_id),
  constraint uk_batch_id_family unique (id, family_id),
  constraint ck_batch_status check (status in ('working','sent','submitted','approved',
                                               'issued_locked','abandoned','archived')),
  constraint ck_batch_validity_dates
    check (price_validity_to is null or price_validity_from is null
           or price_validity_to >= price_validity_from),
  constraint ck_batch_content_version check (content_version >= 1)
);
create index ix_batch_plant  on public.batches (plant_id);
create index ix_batch_owner  on public.batches (owner_user_id);
create index ix_batch_family on public.batches (family_id);
create index ix_batch_status on public.batches (status);
create index ix_batch_sector on public.batches (sector_id);
create index ix_batch_created_by on public.batches (created_by);

-- --------------------------------------------------- batch_collaborators
create table public.batch_collaborators (
  id          bigint      generated always as identity primary key,
  batch_id    bigint      not null,
  app_user_id bigint      not null,
  status      text        not null default 'active',
  created_at  timestamptz not null default now(),
  created_by  bigint      not null,
  constraint fk_bcol_batch      foreign key (batch_id)    references public.batches(id)   on delete restrict,
  constraint fk_bcol_user       foreign key (app_user_id) references public.app_users(id) on delete restrict,
  constraint fk_bcol_created_by foreign key (created_by)  references public.app_users(id) on delete restrict,
  constraint ck_bcol_status check (status in ('active','removed'))
);
create unique index uk_batch_collab_active on public.batch_collaborators (batch_id, app_user_id) where status = 'active';
-- the RLS hot path (§7): resolve "am I a collaborator on this batch" from the user side
create index ix_batch_collab_user on public.batch_collaborators (app_user_id, batch_id) where status = 'active';
create index ix_bcol_batch        on public.batch_collaborators (batch_id);
create index ix_bcol_created_by   on public.batch_collaborators (created_by);

-- ------------------------------------------------ batch_profile_versions
-- EVERY value column is nullable with no default. This is D-25 at the storage
-- boundary: a blank profile field is null, and only null advances the resolution
-- chain (CDM-19). A default of any kind would silently manufacture an override.
create table public.batch_profile_versions (
  id             bigint        generated always as identity primary key,
  batch_id       bigint        not null,
  version_no     integer       not null,
  waste_cbb_pct  numeric(7,3)  null,
  waste_pp_pct   numeric(7,3)  null,
  conv_box_rate  numeric(12,4) null,
  conv_pp_rate   numeric(12,4) null,
  margin_box_pct numeric(7,3)  null,
  margin_pp_pct  numeric(7,3)  null,
  is_current     boolean       not null default true,
  created_at     timestamptz   not null default now(),
  created_by     bigint        not null,
  constraint fk_bpv_batch      foreign key (batch_id)   references public.batches(id)   on delete restrict,
  constraint fk_bpv_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint uk_bpv_version unique (batch_id, version_no),
  constraint ck_bpv_version_no check (version_no >= 1),
  constraint ck_bpv_non_negative check (
        (waste_cbb_pct  is null or waste_cbb_pct  >= 0)
    and (waste_pp_pct   is null or waste_pp_pct   >= 0)
    and (conv_box_rate  is null or conv_box_rate  >= 0)
    and (conv_pp_rate   is null or conv_pp_rate   >= 0)
    and (margin_box_pct is null or margin_box_pct >= 0)
    and (margin_pp_pct  is null or margin_pp_pct  >= 0))
);
create unique index uk_bpv_one_current on public.batch_profile_versions (batch_id) where is_current;
create index ix_bpv_batch      on public.batch_profile_versions (batch_id);
create index ix_bpv_created_by on public.batch_profile_versions (created_by);

-- ---------------------------------------------------- batch_edit_locks
-- A-23: entirely separate from batches.content_version. A-24: staleness is
-- evaluated server-side only, from now() - heartbeat_at, never from a client
-- clock.
create table public.batch_edit_locks (
  id             bigint      generated always as identity primary key,
  batch_id       bigint      not null,
  holder_user_id bigint      not null,
  acquired_at    timestamptz not null default now(),
  heartbeat_at   timestamptz not null default now(),
  released_at    timestamptz null,
  constraint fk_bel_batch  foreign key (batch_id)       references public.batches(id)   on delete restrict,
  constraint fk_bel_holder foreign key (holder_user_id) references public.app_users(id) on delete restrict,
  constraint uk_bel_batch unique (batch_id)
);
create index ix_bel_heartbeat on public.batch_edit_locks (heartbeat_at);
create index ix_bel_holder    on public.batch_edit_locks (holder_user_id);

-- ------------------------------------- the Indian-FY permanent reference
create or replace function app_private.indian_fy_label(p_at timestamptz)
returns text language sql immutable set search_path = '' as $fn$
  select case when extract(month from p_at) >= 4
              then to_char(p_at, 'YYYY') || '-' || to_char(p_at + interval '1 year', 'YY')
              else to_char(p_at - interval '1 year', 'YYYY') || '-' || to_char(p_at, 'YY')
         end;
$fn$;

create or replace function app_private.assign_batch_reference()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare v_fy text; v_seq bigint; v_code text;
begin
  v_fy := app_private.indian_fy_label(now());
  select plant_code into v_code from public.plants where id = new.plant_id;
  if v_code is null then
    raise exception 'unknown plant' using errcode = '23503';
  end if;
  -- scope is the plant, so sequences never collide across plants, and the FY
  -- label keeps each year's series separate (CDM-14)
  v_seq := ref_private.allocate_reference('batch', new.plant_id, v_fy);
  -- whatever the client sent is discarded: the reference is the system's word
  new.batch_reference := format('%s/BAT/%s/%s', v_code, v_fy, lpad(v_seq::text, 5, '0'));
  return new;
end $fn$;

create trigger trg_batch_reference
  before insert on public.batches
  for each row execute function app_private.assign_batch_reference();

-- --------------------------------------------------- access predicates
-- One reusable pair; every Family F child delegates to these rather than
-- restating the rule, so there is exactly one place the Batch access model lives.
create or replace function app_private.can_read_batch(p_batch bigint)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1 from public.batches b
     where b.id = p_batch
       and ( b.owner_user_id = (select app_private.current_app_user())
          or exists (select 1 from public.batch_collaborators bc
                      where bc.batch_id = b.id
                        and bc.app_user_id = (select app_private.current_app_user())
                        and bc.status = 'active')
          or (select app_private.has_plant_cap(b.plant_id,'check_quote'))
          or (select app_private.has_group_cap('administer_users')) ));
$fn$;

-- Write adds three further conditions beyond read (§7.5): the caller HOLDS THE
-- ACTIVE EDIT LOCK, the Batch is in an editable state, and they are owner or
-- active collaborator with make_quote - or hold check_quote while the Batch is
-- submitted, which is CDM-33's Checker edit.
create or replace function app_private.can_write_batch(p_batch bigint)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1
      from public.batches b
      join public.batch_edit_locks l on l.batch_id = b.id
     where b.id = p_batch
       and l.released_at is null
       and l.holder_user_id = (select app_private.current_app_user())
       and (
             ( b.status in ('working','sent')
               and ( b.owner_user_id = (select app_private.current_app_user())
                  or exists (select 1 from public.batch_collaborators bc
                              where bc.batch_id = b.id
                                and bc.app_user_id = (select app_private.current_app_user())
                                and bc.status = 'active') )
               and (select app_private.has_plant_cap(b.plant_id,'make_quote')) )
          or ( b.status = 'submitted'
               and (select app_private.has_plant_cap(b.plant_id,'check_quote')) ) ));
$fn$;

revoke all on function app_private.indian_fy_label(timestamptz) from public;
revoke all on function app_private.indian_fy_label(timestamptz) from anon;
revoke all on function app_private.assign_batch_reference() from public;
revoke all on function app_private.assign_batch_reference() from anon;
revoke all on function app_private.assign_batch_reference() from authenticated;
revoke all on function app_private.can_read_batch(bigint) from public;
revoke all on function app_private.can_read_batch(bigint) from anon;
grant execute on function app_private.can_read_batch(bigint) to authenticated;
revoke all on function app_private.can_write_batch(bigint) from public;
revoke all on function app_private.can_write_batch(bigint) from anon;
grant execute on function app_private.can_write_batch(bigint) to authenticated;

-- ---------------------------------------------------------------- grants
do $$
declare t text;
begin
  foreach t in array array['batches','batch_collaborators','batch_profile_versions','batch_edit_locks']
  loop
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force  row level security', t);
  end loop;
  -- write grants only where §7.5 gives a policy; batch_edit_locks is RPC-only
  execute 'grant insert, update on public.batches to authenticated';
  execute 'grant insert, update on public.batch_collaborators to authenticated';
  execute 'grant insert on public.batch_profile_versions to authenticated';
end $$;

-- ---------------------------------------------------------------- policies
create policy batches_select on public.batches for select to authenticated
  using ( (select app_private.can_read_batch(id)) );
create policy batches_insert on public.batches for insert to authenticated
  with check ( status = 'working'
               and created_by = (select app_private.current_app_user())
               and owner_user_id = (select app_private.current_app_user())
               and (select app_private.has_plant_cap(plant_id,'make_quote')) );
create policy batches_update on public.batches for update to authenticated
  using      ( (select app_private.can_write_batch(id)) )
  with check ( (select app_private.can_write_batch(id)) );

-- CDM-32: collaboration changes are the owner's, the Checker's or the Admin's -
-- a collaborator cannot add collaborators.
create policy batch_collaborators_select on public.batch_collaborators for select to authenticated
  using ( (select app_private.can_read_batch(batch_id)) );
create policy batch_collaborators_insert on public.batch_collaborators for insert to authenticated
  with check ( created_by = (select app_private.current_app_user())
               and exists (select 1 from public.batches b
                            where b.id = batch_id
                              and ( b.owner_user_id = (select app_private.current_app_user())
                                 or (select app_private.has_plant_cap(b.plant_id,'check_quote'))
                                 or (select app_private.has_group_cap('administer_users')) )) );
create policy batch_collaborators_update on public.batch_collaborators for update to authenticated
  using      ( exists (select 1 from public.batches b
                        where b.id = batch_id
                          and ( b.owner_user_id = (select app_private.current_app_user())
                             or (select app_private.has_plant_cap(b.plant_id,'check_quote'))
                             or (select app_private.has_group_cap('administer_users')) )) )
  with check ( exists (select 1 from public.batches b
                        where b.id = batch_id
                          and ( b.owner_user_id = (select app_private.current_app_user())
                             or (select app_private.has_plant_cap(b.plant_id,'check_quote'))
                             or (select app_private.has_group_cap('administer_users')) )) );

-- Append-only: a profile edit inserts a version and moves the current pointer.
-- There is NO update policy, so no role reaching the table through the API can
-- rewrite a profile version (§7.5).
create policy batch_profile_versions_select on public.batch_profile_versions for select to authenticated
  using ( (select app_private.can_read_batch(batch_id)) );
create policy batch_profile_versions_insert on public.batch_profile_versions for insert to authenticated
  with check ( created_by = (select app_private.current_app_user())
               and (select app_private.can_write_batch(batch_id)) );

-- RPC only, both ways (§7.5). Read is still batch-scoped.
create policy batch_edit_locks_select on public.batch_edit_locks for select to authenticated
  using ( (select app_private.can_read_batch(batch_id)) );

-- No DELETE policy anywhere in Family F (CDM-14/CDM-31): rows are deactivated,
-- Batches are abandoned or archived, locks are released - never deleted.