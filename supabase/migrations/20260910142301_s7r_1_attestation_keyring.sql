-- S7-R/1: the attestation keyring (D-AC), created EMPTY.
--
-- WHY A KEYRING EXISTS AT ALL. S7-R admits engine output that the database
-- cannot recompute, so admission has to rest on proof that the bytes came from
-- the trusted executor. That proof is an HMAC-SHA256, and this table is where
-- the verifying half of the key lives. Nothing else in the model needs it.
--
-- NO KEY MATERIAL IS IN THIS MIGRATION, AND NONE MAY EVER BE. The table is
-- created empty. A 256-bit key is generated out of band and provisioned by the
-- Product Owner into two places - the Edge Function's secret configuration and
-- this table - and appears in no migration, no repository file, no fixture, no
-- log, no report and no error message. CP-115 proves the first half of that
-- mechanically: after a from-empty G-B replay this table has zero rows, which
-- is only possible if no migration ever inserted one.
--
-- ONE ACTIVE KEY, BY INDEX RATHER THAN BY CONVENTION. uk_attestation_key_active
-- is a partial unique index over status, so a second 'active' key is
-- unrepresentable. Signing uses the active key; verification additionally
-- accepts a 'retiring' one so a rotation does not invalidate attestations
-- already in flight.
--
-- THE OVERLAP IS BOUNDED BY THE ATTESTATION LIFETIME, NOT BY HABIT. A retiring
-- key stays acceptable for at most 120 seconds - the maximum lifetime any
-- attestation may carry - after which it verifies nothing and the row may be
-- deleted. That bound is enforced in the verifier (S7-R/6) rather than left to
-- whoever performs the rotation.
--
-- REACHABILITY. No role holds any privilege on this table. It is read only from
-- inside a SECURITY DEFINER verifier that never returns the key, never logs it,
-- and never includes it in an error message.

create table app_private.attestation_keys (
  keyid       text        primary key,
  key         bytea       not null,
  status      text        not null,
  created_at  timestamptz not null default now(),
  retiring_at timestamptz,
  constraint ck_ak_keyid  check (keyid ~ '^[a-z0-9][a-z0-9_-]{0,62}$'),
  constraint ck_ak_key_len check (octet_length(key) = 32),
  constraint ck_ak_status check (status in ('active','retiring')),
  constraint ck_ak_retiring_at check ((status = 'retiring') = (retiring_at is not null))
);

create unique index uk_attestation_key_active
  on app_private.attestation_keys (status) where status = 'active';

revoke all on app_private.attestation_keys from public;
revoke all on app_private.attestation_keys from anon;
revoke all on app_private.attestation_keys from authenticated;

comment on table app_private.attestation_keys is
  'S7-R/D-AC: HMAC-SHA256 keys for the qca/1 calculation attestation. Created EMPTY; key material is provisioned out of band by the Product Owner and never appears in a migration, repository file, fixture, log, report or error message. Exactly one active signing key (uk_attestation_key_active); retiring keys verify only, for at most the 120-second maximum attestation lifetime.';