const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..");
const migration = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20261102010000_account_approval_hardening.sql"),
  "utf8",
);
const preflight = fs.readFileSync(
  path.join(root, "supabase", "account-approval-staging-preflight.sql"),
  "utf8",
);
const rollbackCheck = fs.readFileSync(
  path.join(root, "supabase", "account-approval-staging-rollback-check.sql"),
  "utf8",
);
const authSource = fs.readFileSync(path.join(root, "js", "auth.js"), "utf8");
const coreSource = fs.readFileSync(path.join(root, "js", "core.js"), "utf8");
const catalogSource = fs.readFileSync(path.join(root, "js", "catalog.js"), "utf8");
const htmlSource = fs.readFileSync(path.join(root, "index.html"), "utf8");

test("approval registry is private, separate from profile roles, and has no direct app grants", () => {
  assert.match(migration, /CREATE SCHEMA quote_studio_account_private/);
  assert.match(migration, /CREATE TABLE quote_studio_account_private\.account_approvals/);
  assert.match(migration, /CREATE TABLE quote_studio_account_private\.account_approval_audit/);
  assert.match(migration, /REVOKE ALL ON TABLE[\s\S]*FROM PUBLIC, anon, authenticated, service_role/);
  assert.match(migration, /approved_at timestamptz/);
  assert.match(migration, /revoked_at timestamptz/);
  assert.doesNotMatch(migration, /INSERT INTO quote_studio_account_private\.account_approvals[\s\S]{0,400}SELECT[\s\S]{0,100}profiles\.role/);
});

test("all 20 business tables receive a restrictive approval gate and anonymous privileges are removed", () => {
  const expectedTables = [
    "products", "customers", "quote_settings", "quotes", "inventory",
    "stock_movements", "quotation_email_log", "estimate_number_settings",
    "projects", "shift_reports", "shift_alert_settings", "shift_alerts",
    "shift_alert_reads", "shift_schedule_settings",
    "shift_schedule_time_zone_history", "shift_schedule_templates",
    "shift_schedule_instances", "employee_shift_default_history",
    "shift_assignment_override_history", "quote_status_history",
  ];
  for (const table of expectedTables) assert.ok(migration.includes(`'${table}'`), `Missing ${table}`);
  assert.match(migration, /AS RESTRICTIVE FOR ALL TO authenticated/);
  assert.match(migration, /WITH CHECK \(quote_studio_account_private\.is_account_approved\(\)\)/);
  assert.match(migration, /REVOKE ALL PRIVILEGES ON TABLE public\.%I FROM PUBLIC, anon/);
  assert.match(migration, /REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public\.%I/);
  assert.match(migration, /ALTER DEFAULT PRIVILEGES[\s\S]*REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated/);
});

test("user-callable SECURITY DEFINER functions use an exact 28-signature manifest", () => {
  const manifest = migration.match(
    /expected_identities constant text\[\] := ARRAY\[([\s\S]*?)\];/,
  );
  assert.ok(manifest);
  const identities = [...manifest[1].matchAll(/'([^']+)'/g)].map((match) => match[1]);
  const expectedIdentities = [
    "public.admin_delete_quote(uuid)",
    "public.create_custom_shift(text, timestamp without time zone, timestamp without time zone)",
    "public.create_estimate_revision(uuid)",
    "public.generate_estimate_number()",
    "public.get_estimate_number_settings()",
    "public.get_my_shift_alerts()",
    "public.get_scheduled_shift_at(timestamp with time zone)",
    "public.get_shift_alert_settings()",
    "public.get_shift_schedule(date, date, boolean)",
    "public.get_shift_schedule_admin_data()",
    "public.get_shift_schedule_settings()",
    "public.inventory_movement_actor_names()",
    "public.is_admin()",
    "public.manage_profile(uuid, text, text)",
    "public.mark_shift_alert_read(uuid)",
    "public.materialize_shift_schedule(date, date)",
    "public.quote_studio_business_date()",
    "public.record_stock_movement(uuid, text, integer, numeric, text, text)",
    "public.save_estimate_number_settings(text, integer)",
    "public.save_shift_alert_settings(text[])",
    "public.set_employee_default_shift(uuid, text)",
    "public.set_estimate_decision(uuid, text)",
    "public.set_reorder_level(uuid, integer)",
    "public.set_shift_instance_assignment(uuid, uuid, boolean)",
    "public.set_shift_schedule_time_zone(text)",
    "public.set_stock_movement_archived(uuid, boolean)",
    "public.submit_shift_report(uuid)",
    "public.sync_estimate_statuses()",
  ];
  assert.deepEqual(identities, expectedIdentities);
  assert.equal(new Set(identities).size, 28);
  assert.match(migration, /AS routine_identity/);
  assert.match(migration, /format\(\s*'%I\.%I\(%s\)'[\s\S]*routine\.proargtypes::oid\[\][\s\S]*pg_catalog\.format_type\(argument\.type_oid, NULL\)/);
  assert.doesNotMatch(migration, /pg_get_function_identity_arguments/);
  assert.match(migration, /IF observed_identities IS DISTINCT FROM expected_identities THEN/);
  assert.match(migration, /routine\.oid = 'public\.is_admin\(\)'::regprocedure[\s\S]*routine\.prosecdef[\s\S]*routine\.prorettype = 'boolean'::regtype[\s\S]*has_function_privilege\('authenticated', routine\.oid, 'EXECUTE'\)/);

  const matchesManifest = (expected, observed) =>
    JSON.stringify([...expected].sort()) === JSON.stringify([...observed].sort());
  assert.equal(matchesManifest(identities, identities), true);
  assert.equal(
    matchesManifest(identities, identities.map((identity) =>
      identity === "public.manage_profile(uuid, text, text)"
        ? "public.manage_profile(uuid, text, jsonb)"
        : identity)),
    false,
    "a parameter-type mismatch must fail the exact identity comparison",
  );
  assert.equal(matchesManifest(identities, identities.slice(1)), false, "a missing function must fail");
  assert.equal(
    matchesManifest(identities, [...identities, "public.manage_profile(uuid, text, jsonb)"]),
    false,
    "an unexpected overload must fail",
  );

  const targetQuery = migration.slice(
    migration.indexOf("CREATE TEMP TABLE account_approval_secdef_targets"),
    migration.indexOf("DO $function_preflight$"),
  );
  assert.match(targetQuery, /routine\.prokind = 'f'/);
  assert.match(targetQuery, /routine\.prorettype <> 'trigger'::regtype/);
  assert.match(targetQuery, /routine\.oid <> 'public\.is_admin\(\)'::regprocedure/);
  assert.match(migration, /SELECT format\([\s\S]*WHERE routine\.oid = 'public\.is_admin\(\)'::regprocedure/);
  assert.match(migration, /routine\.prosecdef/);
  assert.match(migration, /has_function_privilege\('authenticated', routine\.oid, 'EXECUTE'\)/);
  assert.match(migration, /PERFORM quote_studio_account_private\.require_account_approved\(\)/);
  assert.match(migration, /SELECT quote_studio_account_private\.require_account_approved\(\) AS allowed/);
  assert.match(migration, /session_user <> 'postgres'[\s\S]*auth\.role\(\), ''\) <> 'service_role'/);
  assert.match(migration, /SECURITY DEFINER/);
  assert.match(migration, /SET search_path = ''/);
});

test("function hardening postcondition uses an unambiguous PL/pgSQL table alias", () => {
  const functionHardening = migration.match(
    /DO \$function_hardening\$([\s\S]*?)\$function_hardening\$;/,
  );
  assert.ok(functionHardening);
  assert.match(functionHardening[1], /DECLARE\s+target record;/);
  assert.match(
    functionHardening[1],
    /FROM pg_temp\.account_approval_secdef_targets AS secdef_target\s+JOIN pg_proc AS routine ON routine\.oid = secdef_target\.routine_oid/,
  );
  assert.match(
    functionHardening[1],
    /array_agg\(secdef_target\.routine_identity ORDER BY secdef_target\.routine_identity\)/,
  );
  assert.doesNotMatch(
    functionHardening[1],
    /FROM pg_temp\.account_approval_secdef_targets AS target\b/,
    "the alias must not shadow the PL/pgSQL target record variable",
  );
});

test("STAGING preflight is read-only and mirrors the exact migration function manifest", () => {
  const migrationManifest = migration.match(
    /expected_identities constant text\[\] := ARRAY\[([\s\S]*?)\];/,
  );
  const preflightManifest = preflight.match(
    /expected_functions\(function_identity\) AS \([\s\S]*?VALUES([\s\S]*?)\),\s*public_tables AS/,
  );
  assert.ok(migrationManifest);
  assert.ok(preflightManifest);
  const migrationIdentities = [...migrationManifest[1].matchAll(/'([^']+)'/g)]
    .map((match) => match[1]);
  const preflightIdentities = [...preflightManifest[1].matchAll(/\('([^']+)'\)/g)]
    .map((match) => match[1]);
  assert.deepEqual(preflightIdentities, migrationIdentities);
  assert.match(preflight, /unnest\(routine\.proargtypes::oid\[\]\)\s+WITH ORDINALITY/);
  assert.match(preflight, /pg_catalog\.format_type\(argument\.type_oid, NULL\)/);
  assert.doesNotMatch(preflight, /pg_get_function_identity_arguments/);
  assert.match(preflight, /argument names and defaults are ignored/);
  const uncommented = preflight.replace(/--.*$/gm, "");
  assert.doesNotMatch(
    uncommented,
    /^\s*(?:CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|TRUNCATE|GRANT|REVOKE|CALL|DO)\b/im,
    "preflight must not contain database-changing SQL commands",
  );
  assert.match(preflight, /'Exact authenticated SECURITY DEFINER function identities'/);
  assert.match(preflight, /'Function manifest diagnostics'/);
  assert.match(preflight, /'Expected public table inventory'/);
  assert.match(preflight, /'Verified owner exists for bootstrap'/);
  assert.match(preflight, /'current_user is postgres'/);
  assert.match(preflight, /'session_user is postgres for bootstrap'/);
  assert.match(preflight, /'Database CREATE privilege'/);
  assert.match(preflight, /'Public schema USAGE privilege'/);
  assert.match(preflight, /'Public schema CREATE privilege'/);
  assert.match(preflight, /'Postgres ownership and default-ACL authority'/);
  assert.match(preflight, /SELECT check_name, result, detail\s+FROM checks/);
});

test("post-deployment verification is read-only and avoids exposing account identifiers", () => {
  const postDeployCheck = fs.readFileSync(
    path.join(root, "supabase", "account-approval-staging-post-deploy-check.sql"),
    "utf8",
  );
  const uncommented = postDeployCheck.replace(/--.*$/gm, "");
  assert.doesNotMatch(
    uncommented,
    /^\s*(?:CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|TRUNCATE|GRANT|REVOKE|CALL|DO)\b/im,
    "post-deployment checks must not modify database objects or rows",
  );
  assert.match(postDeployCheck, /REPLACE_WITH_VERIFIED_STAGING_OWNER_AUTH_UUID/);
  assert.match(postDeployCheck, /REPLACE_WITH_EXISTING_UNAPPROVED_STAGING_AUTH_UUID/);
  assert.match(postDeployCheck, /All 20 restrictive approval policies are installed/);
  assert.match(postDeployCheck, /No effective anonymous table privileges in public/);
  assert.match(postDeployCheck, /All 30 authenticated SECURITY DEFINER RPCs contain approval guards/);
  assert.match(postDeployCheck, /routine\.oid <> to_regprocedure\('public\.is_account_approved\(\)'\)/);
  assert.match(postDeployCheck, /Approved owner can access business data/);
  assert.match(postDeployCheck, /AND EXISTS \(SELECT 1 FROM public\.products\)/);
  assert.match(postDeployCheck, /Unapproved account is denied business access/);
  assert.match(postDeployCheck, /ROLLBACK;/);
});

test("failed migration rollback check is read-only and checks created effects", () => {
  const uncommented = rollbackCheck.replace(/--.*$/gm, "");
  assert.doesNotMatch(
    uncommented,
    /^\s*(?:CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|TRUNCATE|GRANT|REVOKE|CALL|DO)\b/im,
    "rollback verification must not modify database state",
  );
  assert.match(rollbackCheck, /Private approval schema absent/);
  assert.match(rollbackCheck, /Migration-created public RPCs absent/);
  assert.match(rollbackCheck, /Restrictive account policies absent/);
  assert.match(rollbackCheck, /No public routine retains injected approval guard/);
  assert.match(rollbackCheck, /Temporary target table absent in this session/);
  assert.match(rollbackCheck, /transaction rollback is the authority/i);
});

test("approval management prevents self-approval, protects privileged roles, and audits changes", () => {
  assert.match(migration, /p_user_id = actor_id/);
  assert.match(migration, /Only an owner may approve an owner or administrator/);
  assert.match(migration, /Only an owner may revoke an owner or administrator/);
  assert.match(migration, /The last approved owner cannot be revoked/);
  assert.match(migration, /event_type, subject_user_id, actor_user_id, actor_database_role, reason/);
  assert.match(migration, /IF session_user <> 'postgres'/);
});

test("frontend blocks pending sessions and offers explicit admin approval controls", () => {
  const approvalCheck = authSource.indexOf('db.rpc("is_account_approved")');
  const appDisplay = authSource.indexOf('showOnlyAuth("app")', approvalCheck);
  assert.ok(approvalCheck >= 0);
  assert.ok(appDisplay > approvalCheck);
  assert.match(authSource, /showOnlyAuth\("pendingApproval"\)/);
  assert.match(htmlSource, /id="pendingApproval"/);
  assert.match(coreSource, /db\.rpc\("list_account_approvals"\)/);
  assert.match(catalogSource, /data-account-action=/);
  assert.match(authSource, /approve_account_access/);
  assert.match(authSource, /revoke_account_access/);
});
