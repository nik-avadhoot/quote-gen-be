-- S9(a): Family G - Quote families, immutable revisions, immutable Items and
-- their frozen calculation evidence. Schema, constraints, grants, RLS and
-- policies ONLY. No Send RPC, no workflow RPC, no reference allocation, no row
-- is created and no Quote number is consumed by this migration.
--
-- WHY IMMUTABILITY IS NOT AN RLS QUESTION ALONE. The canonical design (§7.4)
-- says "no UPDATE and no DELETE policy will exist" on quote_items and
-- calculation_snapshots, and calls that absence "the structural form of Quote
-- Items cannot calculate or edit". Absence of a POLICY is necessary and not
-- sufficient: a policy gates a privilege, so if the table privilege were ever
-- granted, a later policy - or a change to force RLS - would open the path.
-- Both halves are therefore closed here:
--
--   1. authenticated is granted SELECT and nothing else on every Family G
--      table. No INSERT, no UPDATE, no DELETE privilege exists to be gated.
--   2. RLS is ENABLED and FORCED, and no UPDATE/DELETE policy is written.
--
-- FORCE matters for a reason worth stating: without it, a table's OWNER bypasses
-- RLS. Forcing it means even the owner is subject to policy, so the guarantee
-- does not quietly depend on which role the connection happens to use.
--
-- AN APPLICATION ADMIN IS NOT A DATABASE ROLE. `administer_users` is a group
-- capability held by an app_user. It reaches these tables through the same
-- `authenticated` database role as everyone else, so it inherits exactly the
-- privileges granted above - SELECT. It is deliberately allowed to READ (it is
-- already inside app_private.can_read_batch) and it has no write path, because
-- there is no write privilege for a policy to admit. That is a different thing
-- from the database owner or the service role, which bypass PostgREST entirely
-- and are outside the API surface this stage governs.
--
-- WRITES ARRIVE LATER. Every Family G write is RPC-only by design: the atomic
-- Send RPC (S9(b)) and the workflow RPCs (S9(c)), both SECURITY DEFINER. They
-- do not exist yet, so today Family G is readable and, through the API,
-- unwritable by every role that reaches it.

-- ═══════════════════════════════════════════════════════════ quote_families
-- CDM-21: one family per Batch. CDM-30: an abandoned pre-approval family
-- consumes no Quote Reference, which is exactly `quote_reference is null` at
-- abandonment rather than a rule someone has to remember.
create table public.quote_families (
  id              bigint      generated always as identity primary key,
  batch_id        bigint      not null,
  quote_reference text        null,
  status          text        not null default 'draft',
  created_at      timestamptz not null default now(),
  created_by      bigint      not null,
  constraint fk_qf_batch      foreign key (batch_id)   references public.batches(id)   on delete restrict,
  constraint fk_qf_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint uk_qf_batch     unique (batch_id),
  constraint uk_qf_reference unique (quote_reference),
  constraint uk_qf_id_batch  unique (id, batch_id),
  constraint ck_qf_status check (status in ('draft','active','abandoned')),
  constraint ck_qf_abandoned_unreferenced
    check (status <> 'abandoned' or quote_reference is null)
);
create index ix_qf_batch      on public.quote_families (batch_id);
create index ix_qf_created_by on public.quote_families (created_by);

-- ══════════════════════════════════════════════════════════ quote_revisions
-- revision_no is NULLABLE and allocated at first approval (CDM-21): a draft
-- that is never approved must not consume a number.
create table public.quote_revisions (
  id                 bigint      generated always as identity primary key,
  family_id          bigint      not null,
  revision_no        integer     null,
  source_revision_id bigint      null,
  workflow_status    text        not null default 'draft',
  standing           text        null,
  addressee_name     text        null,
  addressee_details  jsonb       null,
  quote_date         date        null,
  offer_validity_to  date        null,
  approved_by        bigint      null,
  approved_at        timestamptz null,
  issued_by          bigint      null,
  issued_at          timestamptz null,
  voided_by          bigint      null,
  voided_at          timestamptz null,
  void_reason        text        null,
  withdraw_reason    text        null,
  return_note        text        null,
  created_at         timestamptz not null default now(),
  created_by         bigint      not null,
  constraint fk_qr_family      foreign key (family_id)          references public.quote_families(id) on delete restrict,
  constraint fk_qr_source      foreign key (source_revision_id) references public.quote_revisions(id) on delete restrict,
  constraint fk_qr_approved_by foreign key (approved_by)        references public.app_users(id)      on delete restrict,
  constraint fk_qr_issued_by   foreign key (issued_by)          references public.app_users(id)      on delete restrict,
  constraint fk_qr_voided_by   foreign key (voided_by)          references public.app_users(id)      on delete restrict,
  constraint fk_qr_created_by  foreign key (created_by)         references public.app_users(id)      on delete restrict,
  constraint uk_qr_revision  unique (family_id, revision_no),
  constraint uk_qr_id_family unique (id, family_id),
  constraint ck_qr_revision_no check (revision_no is null or revision_no >= 1),
  constraint ck_qr_workflow
    check (workflow_status in ('draft','submitted','returned','approved','issued','withdrawn')),
  constraint ck_qr_standing
    check (standing is null or standing in ('current','superseded','voided')),
  -- CDM-21: approval is what allocates the number, so approved/issued cannot lack one
  constraint ck_qr_approved_has_revision_no
    check (workflow_status not in ('approved','issued') or revision_no is not null),
  -- CDM-24: attribution is inseparable from the act
  constraint ck_qr_approval_pair check ((approved_by is null) = (approved_at is null)),
  constraint ck_qr_issue_pair    check ((issued_by   is null) = (issued_at   is null)),
  constraint ck_qr_void_pair     check ((voided_by   is null) = (voided_at   is null)),
  -- CDM-30: voiding always carries its reason
  constraint ck_qr_void_reason check (standing <> 'voided' or void_reason is not null),
  constraint ck_qr_not_self_source check (source_revision_id is distinct from id)
);
create index ix_qr_family     on public.quote_revisions (family_id);
create index ix_qr_status     on public.quote_revisions (workflow_status);
create index ix_qr_source     on public.quote_revisions (source_revision_id);
create index ix_qr_created_by on public.quote_revisions (created_by);

-- ═════════════════════════════════════════════════ calculation_snapshots
-- Immutable evidence (CDM-22). Hybrid typed + versioned JSONB (§11.1): typed
-- where a commercial question is routinely asked of it, JSONB for the complete
-- engine input and output, which evolves.
--
-- S8 FREIGHT PROVENANCE, DATABASE-BOUND (Product Owner decision, 2026-09-09).
-- S8 made governed and temporary freight authority distinguishable at runtime.
-- The runtime field enables enforcement; it does not guarantee it. This is where
-- it is guaranteed, because an issued snapshot is immutable and a wrong
-- provenance recorded here is uncorrectable:
--
--   · freight_source is a CLOSED list that does not contain 'unresolved', so
--     unresolved freight cannot enter a Quote snapshot at all;
--   · ck_cs_freight_authority_binds_source pins each source to exactly one
--     authority - no other combination is accepted;
--   · a governed 'master' snapshot must carry BOTH the Freight Set Version and
--     the Freight Entry, in the approved reference shape;
--   · a temporary source may carry NEITHER of them.
--
-- Warn-and-permit is the Product Owner's issuance rule: a Quote MAY be issued on
-- temporary freight. What it may never do is describe that freight as approved
-- Freight Master authority, and a later U3/U4 replacement must not rewrite an
-- already-issued snapshot - which the absence of any UPDATE path enforces.
create table public.calculation_snapshots (
  id                             bigint        generated always as identity primary key,
  schema_version                 integer       not null,
  engine_version                 text          not null,
  rounding_rule_version          text          not null,
  pricing_basis_release_id       bigint        not null,
  calculation_default_version_id bigint        not null,
  pricing_date                   date          not null,
  -- paired effective value + source for every inherited field (CDM-22)
  effective_waste_pct            numeric(7,3)  not null,
  waste_source                   text          not null,
  effective_conv_rate            numeric(12,4) not null,
  conv_source                    text          not null,
  effective_margin_pct           numeric(7,3)  not null,
  margin_source                  text          not null,
  effective_interest_pct         numeric(7,3)  not null,
  interest_source                text          not null,
  effective_freight              numeric(12,4) not null,
  freight_source                 text          not null,
  freight_authority              text          not null,
  freight_set_version_id         bigint        null,
  freight_entry_id               bigint        null,
  -- results worth querying without opening the JSON
  total_cost                     numeric(14,4) not null,
  final_rate                     numeric(14,4) not null,
  rate_per_kg                    numeric(14,4) not null,
  calc_moq                       bigint        null,
  calculation_fingerprint        text          not null,
  presentation_fingerprint       text          not null,
  effective_inputs               jsonb         not null,
  results                        jsonb         not null,
  calculated_by                  bigint        not null,
  calculated_at                  timestamptz   not null default now(),
  constraint fk_cs_release   foreign key (pricing_basis_release_id)
    references public.pricing_basis_releases(id) on delete restrict,
  constraint fk_cs_cdv       foreign key (calculation_default_version_id)
    references public.calculation_default_versions(id) on delete restrict,
  constraint fk_cs_freight_set_version foreign key (freight_set_version_id)
    references public.freight_set_versions(id) on delete restrict,
  constraint fk_cs_freight_entry foreign key (freight_entry_id)
    references public.freight_entries(id) on delete restrict,
  constraint fk_cs_calculated_by foreign key (calculated_by)
    references public.app_users(id) on delete restrict,
  constraint ck_cs_schema_version  check (schema_version >= 1),
  constraint ck_cs_engine_version  check (btrim(engine_version) <> ''),
  constraint ck_cs_rounding_version check (btrim(rounding_rule_version) <> ''),
  constraint ck_cs_fingerprints check (btrim(calculation_fingerprint) <> ''
                                   and btrim(presentation_fingerprint) <> ''),
  -- the four non-freight chains resolve or the row is not evidence
  constraint ck_cs_waste_source    check (waste_source    in ('row','batch','sector','system')),
  constraint ck_cs_conv_source     check (conv_source     in ('row','batch','sector','system')),
  constraint ck_cs_margin_source   check (margin_source   in ('row','batch','sector','system')),
  constraint ck_cs_interest_source check (interest_source in ('pricing_group','derived_annual','system')),
  -- CDM-17 / S8. 'unresolved' is ABSENT on purpose: it cannot be sent.
  constraint ck_cs_freight_source
    check (freight_source in ('row','legacy_batch','pricing_group','master','legacy_matrix')),
  constraint ck_cs_freight_authority check (freight_authority in ('governed','temporary')),
  constraint ck_cs_freight_authority_binds_source check (
        (freight_source in ('row','pricing_group','master') and freight_authority = 'governed')
     or (freight_source in ('legacy_batch','legacy_matrix')  and freight_authority = 'temporary')),
  -- a governed approved-master snapshot carries BOTH references or is not one
  constraint ck_cs_master_has_both_refs check (
    freight_source <> 'master'
    or (freight_set_version_id is not null and freight_entry_id is not null)),
  -- a temporary source may never occupy the governed reference shape
  constraint ck_cs_temporary_carries_no_governed_ref check (
    freight_authority <> 'temporary'
    or (freight_set_version_id is null and freight_entry_id is null)),
  constraint ck_cs_effective_inputs_object check (jsonb_typeof(effective_inputs) = 'object'),
  constraint ck_cs_results_object          check (jsonb_typeof(results) = 'object')
);
create index ix_cs_release       on public.calculation_snapshots (pricing_basis_release_id);
create index ix_cs_cdv           on public.calculation_snapshots (calculation_default_version_id);
create index ix_cs_freight_set   on public.calculation_snapshots (freight_set_version_id);
create index ix_cs_freight_entry on public.calculation_snapshots (freight_entry_id);
create index ix_cs_calculated_by on public.calculation_snapshots (calculated_by);
create index ix_cs_freight_auth  on public.calculation_snapshots (freight_authority);

-- ═════════════════════════════════════════════════════════════ quote_items
-- Immutable (CDM-02, CDM-22). PM-7: the lineage, not the row id, so the link
-- survives later edits to the originating Batch row (§5.10).
create table public.quote_items (
  id                      bigint generated always as identity primary key,
  revision_id             bigint not null,
  batch_row_lineage_id    bigint not null,
  pricing_group_id        bigint not null,
  calculation_snapshot_id bigint not null,
  constraint fk_qi_revision foreign key (revision_id)
    references public.quote_revisions(id) on delete restrict,
  constraint fk_qi_lineage  foreign key (batch_row_lineage_id)
    references public.batch_rows(lineage_id) on delete restrict,
  constraint fk_qi_pricing_group foreign key (pricing_group_id)
    references public.pricing_groups(id) on delete restrict,
  constraint fk_qi_snapshot foreign key (calculation_snapshot_id)
    references public.calculation_snapshots(id) on delete restrict,
  constraint uk_qi_revision_lineage unique (revision_id, batch_row_lineage_id),
  constraint uk_qi_snapshot         unique (calculation_snapshot_id)
);
create index ix_qi_revision      on public.quote_items (revision_id);
create index ix_qi_lineage       on public.quote_items (batch_row_lineage_id);
create index ix_qi_pricing_group on public.quote_items (pricing_group_id);

-- CDM-16: one Item covers every same-priced Delivery Group; it is not repeated
-- once per destination.
create table public.quote_item_delivery_groups (
  id                bigint generated always as identity primary key,
  quote_item_id     bigint not null,
  delivery_group_id bigint not null,
  constraint fk_qidg_item  foreign key (quote_item_id)     references public.quote_items(id)     on delete restrict,
  constraint fk_qidg_group foreign key (delivery_group_id) references public.delivery_groups(id) on delete restrict,
  constraint uk_qidg unique (quote_item_id, delivery_group_id)
);
create index ix_qidg_item  on public.quote_item_delivery_groups (quote_item_id);
create index ix_qidg_group on public.quote_item_delivery_groups (delivery_group_id);

-- ══════════════════════════════════════════════════════ append-only events
create table public.quote_workflow_events (
  id            bigint      generated always as identity primary key,
  revision_id   bigint      not null,
  event_type    text        not null,
  actor_user_id bigint      not null,
  occurred_at   timestamptz not null default now(),
  note          text        null,
  constraint fk_qwe_revision foreign key (revision_id)   references public.quote_revisions(id) on delete restrict,
  constraint fk_qwe_actor    foreign key (actor_user_id) references public.app_users(id)       on delete restrict,
  constraint ck_qwe_event_type check (event_type in
    ('submitted','returned','approved','withdrawn','issued','voided','superseded','archived'))
);
create index ix_qwe_revision on public.quote_workflow_events (revision_id, occurred_at);
create index ix_qwe_actor    on public.quote_workflow_events (actor_user_id);

-- CDM-28: standing and outcome are independent - an Accepted revision may later
-- be Superseded, so this is a separate append-only stream, not a status column.
create table public.customer_outcome_events (
  id                   bigint      generated always as identity primary key,
  revision_id          bigint      not null,
  outcome              text        not null,
  acceptance_date      date        null,
  acceptance_reference text        null,
  note                 text        null,
  recorded_by          bigint      not null,
  occurred_at          timestamptz not null default now(),
  constraint fk_coe_revision    foreign key (revision_id) references public.quote_revisions(id) on delete restrict,
  constraint fk_coe_recorded_by foreign key (recorded_by) references public.app_users(id)       on delete restrict,
  constraint ck_coe_outcome check (outcome in ('awaiting_response','accepted','rejected','expired'))
);
create index ix_coe_revision on public.customer_outcome_events (revision_id, occurred_at);
create index ix_coe_recorded_by on public.customer_outcome_events (recorded_by);

create table public.export_events (
  id                      bigint      generated always as identity primary key,
  revision_id             bigint      not null,
  template_name           text        not null,
  template_version        text        not null,
  is_official             boolean     not null,
  mismatch_acknowledged   boolean     not null default false,
  acknowledgement_note    text        null,
  representative_choices  jsonb       null,
  exported_by             bigint      not null,
  exported_at             timestamptz not null default now(),
  constraint fk_ee_revision    foreign key (revision_id) references public.quote_revisions(id) on delete restrict,
  constraint fk_ee_exported_by foreign key (exported_by) references public.app_users(id)       on delete restrict,
  -- CDM-36: an acknowledged mismatch always carries its note
  constraint ck_ee_ack check (not mismatch_acknowledged or acknowledgement_note is not null)
);
create index ix_ee_revision    on public.export_events (revision_id, exported_at);
create index ix_ee_exported_by on public.export_events (exported_by);

-- Parts belong wholly to one event; no event is deletable post-cutover, so the
-- cascade can never orphan evidence that outlives its parent.
create table public.export_parts (
  id              bigint  generated always as identity primary key,
  export_event_id bigint  not null,
  part_name       text    not null,
  part_kind       text    not null,
  sequence_no     integer not null,
  constraint fk_ep_event foreign key (export_event_id) references public.export_events(id) on delete cascade,
  constraint uk_ep_sequence unique (export_event_id, sequence_no),
  constraint ck_ep_part_name check (btrim(part_name) <> ''),
  constraint ck_ep_part_kind check (btrim(part_kind) <> ''),
  constraint ck_ep_sequence  check (sequence_no >= 1)
);
create index ix_ep_event on public.export_parts (export_event_id);

-- ═══════════════════════════════════════════════════════════════════ grants
-- SELECT and nothing else, on every Family G table, for both API roles. There
-- is no INSERT/UPDATE/DELETE privilege for any policy to admit, so immutability
-- does not rest on the absence of a policy alone. Writes arrive as SECURITY
-- DEFINER RPCs in S9(b)/S9(c).
do $$
declare t text;
begin
  foreach t in array array['quote_families','quote_revisions','calculation_snapshots',
                           'quote_items','quote_item_delivery_groups',
                           'quote_workflow_events','customer_outcome_events',
                           'export_events','export_parts']
  loop
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force  row level security', t);
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════ readability
-- Traversal helpers. Quote rows are reachable exactly when their originating
-- Batch is, so authority is not restated in five places and cannot drift.
--
-- DEFINED AFTER THE TABLES, deliberately: a `language sql` body is parsed and
-- validated at CREATE time, so declaring these first would fail on tables that
-- do not exist yet. They are only needed by the policies below.
create or replace function app_private.can_read_quote_family(p_family bigint)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1 from public.quote_families qf
     where qf.id = p_family
       and (select app_private.can_read_batch(qf.batch_id)) );
$fn$;

create or replace function app_private.can_read_quote_revision(p_revision bigint)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1 from public.quote_revisions qr
     where qr.id = p_revision
       and (select app_private.can_read_quote_family(qr.family_id)) );
$fn$;

create or replace function app_private.can_read_quote_item(p_item bigint)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1 from public.quote_items qi
     where qi.id = p_item
       and (select app_private.can_read_quote_revision(qi.revision_id)) );
$fn$;

-- ═════════════════════════════════════════════════════════════════ policies
-- SELECT only, everywhere. Quote visibility follows Batch visibility, so a
-- caller sees the Quotes of the Batches they can already read and no others.
create policy quote_families_select on public.quote_families for select to authenticated
  using ( (select app_private.can_read_batch(batch_id)) );

create policy quote_revisions_select on public.quote_revisions for select to authenticated
  using ( (select app_private.can_read_quote_family(family_id)) );

create policy quote_items_select on public.quote_items for select to authenticated
  using ( (select app_private.can_read_quote_revision(revision_id)) );

-- A snapshot is visible exactly through the one Item that owns it (uk_qi_snapshot).
-- There is no Quote-side path from a snapshot to Batch inputs (§10.5 layer 1).
create policy calculation_snapshots_select on public.calculation_snapshots for select to authenticated
  using ( exists (select 1 from public.quote_items qi
                   where qi.calculation_snapshot_id = calculation_snapshots.id
                     and (select app_private.can_read_quote_item(qi.id))) );

create policy quote_item_delivery_groups_select on public.quote_item_delivery_groups
  for select to authenticated
  using ( (select app_private.can_read_quote_item(quote_item_id)) );

create policy quote_workflow_events_select on public.quote_workflow_events for select to authenticated
  using ( (select app_private.can_read_quote_revision(revision_id)) );

create policy customer_outcome_events_select on public.customer_outcome_events for select to authenticated
  using ( (select app_private.can_read_quote_revision(revision_id)) );

create policy export_events_select on public.export_events for select to authenticated
  using ( (select app_private.can_read_quote_revision(revision_id)) );

create policy export_parts_select on public.export_parts for select to authenticated
  using ( exists (select 1 from public.export_events ee
                   where ee.id = export_parts.export_event_id
                     and (select app_private.can_read_quote_revision(ee.revision_id))) );

-- The traversal helpers are internal machinery, not an API surface.
revoke all on function app_private.can_read_quote_family(bigint)   from public, anon, authenticated;
revoke all on function app_private.can_read_quote_revision(bigint) from public, anon, authenticated;
revoke all on function app_private.can_read_quote_item(bigint)     from public, anon, authenticated;
