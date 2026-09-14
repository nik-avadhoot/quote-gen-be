-- S7-R/2a: fix - the two-argument unnest cannot be schema-qualified.
--
-- unnest(a, b) is not an ordinary function call. It is the multi-argument
-- ROWS FROM form, permitted only in FROM and resolved by the parser, so
-- pg_catalog.unnest(p_keys, p_vals) does not resolve at all - it looks for a
-- two-argument unnest that does not exist. The single-argument qualified calls
-- in the validation block above are ordinary calls and are unaffected.
--
-- Leaving it unqualified is safe here for the same reason the NORMALIZE
-- keyword is: pg_catalog is searched implicitly even under search_path = '',
-- and nothing else can define a two-argument unnest into that position.
--
-- Nothing else in the function changes.

create or replace function app_private.fingerprint_serialize(
  p_domain text, p_keys text[], p_vals text[])
returns text language plpgsql immutable set search_path = '' as $fn$
declare v_n int; v_bad text;
begin
  if p_domain is null or p_domain !~ '^[a-z]+/[0-9]+$' then
    raise exception 'fingerprint_serialize: bad domain' using errcode = '22023';
  end if;
  v_n := pg_catalog.array_length(p_keys, 1);
  if v_n is null or v_n = 0 or v_n is distinct from pg_catalog.array_length(p_vals, 1) then
    raise exception 'fingerprint_serialize: key/value arity' using errcode = '22023';
  end if;

  select k into v_bad from pg_catalog.unnest(p_keys) k
   where k is null or k !~ '^[a-z][a-z0-9_.]*$' limit 1;
  if v_bad is not null or exists (select 1 from pg_catalog.unnest(p_keys) k
                                   group by k having pg_catalog.count(*) > 1) then
    raise exception 'fingerprint_serialize: malformed or duplicate key' using errcode = '22023';
  end if;
  if exists (select 1 from pg_catalog.unnest(p_vals) v where v is null) then
    raise exception 'fingerprint_serialize: null encoded value' using errcode = '22023';
  end if;

  return p_domain || E'\n' || (
    select pg_catalog.string_agg(t.k || '=' || t.v, E'\n' order by t.k collate "C")
      from unnest(p_keys, p_vals) as t(k, v));
end $fn$;

revoke all on function app_private.fingerprint_serialize(text, text[], text[])
  from public, anon, authenticated;