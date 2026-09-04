-- P2-5: cover the last uncovered foreign key.
-- app_private.pending_invitations.consumed_by references app_users with ON DELETE
-- RESTRICT, so without an index that check is a sequential scan. Same standard
-- applied to every other FK in the programme.
create index ix_invite_consumed_by on app_private.pending_invitations (consumed_by);