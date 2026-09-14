-- S7-R/2: the value encoders and the shared line serializer.
--
-- THIS IS THE HALF OF THE BYTE CONTRACT THAT TOUCHES NO TABLE. It is therefore
-- IMMUTABLE and SECURITY INVOKER: it answers "what do these values serialize
-- to", which is a pure function of its arguments and needs no privilege at all.
-- The gatherer that reads tables is a separate, DEFINER function (S7-R/3).
--
-- WHY THE ENCODERS ARE SEPARATE FUNCTIONS. Numeric scale is the single easiest
-- way for two callers to disagree: 5.000::numeric(7,3)::text is '5.000' while
-- 5::numeric::text is '5' - same number, different bytes, different hash. Every
-- value therefore goes through one of these five, and no call site is permitted
-- to cast to text itself. One place to get it right, and one place to gate.
--
-- normalize(v, NFC) IS DELIBERATELY UNQUALIFIED. The Unicode form is a bare
-- keyword in the special NORMALIZE syntax and does not parse through a schema
-- qualification. pg_catalog is implicitly searched even under search_path = '',
-- so this resolves to the builtin and to nothing else.
--
-- SORTING IS BY KEY, ON PARALLEL ARRAYS - NOT BY THE JOINED LINE. Sorting the
-- assembled "key=value" strings would be *almost* equivalent and wrong in one
-- case: '.' (0x2E) sorts below '=' (0x3D), so a key that is a prefix of another
-- with a dot after it would order the two lines the other way round. Passing
-- keys and values separately removes that trap rather than relying on the field
-- list never containing such a pair.
--
-- COLLATE "C" IS LOAD-BEARING. A locale collation orders differently between
-- databases and can change under an ICU upgrade, which would silently re-stale
-- every row in the database on a deploy that changed nothing.

create or replace function app_private.fp_text(p_value text)
returns text language sql immutable set search_path = '' as $$
  select case when p_value is null then '\N'
              else replace(replace(replace(
                     normalize(p_value, NFC),
                     '\', '\\'), E'\n', '\n'), E'\r', '\r')
         end
$$;

create or replace function app_private.fp_num(p_value numeric)
returns text language sql immutable set search_path = '' as $$
  select case when p_value is null then '\N'
              else pg_catalog.trim_scale(p_value)::text end
$$;

create or replace function app_private.fp_int(p_value bigint)
returns text language sql immutable set search_path = '' as $$
  select case when p_value is null then '\N' else p_value::text end
$$;

create or replace function app_private.fp_bool(p_value boolean)
returns text language sql immutable set search_path = '' as $$
  select case when p_value is null then '\N' when p_value then 't' else 'f' end
$$;

create or replace function app_private.fp_date(p_value date)
returns text language sql immutable set search_path = '' as $$
  select case when p_value is null then '\N'
              else pg_catalog.to_char(p_value, 'YYYY-MM-DD') end
$$;

-- payload := domain || LF || line || LF || … || line      (no trailing LF)
-- line    := key || '=' || encoded_value
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

  -- Every key is emitted, so a malformed or duplicated key must fail loudly
  -- here rather than produce a payload that hashes plausibly.
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
      from pg_catalog.unnest(p_keys, p_vals) as t(k, v));
end $fn$;

create or replace function app_private.fingerprint_hex(p_payload text)
returns text language sql immutable set search_path = '' as $$
  select pg_catalog.encode(
           pg_catalog.sha256(pg_catalog.convert_to(p_payload, 'UTF8')), 'hex')
$$;

revoke all on function app_private.fp_text(text)   from public, anon, authenticated;
revoke all on function app_private.fp_num(numeric) from public, anon, authenticated;
revoke all on function app_private.fp_int(bigint)  from public, anon, authenticated;
revoke all on function app_private.fp_bool(boolean) from public, anon, authenticated;
revoke all on function app_private.fp_date(date)   from public, anon, authenticated;
revoke all on function app_private.fingerprint_serialize(text, text[], text[])
  from public, anon, authenticated;
revoke all on function app_private.fingerprint_hex(text) from public, anon, authenticated;