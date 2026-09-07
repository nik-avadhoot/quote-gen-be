-- Family B governed mutations - schema additions.
--
-- WHY. The U1 Customer Family mutation slice (post-S7 handover, U1-C
-- correction round) needs compare-and-swap protection on every mutable
-- Family B record, and neither table carried what that requires yet:
--
--   customer_families        already had content_version (S1/P2-3), but no
--                             attribution for the proposed->active approval
--                             transition this slice adds.
--   customer_family_aliases  had NEITHER content_version NOR any concept of
--                             retirement - it was insert-only (created by
--                             merge_families and nothing else) before this
--                             slice adds direct alias edit/retire.
--
-- CAS TECHNIQUE. Matches the established pattern exactly
-- (app_private.revise_batch_profile, S6-12): a self-referential no-op
-- UPDATE guarded by `content_version = p_expected` is the compare-and-swap,
-- and the row lock it takes serialises concurrent callers instead of
-- letting the second one silently overwrite the first. 40001
-- (serialization_failure) is the established conflict code.

alter table public.customer_families
  add column approved_by bigint null references app_users(id) on delete restrict,
  add column approved_at timestamptz null;

alter table public.customer_family_aliases
  add column content_version integer not null default 1,
  add column status text not null default 'active',
  add constraint ck_alias_status check (status in ('active', 'retired'));

comment on column public.customer_families.approved_by is
  'Set only by app_private.approve_customer_family() when status moves proposed -> active. Null for a Family that was created directly as active (manage_customer_master path) or is still proposed.';
comment on column public.customer_family_aliases.content_version is
  'CAS token, same convention as every other mutable Family B/S6 record. Starts at 1, incremented by app_private.update_family_alias() / retire_family_alias().';
