-- S1(a) foundation: organisation, access, RLS. Family A only.
-- Grants are REVOKED first: Supabase's default ACL grants ALL privileges on new
-- public tables to anon and authenticated (S0a E-5), so RLS alone is not the gate.

create schema if not exists app_private;
grant usage on schema app_private to authenticated;

create schema if not exists ref_private;
revoke all on schema ref_private from public;
revoke all on schema ref_private from anon, authenticated;

create table public.avadhoot_groups (
  id              bigint generated always as identity primary key,
  name            text        not null,
  status          text        not null default 'active',
  content_version integer     not null default 1,
  created_at      timestamptz not null default now(),
  constraint ck_groups_status check (status in ('active','inactive'))
);

create table public.plants (
  id              bigint generated always as identity primary key,
  group_id        bigint      not null,
  plant_code      text        not null,
  name            text        not null,
  timezone        text        not null default 'Asia/Kolkata',
  status          text        not null default 'active',
  content_version integer     not null default 1,
  created_at      timestamptz not null default now(),
  constraint fk_plants_group    foreign key (group_id) references public.avadhoot_groups(id) on delete restrict,
  constraint uk_plants_code     unique (plant_code),
  constraint uk_plants_id_group unique (id, group_id),
  constraint ck_plants_status   check (status in ('active','inactive'))
);
create index ix_plants_group on public.plants (group_id);

create table public.app_users (
  id              bigint generated always as identity primary key,
  auth_user_id    uuid        null,
  display_name    text        not null,
  status          text        not null default 'invited',
  deactivated_at  timestamptz null,
  content_version integer     not null default 1,
  created_at      timestamptz not null default now(),
  constraint fk_app_users_auth  foreign key (auth_user_id) references auth.users(id) on delete restrict,
  constraint uk_app_users_auth  unique (auth_user_id),
  constraint ck_app_users_status          check (status in ('invited','active','deactivated')),
  constraint ck_app_users_deactivated     check ((status = 'deactivated') = (deactivated_at is not null)),
  constraint ck_app_users_active_has_auth check (status <> 'active' or auth_user_id is not null)
);
create index ix_app_users_auth on public.app_users (auth_user_id);

create table public.capabilities (
  id              bigint generated always as identity primary key,
  capability_key  text not null,
  scope_kind      text not null,
  description     text not null,
  constraint uk_capabilities_key       unique (capability_key),
  constraint uk_capabilities_key_scope unique (capability_key, scope_kind),
  constraint ck_capabilities_scope     check (scope_kind in ('group','plant'))
);

create table public.group_capability_grants (
  id            bigint generated always as identity primary key,
  app_user_id   bigint      not null,
  capability_id bigint      not null,
  status        text        not null default 'active',
  granted_at    timestamptz not null default now(),
  granted_by    bigint      not null,
  revoked_at    timestamptz null,
  revoked_by    bigint      null,
  constraint fk_ggrant_user  foreign key (app_user_id)   references public.app_users(id)    on delete restrict,
  constraint fk_ggrant_cap   foreign key (capability_id) references public.capabilities(id) on delete restrict,
  constraint fk_ggrant_by    foreign key (granted_by)    references public.app_users(id)    on delete restrict,
  constraint fk_ggrant_rvby  foreign key (revoked_by)    references public.app_users(id)    on delete restrict,
  constraint ck_ggrant_status  check (status in ('active','revoked')),
  constraint ck_ggrant_revoked check ((status = 'revoked') = (revoked_at is not null))
);
create unique index uk_group_grant_one_active
  on public.group_capability_grants (app_user_id, capability_id) where status = 'active';

create table public.plant_capability_grants (
  id            bigint generated always as identity primary key,
  app_user_id   bigint      not null,
  plant_id      bigint      not null,
  capability_id bigint      not null,
  status        text        not null default 'active',
  granted_at    timestamptz not null default now(),
  granted_by    bigint      not null,
  revoked_at    timestamptz null,
  revoked_by    bigint      null,
  constraint fk_pgrant_user  foreign key (app_user_id)   references public.app_users(id)    on delete restrict,
  constraint fk_pgrant_plant foreign key (plant_id)      references public.plants(id)       on delete restrict,
  constraint fk_pgrant_cap   foreign key (capability_id) references public.capabilities(id) on delete restrict,
  constraint fk_pgrant_by    foreign key (granted_by)    references public.app_users(id)    on delete restrict,
  constraint fk_pgrant_rvby  foreign key (revoked_by)    references public.app_users(id)    on delete restrict,
  constraint ck_pgrant_status  check (status in ('active','revoked')),
  constraint ck_pgrant_revoked check ((status = 'revoked') = (revoked_at is not null))
);
create unique index uk_plant_grant_one_active
  on public.plant_capability_grants (app_user_id, plant_id, capability_id) where status = 'active';

create table public.operational_settings (
  id            bigint generated always as identity primary key,
  scope_type    text        not null,
  plant_id      bigint      null,
  setting_key   text        not null,
  setting_value jsonb       not null,
  version_no    integer     not null default 1,
  status        text        not null default 'current',
  created_at    timestamptz not null default now(),
  created_by    bigint      not null,
  constraint fk_opset_plant foreign key (plant_id)   references public.plants(id)    on delete restrict,
  constraint fk_opset_by    foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint ck_opset_scope         check (scope_type in ('group','plant')),
  constraint ck_opset_plant_present check ((scope_type = 'plant') = (plant_id is not null)),
  constraint ck_opset_status        check (status in ('current','superseded'))
);
create unique index uk_opset_current
  on public.operational_settings (scope_type, coalesce(plant_id, 0), setting_key) where status = 'current';

create table ref_private.reference_sequences (
  id         bigint generated always as identity primary key,
  scope_type text   not null,
  scope_key  bigint not null,
  fy_label   text   null,
  next_value bigint not null default 1,
  constraint ck_refseq_positive check (next_value >= 1),
  constraint uk_refseq unique (scope_type, scope_key, fy_label)
);
revoke all on ref_private.reference_sequences from public;
revoke all on ref_private.reference_sequences from anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['avadhoot_groups','plants','app_users','capabilities',
                           'group_capability_grants','plant_capability_grants','operational_settings']
  loop
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

grant select on public.avadhoot_groups, public.plants, public.capabilities,
                public.operational_settings, public.app_users,
                public.group_capability_grants, public.plant_capability_grants
  to authenticated;
grant insert, update on public.group_capability_grants, public.plant_capability_grants,
                        public.operational_settings to authenticated;
grant update (display_name) on public.app_users to authenticated;

do $$
declare t text;
begin
  foreach t in array array['avadhoot_groups','plants','app_users','capabilities',
                           'group_capability_grants','plant_capability_grants','operational_settings']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force  row level security', t);
  end loop;
end $$;

create or replace function app_private.current_app_user()
returns bigint language sql stable security definer set search_path = '' as $fn$
  select u.id from public.app_users u
   where u.auth_user_id = (select auth.uid()) and u.status = 'active';
$fn$;

create or replace function app_private.has_group_cap(p_cap text)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1 from public.group_capability_grants g
      join public.capabilities c on c.id = g.capability_id
      join public.app_users    u on u.id = g.app_user_id
     where u.auth_user_id = (select auth.uid()) and u.status = 'active'
       and c.capability_key = p_cap and g.status = 'active');
$fn$;

create or replace function app_private.has_plant_cap(p_plant bigint, p_cap text)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1 from public.plant_capability_grants g
      join public.capabilities c on c.id = g.capability_id
      join public.app_users    u on u.id = g.app_user_id
     where u.auth_user_id = (select auth.uid()) and u.status = 'active'
       and g.plant_id = p_plant and c.capability_key = p_cap and g.status = 'active');
$fn$;

create or replace function app_private.is_plant_member(p_plant bigint)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select app_private.has_plant_cap(p_plant, 'plant_access');
$fn$;

alter function app_private.is_admin(uuid) set search_path = '';

do $$
declare f text;
begin
  foreach f in array array['app_private.current_app_user()',
                           'app_private.has_group_cap(text)',
                           'app_private.has_plant_cap(bigint,text)',
                           'app_private.is_plant_member(bigint)']
  loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant  execute on function %s to authenticated', f);
  end loop;
end $$;

create policy app_users_select on public.app_users for select to authenticated
  using ( auth_user_id = (select auth.uid())
          or (select app_private.has_group_cap('administer_users')) );
create policy app_users_update_own on public.app_users for update to authenticated
  using      ( auth_user_id = (select auth.uid()) )
  with check ( auth_user_id = (select auth.uid()) );

create policy groups_select       on public.avadhoot_groups      for select to authenticated using ( true );
create policy plants_select       on public.plants               for select to authenticated using ( true );
create policy capabilities_select on public.capabilities         for select to authenticated using ( true );
create policy opset_select        on public.operational_settings for select to authenticated using ( true );

create policy ggrant_select on public.group_capability_grants for select to authenticated
  using ( app_user_id = (select app_private.current_app_user())
          or (select app_private.has_group_cap('administer_users')) );
create policy ggrant_insert on public.group_capability_grants for insert to authenticated
  with check ( (select app_private.has_group_cap('administer_users')) );
create policy ggrant_update on public.group_capability_grants for update to authenticated
  using      ( (select app_private.has_group_cap('administer_users')) )
  with check ( (select app_private.has_group_cap('administer_users')) and status = 'revoked' );

create policy pgrant_select on public.plant_capability_grants for select to authenticated
  using ( app_user_id = (select app_private.current_app_user())
          or (select app_private.has_group_cap('administer_users')) );
create policy pgrant_insert on public.plant_capability_grants for insert to authenticated
  with check ( (select app_private.has_group_cap('administer_users')) );
create policy pgrant_update on public.plant_capability_grants for update to authenticated
  using      ( (select app_private.has_group_cap('administer_users')) )
  with check ( (select app_private.has_group_cap('administer_users')) and status = 'revoked' );

insert into public.avadhoot_groups (name) values ('Avadhoot Group');

insert into public.plants (group_id, plant_code, name, timezone)
select g.id, v.code, v.name, 'Asia/Kolkata'
  from public.avadhoot_groups g,
       (values ('NAG','Nagpur'), ('PUN','Pune'), ('KOL','Kolkata')) as v(code, name);

insert into public.capabilities (capability_key, scope_kind, description) values
  ('read_party_master','group','Read Families, Parties, Locations'),
  ('read_construction_library','group','Read Constructions and versions'),
  ('manage_customer_master','group','Write Family/Party/Location'),
  ('manage_construction_library','group','Publish Constructions'),
  ('administer_users','group','Invitation, grants, settings'),
  ('declare_cutover','group','Declare Formal Data Cutover'),
  ('plant_access','plant','Baseline read of a plant''s data'),
  ('make_quote','plant','Maker'),
  ('check_quote','plant','Checker'),
  ('manage_sku_master','plant','SKU publication'),
  ('adopt_construction_for_plant','plant','Adopt a Construction version'),
  ('propose_commercial_master','plant','Propose commercial masters'),
  ('approve_commercial_master','plant','Approve commercial masters');