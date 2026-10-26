# Inventory security preparation

The migration `20261025150000_secure_inventory_workflows.sql` is local only.
It requires the existing audited baseline, profiles, inventory, stock_movements,
products, shift_reports, and handoff-alert migration. The local baseline is now
prepared from the 15 approved metadata queries; no database execution has occurred.
See STAGING_BASELINE.md for provenance, synthetic setup, and limitations, and
STAGING_PRIVILEGE_REVIEW.md for proposed hardening. Do not apply this fresh-schema
baseline to production. Staging execution requires separate approval.

## Exact staging migration order (all pending execution)

1. `20261023155000_original_application_baseline.sql`
2. `20261023160000_add_project_name_to_quotes.sql`
3. `20261023161000_estimate_number_settings.sql`
4. `20261023162000_add_shared_projects.sql`
5. `20261023163000_add_shift_reports.sql`
6. `20261023164000_add_shift_handoff_alerts.sql`
7. `20261025150000_secure_inventory_workflows.sql`

Run once, as postgres, against the verified empty staging project only after
separate approval. Require PostgreSQL 17+ for audited MAINTAIN grants and standard
Supabase auth/roles. Keep traffic disabled until all seven migrations succeed.

## Baseline validation checklist (not yet executed)

- [ ] Confirm the exact approved target `bzejwackkozoqqrxfnrz` directly in the
  staging project configuration.
- [ ] Confirm executor, database version, CREATE privilege, empty app schema,
  auth.users/auth.uid(), UUID generation, and absence of the private schema.
- [ ] Apply all seven migrations; verify migration history and stop on first error.
- [ ] Rebuild a second disposable database from scratch using the same files.
- [ ] Compare resulting metadata: 14 public tables, 100 columns, 56 constraints,
  20 indexes, 1 public identity sequence, 26 policies, 15 public functions,
  1 handoff trigger, plus the private helper introduced by the final patch.
- [ ] Compare column types/defaults/nullability, FK delete actions, UUID defaults,
  unique part/quote numbers, check constraints, and archive fields with audit.
- [ ] Verify quotation_email_log identity is ALWAYS, starts at 1, increments by 1,
  has bigint bounds/cache 1/no cycle, and is owned by its id column; quote_id has
  an index but no invented FK. No email-log records copied.
- [ ] Verify all table RLS enabled/not forced, postgres application ownership,
  routine search_path/security/volatility, and actual ACL/default-ACL inheritance.
  Expected broad privileges are documented risks, not a security-test pass.
- [ ] Confirm no auth.users provisioning trigger; bootstrap synthetic admin and
  employee profiles explicitly following STAGING_BASELINE.md, with no real users.
- [ ] Initialize synthetic settings/products/customer/stock through the documented
  flows; check no settings rows or counters were copied from production.
- [ ] Test admin/employee login, catalog CRUD, customer access, quote snapshots,
  unique numbering/concurrency, shared project permissions, admin quote deletion,
  movement actor names, reorder, archive/restore, and FK failures.
- [ ] Verify employee cannot manage profiles; admin behavior and admin/employee
  quote-default access remain compatible. Missing-profile/anonymous access must
  match each captured policy, not an assumed global profile requirement.
- [ ] Confirm staging frontend isolation before browser tests; no production
  URL/key, live mail integration, production contacts, or copied credentials.
- [ ] Test email-log table/sequence ACLs with synthetic data only if separately
  authorized; outbound email/Edge Function deployment remains outside this step.
- [ ] Complete the inventory test matrix below and review hardening proposals.

## Design

- Role values are exact lowercase labels; existing roles are not changed.
- Manual receive/issue/adjust: owner, admin, manager only.
- Own-report submission: owner, admin, manager, supervisor, user, employee.
- Viewer, missing profiles, unknown roles, and unauthenticated callers are denied.
- Other users' reports cannot be submitted, including by admins. This deliberately
  narrows the old creator-or-admin submission behavior to the approved own-report rule.
- Private stock writer is SECURITY INVOKER, owned by postgres, with client and
  service_role EXECUTE revoked and schema access revoked. Public wrappers run as
  postgres with an empty search_path and explicit authorization. No bypass flag,
  reference value, or session setting selects the privileged path.
- Creation of the private schema intentionally fails if it already exists.
- A catalog-only prerequisite block checks required schemas, tables, used columns,
  function signatures, named roles, postgres execution/ownership, database CREATE
  privilege, and the named enabled AFTER UPDATE row-level alert trigger before DDL.
  It does not certify column types, trigger WHEN/UPDATE filters, function bodies,
  inherited/default grants, or every table permission; verify these in staging.
- The editor stores its creator ID on opening/creating a report and clears it on
  reset. Both submit controls and the click guard use that ID, independently of
  the selected report month. Missing creator information fails closed for saved reports.
- Reorder, archive, existing RLS, user roles, and unrelated admin features are unchanged.
- Existing broad TRUNCATE/TRIGGER/REFERENCES grants and profile role assignment
  remain separate known security issues. This patch does not make Owner assignment safe.

## Required staging tests (synthetic data only; not yet executed)

1. Test direct manual RPC calls for every role, all three movement types, missing
   profile, unknown role, and anonymous callers. Only owner/admin/manager succeed.
2. Attempt direct private-helper execution as authenticated, anon, and service_role;
   verify schema/EXECUTE denial. Check effective ACLs and default grants.
3. Submit each allowed role's own draft; verify exact deductions, actor attribution,
   submission fields, and handoff alerts. Viewer and non-owner attempts must fail
   with no changes to stock, movements, report, or alerts.
4. Try forged references, notes, extra bypass arguments, product IDs and quantities;
   references/notes must not grant authorization, and RPC signatures reject extras.
5. Verify inactive products, null movement type, invalid/negative quantities,
   missing adjustment reasons, invalid receipt costs, and insufficient stock fail.
6. Submit the same report twice and concurrently: deduct once. Run concurrent
   stock operations and verify quantity/cost consistency and no partial writes.
7. Fail a later report item or the handoff trigger; all earlier deductions must
   roll back. Verify received weighted-average cost and zero-stock reset behavior.
8. Test disabled manual controls and direct event invocation in the frontend,
   inventory viewing for all roles, and unchanged admin-only reorder/archive behavior.
9. Verify Viewer cannot submit via a stale frontend; revoke/change a role during
   a session and verify fresh database authorization on subsequent RPC calls.
10. Open another user's draft, change the displayed month until the draft disappears
    from the list, and confirm submission remains disabled and direct click invocation
    is rejected. Repeat with an own draft (still enabled), a new saved draft, reset,
    and missing creator metadata. Database ownership checks remain authoritative.
11. In disposable databases, independently remove each prerequisite, disable or
    misattach the alert trigger, use a non-postgres executor, and pre-create the
    private schema. Verify a clear failure and no partial migration changes.
    Verify trigger WHEN/UPDATE filters still cover draft-to-submitted transitions.

## Local correction validation

Creator-state assignments and guards, prerequisite ordering, role allowlists, and
unchanged stock calculation bodies were inspected locally. PostgreSQL, psql, Node,
and Docker were not available on PATH; no SQL execution or browser/runtime test
was performed. SQL syntax and runtime dependency validation remain incomplete.

## Before deployment

The approved metadata queries recovered inventory constraints, application
triggers, and schema/default ACLs. External dependencies remain unverified.
Review the prepared baseline and obtain separate staging execution approval.
Run database tests above and browser checks. Review the migration and production
execution separately. Deploy database restrictions before frontend changes.
Do not roll back by restoring unrestricted stock writes.
