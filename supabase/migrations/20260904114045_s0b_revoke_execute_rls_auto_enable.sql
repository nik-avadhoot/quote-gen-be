-- S0b: remove inert but misleading EXECUTE grants on public.rls_auto_enable().
-- The function returns the pseudo-type event_trigger and cannot be invoked directly;
-- these grants are therefore unexercisable. Event-trigger dispatch does not consult
-- client EXECUTE privileges, so the ensure_rls event trigger is unaffected.
-- Function body, ownership, the event trigger, and postgres EXECUTE are all unchanged.
revoke execute on function public.rls_auto_enable() from public;
revoke execute on function public.rls_auto_enable() from anon;
revoke execute on function public.rls_auto_enable() from authenticated;
revoke execute on function public.rls_auto_enable() from service_role;