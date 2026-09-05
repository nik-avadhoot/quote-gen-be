-- P2-9: give legacy row 2 a governed successor path.
--
-- Product Owner ruling, 2026-09-05 (CDM-05-A): the legacy `plant = 'Group'`
-- value is a DELIBERATE all-plant scope, not dirty data. Row 2 stays a Maker,
-- keeps its existing authentication account and sign-in history, and is
-- migrated through the approved invitation/bootstrap mechanism.
--
-- Accepted Phase 2 representation: EXPLICIT grants of plant_access + make_quote
-- at NAG, PUN and KOL. Automatic access to plants created later is DEFERRED for
-- separate product consideration - a new plant will require an explicit
-- administrator grant. That limitation is proved, not assumed, by MP-8.
--
-- No Checker capability, no administer_users, and no group capability is
-- granted here. bootstrap_app_user() with grant_admin = false creates an ACTIVE
-- identity holding NOTHING; the administrator then applies the plant set
-- through PATCH /admin/users/<id>. That keeps every grant attributable to a
-- real administrator rather than to a migration.
--
-- Written as a guarded query rather than literal values so that no email,
-- display name or uuid appears in the migration set. It is idempotent, and on a
-- fresh zero-to-current replay `profiles` is empty, so it selects nothing and
-- does nothing - which is correct, because there is no legacy identity to
-- carry forward in that world.

insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
select u.email, p.display_name, false
  from public.profiles p
  join auth.users u on u.id = p.id
 where p.role = 'maker'
   and p.active
   and not exists (select 1 from public.app_users a where a.auth_user_id = p.id)
   and not exists (select 1 from app_private.pending_invitations i
                    where lower(i.invite_email) = lower(u.email));