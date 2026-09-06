-- S7-2: the explicit Pricing Group interest override keeps its reason and its
-- attribution.
--
-- Canonical Amendment 01, A-04 (Product Owner, 2026-09-06). The override is
-- RETAINED - it is the commercial escape hatch, and removing it would leave a
-- negotiated term unquotable and put pressure on the closed Payment Terms list,
-- which is the friction S5 deliberately built. What it gains is accountability:
-- "where the override differs from the derived percentage, a reason is mandatory,
-- and the actor, the time, the derived percentage and the overridden percentage
-- are all preserved".
--
-- Four columns, because all four of those things were named:
--
--   interest_override_pct           already existed - the OVERRIDDEN value
--   interest_override_derived_pct   the DERIVED value, as at the moment of override
--   interest_override_reason        mandatory when the two differ
--   interest_override_by / _at      the ACTOR and the TIME
--
-- THE CHECK IS INTRA-ROW ON PURPOSE. Whether an override "differs from the
-- derived percentage" cannot be answered by a CHECK that would have to reach the
-- effective Pricing Basis Release, its Calculation Defaults version and the
-- annual rate - a CHECK may not contain a subquery, and an RPC-only rule is
-- silently bypassed by any later write path that forgets to call it. Recording
-- the derived value ALONGSIDE the override turns the rule into a comparison of
-- two columns in one row, which a CHECK can enforce against every writer
-- including the BYPASSRLS roles.
--
-- WHAT THAT DOES AND DOES NOT PROVE. The derived value is caller-asserted, so a
-- determined caller could record a derived value equal to the override and skip
-- the reason. It is not a security boundary and is not claimed as one: this is a
-- replaceable pre-Send working value (CDM-22), and S9 freezes the resolver's own
-- derivation at Send. The actor and the time are NOT caller-asserted - the
-- trigger writes them - which is the part that has to be trustworthy for CDM-34.
--
-- BLANK, ZERO AND OVERRIDE. Null means inherit and the derivation applies. Zero
-- is an explicit zero - a deliberate decision that no interest is charged - and
-- it is an override like any other, so it carries a reason and attribution.
-- Clearing the override clears all four companions, so an inheriting Pricing
-- Group never carries the residue of a decision that no longer stands.

alter table public.pricing_groups
  add column interest_override_derived_pct numeric(7,3)  null,
  add column interest_override_reason      text          null,
  add column interest_override_by          bigint        null,
  add column interest_override_at          timestamptz   null;

alter table public.pricing_groups
  add constraint fk_pg_interest_override_by
    foreign key (interest_override_by) references public.app_users(id) on delete restrict,
  add constraint ck_pg_interest_override_derived_range
    check (interest_override_derived_pct is null
           or (interest_override_derived_pct >= 0 and interest_override_derived_pct < 100)),
  -- an override is inseparable from its attribution (CDM-34), in both directions
  add constraint ck_pg_interest_override_attribution
    check ((interest_override_pct is null) = (interest_override_by is null)
       and (interest_override_pct is null) = (interest_override_at is null)),
  -- and from its reason, unless it agrees with a recorded derived value
  add constraint ck_pg_interest_override_reason
    check (interest_override_pct is null
           or (interest_override_derived_pct is not null
               and interest_override_pct = interest_override_derived_pct)
           or (interest_override_reason is not null and btrim(interest_override_reason) <> ''));

-- §2 of the brief: index every foreign key
create index ix_pg_interest_override_by on public.pricing_groups (interest_override_by);

-- Attribution is written by the database and never accepted from the client
-- (CDM-34). Assignment rather than rejection, matching the approval branch of
-- app_private.guard_master_version_transition, which sets approved_by/at the
-- same way. Re-stamped whenever the decision itself changes - value, derived
-- value or reason - and left alone when an unrelated column moves, so editing a
-- Pricing Group's label does not rewrite who decided its interest.
create or replace function app_private.stamp_interest_override_attribution()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if new.interest_override_pct is null then
    -- inherit: no decision stands, so no residue of one is kept
    new.interest_override_derived_pct := null;
    new.interest_override_reason      := null;
    new.interest_override_by          := null;
    new.interest_override_at          := null;
    return new;
  end if;

  if tg_op = 'INSERT'
     or old.interest_override_pct         is distinct from new.interest_override_pct
     or old.interest_override_derived_pct is distinct from new.interest_override_derived_pct
     or old.interest_override_reason      is distinct from new.interest_override_reason then
    new.interest_override_by := app_private.current_app_user();
    new.interest_override_at := now();
  else
    new.interest_override_by := old.interest_override_by;
    new.interest_override_at := old.interest_override_at;
  end if;

  -- A caller with no application identity cannot record a commercial decision.
  -- ck_pg_interest_override_attribution would refuse this anyway; raising here
  -- says why instead of naming a constraint.
  if new.interest_override_by is null then
    raise exception 'an interest override must be attributable to an application user (CDM-34)'
      using errcode = '42501';
  end if;

  return new;
end $fn$;

create trigger trg_pg_interest_override_attribution
  before insert or update on public.pricing_groups
  for each row execute function app_private.stamp_interest_override_attribution();

revoke all on function app_private.stamp_interest_override_attribution() from public, anon, authenticated;

comment on column public.pricing_groups.interest_override_pct is
  'CDM-18 / Amendment 01 A-04: the explicit override. Null inherits and the annual derivation applies; zero is an explicit zero, not a blank. Takes precedence over the derivation.';

comment on column public.pricing_groups.interest_override_derived_pct is
  'The percentage the resolver derived at the moment of override. Caller-asserted working value; S9 freezes the resolver''s own derivation at Send. Present so the reason rule is enforceable intra-row.';

comment on column public.pricing_groups.interest_override_reason is
  'Mandatory when the override differs from the recorded derived percentage (Amendment 01 A-04).';
