-- S6-3: Family F, part three - SETs, their cardinality counter, and the
-- replaceable working calculation.
--
-- §5.9: "an active SET has at least one component" is an aggregate over a child
-- table, which a CHECK cannot express. A counter column maintained by a trigger
-- turns it into an ordinary check, and that makes CDM-20's dissolve/reactivate
-- transition MECHANICAL: the counter reaching 0 drives status='dissolved', and
-- rising to 1 restores 'active' ON THE SAME ROW, so identity and label survive
-- (A-9, A-15). No write path can produce an active empty SET.
--
-- DECLARED DEVIATION, and the reason. §4.6 lists `status default 'active'`
-- alongside `active_component_count default 0`, but those two defaults together
-- violate ck_set_active_has_component immediately - a SET created with both
-- defaults could never be inserted at all. The check is the authority, because
-- it encodes CDM-20; the default is what has to give. status therefore defaults
-- to 'dissolved', which is also the truthful state of a SET that has no
-- components yet, and the counter trigger promotes it the moment the first
-- component is attached. That is exactly CDM-20's "attaching the first
-- Plate/Partition creates or reactivates a SET".
--
-- THE COUNTER IS THE DATABASE'S WORD. A BEFORE UPDATE trigger on batch_sets
-- recomputes active_component_count from the membership table and discards
-- whatever the client sent, so the column cannot be talked out of agreeing with
-- reality. The check then has something trustworthy to test.
--
-- A-16: uk_set_code_normalised is UNCONDITIONAL and normalised. It mirrors
-- normSetCode = v => (v||"").trim().toUpperCase() (engine/rowType.js:32). A raw
-- text index would let `abc` and `ABC` coexist while the application treats them
-- as one SET - a comparison site in the one layer the audit gate cannot see.
-- Being unconditional, dissolved SETs keep reserving their code (CDM-20).

create table public.batch_sets (
  id                     bigint      generated always as identity primary key,
  batch_id               bigint      not null,
  box_row_id             bigint      not null,
  box_row_type           text        not null default 'box',
  set_code               text        not null,
  status                 text        not null default 'dissolved',
  active_component_count integer     not null default 0,
  created_at             timestamptz not null default now(),
  created_by             bigint      not null,
  constraint fk_set_batch      foreign key (batch_id) references public.batches(id) on delete restrict,
  constraint fk_set_box_row    foreign key (box_row_id, batch_id)
    references public.batch_rows(id, batch_id) on delete restrict,
  -- §5.6: a non-Box parent has no matching parent key, so it cannot be named
  constraint fk_set_box_is_box foreign key (box_row_id, box_row_type)
    references public.batch_rows(id, row_type) on delete restrict,
  constraint fk_set_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint uk_set_id_batch  unique (id, batch_id),
  constraint uk_set_box_row   unique (box_row_id),
  constraint ck_set_code_not_blank check (btrim(set_code) <> ''),
  constraint ck_set_box_row_type   check (box_row_type = 'box'),
  constraint ck_set_status         check (status in ('active','dissolved')),
  constraint ck_set_count_non_negative check (active_component_count >= 0),
  constraint ck_set_active_has_component
    check (status <> 'active' or active_component_count >= 1)
);
create unique index uk_set_code_normalised on public.batch_sets (batch_id, upper(btrim(set_code)));
create index ix_set_batch      on public.batch_sets (batch_id);
create index ix_set_box_row    on public.batch_sets (box_row_id, batch_id);
create index ix_set_box_type   on public.batch_sets (box_row_id, box_row_type);
create index ix_set_created_by on public.batch_sets (created_by);

-- Components only. The Box is batch_sets.box_row_id, never a membership row.
create table public.batch_set_memberships (
  id         bigint      generated always as identity primary key,
  set_id     bigint      not null,
  row_id     bigint      not null,
  batch_id   bigint      not null,
  role       text        not null,
  status     text        not null default 'active',
  created_at timestamptz not null default now(),
  created_by bigint      not null,
  constraint fk_bsm_set        foreign key (set_id, batch_id)
    references public.batch_sets(id, batch_id) on delete restrict,
  constraint fk_bsm_row        foreign key (row_id, batch_id)
    references public.batch_rows(id, batch_id) on delete restrict,
  constraint fk_bsm_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint ck_bsm_role   check (role in ('plate','partition','other')),
  constraint ck_bsm_status check (status in ('active','removed'))
);
create unique index uk_bsm_active on public.batch_set_memberships (set_id, row_id) where status = 'active';
create index ix_bsm_set        on public.batch_set_memberships (set_id, batch_id);
create index ix_bsm_row        on public.batch_set_memberships (row_id, batch_id);
create index ix_bsm_created_by on public.batch_set_memberships (created_by);

-- ---------------------------------------------- batch_calculations
-- The one place a Batch child cascades (§4.9): a working calculation is
-- worthless without its row and is explicitly replaceable pre-Send (CDM-22).
-- Frozen evidence lives in calculation_snapshots, which is restrict - that is
-- S9's table, not this one.
create table public.batch_calculations (
  id                       bigint      generated always as identity primary key,
  batch_row_id             bigint      not null,
  batch_id                 bigint      not null,
  calculation_fingerprint  text        not null,
  presentation_fingerprint text        not null,
  engine_version           text        not null,
  schema_version           integer     not null,
  effective_inputs         jsonb       not null,
  results                  jsonb       not null,
  computed_by              bigint      null,
  computed_at              timestamptz not null default now(),
  constraint fk_bc_row foreign key (batch_row_id, batch_id)
    references public.batch_rows(id, batch_id) on delete cascade,
  constraint fk_bc_computed_by foreign key (computed_by) references public.app_users(id) on delete restrict,
  constraint uk_bc_row unique (batch_row_id),
  constraint ck_bc_fingerprints check (btrim(calculation_fingerprint) <> ''
                                   and btrim(presentation_fingerprint) <> ''),
  constraint ck_bc_engine_version check (btrim(engine_version) <> ''),
  constraint ck_bc_schema_version check (schema_version >= 1)
);
create index ix_bc_row         on public.batch_calculations (batch_row_id, batch_id);
create index ix_bc_batch       on public.batch_calculations (batch_id);
create index ix_bc_computed_by on public.batch_calculations (computed_by);

-- ------------------------------------------- §5.9 the cardinality counter
create or replace function app_private.sync_set_component_count()
returns trigger language plpgsql set search_path = '' as $fn$
declare v_set bigint; v_n int;
begin
  v_set := coalesce(new.set_id, old.set_id);
  select count(*)::int into v_n
    from public.batch_set_memberships
   where set_id = v_set and status = 'active';

  update public.batch_sets
     set active_component_count = v_n,
         status = case when v_n >= 1 then 'active' else 'dissolved' end
   where id = v_set;

  return coalesce(new, old);
end $fn$;

create trigger trg_bsm_sync_count
  after insert or update or delete on public.batch_set_memberships
  for each row execute function app_private.sync_set_component_count();

-- The counter is not the client's to state.
create or replace function app_private.recompute_set_count()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  select count(*)::int into new.active_component_count
    from public.batch_set_memberships
   where set_id = new.id and status = 'active';
  return new;
end $fn$;

create trigger trg_set_recompute_count
  before update on public.batch_sets
  for each row execute function app_private.recompute_set_count();

-- ---------------------------------------------------------------- grants
do $$
declare t text;
begin
  foreach t in array array['batch_sets','batch_set_memberships','batch_calculations']
  loop
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force  row level security', t);
  end loop;
  execute 'grant insert, update on public.batch_sets to authenticated';
  execute 'grant insert, update on public.batch_set_memberships to authenticated';
  -- batch_calculations is RPC only (§7.5): no write grant at all
end $$;

-- ---------------------------------------------------------------- policies
do $$
declare t text;
begin
  foreach t in array array['batch_sets','batch_set_memberships']
  loop
    execute format($p$
      create policy %1$s_select on public.%1$I for select to authenticated
        using ( (select app_private.can_read_batch(batch_id)) )$p$, t);
    execute format($p$
      create policy %1$s_insert on public.%1$I for insert to authenticated
        with check ( created_by = (select app_private.current_app_user())
                     and (select app_private.can_write_batch(batch_id)) )$p$, t);
    execute format($p$
      create policy %1$s_update on public.%1$I for update to authenticated
        using      ( (select app_private.can_write_batch(batch_id)) )
        with check ( (select app_private.can_write_batch(batch_id)) )$p$, t);
  end loop;
end $$;

-- Read only, batch-scoped. Writes are the Calculate function's, which is S7 -
-- so today there is no write policy and no write grant, and the table is
-- unwritable by every role reaching it through the API.
create policy batch_calculations_select on public.batch_calculations for select to authenticated
  using ( (select app_private.can_read_batch(batch_id)) );

revoke all on function app_private.sync_set_component_count() from public, anon, authenticated;
revoke all on function app_private.recompute_set_count() from public, anon, authenticated;