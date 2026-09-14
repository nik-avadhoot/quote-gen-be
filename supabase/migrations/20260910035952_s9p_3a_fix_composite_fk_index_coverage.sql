-- S9-P/3a: fk_batch_pricing_basis was not index-covered.
--
-- CAUGHT BY BF-5, an existing Family F gate: "every foreign key in Family F is
-- index-covered, composite ones included". S9-P/3 added a COMPOSITE foreign key
-- on (pricing_basis_release_id, plant_id) but only a single-column index on
-- (pricing_basis_release_id). A single-column index does not cover a two-column
-- foreign key: the planner needs the FK's columns as the index's leading
-- columns, in order, for the referencing-side lookup a cascade or a parent
-- delete performs.
--
-- This is exactly the class of defect the gate exists for, and it was invisible
-- to every assertion this tranche wrote - the constraint worked, the refusals
-- were correct, and only the index shape was wrong. Recorded rather than quietly
-- corrected, because a green suite that missed it would have been misleading.

drop index if exists public.ix_batch_pricing_basis;

create index ix_batch_pricing_basis
  on public.batches (pricing_basis_release_id, plant_id);