-- P2-3: Family B - party masters. Customer Family, Party (Prospect/Customer as one
-- permanent identity), Customer Location, plus effective-dated membership, aliases,
-- legacy references and versioned location detail.
--
-- CDM-06: Prospect and Customer are lifecycle STATES of one permanent identity, so
-- graduation must never create a second row.
-- CDM-07: family membership is effective-dated with exactly one current row.
-- CDM-08: external Bill-to/Ship-to reference the third party's real Location; no
-- duplicate child rows are created under the quoting Family.

create table public.customer_families (
  id                 bigint generated always as identity primary key,
  group_customer_code text       null,
  name               text        not null,
  status             text        not null default 'active',
  surviving_family_id bigint     null,
  content_version    integer     not null default 1,
  created_at         timestamptz not null default now(),
  created_by         bigint      not null,
  constraint fk_family_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint fk_family_surviving  foreign key (surviving_family_id) references public.customer_families(id) on delete restrict,
  constraint uk_family_group_code unique (group_customer_code),
  constraint ck_family_status check (status in ('proposed','active','retired')),
  constraint ck_family_retired_has_survivor check (status <> 'retired' or surviving_family_id is not null)
);
create index ix_family_surviving on public.customer_families (surviving_family_id);
create index ix_family_created_by on public.customer_families (created_by);

create table public.customer_family_aliases (
  id         bigint generated always as identity primary key,
  family_id  bigint      not null,
  alias      text        not null,
  created_at timestamptz not null default now(),
  created_by bigint      not null,
  constraint fk_alias_family     foreign key (family_id)  references public.customer_families(id) on delete restrict,
  constraint fk_alias_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint uk_alias unique (family_id, alias)
);
create index ix_alias_created_by on public.customer_family_aliases (created_by);

create table public.parties (
  id              bigint generated always as identity primary key,
  customer_code   text        null,
  display_name    text        not null,
  lifecycle_state text        not null default 'prospect',
  status          text        not null default 'proposed',
  surviving_party_id bigint   null,
  content_version integer     not null default 1,
  created_at      timestamptz not null default now(),
  created_by      bigint      not null,
  constraint fk_party_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint fk_party_surviving  foreign key (surviving_party_id) references public.parties(id) on delete restrict,
  constraint uk_party_customer_code unique (customer_code),
  constraint uk_party_id_state      unique (id, lifecycle_state),
  constraint ck_party_lifecycle check (lifecycle_state in ('prospect','customer')),
  constraint ck_party_status    check (status in ('proposed','active','merged','inactive')),
  -- CDM-06: a graduated Customer must carry a permanent Customer Code
  constraint ck_party_customer_has_code check (lifecycle_state <> 'customer' or customer_code is not null),
  constraint ck_party_merged_has_survivor check (status <> 'merged' or surviving_party_id is not null)
);
create index ix_party_surviving  on public.parties (surviving_party_id);
create index ix_party_created_by on public.parties (created_by);

create table public.party_family_memberships (
  id              bigint generated always as identity primary key,
  party_id        bigint      not null,
  family_id       bigint      not null,
  effective_from  date        not null,
  effective_until date        null,
  is_current      boolean     not null default true,
  created_at      timestamptz not null default now(),
  created_by      bigint      not null,
  constraint fk_pfm_party      foreign key (party_id)   references public.parties(id) on delete restrict,
  constraint fk_pfm_family     foreign key (family_id)  references public.customer_families(id) on delete restrict,
  constraint fk_pfm_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint ck_pfm_period  check (effective_until is null or effective_until >= effective_from),
  constraint ck_pfm_current check ((is_current) = (effective_until is null))
);
-- CDM-07: exactly one current family per party
create unique index uk_pfm_one_current on public.party_family_memberships (party_id) where is_current;
create index ix_pfm_family     on public.party_family_memberships (family_id);
create index ix_pfm_created_by on public.party_family_memberships (created_by);

create table public.party_external_references (
  id         bigint generated always as identity primary key,
  party_id   bigint      not null,
  ref_kind   text        not null,
  ref_value  text        not null,
  created_at timestamptz not null default now(),
  created_by bigint      not null,
  constraint fk_pxr_party      foreign key (party_id)   references public.parties(id) on delete restrict,
  constraint fk_pxr_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint ck_pxr_kind check (ref_kind in ('legacy_customer_code','customer_item_ref','other')),
  constraint uk_pxr unique (party_id, ref_kind, ref_value)
);
create index ix_pxr_created_by on public.party_external_references (created_by);

create table public.customer_locations (
  id             bigint generated always as identity primary key,
  party_id       bigint      not null,
  location_code  text        null,
  bill_to_eligible boolean   not null default false,
  ship_to_eligible boolean   not null default false,
  status         text        not null default 'proposed',
  content_version integer    not null default 1,
  created_at     timestamptz not null default now(),
  created_by     bigint      not null,
  constraint fk_loc_party      foreign key (party_id)   references public.parties(id) on delete restrict,
  constraint fk_loc_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint uk_loc_code unique (location_code),
  constraint uk_loc_id_party unique (id, party_id),
  constraint ck_loc_status check (status in ('proposed','active','inactive')),
  -- DM-118: a Location must be usable for something
  constraint ck_loc_eligible check (bill_to_eligible or ship_to_eligible)
);
create index ix_loc_party      on public.customer_locations (party_id);
create index ix_loc_created_by on public.customer_locations (created_by);

create table public.customer_location_versions (
  id           bigint generated always as identity primary key,
  location_id  bigint      not null,
  version_no   integer     not null,
  location_type text       null,
  address_text text        null,
  contact_name text        null,
  notes        text        null,
  status       text        not null default 'current',
  created_at   timestamptz not null default now(),
  created_by   bigint      not null,
  constraint fk_lv_location   foreign key (location_id) references public.customer_locations(id) on delete restrict,
  constraint fk_lv_created_by foreign key (created_by)  references public.app_users(id) on delete restrict,
  constraint uk_lv_version unique (location_id, version_no),
  constraint ck_lv_status check (status in ('current','superseded')),
  constraint ck_lv_type check (location_type is null or location_type in ('plant','office','warehouse','other'))
);
create unique index uk_lv_one_current on public.customer_location_versions (location_id) where status = 'current';
create index ix_lv_created_by on public.customer_location_versions (created_by);

-- ---------------------------------------------------------------- grants
do $$
declare t text;
begin
  foreach t in array array['customer_families','customer_family_aliases','parties',
                           'party_family_memberships','party_external_references',
                           'customer_locations','customer_location_versions']
  loop
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant insert, update on public.%I to authenticated', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force  row level security', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- policies
-- One policy per table per action. Read requires an explicit group grant
-- (CDM-05/CDM-35): being authenticated is not itself access.
do $$
declare t text;
begin
  foreach t in array array['customer_families','customer_family_aliases','parties',
                           'party_family_memberships','party_external_references',
                           'customer_locations','customer_location_versions']
  loop
    execute format($p$
      create policy %1$s_select on public.%1$I for select to authenticated
        using ( (select app_private.has_group_cap('read_party_master')) )$p$, t);
    execute format($p$
      create policy %1$s_update on public.%1$I for update to authenticated
        using      ( (select app_private.has_group_cap('manage_customer_master')) )
        with check ( (select app_private.has_group_cap('manage_customer_master')) )$p$, t);
  end loop;
end $$;

-- INSERT: master capability, OR the Maker proposal route (CDM-06/DM-116/DM-121/DM-122).
-- Both predicates live inside the Maker branch, so a make_quote holder cannot insert
-- an active Customer, and cannot reach the master route without the capability.
create policy parties_insert on public.parties for insert to authenticated
  with check (
        (select app_private.has_group_cap('manage_customer_master'))
     or ( status = 'proposed' and lifecycle_state = 'prospect'
          and exists (select 1
                        from public.plant_capability_grants g
                        join public.capabilities c on c.id = g.capability_id
                       where g.app_user_id = (select app_private.current_app_user())
                         and c.capability_key = 'make_quote'
                         and g.status = 'active') ) );

create policy customer_families_insert on public.customer_families for insert to authenticated
  with check (
        (select app_private.has_group_cap('manage_customer_master'))
     or ( status = 'proposed'
          and exists (select 1
                        from public.plant_capability_grants g
                        join public.capabilities c on c.id = g.capability_id
                       where g.app_user_id = (select app_private.current_app_user())
                         and c.capability_key = 'make_quote'
                         and g.status = 'active') ) );

create policy customer_locations_insert on public.customer_locations for insert to authenticated
  with check (
        (select app_private.has_group_cap('manage_customer_master'))
     or ( status = 'proposed'
          and exists (select 1
                        from public.plant_capability_grants g
                        join public.capabilities c on c.id = g.capability_id
                       where g.app_user_id = (select app_private.current_app_user())
                         and c.capability_key = 'make_quote'
                         and g.status = 'active') ) );

-- Supporting tables: master capability only.
create policy customer_family_aliases_insert on public.customer_family_aliases for insert to authenticated
  with check ( (select app_private.has_group_cap('manage_customer_master')) );
create policy party_family_memberships_insert on public.party_family_memberships for insert to authenticated
  with check ( (select app_private.has_group_cap('manage_customer_master')) );
create policy party_external_references_insert on public.party_external_references for insert to authenticated
  with check ( (select app_private.has_group_cap('manage_customer_master')) );
create policy customer_location_versions_insert on public.customer_location_versions for insert to authenticated
  with check ( (select app_private.has_group_cap('manage_customer_master')) );
-- No DELETE policy on any table: formal records are deactivated, never deleted (CDM-31).