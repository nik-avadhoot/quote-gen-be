-- P2-6: the P-5 guard found public.set_updated_at() executable by anon.
--
-- Same class as the S0b finding: it returns the pseudo-type `trigger`, so it cannot
-- be invoked directly and the grant is inert - but an inert grant on a function that
-- runs during DML is exactly the kind of thing that stops being inert after an
-- unrelated edit. Trigger dispatch does not consult EXECUTE, so revoking cannot
-- affect profiles_set_updated_at.
--
-- Left in place rather than dropped: the function is still bound to the legacy
-- trigger, and dropping it belongs to the S3(c) packet, not here.

revoke execute on function public.set_updated_at() from public;
revoke execute on function public.set_updated_at() from anon;
revoke execute on function public.set_updated_at() from authenticated;
revoke execute on function public.set_updated_at() from service_role;