-- S6-11 (S6-C1, prerequisite): lineage is allocated by the database, and an
-- ordinary caller can add a Batch row at all.
--
-- FOUND THE SAME WAY AS S6-9, one statement later. batch_rows.lineage_id carried
--
--     default nextval('app_private.batch_row_lineage_seq')
--
-- while S6-2 revoked every privilege on that sequence from anon and
-- authenticated. A column default is evaluated as the INSERTING role, so the
-- default could only ever be evaluated by the table owner. Every S6 suite ran as
-- the table owner, so every suite inserted rows happily and the defect was
-- invisible. An authenticated Maker inserting a Batch row got
--
--     42501 permission denied for sequence batch_row_lineage_seq
--
-- which means the central write operation of the Batch workspace - adding a row -
-- was unavailable to every real caller. Not narrowed, not mis-scoped: unavailable.
--
-- THE FIX IS THE ONE S6-1 ALREADY CHOSE FOR THE OTHER ALLOCATED IDENTITY.
-- batch_reference is not a default either; it is written by a SECURITY DEFINER
-- BEFORE INSERT trigger that discards whatever the client sent, precisely so the
-- reference cannot be chosen, duplicated or guessed. lineage_id has exactly the
-- same character and a stronger reason: CDM-22 makes it stable across revisions
-- and §5.10 makes it the unique FK target S9's quote_items will point at. It is
-- the PM-7 key. So it is allocated the same way, and the sequence stays revoked.
--
-- THIS ALSO CLOSES A HOLE THAT WAS OPEN INDEPENDENTLY OF THE GRANT. Because
-- lineage_id was an ordinary column with a default, a caller holding table-level
-- INSERT could NAME it and choose its own value. uk_row_lineage would have
-- stopped a collision and guard_row_sku_immutable stops a later change, but
-- nothing stopped a caller picking an arbitrary unused lineage on the way in.
-- After this migration the trigger overwrites unconditionally, so lineage is the
-- system's word on every path, exactly as the Batch reference is.
--
-- Gaps remain legitimate and unchanged (§12.3): a lineage allocated by a
-- transaction that then rolls back is simply not used. Nothing renumbers.

create or replace function app_private.assign_row_lineage()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  -- whatever the client sent is discarded: lineage is the system's word, and
  -- S9's quote_items will point at it permanently (CDM-22, §5.10)
  new.lineage_id := nextval('app_private.batch_row_lineage_seq');
  return new;
end $fn$;

-- the trigger is the single allocator, so the unreachable default goes
alter table public.batch_rows alter column lineage_id drop default;

create trigger trg_row_lineage
  before insert on public.batch_rows
  for each row execute function app_private.assign_row_lineage();

revoke all on function app_private.assign_row_lineage() from public, anon, authenticated;
