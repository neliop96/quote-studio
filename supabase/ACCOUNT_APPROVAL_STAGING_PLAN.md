# Account approval hardening: future STAGING procedure

This plan is documentation only. No Supabase project has been contacted, and no SQL in this repository has been executed remotely.

## What the local migration does

`migrations/20261102010000_account_approval_hardening.sql` is one transaction so the approval registry, restrictive table policies, privilege changes, and RPC guards take effect together. It:

- Keeps explicit approvals in `quote_studio_account_private.account_approvals`, separate from `public.profiles.role`; absent and revoked approvals deny access.
- Keeps the approval audit table and registry inaccessible for direct application-role reads and writes.
- Adds a restrictive `authenticated` policy to each of the 20 business tables. Restrictive policies are ANDed with existing permissive policies, so the existing role-specific workflows remain in place only for approved accounts.
- Removes anonymous table privileges and removes `TRUNCATE`, `REFERENCES`, `TRIGGER`, and PostgreSQL 17 `MAINTAIN` privileges from application roles. It preserves existing authenticated business-table DML grants and service-role access.
- Removes anonymous function/sequence privileges and prevents new public functions from inheriting `authenticated` execution by default; future application RPCs must be explicitly granted.
- Retains own-profile reads and `full_name` updates while removing direct application-role writes to profile roles. It requires the already-installed profile-role guard.
- Adds approval, revocation, and approval-list RPCs. Self-approval is prohibited; only an owner can approve or revoke an owner/admin; the last approved owner cannot be revoked.
- Replaces `public.is_admin()` with an approved-account-aware check that returns false, rather than throwing, for pending users.
- Adds the approval check to each reviewed authenticated-callable application `SECURITY DEFINER` function, including SQL and PL/pgSQL bodies. Trigger-returning functions and Supabase-managed schemas are excluded. The migration has an explicit 27-function review manifest and fails if the installed callable-function set differs or a target uses an unsupported language. `quote_studio_business_date()` is reviewed and guarded separately: authenticated callers require approval, while the verified Edge Function's service-role call and trusted postgres maintenance remain supported.
- Does not seed approvals from profile roles. It does not change signup, invitations, MFA, password recovery, quotation-email delivery, or workflow data.

## User-callable SECURITY DEFINER review

The migration checks that the authenticated-callable application function set exactly matches this review manifest before replacing any function body. The inserted check is an entry guard; it does not replace existing role, row-ownership, validation, locking, or workflow checks.

| Function group | Existing authorization / data dependency reviewed | Change |
|---|---|---|
| `is_admin()` | Reads the caller's `profiles.role`; used by policies and other RPCs. | Special replacement requires explicit approval and still recognizes both `owner` and `admin`; returns false for pending users. |
| `admin_delete_quote`, `set_reorder_level`, `set_stock_movement_archived` | Administrative quotation/inventory actions; depend on admin role and application row constraints. | Existing admin checks and validation remain after the approval guard. |
| `record_stock_movement` | Allows owner/admin/manager inventory writes and delegates atomic stock arithmetic to a private, non-callable helper. | Role check and private helper remain; approval guard is added before either runs. |
| `inventory_movement_actor_names` | Returns display names for inventory actors and is used by the authenticated inventory UI. | Caller approval is checked before profile/movement reads. |
| `get_estimate_number_settings`, `save_estimate_number_settings`, `generate_estimate_number` | Read configuration, permit admin-only changes, or atomically reserve a serial using a row lock. | Existing role checks and serial lock remain; all require approval. |
| `submit_shift_report` | Submits only the caller's own draft, validates task/product content, and uses the private stock movement helper. | Ownership, validation, and stock workflow remain; approval is checked first. |
| `get_shift_alert_settings`, `save_shift_alert_settings`, `get_my_shift_alerts`, `mark_shift_alert_read` | Read alert settings, admin-update recipient roles, or limit alert retrieval/read receipts to the caller's role. | Existing role and recipient checks remain; all require approval. The trigger-only alert creator is excluded and remains reachable only through its trigger. |
| `get_shift_schedule_settings`, `get_shift_schedule_admin_data`, `get_shift_schedule`, `get_scheduled_shift_at` | Read settings, admin history, caller/assigned schedules, or schedule-at-time results; use private calendar/DST helpers. | Existing owner/admin and caller-assignment rules remain; approval is checked before reads. Private schedule helpers are not callable by authenticated users and are unchanged. |
| `set_shift_schedule_time_zone`, `materialize_shift_schedule`, `set_employee_default_shift`, `set_shift_instance_assignment`, `create_custom_shift` | Admin-only scheduling writes with timezone validation, overlap checks, audit history, and private helper calls. | Existing admin checks, validation, and helper dependencies remain; approval is checked before writes. |
| `create_estimate_revision`, `set_estimate_decision`, `sync_estimate_statuses` | Revision creation and customer decisions enforce estimate ownership/admin checks; status sync binds Sent transitions to email logs and validity dates. | Existing estimate/version/email conditions remain; approval is checked before each operation. |
| `manage_profile` | Admin/owner-only profile updates with self-role, privileged-role, and last-owner protections; the profile role trigger is a second guard. | Existing profile authorization and role invariants remain; approval is checked before management. |
| `quote_studio_business_date()` | Read-only date helper used by estimate triggers and the server-side email function. The Edge Function checks its caller before creating/using the service-role client. | Authenticated callers must be approved; service-role and trusted postgres callers retain the required utility behavior. |

Trigger-only `profile_role_write_guard`, `create_shift_alerts_for_submitted_report`, estimate guards/history recorders, and private inventory/schedule helpers are not in the authenticated-callable manifest and are not rewritten. Their internal/trigger execution is preserved. The migration fails rather than silently accepting a new or missing user-callable `SECURITY DEFINER` function.

The migration also requires the installed `save_estimate_number_settings` and `save_shift_alert_settings` bodies to use `public.is_admin()`. That verified prerequisite preserves the intended owner/admin access; it does not silently retain an admin-only comparison against `profiles.role`.

## Required review before a future STAGING change

1. Re-run the read-only STAGING inventory and compare all 21 public tables and every authenticated-callable application `SECURITY DEFINER` function with the migration preconditions and implementation. Review all new functions and exact grants.
2. Independently confirm the bootstrap account's identity with the business owner, confirm it is the intended Auth user, confirm its email is verified, and confirm its profile role is `owner`. Do not infer identity or approval from a profile role alone.
3. Normally back up the STAGING schema and record its current RLS policies, effective table privileges, function signatures/owners/EXECUTE grants, profile-role guard, and current owner UUIDs. The operator has explicitly waived this backup for the disposable STAGING test described below.
4. Confirm the application Auth setting still disables public signup and that administrator invitations create the expected Auth user and profile.
5. Normally test the complete migration against a disposable local Supabase database with the same schema/migrations first. The operator has explicitly accepted proceeding without local PostgreSQL integration tests for this disposable STAGING test; this is a validation waiver, not a passing test result.

## STAGING deployment package (requires separate deployment approval)

**Target:** `bzejwackkozoqqrxfnrz` only. Verify this project reference in the Dashboard before every step. Never select or access LIVE. The repository has no standard migration ledger; do not use `supabase db push` or infer migration state from filenames.

The operator confirms the application is not in production, both environments are development environments, and STAGING is disposable. The operator explicitly accepts loss/rebuild of STAGING data, deployment without a backup, and direct STAGING testing without local PostgreSQL integration tests. These waivers do not relax any migration precondition, approval guard, owner identity/confirmation requirement, bootstrap requirement, or post-deployment check. The reported STAGING preflight run returned 19 PASS checks; run the latest preflight again immediately before migration.

### Exact SQL Editor execution order

1. **Target and maintenance.** In Supabase Dashboard, confirm the active project is `bzejwackkozoqqrxfnrz`. Do not open or select LIVE (`fssyblwhkqfarpbjujsb`). Keep Quote Studio unavailable during migration and validation. Independently verify the owner identity and UUID; confirm the same Auth user has a confirmed email and an existing `owner` profile.
2. **Latest preflight.** Open [account-approval-staging-preflight.sql](./account-approval-staging-preflight.sql), replace its owner UUID placeholder in the SQL Editor with the verified STAGING UUID, and run it read-only as `postgres`. Confirm every check passes, especially exact function identities, all 21 table checks, privileges/ownership, profile guard, and owner readiness. **STOP on any FAIL, SQL error, unexpected/missing identity, or if the target reference is uncertain.**
3. **Run the full migration.** Open [20261102010000_account_approval_hardening.sql](./migrations/20261102010000_account_approval_hardening.sql), verify it is the complete current file and the SQL Editor still targets STAGING, then run the entire script once as `postgres`. Do not select or execute fragments. **STOP on any error or if the editor does not confirm successful completion/commit.** Its explicit transaction rolls back on pre-commit failure; prior broad access then remains, so keep maintenance enabled.
4. **Immediately bootstrap the verified owner.** In the same STAGING SQL Editor, as a direct `postgres` session, execute this exact statement after replacing both placeholders. Use a real durable ticket/reference; do not put email, passwords, or other personal data in the reason:

   ```sql
   SELECT quote_studio_account_private.bootstrap_verified_owner(
     'REPLACE_WITH_VERIFIED_STAGING_OWNER_AUTH_UUID'::uuid,
     'Change reference REPLACE_WITH_TICKET; owner identity independently verified'
   );
   ```

   The function is created in the migration and callable only by `postgres`; its body also requires `session_user = 'postgres'`. It rejects an unconfirmed/missing owner, a profile not already marked `owner`, invalid reason (12–500 characters), or an already approved owner. **STOP on any error; do not use client/admin approval, change profile roles, or proceed to app testing.**
5. **Post-deployment checks.** Run [account-approval-staging-post-deploy-check.sql](./account-approval-staging-post-deploy-check.sql) as `postgres`, replacing the owner UUID and an existing unapproved STAGING test-account UUID. Confirm every catalog and simulated-owner/pending-account check passes. The simulated claim/role changes end in `ROLLBACK`. **STOP on any FAIL, SQL error, or missing test fixture.**
6. **Application testing.** Verify actual owner sign-in and business-data access. Have the verified owner approve intended accounts one at a time. Verify pending-account denial and revocation, invitations, password recovery, quotation email, inventory, estimates, and scheduling. **Keep maintenance enabled until every check passes.** Then record the migration checksum, backup and local-integration-test waivers, ticket reference, bootstrap audit verification, and results.

### Failure recovery

- **Migration fails before commit:** transaction rollback should leave the prior schema/policies in place. Keep maintenance enabled because the prior broad access remains; save the error, do not run fragments, and stop for review before any retry.
- **Migration commits but bootstrap fails:** the restrictive gates remain and users are blocked. Keep maintenance enabled. As `postgres`, check whether an active approved owner exists without sharing identifiers. If none exists and the verified owner still meets all bootstrap requirements, retry the exact bootstrap statement once. If an owner is already approved, the owner cannot be re-bootstrapped; stop and inspect before proceeding. If the function is unavailable or prerequisites fail, obtain a separately reviewed postgres-only recovery procedure.
- **Post-deployment check fails:** keep the app unavailable. Diagnose and use a separately reviewed forward-fix. Never directly edit the registry/audit tables, drop approval objects, remove restrictive policies, or restore broad grants.
- **Committed migration cannot be repaired and no backup exists:** treat STAGING as disposable. Keep it offline and, under a separately approved procedure, rebuild/reset only the verified STAGING project/schema, then reapply the approved baseline and migrations. Reconfirm the STAGING project reference before every destructive action. Never reset or access LIVE.

## Real local database tests

Use only a disposable local Supabase instance on `127.0.0.1:54322` with the `postgres` database role. Create four local Auth fixtures with `.test` email addresses and profiles for: owner, admin, approved employee, and pending employee. Apply the ordinary local application schema and this migration, then bootstrap the local fixture owner. The runner rejects non-loopback URLs, other ports, databases, and users; it never falls back to a remote project.

PowerShell example (set a local-only URL/password and fixture UUIDs in the current shell first):

```powershell
$env:LOCAL_SUPABASE_DB_URL = "postgresql://postgres:LOCAL_PASSWORD@127.0.0.1:54322/postgres"
$env:LOCAL_TEST_APPROVED_OWNER_ID = "LOCAL-OWNER-UUID"
$env:LOCAL_TEST_APPROVED_ADMIN_ID = "LOCAL-ADMIN-UUID"
$env:LOCAL_TEST_APPROVED_EMPLOYEE_ID = "LOCAL-EMPLOYEE-UUID"
$env:LOCAL_TEST_PENDING_USER_ID = "LOCAL-PENDING-UUID"
node --test tests\account-approval.integration.test.cjs
```

The SQL test runs in a transaction and rolls back its fixture approvals, product sentinel, approval actions, revocation, and audit entries. All four fixture Auth emails must end in `.test`. With no local database URL the test is reported as skipped, not passed.

## Rollback and recovery

- A failed migration transaction rolls back atomically. Do not manually apply fragments.
- For an application-code rollback, keep the database approval gates, privilege revocations, and RPC guards in place. A frontend rollback must not restore access based on a profile role.
- Do not drop the private registry, remove restrictive policies, restore anonymous privileges, or restore broad authenticated RPC behavior as an emergency rollback.
- If an owner is unexpectedly blocked, connect using a verified postgres session and use the postgres-only bootstrap/recovery function after independent identity verification. Do not assume another admin exists.
- If a database defect requires reverting the enforcement, stop application access and prepare a separately reviewed forward-fix or a narrowly scoped recovery migration. Any rollback must retain account approval checks and must be tested against the same local PostgreSQL integration suite first.

## Current execution status

The migration and tests are local repository changes only. No remote SQL, project settings, secrets, database, deployment, commit, or push has been performed. Local PostgreSQL integration execution remains blocked when `psql`/local Supabase is unavailable.
