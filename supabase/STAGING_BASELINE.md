# Quote Studio staging baseline

Local preparation only. No database SQL has been executed. Execution requires
separate approval and a verified target of bzejwackkozoqqrxfnrz. Never apply this
baseline to the existing production database.

## Provenance and scope

20261023155000_original_application_baseline.sql was reconstructed from the
15 successful, approved, catalog-only production metadata queries on 2026-10-25.
Function bodies were reviewed for credentials/sensitive literals; none were found.
No application/authentication records, current sequence values, or credentials
were copied. This is a schema reconstruction, not a complete database dump.

The baseline creates 8 tables, 67 columns, 30 constraints, 6 functions, 19 policies,
the email-log identity sequence, and 3 standalone indexes. Primary/unique
constraints create their backing indexes. It preserves audited owners, types,
defaults, nullability, FK actions, function settings, and ACLs. The six existing
migrations supply the other 6 tables, 33 columns, 26 constraints, 9 public functions,
7 policies, and handoff trigger; the quote project_name column is counted there.
The security patch then adds its private helper and replaces 2 public functions.

Do not create project_name or the six later tables in the baseline. Do not
separately CREATE the email-log sequence: GENERATED ALWAYS AS IDENTITY creates
the named sequence and its ownership dependency. quotation_email_log.quote_id
had an index but no FK in the audit; none has been invented. No custom public
enum/domain was returned. profiles.role remains nonblank text with default
employee, not a new role-management design.

## Prerequisites

- Fresh Supabase staging project, initialized auth.users and auth.uid(), UUID
  generation, public schema, and standard postgres/anon/authenticated/service_role.
- PostgreSQL 17 or newer for the audited MAINTAIN grants. The exact production
  version was not queried; this is a syntax compatibility requirement.
- Migration executor is postgres with CREATE privileges and ability to set owners
  and postgres default ACLs. Apply all seven files using the same executor.
- Public application schema empty; the baseline intentionally fails on existing
  relations or non-extension routines. Private inventory schema must be absent.
- Keep staging isolated from real users and integrations while broad grants remain.
- Configure the test frontend separately for staging URL/publishable key and
  staging-only Auth redirect URLs. Current js/core.js targets a different project.
  No frontend configuration was changed by this work.

Managed auth schema/function definitions, platform roles/memberships, database
ACLs, public schema ownership, and supabase_admin default ACLs are platform
prerequisites, not recreated. The migration restores application grants and
audited postgres defaults in public; it does not change global default ACLs.
Unusual pre-existing global grants require review during staging validation.

## Exact migration order

1. 20261023155000_original_application_baseline.sql
2. 20261023160000_add_project_name_to_quotes.sql
3. 20261023161000_estimate_number_settings.sql
4. 20261023162000_add_shared_projects.sql
5. 20261023163000_add_shift_reports.sql
6. 20261023164000_add_shift_handoff_alerts.sql
7. 20261025150000_secure_inventory_workflows.sql

Apply once in order with a migration runner that stops on errors and records each
version. Do not rerun completed CREATE TABLE migrations or insert guessed history.
Baseline and security patch contain their own transaction boundaries; verify the
runner supports these. Intermediate versions retain the old stock writer, so
do not allow application traffic until the entire chain succeeds.

## Synthetic setup, only after approved migrations

These are instructions, not an automatic seed migration. No setup has been run.

1. Confirm the project reference in the staging Dashboard. Use staging Auth's
   supported Create user flow to create two fictional accounts, e.g.
   qs-admin@example.test and qs-employee@example.test. Use unique generated test
   passwords kept outside the repository. Disable real outbound mail or use a
   controlled test mailbox; do not invite production users or copy auth rows.
2. Copy only the newly created staging UUIDs. As the staging administrator, create
   profiles with those exact IDs, fictional full names, and roles admin and
   employee. There is no audited auth.users provisioning trigger; create profiles
   explicitly. The first admin cannot bootstrap itself through client RLS.
3. Sign in as the synthetic admin. Create product part STAGING-001, category Test,
   subcategory Synthetic, description Synthetic test product, supplier Test supplier,
   price 10.00, active true. Record its staging-generated ID.
4. Create customer Synthetic Customer, contact Test Contact,
   email customer@example.test, phone 000-000-0000, address Test address,
   notes Synthetic staging fixture. Do not use real contact details.
5. As admin, save quote_settings id 1 using synthetic defaults markup 20,
   labor_rate 75, tax_rate 8.625, labor_hours 0. These match audited schema
   defaults, not production settings records.
6. The numbering migration initializes EST / width 3 / next serial 1 when quotes
   are empty. Do not import a production serial. The handoff migration initializes
   empty recipient_roles; as synthetic admin, select employee through the settings
   RPC after that synthetic profile exists.
7. As the synthetic admin, call record_stock_movement through the authenticated
   app: receive 100 units of STAGING-001 at unit cost 10, reference STAGING-SEED,
   notes Synthetic opening inventory. This creates inventory and an attributed
   stock_movements row together. Set reorder level 5 through set_reorder_level.
   Do not directly seed inventory balances without corresponding movements.
8. As employee, create one synthetic quotation and shared project. Create a draft
   shift report with one task, 2 units of that product, and fictional handoff notes.
   Verify draft saving changes no stock; submission changes 100 to 98 exactly once.
9. Keep quotation_email_log empty unless testing a separately reviewed mock email
   integration. Never copy delivery IDs or send messages to real recipients.

## Missing definitions and limits

No missing definition was discovered among the captured original tables,
constraints, indexes, six baseline functions, and policies. The only audited
non-internal trigger is provided by the handoff migration. There is no verified
profile-creation trigger to recreate and no inventory trigger to invent.

The metadata does not establish an external profile-provisioning process, Edge
Function source/deployment, email integration configuration, Auth project settings,
or external secrets. Email sending remains outside database-baseline readiness.
Do not retrieve/copy production secrets. Views/materialized views/foreign tables
were absent from the relation ACL results. Publications, extension inventory,
function dependency catalogs, table storage options, and database-version parity
were not covered by the 15 queries; do not claim full project parity.

After approval, follow INVENTORY_SECURITY_VALIDATION.md. Proposed hardening is
documented separately in STAGING_PRIVILEGE_REVIEW.md and is not applied here.

## Local validation performed

Compared the written baseline with the retained query results: all 67 column
names/types and captured defaults, 30 complete constraint definitions, 6 complete
function definitions (only line endings and SQL statement terminators normalized),
and 19 policy names/expressions matched. Checked standalone index selection,
identity options, key-before-FK ordering, RLS declarations, and explicit grant
construction against captured ACLs. No later table or project_name is created
here. Git whitespace validation passed. Existing six migration files and frontend
files were not changed by this preparation.

No PostgreSQL parser/server, psql, Docker, or Node was available on PATH for
runtime validation. No SQL was executed locally or remotely. The baseline is
prepared for an approved isolated staging test, not certified as runtime-tested.
