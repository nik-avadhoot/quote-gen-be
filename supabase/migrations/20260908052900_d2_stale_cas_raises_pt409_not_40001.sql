-- D2 - deliberate stale-version (CAS) conflicts must NOT raise SQLSTATE 40001.
-- Full rationale, measurements and the PT409 evidence are in the repository
-- copy of this migration; summarised here:
--   40001 is serialization_failure and the Data API retries it. Our CAS
--   conflict is deterministic, so each retry re-raised it and the request never
--   returned. postgres_logs showed 1,025,464 x 40001 ~10 ms apart from the
--   `authenticator` role, versus 8 x P0002 and 1,368 x 42501 in the same window.
--   PT409 was probed live on this stack (HTTP 409 in 688 ms); the PostgREST 12+
--   `raise sqlstate 'PGRST'` form is rejected here with PGRST121, so the stack
--   is <= 11 and PT409 is the correct non-retryable shape.
-- A genuine 40001 raised by Postgres itself is NOT reinterpreted; only
-- deliberate raises inside our governed operations move.

do $mig$
declare
  r record; v_def text; v_new text; v_fns int := 0; v_sites int := 0;
begin
  for r in
    select p.oid, n.nspname, p.proname,
           (length(p.prosrc) - length(replace(p.prosrc, 'errcode = ''40001''', '')))
             / length('errcode = ''40001''') as sites
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app_private' and p.prosrc like '%errcode = ''40001''%'
     order by p.proname
  loop
    v_def := pg_get_functiondef(r.oid);
    v_new := replace(v_def, 'errcode = ''40001''', 'errcode = ''PT409''');
    if v_new = v_def then
      raise exception 'D2: expected a deliberate 40001 CAS raise in %.%, found none',
        r.nspname, r.proname;
    end if;
    execute v_new;
    v_fns := v_fns + 1; v_sites := v_sites + r.sites;
  end loop;
  if v_fns <> 11 or v_sites <> 12 then
    raise exception 'D2: expected 11 governed operations / 12 raise sites, rewrote % / %',
      v_fns, v_sites;
  end if;
  raise notice 'D2: rewrote % governed operations (% raise sites) to PT409', v_fns, v_sites;
end
$mig$;

do $mig$
declare
  r record; v_def text; v_new text; v_fns int := 0;
begin
  for r in
    select p.oid, n.nspname, p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'tests' and p.prosrc like '%40001%'
     order by p.proname
  loop
    v_def := pg_get_functiondef(r.oid);
    -- every occurrence, not only the compared literal: three suites also name
    -- the code in the assertion's own description text.
    v_new := replace(v_def, '40001', 'PT409');
    if v_new = v_def then
      raise exception 'D2: expected a 40001 expectation in %.%, found none',
        r.nspname, r.proname;
    end if;
    execute v_new;
    v_fns := v_fns + 1;
  end loop;
  if v_fns <> 4 then
    raise exception 'D2: expected 4 pgTAP suites asserting 40001, rewrote %', v_fns;
  end if;
  raise notice 'D2: corrected % pgTAP suites to expect PT409', v_fns;
end
$mig$;

do $mig$
declare v_left int; v_pt int;
begin
  select count(*) into v_left
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app_private','tests') and p.prosrc like '%40001%';
  if v_left <> 0 then
    raise exception 'D2: % function(s) still reference 40001', v_left;
  end if;

  select count(*) into v_pt
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app_private','tests') and p.prosrc like '%PT409%';
  if v_pt <> 15 then
    raise exception 'D2: expected 15 functions referencing PT409, found %', v_pt;
  end if;

  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app_private' and p.prosrc like '%PT409%'
       and (has_function_privilege('anon', p.oid, 'EXECUTE')
         or has_function_privilege('service_role', p.oid, 'EXECUTE')
         or not has_function_privilege('authenticated', p.oid, 'EXECUTE'))
  ) then
    raise exception 'D2: a rewritten governed operation has the wrong EXECUTE posture';
  end if;

  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'tests' and p.prosrc like '%PT409%'
       and (has_function_privilege('anon', p.oid, 'EXECUTE')
         or has_function_privilege('authenticated', p.oid, 'EXECUTE')
         or has_function_privilege('service_role', p.oid, 'EXECUTE'))
  ) then
    raise exception 'D2: a rewritten tests suite became executable by an app role';
  end if;

  raise notice 'D2 verified: 0 remaining 40001 sites, 15 functions on PT409, ACLs intact';
end
$mig$;