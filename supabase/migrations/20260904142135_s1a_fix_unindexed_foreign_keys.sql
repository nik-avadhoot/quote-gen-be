-- S1(a) defect correction: cover every foreign key with an index.
-- Advisor lint 0001 flagged 9 FK columns without a covering index on the Family A
-- grant/settings tables. Uncovered FK columns force sequential scans on the
-- ON DELETE RESTRICT checks that CDM-31 relies on, and on capability joins.
-- Corrected within the approved design; no schema or policy semantics change.

create index ix_ggrant_cap  on public.group_capability_grants (capability_id);
create index ix_ggrant_by   on public.group_capability_grants (granted_by);
create index ix_ggrant_rvby on public.group_capability_grants (revoked_by);

create index ix_pgrant_plant on public.plant_capability_grants (plant_id);
create index ix_pgrant_cap   on public.plant_capability_grants (capability_id);
create index ix_pgrant_by    on public.plant_capability_grants (granted_by);
create index ix_pgrant_rvby  on public.plant_capability_grants (revoked_by);

create index ix_opset_plant on public.operational_settings (plant_id);
create index ix_opset_by    on public.operational_settings (created_by);