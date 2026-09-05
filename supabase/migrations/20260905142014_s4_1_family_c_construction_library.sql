-- S4-1: Family C, part one - the Construction Library.
--
-- CDM-12: Construction is the ONE product definition designed for sharing. It
-- carries a neutral permanent sequence code, a deliberately non-unique
-- descriptive name, and immutable technical versions. Formal Batch use requires
-- adoption of an exact version by an exact plant.
--
-- CDM-13, made structural rather than documented: there is NO waste, conversion,
-- waste_pp or conv_rate_pp column on construction_versions. The live engine reads
-- exactly those off the construction (engine/costing.js:201-204), which places
-- Construction ABOVE the Batch Profile in a resolution chain CDM-19 does not
-- contain. Omitting the columns is what makes that hidden tier unimportable
-- (CDM-37) rather than merely unused. Gate PC-11 asserts their absence by pattern
-- scan, so a later column named `wastage_pct` fails too.
--
-- Layer naming follows the live SPEC data (TOP / F1 / L1 / F2 / L2, schema.sql:102)
-- so the S11 import map is a rename, not a reinterpretation.

-- ---------------------------------------------------------------- constructions
create table public.constructions (
  id                        bigint generated always as identity primary key,
  construction_code         text        null,
  name                      text        not null,
  status                    text        not null default 'proposed',
  surviving_construction_id bigint      null,
  content_version           integer     not null default 1,
  created_at                timestamptz not null default now(),
  created_by                bigint      not null,
  constraint fk_construction_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint fk_construction_surviving  foreign key (surviving_construction_id) references public.constructions(id) on delete restrict,
  constraint uk_construction_code     unique (construction_code),
  -- [scope] composite target: lets a child bind the parent's status structurally
  constraint uk_construction_id_status unique (id, status),
  constraint ck_construction_status check (status in ('proposed','published','merged')),
  -- CDM-12: publication is what allocates the permanent code
  constraint ck_construction_published_has_code check (status <> 'published' or construction_code is not null),
  -- CDM-12: a duplicate merges INTO an existing Construction, with lineage retained
  constraint ck_construction_merged_has_survivor check (status <> 'merged' or surviving_construction_id is not null),
  constraint ck_construction_not_self_survivor  check (surviving_construction_id is distinct from id),
  -- CDM-03/CDM-12: neutral permanent sequence, e.g. CON-000125. No technical meaning encoded.
  constraint ck_construction_code_format check (construction_code is null or construction_code ~ '^CON-[0-9]{6}$'),
  constraint ck_construction_name_present check (btrim(name) <> '')
);
-- CDM-12/DM-143: names may repeat; the index serves technical comparison, never uniqueness
create index ix_construction_name       on public.constructions (lower(name));
create index ix_construction_surviving  on public.constructions (surviving_construction_id);
create index ix_construction_created_by on public.constructions (created_by);

-- ------------------------------------------------------- construction_versions
create table public.construction_versions (
  id              bigint generated always as identity primary key,
  construction_id bigint       not null,
  version_no      integer      not null,
  ply             integer      not null,
  flute_f1        text         null,
  flute_f2        text         null,
  layer_top_code  text         null,
  layer_f1_code   text         null,
  layer_l1_code   text         null,
  layer_f2_code   text         null,
  layer_l2_code   text         null,
  layer_top_gsm   numeric(8,2) null,
  layer_f1_gsm    numeric(8,2) null,
  layer_l1_gsm    numeric(8,2) null,
  layer_f2_gsm    numeric(8,2) null,
  layer_l2_gsm    numeric(8,2) null,
  board_gsm       numeric(8,2) null,
  effective_from  date         null,
  approved_by     bigint       null,
  approved_at     timestamptz  null,
  created_at      timestamptz  not null default now(),
  created_by      bigint       not null,
  constraint fk_cv_construction foreign key (construction_id) references public.constructions(id) on delete restrict,
  constraint fk_cv_approved_by  foreign key (approved_by)     references public.app_users(id)     on delete restrict,
  constraint fk_cv_created_by   foreign key (created_by)      references public.app_users(id)     on delete restrict,
  constraint uk_cv_version         unique (construction_id, version_no),
  -- [scope] composite target for plant_construction_adoptions and, later, sku_versions
  constraint uk_cv_id_construction unique (id, construction_id),
  constraint ck_cv_version_no  check (version_no >= 1),
  constraint ck_cv_ply         check (ply between 1 and 11),
  -- approval attribution is inseparable from approval itself (CDM-34)
  constraint ck_cv_approval_pair check ((approved_by is null) = (approved_at is null))
);
create index ix_cv_construction on public.construction_versions (construction_id);
create index ix_cv_approved_by  on public.construction_versions (approved_by);
create index ix_cv_created_by   on public.construction_versions (created_by);

-- ------------------------------------------------- plant_construction_adoptions
-- CDM-12: formal Batch use requires adoption of an EXACT version by an EXACT plant.
create table public.plant_construction_adoptions (
  id                      bigint generated always as identity primary key,
  plant_id                bigint      not null,
  construction_version_id bigint      not null,
  status                  text        not null default 'adopted',
  adopted_by              bigint      not null,
  adopted_at              timestamptz not null default now(),
  constraint fk_pca_plant      foreign key (plant_id)                references public.plants(id)                on delete restrict,
  constraint fk_pca_version    foreign key (construction_version_id) references public.construction_versions(id) on delete restrict,
  constraint fk_pca_adopted_by foreign key (adopted_by)              references public.app_users(id)             on delete restrict,
  constraint uk_pca_plant_version unique (plant_id, construction_version_id),
  constraint ck_pca_status check (status in ('adopted','withdrawn'))
);
create index ix_pca_plant      on public.plant_construction_adoptions (plant_id);
create index ix_pca_version    on public.plant_construction_adoptions (construction_version_id);
create index ix_pca_adopted_by on public.plant_construction_adoptions (adopted_by);

-- ---------------------------------------------------------------- grants
-- §7.1: Supabase's default privileges grant `anon` everything. Revoking is
-- mandatory, not assumed - a table created without it inherits arwdDxtm.
do $$
declare t text;
begin
  foreach t in array array['constructions','construction_versions','plant_construction_adoptions']
  loop
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant insert, update on public.%I to authenticated', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force  row level security', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- policies
-- CDM-12/CDM-35: the Construction Library is group-wide, so its predicates are
-- group capabilities. Reading it requires read_construction_library explicitly -
-- being authenticated is not itself access.
create policy constructions_select on public.constructions for select to authenticated
  using ( (select app_private.has_group_cap('read_construction_library')) );

-- CDM-12/DM-144: a Maker may PROPOSE a Construction from Batch Entry. The branch is
-- deliberately narrow - status='proposed' sits inside it, so a make_quote holder
-- cannot insert a published Construction and cannot reach the master route at all.
create policy constructions_insert on public.constructions for insert to authenticated
  with check (
        (select app_private.has_group_cap('manage_construction_library'))
     or ( status = 'proposed'
          and construction_code is null          -- a proposal never carries a permanent code
          -- CDM-34: a proposer may not attribute their proposal to someone else
          and created_by = (select app_private.current_app_user())
          and exists (select 1
                        from public.plant_capability_grants g
                        join public.capabilities c on c.id = g.capability_id
                       where g.app_user_id = (select app_private.current_app_user())
                         and c.capability_key = 'make_quote'
                         and g.status = 'active') ) );

create policy constructions_update on public.constructions for update to authenticated
  using      ( (select app_private.has_group_cap('manage_construction_library')) )
  with check ( (select app_private.has_group_cap('manage_construction_library')) );

create policy construction_versions_select on public.construction_versions for select to authenticated
  using ( (select app_private.has_group_cap('read_construction_library')) );

-- "As above" (§7.5) resolved: construction_versions has no status of its own, so the
-- Maker proposal route is bounded by the PARENT Construction's status. A Maker may
-- write version 1 of the Construction they are proposing; adding a version to an
-- already-published shared master is a technical change to published history and
-- needs manage_construction_library (CDM-12/PM-3).
create policy construction_versions_insert on public.construction_versions for insert to authenticated
  with check (
        (select app_private.has_group_cap('manage_construction_library'))
     or ( approved_at is null                    -- a proposal is never born approved
          and created_by = (select app_private.current_app_user())
          and exists (select 1 from public.constructions k
                       where k.id = construction_id and k.status = 'proposed')
          and exists (select 1
                        from public.plant_capability_grants g
                        join public.capabilities c on c.id = g.capability_id
                       where g.app_user_id = (select app_private.current_app_user())
                         and c.capability_key = 'make_quote'
                         and g.status = 'active') ) );

-- CDM-12: a technical change is a NEW version, never an edit of an approved one.
-- The policy states the rule for `authenticated`; the trigger below states it for
-- every role, including those holding BYPASSRLS.
create policy construction_versions_update on public.construction_versions for update to authenticated
  using      ( approved_at is null and (select app_private.has_group_cap('manage_construction_library')) )
  with check ( (select app_private.has_group_cap('manage_construction_library')) );

-- CDM-04/CDM-35: adoption is plant-owned, so its predicates are plant capabilities
-- read off the row's own plant_id - one column read plus one helper call, no join.
create policy plant_construction_adoptions_select on public.plant_construction_adoptions for select to authenticated
  using ( (select app_private.has_plant_cap(plant_id,'plant_access')) );
create policy plant_construction_adoptions_insert on public.plant_construction_adoptions for insert to authenticated
  with check ( (select app_private.has_plant_cap(plant_id,'adopt_construction_for_plant')) );
create policy plant_construction_adoptions_update on public.plant_construction_adoptions for update to authenticated
  using      ( (select app_private.has_plant_cap(plant_id,'adopt_construction_for_plant')) )
  with check ( (select app_private.has_plant_cap(plant_id,'adopt_construction_for_plant')) );

-- No DELETE policy on any Family C table: formal records are withdrawn, merged or
-- discontinued, never deleted (CDM-31).

-- ------------------------------------------------------------ guard triggers
-- Why a trigger AND a policy, when §7.5 specifies only the policy:
-- RLS does not apply to `service_role`, which holds BYPASSRLS (S0a E-4). A policy
-- therefore states immutability for `authenticated` and for nobody else. A
-- BEFORE trigger fires for every role regardless. This is the same argument §7.5
-- already accepted for the Family E transition matrix, applied to the rule CDM-12
-- states in the strongest terms: an approved Construction Version is immutable.
--
-- DELETE is deliberately NOT trigger-blocked. It is governed exactly as every
-- Family A and Family B table governs it - no DELETE grant and no DELETE policy,
-- so no role reaching the table through PostgREST can issue one (CDM-31). Adding a
-- trigger block here would be stricter than the standard accepted at 217/217 and
-- would leave the regression fixtures unable to clean up after themselves.

create or replace function app_private.guard_construction_version_immutable()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  -- CDM-12: a technical change is a new version, never an edit of an approved one
  if old.approved_at is not null then
    raise exception 'construction version % is approved and immutable - a technical change is a new version (CDM-12)', old.id
      using errcode = '23514';
  end if;
  -- a version may not be re-parented or renumbered, approved or not
  if new.construction_id is distinct from old.construction_id then
    raise exception 'construction_id is immutable on construction_versions'
      using errcode = '23514';
  end if;
  if new.version_no is distinct from old.version_no then
    raise exception 'version_no is immutable on construction_versions'
      using errcode = '23514';
  end if;
  return new;
end $fn$;

create trigger trg_cv_immutable
  before update on public.construction_versions
  for each row execute function app_private.guard_construction_version_immutable();

-- CDM-03: permanent business references are unique in their approved scope and
-- never reused. Once allocated, a Construction Code can never change, and never
-- be released back to null. CDM-12's lifecycle is enforced here rather than in a
-- policy because a policy sees OLD and NEW independently and can never express a
-- transition matrix (§7.5).
create or replace function app_private.guard_construction_permanence()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if old.construction_code is not null
     and new.construction_code is distinct from old.construction_code then
    raise exception 'construction_code % is permanent and can never be changed or released (CDM-03)', old.construction_code
      using errcode = '23514';
  end if;

  if new.status is distinct from old.status then
    -- exhaustive; anything unlisted raises. Lifecycle per SR DEV proposal §4.3.
    if not ( (old.status = 'proposed' and new.status in ('published','merged')) ) then
      raise exception 'illegal Construction transition % -> % (CDM-12: proposed -> published | merged, both terminal)', old.status, new.status
        using errcode = '23514';
    end if;
  end if;

  return new;
end $fn$;

create trigger trg_construction_permanence
  before update on public.constructions
  for each row execute function app_private.guard_construction_permanence();

-- An adoption binds one plant to one exact version (CDM-12). Neither side may be
-- re-pointed afterwards: the UPDATE policy checks the capability against OLD and
-- NEW independently, so a caller holding the capability at two plants could
-- otherwise walk the row between them. Only `status` is meant to change.
create or replace function app_private.guard_adoption_binding()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if new.plant_id is distinct from old.plant_id then
    raise exception 'plant_id is immutable on plant_construction_adoptions'
      using errcode = '23514';
  end if;
  if new.construction_version_id is distinct from old.construction_version_id then
    raise exception 'construction_version_id is immutable on plant_construction_adoptions'
      using errcode = '23514';
  end if;
  return new;
end $fn$;

create trigger trg_pca_binding
  before update on public.plant_construction_adoptions
  for each row execute function app_private.guard_adoption_binding();