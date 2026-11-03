# Profile and role security proposal

Local review only. The migration `20261025234000_protect_profile_role_management.sql`
is proposed for isolated staging after the current function-permission migration.
It has not been executed and changes no profile rows. Do not apply it to production.

## Proposed enforcement

- Allowed role labels are `owner`, `admin`, `manager`, `supervisor`, `user`,
  `viewer`, and legacy `employee`. Existing values outside this set stop the
  migration for review; no data is rewritten.
- `owner` and `admin` share current administrator capabilities. Only an owner
  may create, promote, demote, or modify another owner/admin profile. There is
  no application profile-deletion RPC; privileged Auth-user deletion is blocked
  and requires a separately approved trusted maintenance procedure. Users cannot
  change their own role, including owners. The last owner cannot be demoted
  through `manage_profile`.
- Authenticated direct writes to `profiles` cannot INSERT or DELETE rows and can
  UPDATE only `full_name` for their own profile. The `id`, `role`, and `created_at`
  columns are not writable by authenticated clients. Profile creation and role
  changes go through `manage_profile`, executable only by `authenticated`, with
  authorization in the SECURITY DEFINER function and a second check in a row
  trigger. There is deliberately no `delete_profile()` RPC.
- `service_role` loses profile INSERT/UPDATE/DELETE/TRUNCATE table privileges.
  This is necessary because `TRUNCATE` bypasses row triggers. It also ensures
  profile protection does not depend on RLS, which service_role bypasses.
- The own-profile UPDATE policy is limited to `id = auth.uid()`; administrators
  cannot use direct table updates to rename other profiles. They may do so through
  `manage_profile` for nonprivileged targets. The trigger denies ordinary-admin
  changes to owner/admin profiles, including safe-field changes. A restrictive
  own-row policy prevents additional permissive UPDATE policies from widening
  this row boundary.
- The SECURITY DEFINER trigger does not infer trust from `auth.uid() IS NULL`,
  `current_user` (which becomes the function owner), or service_role. User
  mutations require a JWT role of exactly `authenticated` plus a matching
  profile. Trusted maintenance requires the actual database
  `session_user = 'postgres'`. That path bypasses role/owner authorization and
  must be reserved for controlled maintenance; it still prevents changing a
  profile's `id`. All service-role and other null-identity profile mutations are
  rejected. Creating an Auth user does not create a profile; an authenticated
  owner must create it using `manage_profile`.
- Inside these postgres-owned SECURITY DEFINER functions, `current_user` is
  `postgres`; `session_user` remains the login role of the original database
  connection. A Supabase API JWT can select the API role (`authenticated` or
  `service_role`) but cannot change `session_user` to `postgres`. The SQL Editor
  bootstrap therefore requires verifying both values; do not infer trust from
  `current_user` inside the trigger.
- Supabase Auth account deletion and cascading deletion of `public.profiles`
  remain unsupported pending isolated synthetic-account testing. The Auth Admin
  API's database session identity and cascade behavior are not established by
  these local files. The trigger currently fails closed, so deletion that reaches
  the profile row should fail atomically rather than orphan Auth/profile state.
  Do not work around this with service_role profile DML. Review the Auth database
  role, owner handoff, and all profile foreign-key references before designing
  deletion support; no cascade delete of quotes/reports is introduced.

## Role compatibility

- `is_admin()` now recognizes `owner` and `admin`. Existing RLS policies that use
  it therefore grant the same product, quote, customer, reorder, and profile-read
  capabilities to owners as admins. The profile-management policy is narrowed;
  sensitive writes use the guarded RPCs.
- Explicit admin checks in quote deletion, estimate settings, movement archival,
  shared-project deletion, quote defaults, and shift-alert settings are updated
  to use owner/admin semantics.
- SECURITY DEFINER behavior review: `is_admin()` adds owner to its existing
  admin result; `admin_delete_quote()` preserves its authentication, null-ID,
  delete, and not-found checks; `set_stock_movement_archived()` preserves its
  admin check, required archive flag, and audit-field updates; and
  `save_estimate_number_settings()` preserves its prefix/width validation and
  returned settings. `save_shift_alert_settings()` keeps its role validation and
  update behavior but accepts owner/admin as the authorized actor. The
  `get_shift_alert_settings()` payload and `create_shift_alerts_for_submitted_report()`
  workflow are unchanged; owner/admin are both omitted from recipient roles, and
  the trigger uses `is_admin()` for the previously admin-only exception. The
  existing `set_reorder_level()` and other `is_admin()` callers gain owner
  compatibility without body changes.
- `owner` and `admin` are excluded from handoff-recipient roles. Manager,
  supervisor, user, viewer, and employee remain eligible when present in profiles.
- Existing inventory permissions remain: owner/admin/manager may change stock;
  owner/admin retain admin-only reorder/archive controls.
- Existing shift submission permissions remain: owner, admin, manager, supervisor,
  user, and legacy employee may submit their own reports. Viewer cannot submit.
- Quote-default reads remain available to every supported role: owner, admin,
  manager, supervisor, user, viewer, and legacy employee. Only owner/admin can
  write quote defaults; the migration changes the SELECT policy only.
- The frontend uses a shared owner/admin check for existing admin controls. It
  does not currently provide profile create/change/delete controls; the new RPCs
  therefore have no in-app management UI yet.

## Trusted bootstrap and synthetic test plan

The migration creates no owner account. For isolated staging only, create at
least two synthetic Auth users through the staging Auth dashboard's supported
flow. Verify the SQL editor session reports both `current_user = 'postgres'` and
`session_user = 'postgres'`. In a transaction, insert a profile for one synthetic
Auth UUID with role `owner`; the FK requires the Auth user to exist, while the
trusted postgres trigger path permits this initial bootstrap. Commit only after
confirming the inserted UUID and role. Sign in as that synthetic owner and use
`manage_profile` to add synthetic admin, manager, supervisor, user, viewer, and
legacy employee profiles. Do not use the service-role API to create the first
owner, store service credentials in the frontend, or reuse production identities.

Bootstrap SQL template (replace the placeholder with the UUID of the synthetic
Auth user created in this isolated staging project):

```sql
SELECT current_user, session_user;
BEGIN;
INSERT INTO public.profiles (id, full_name, role)
VALUES ('<synthetic-auth-user-uuid>'::uuid, 'Staging Owner', 'owner');
SELECT id, full_name, role
FROM public.profiles
WHERE id = '<synthetic-auth-user-uuid>'::uuid;
-- Review the result, then issue COMMIT; otherwise issue ROLLBACK.
```

The trusted postgres path does not enforce the last-owner invariant. The bootstrap
and any later postgres maintenance must independently preserve at least one
synthetic owner and verify the affected Auth UUID before committing.

After separate staging approval, test at minimum:

1. As a regular user, attempt direct self INSERT, direct role UPDATE, and
   `INSERT ... ON CONFLICT DO UPDATE` with role changes. Each must fail by ACL or
   trigger. Confirm self `full_name` UPDATE succeeds and changing `id`, `role`,
   or `created_at` fails.
2. Separately as `user`, `viewer`, `manager`, `supervisor`, and legacy `employee`,
   call `manage_profile`, modify another profile, and attempt direct profile
   INSERT/DELETE. Management must fail; safe own-name update remains allowed.
   No profile-delete RPC should be exposed.
3. As admin, create and update nonprivileged profiles; attempt to create,
   promote, demote, rename, or delete an owner/admin. All privileged-target
   operations must fail. Confirm admin self-name update succeeds but self-role
   change fails.
4. As owner, create/change another privileged profile and manage ordinary
  profiles. Attempt self-role change, self-delete, and demotion of the final
  owner; all must fail. Confirm there is no profile-delete RPC.
5. As anon, attempt INSERT/UPDATE/DELETE and `manage_profile`; all must fail. As
  service_role with and without a subject claim, attempt profile INSERT/UPDATE/
  DELETE/TRUNCATE and `manage_profile`; all must fail. Verify Auth-user deletion that
  would cascade into profiles fails atomically, without deleting either side.
  Verify trusted postgres maintenance separately in a disposable project.
6. Verify every role against existing workflows: admin-only controls for owner
  and admin; inventory changes for owner/admin/manager; own shift submission for
  the existing allowed roles; viewer denied submission; and all seven supported
  roles can read quote defaults while only owner/admin can write them.
7. Attempt simultaneous demotion of multiple owners. The advisory lock and
  last-owner check must leave at least one owner.
8. Check migration rollback behavior in a disposable database and confirm no
   profile rows or Auth users were inserted, updated, or deleted by migration
   application itself.

## Read-only staging verification SQL

These queries inspect catalog and profile state only. Do not run them until
staging access is separately approved.

```sql
-- Existing role labels and row counts.
SELECT role, count(*) AS profile_count
FROM public.profiles
GROUP BY role
ORDER BY role;

-- Direct authenticated/anonymous table and column privileges.
SELECT
  has_table_privilege('anon', 'public.profiles', 'INSERT') AS anon_insert,
  has_table_privilege('anon', 'public.profiles', 'UPDATE') AS anon_table_update,
  has_table_privilege('anon', 'public.profiles', 'DELETE') AS anon_delete,
  has_table_privilege('anon', 'public.profiles', 'TRUNCATE') AS anon_truncate,
  has_table_privilege('authenticated', 'public.profiles', 'INSERT') AS auth_insert,
  has_table_privilege('authenticated', 'public.profiles', 'UPDATE') AS auth_table_update,
  has_table_privilege('authenticated', 'public.profiles', 'DELETE') AS auth_delete,
  has_table_privilege('authenticated', 'public.profiles', 'TRUNCATE') AS auth_truncate,
  has_table_privilege('service_role', 'public.profiles', 'INSERT') AS service_insert,
  has_table_privilege('service_role', 'public.profiles', 'UPDATE') AS service_update,
  has_table_privilege('service_role', 'public.profiles', 'DELETE') AS service_delete,
  has_table_privilege('service_role', 'public.profiles', 'TRUNCATE') AS service_truncate,
  has_column_privilege('authenticated', 'public.profiles', 'full_name', 'UPDATE') AS auth_update_name,
  has_column_privilege('authenticated', 'public.profiles', 'role', 'UPDATE') AS auth_update_role,
  has_column_privilege('authenticated', 'public.profiles', 'id', 'UPDATE') AS auth_update_id,
  has_column_privilege('authenticated', 'public.profiles', 'created_at', 'UPDATE') AS auth_update_created_at;

-- Profile policies after migration.
SELECT policyname, cmd, roles, qual, with_check
FROM pg_catalog.pg_policies
WHERE schemaname = 'public' AND tablename = 'profiles'
ORDER BY policyname;

-- Quote-default policies: SELECT should cover all supported roles; writes stay admin-only.
SELECT policyname, cmd, roles, qual, with_check
FROM pg_catalog.pg_policies
WHERE schemaname = 'public' AND tablename = 'quote_settings'
ORDER BY policyname;

-- Effective RPC/trigger execution privileges.
SELECT
  routine.oid::regprocedure AS routine_name,
  has_function_privilege('anon', routine.oid, 'EXECUTE') AS anon_execute,
  has_function_privilege('authenticated', routine.oid, 'EXECUTE') AS auth_execute,
  has_function_privilege('service_role', routine.oid, 'EXECUTE') AS service_role_execute
FROM pg_catalog.pg_proc AS routine
JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
WHERE namespace.nspname = 'public'
  AND routine.proname IN ('is_admin', 'manage_profile', 'profile_role_write_guard')
ORDER BY routine.oid::regprocedure::text;

SELECT pg_catalog.to_regprocedure('public.delete_profile(uuid)') IS NULL
  AS profile_delete_rpc_absent;

-- Trigger enabled state and SECURITY DEFINER/search_path settings.
SELECT
  tg.tgname,
  tg.tgenabled,
  pg_catalog.pg_get_triggerdef(tg.oid) AS trigger_definition,
  proc.prosecdef AS security_definer,
  proc.proconfig AS function_settings
FROM pg_catalog.pg_trigger AS tg
JOIN pg_catalog.pg_proc AS proc ON proc.oid = tg.tgfoid
WHERE tg.tgrelid = 'public.profiles'::regclass
  AND NOT tg.tgisinternal;

-- Check whether any non-internal trigger provisions profiles from auth.users.
SELECT tg.tgname, pg_catalog.pg_get_triggerdef(tg.oid) AS trigger_definition
FROM pg_catalog.pg_trigger AS tg
WHERE tg.tgrelid = 'auth.users'::regclass
  AND NOT tg.tgisinternal;

-- Policies that branch on profile roles.
SELECT schemaname, tablename, policyname, cmd, roles, qual, with_check
FROM pg_catalog.pg_policies
WHERE schemaname = 'public'
  AND concat_ws(' ', qual, with_check) ~* '(owner|admin|manager|supervisor|user|viewer|employee)'
ORDER BY tablename, policyname;

-- Function bodies with explicit role checks, for compatibility review.
SELECT routine.oid::regprocedure AS routine_name, routine.prosrc
FROM pg_catalog.pg_proc AS routine
JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
WHERE namespace.nspname = 'public'
  AND routine.prosrc ~* 'role.*(owner|admin|manager|supervisor|user|viewer|employee)'
ORDER BY routine.oid::regprocedure::text;

-- Confirm at least one owner remains.
SELECT count(*) AS owner_count
FROM public.profiles
WHERE role = 'owner';
```

authenticated-only; the trigger helper is not directly executable by any API
Expected: authenticated has only `full_name` column UPDATE and no table-level
INSERT/UPDATE/DELETE/TRUNCATE; anon and service_role have no profile writes or
TRUNCATE; the new management RPC is authenticated-only; and the trigger helper
is not directly executable by an API role. `delete_profile()` is absent, and at
least one owner remains. The own-profile SELECT policy must remain present, and
the UPDATE policy must use `id = auth.uid()` without admin-wide access.
Quote-default SELECT includes all seven supported labels; its INSERT and UPDATE
policies remain limited to `is_admin()`. Role-sensitive policy/function results
should match the compatibility notes above.