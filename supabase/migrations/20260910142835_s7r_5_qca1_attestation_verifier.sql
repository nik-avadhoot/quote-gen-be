-- S7-R/5: the qca/1 attestation byte contract and its verifier.
--
-- WHAT THIS EXISTS FOR. S7-R admits twenty engine scalars the database cannot
-- recompute, because the engine is JavaScript and there must be exactly one of
-- it. Admission therefore rests on proof that the bytes came from the trusted
-- executor. A public function granted to authenticated is a PostgREST endpoint
-- - POST /rest/v1/rpc/<name> - reachable by anyone who can log in, with any
-- arguments. Without this verifier that endpoint would be a self-service
-- price-setting facility whose output Send freezes immutably.
--
-- FRAMING IS LENGTH-PREFIXED, NOT DELIMITED. frame(b) = int8send(len) || b, an
-- 8-byte big-endian length from a builtin. Because every field carries its own
-- length, no value can forge a field boundary and no two distinct tuples can
-- collapse to one mac_input - the failure a delimiter-joined string invites.
--
-- DOMAIN SEPARATION IS THE FIRST FRAMED FIELD, not an outer prefix. 'qca/1' is
-- framed like any other field, so an input built under qcf/1 or qpf/1 cannot
-- collide with an attestation input even were every other field identical.
--
-- ONLY THREE FIELDS ARE READ FROM THE ATTESTATION - keyid, computed_at and
-- expires_at - because the database cannot derive them. Every other field is
-- rebuilt from the caller's own identity and durable state. The attestation is
-- therefore never a source of truth about anything the database can determine
-- for itself, and there is exactly ONE verification failure rather than
-- per-field diagnostics, which would be a forgery oracle.
--
-- THE KEY IS NEVER RETURNED, LOGGED OR NAMED IN AN ERROR. qca_key hands the
-- bytes only to the verifier in this same schema; every refusal below carries
-- fixed wording that mentions neither key nor MAC.
--
-- A RETIRING KEY IS BOUNDED BY THE MAXIMUM ATTESTATION LIFETIME. 120 seconds
-- after rotation it verifies nothing, so an overlap cannot quietly become a
-- second permanent signing key.

create or replace function app_private.qca_frame(p_bytes bytea)
returns bytea language sql immutable set search_path = '' as $$
  select pg_catalog.int8send(pg_catalog.octet_length(p_bytes)::bigint) || p_bytes
$$;

create or replace function app_private.qca_ts(p_value timestamptz)
returns text language sql immutable set search_path = '' as $$
  select pg_catalog.to_char(p_value at time zone 'UTC',
                            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
$$;

create or replace function app_private.qca_mac_input(
  p_keyid text, p_auth_sub text, p_app_user_id bigint,
  p_batch_id bigint, p_batch_row_id bigint, p_content_version integer,
  p_release_id bigint, p_engine_version text,
  p_calc_fp text, p_pres_fp text, p_results_sha text,
  p_computed_at timestamptz, p_expires_at timestamptz)
returns bytea language sql immutable set search_path = '' as $$
  select app_private.qca_frame(pg_catalog.convert_to('qca/1','UTF8'))
      || app_private.qca_frame(pg_catalog.convert_to(p_keyid,'UTF8'))
      || app_private.qca_frame(pg_catalog.convert_to(p_auth_sub,'UTF8'))
      || app_private.qca_frame(pg_catalog.convert_to(p_app_user_id::text,'UTF8'))
      || app_private.qca_frame(pg_catalog.convert_to(p_batch_id::text,'UTF8'))
      || app_private.qca_frame(pg_catalog.convert_to(p_batch_row_id::text,'UTF8'))
      || app_private.qca_frame(pg_catalog.convert_to(p_content_version::text,'UTF8'))
      || app_private.qca_frame(pg_catalog.convert_to(p_release_id::text,'UTF8'))
      || app_private.qca_frame(pg_catalog.convert_to(normalize(p_engine_version, NFC),'UTF8'))
      || app_private.qca_frame(pg_catalog.convert_to(p_calc_fp,'UTF8'))
      || app_private.qca_frame(pg_catalog.convert_to(p_pres_fp,'UTF8'))
      || app_private.qca_frame(pg_catalog.convert_to(p_results_sha,'UTF8'))
      || app_private.qca_frame(pg_catalog.convert_to(app_private.qca_ts(p_computed_at),'UTF8'))
      || app_private.qca_frame(pg_catalog.convert_to(app_private.qca_ts(p_expires_at),'UTF8'))
$$;

-- envelope := "qca/1" ~ keyid ~ computed_at ~ expires_at ~ mac_hex
-- '~' is used because '.' and ':' both occur inside the timestamps.
create or replace function app_private.qca_parse(
  p_attestation text,
  out o_keyid text, out o_computed_at timestamptz,
  out o_expires_at timestamptz, out o_mac text)
returns record language plpgsql stable set search_path = '' as $fn$
declare p text[]; c_ts constant text := '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$';
begin
  if p_attestation is null then return; end if;
  p := pg_catalog.string_to_array(p_attestation, '~');
  if pg_catalog.array_length(p,1) is distinct from 5 then return; end if;
  if p[1] is distinct from 'qca/1' then return; end if;
  if p[2] !~ '^[a-z0-9][a-z0-9_-]{0,62}$' then return; end if;
  if p[3] !~ c_ts or p[4] !~ c_ts then return; end if;
  if p[5] !~ '^[0-9a-f]{64}$' then return; end if;
  o_keyid := p[2];
  o_computed_at := p[3]::timestamptz;
  o_expires_at  := p[4]::timestamptz;
  o_mac := p[5];
end $fn$;

-- Returns the key ONLY when it may still verify. Never returned to any caller
-- outside app_private; never logged; never placed in an error message.
create or replace function app_private.qca_key(p_keyid text)
returns bytea language sql stable security definer set search_path = '' as $$
  select k.key from app_private.attestation_keys k
   where k.keyid = p_keyid
     and ( k.status = 'active'
        or ( k.status = 'retiring'
             and k.retiring_at > pg_catalog.now() - interval '120 seconds' ) )
$$;

revoke all on function app_private.qca_frame(bytea)         from public, anon, authenticated;
revoke all on function app_private.qca_ts(timestamptz)      from public, anon, authenticated;
revoke all on function app_private.qca_mac_input(text,text,bigint,bigint,bigint,integer,bigint,text,text,text,text,timestamptz,timestamptz)
  from public, anon, authenticated;
revoke all on function app_private.qca_parse(text)          from public, anon, authenticated;
revoke all on function app_private.qca_key(text)            from public, anon, authenticated;