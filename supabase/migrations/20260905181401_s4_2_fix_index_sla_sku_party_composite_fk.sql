-- S4-2 fix: fk_sla_sku_party (sku_id, party_id) had no covering index.
--
-- ix_sla_sku is (sku_id, plant_id) and ix_sla_party is (party_id), so neither
-- leads with the pair. Supabase's own 0001 lint is satisfied by a leading-column
-- match and therefore did NOT report this; PS-5 checks the full key in order and
-- did. The gate is deliberately stricter than the advisor, and this is what that
-- buys: every restrict check on the (sku_id, party_id) parent key now has an
-- index to use instead of a sequential scan of the child.

create index ix_sla_sku_party on public.sku_location_applicabilities (sku_id, party_id);