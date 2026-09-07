-- Fix: customer_families.approved_by (added by family_b_mutations_schema) had no
-- covering index - the performance advisor flags it and the established
-- discipline elsewhere in this codebase (S6 Family F's BF-5: "every foreign
-- key ... is index-covered") applies here too. A small, additive index.
create index if not exists ix_customer_families_approved_by
  on public.customer_families (approved_by);
