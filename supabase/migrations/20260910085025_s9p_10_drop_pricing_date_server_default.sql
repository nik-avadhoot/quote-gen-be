-- S9-P/10: remove the server-date default from batches.pricing_date (D-V).
--
-- WHY. The column carried `default current_date`, which is the SERVER's date.
-- CDM-34 and S12.4 require the Pricing Date to be the PRODUCING PLANT's local
-- date, computed from `now() at time zone plants.timezone`, and app_private
-- .create_batch computes exactly that. The default was therefore a second,
-- silently wrong answer waiting for any insert path that did not name the
-- column - and around midnight, or around 31 March, it disagrees with the Batch
-- Reference's financial year, which is derived from the plant clock in the same
-- INSERT.
--
-- The column stays NOT NULL. Removing the default does not weaken the column; it
-- makes supplying a value mandatory, which is what create_batch already does.
-- An insert path that forgets now fails loudly instead of recording a date
-- nobody chose.
--
-- A CORRECTION TO THE PROPOSAL THIS IMPLEMENTS. The authority-correction
-- proposal said that once direct INSERT was revoked the default would be "dead"
-- because only create_batch inserts. That was wrong: tests.batch_workspace() and
-- tests.batch_sets() also insert into batches, at OWNER level, where the
-- `authenticated` revocation does not apply, and both relied on this default.
-- Dropping it breaks them, which S9-P/11 repairs by having those fixtures supply
-- the plant-local date explicitly - the same rule create_batch follows.

alter table public.batches alter column pricing_date drop default;

comment on column public.batches.pricing_date is
  'S9-P: the date the commercial basis is read as at. NOT NULL with NO default - every insert path must supply the PRODUCING PLANT local date (S12.4/CDM-34), which app_private.create_batch computes from plants.timezone. A server-date default was removed at S9-P/10 because it is a second, silently wrong answer.';