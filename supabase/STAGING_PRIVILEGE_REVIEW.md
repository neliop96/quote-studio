# Privilege review: proposals only

The TRUNCATE revocation was manually applied in staging using SQL Editor. SQL
Editor execution does not automatically create a Supabase migration history
entry. Verification confirmed all 14 public tables return false for TRUNCATE
privileges for both anon and authenticated. The function-permission migration in
this review is local and proposed only; it has not been executed. No production
configuration changes are authorized by creating the baseline.

## Preserved behavior

- Baseline object ACLs match captured production metadata, including broad anon
  and authenticated SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER/MAINTAIN
  grants on most original tables. quote_settings excludes anon;
  quotation_email_log grants only service_role among client/service roles.
- The email-log identity sequence grants SELECT/UPDATE/USAGE to anon,
  authenticated, and service_role, as audited.
- Audited postgres public default ACLs are recreated so the existing migrations
  inherit the same grants as production. Existing functions revoke PUBLIC in
  several migrations but retain direct anon grants inherited from defaults.
- RLS is enabled, not forced. postgres-owned SECURITY DEFINER routines use an
  empty search_path. service_role has BYPASSRLS as a Supabase platform prerequisite.
- profiles.role remains nonblank text with default employee. is_admin recognizes
  only admin. Profile management remains admin-only, not self-service.
- quote_settings SELECT is limited to admin/employee. Customer INSERT/UPDATE is
  allowed to any authenticated caller by existing policies.
- No new grants to PUBLIC are added for baseline tables/functions/sequences.
  Public schema USAGE matches the audited schema permissions.
- The last existing migration intentionally restricts inventory workflow access.
  That previously authorized patch is the only workflow hardening in this chain.

## Proposed follow-up requiring review and approval

1. Replace broad table ACLs with the exact operations each client needs. The
  staging migration revokes TRUNCATE (not protected by RLS) from anon and
  authenticated; review TRIGGER, REFERENCES, and MAINTAIN separately unless a
  verified requirement exists. Inspect effective inherited grants.
2. Apply the proposed `20261025233000_harden_function_execute_privileges.sql`
  only after approval. It revokes PUBLIC and anon from all 15 application
  functions, preserves authenticated/service_role on the 14 user-callable RPCs,
  and leaves the trigger-only function inaccessible to those roles. `is_admin()`
  retains authenticated EXECUTE for policies that call it.
3. Limit email-log sequence privileges to the integration that writes logs.
4. Review and test `20261025234000_protect_profile_role_management.sql` before
  staging use. Until applied, the baseline admin profile policy still permits
  profile writes by admins; see PROFILE_ROLE_SECURITY_REVIEW.md for the proposed
  owner bootstrap, role compatibility, and synthetic test plan.
5. Decide whether quote_settings readers should include the expanded inventory
   roles. Preserve admin/employee behavior until a role design is approved.
6. Review authenticated customer writes and quote update ownership rules against
   intended business behavior; do not change them silently.
7. Verify later-table ACLs after the full chain. Existing incremental migrations
   grant selected operations without first revoking every inherited privilege.

Staging is suitable only for isolated synthetic validation until these known ACL
risks are accepted or separately hardened. Do not advertise this reconstruction
as a hardened production deployment.

## Function authorization and defaults

The local JavaScript uses authenticated RPCs for estimate settings/numbering and
shift-alert settings/reads. Estimate-number and shift-alert settings writes
check for an exact `admin` profile role inside their SECURITY DEFINER functions;
the UI checks are not the authorization boundary. `get_estimate_number_settings()`
and `get_shift_alert_settings()` require authentication but do not restrict reads
to admins. `generate_estimate_number()` requires a signed-in user, then advances
the shared serial; any authenticated caller can consume a number directly. This
proposal changes ACLs only and does not alter that behavior. Consider a separate
approved business-rule change if serial consumption should require a profile or
an eligible quote creator.

`is_admin()` is referenced by authenticated RLS policies. The proposed ACL keeps
authenticated EXECUTE and removes anon EXECUTE; no local policy targets anon.
The shift-alert read/mark functions require a matching employee profile and role.
The trigger function is invoked by the database trigger, not an application RPC.

The baseline's `ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public`
grants EXECUTE to anon, authenticated, and service_role. A staging-only default
privilege change was reported as already executed, but its exact statement and
resulting catalog state are not recorded in the local files. PostgreSQL's built-in
global function default also grants EXECUTE to PUBLIC. A schema-level REVOKE
cannot cancel that global default.

The proposed function-permission migration changes only the ACLs of the 15
existing application functions. It does not change global or schema-specific
default privileges. Future postgres-created public functions may therefore
continue to inherit anon and/or PUBLIC EXECUTE, depending on the actual staging
default ACL state. The read-only verification query below inspects explicit
default-ACL overrides; absence of an override means built-in/global defaults
still apply as described, not that execution is denied.

Safe options for a separate, reviewed decision:

- Create a dedicated owner role for application functions, use it as the
  function owner, and configure defaults for that role. This isolates application
  defaults from unrelated postgres-created functions and schemas.
- Separately review a global `ALTER DEFAULT PRIVILEGES FOR ROLE postgres
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`, along with any required public-schema
  anon revoke and explicit authenticated/service_role grants. This affects
  postgres-created functions in every schema and must account for the
  already-reported staging-only change and all postgres-owned schemas.

Neither option is included in this migration or assumed applied/recorded in
Supabase migration history.

## Read-only verification SQL

Run only after separately approved staging access; these statements read catalog
metadata and do not change database state.

```sql
-- Effective EXECUTE, including PUBLIC and inherited role grants.
SELECT
  p.oid::regprocedure AS function_name,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
  has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute
FROM pg_catalog.pg_proc AS p
JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
ORDER BY p.oid::regprocedure::text;

-- Effective is_admin access and policies that depend on it.
SELECT has_function_privilege(
  'authenticated', 'public.is_admin()'::regprocedure, 'EXECUTE'
) AS authenticated_can_call_is_admin;

SELECT schemaname, tablename, policyname, roles, qual, with_check
FROM pg_catalog.pg_policies
WHERE coalesce(qual, '') ILIKE '%is_admin%'
   OR coalesce(with_check, '') ILIKE '%is_admin%'
ORDER BY schemaname, tablename, policyname;

-- Explicit postgres global and public-schema default function ACL overrides.
-- This reports overrides only; a missing row leaves built-in/global defaults
-- applicable and does not imply that PUBLIC EXECUTE is absent.
WITH requested_scopes AS (
  SELECT 0::oid AS namespace_oid, 'global'::text AS scope_name
  UNION ALL
  SELECT 'public'::regnamespace::oid, 'public'::text
), function_owners AS (
  SELECT oid, rolname
  FROM pg_catalog.pg_roles
  WHERE rolname = 'postgres'
  UNION
  SELECT DISTINCT role.oid, role.rolname
  FROM pg_catalog.pg_default_acl AS existing
  JOIN pg_catalog.pg_roles AS role ON role.oid = existing.defaclrole
  WHERE existing.defaclobjtype = 'f'
)
SELECT
  function_owners.rolname AS creator_role,
  requested_scopes.scope_name,
  coalesce(
    defaults.defaclacl::text,
    CASE requested_scopes.scope_name
      WHEN 'global' THEN '<no global override; PostgreSQL built-in defaults apply>'
      ELSE '<no schema override; global/built-in defaults apply>'
    END
  ) AS default_acl
FROM requested_scopes
 CROSS JOIN function_owners
LEFT JOIN pg_catalog.pg_default_acl AS defaults
  ON defaults.defaclrole = function_owners.oid
 AND defaults.defaclobjtype = 'f'
 AND defaults.defaclnamespace = requested_scopes.namespace_oid
ORDER BY function_owners.rolname, requested_scopes.namespace_oid;
```

Expected after the proposed migration: all `anon_execute` values are false;
authenticated and service_role are true for the 14 callable RPCs; `is_admin()`
remains executable by authenticated; and the trigger-only function is not
executable by anon, authenticated, or service_role. The migration leaves default
ACLs unchanged. Check role memberships and the global/public default-ACL rows
for postgres and any other function creator roles to assess future functions.
