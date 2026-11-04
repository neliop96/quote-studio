-- Read-only verification after the account-approval migration and owner bootstrap.
-- Replace both UUID placeholders with independently verified STAGING Auth UUIDs.
-- Run the catalog checks as postgres. The final transaction locally impersonates
-- authenticated JWT claims for access checks and rolls back all SET LOCAL state.
-- No account UUIDs, emails, or business rows are returned.

WITH expected_business_tables(table_name) AS (
  VALUES
    ('products'),
    ('customers'),
    ('quote_settings'),
    ('quotes'),
    ('inventory'),
    ('stock_movements'),
    ('quotation_email_log'),
    ('estimate_number_settings'),
    ('projects'),
    ('shift_reports'),
    ('shift_alert_settings'),
    ('shift_alerts'),
    ('shift_alert_reads'),
    ('shift_schedule_settings'),
    ('shift_schedule_time_zone_history'),
    ('shift_schedule_templates'),
    ('shift_schedule_instances'),
    ('employee_shift_default_history'),
    ('shift_assignment_override_history'),
    ('quote_status_history')
),
business_tables AS (
  SELECT
    expected.table_name,
    relation.oid,
    relation.relrowsecurity
  FROM expected_business_tables AS expected
  LEFT JOIN pg_catalog.pg_class AS relation
    ON relation.oid = to_regclass('public.' || expected.table_name)
),
guarded_functions AS (
  SELECT routine.oid, routine.prosrc
  FROM pg_catalog.pg_proc AS routine
  JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
  WHERE namespace.nspname = 'public'
    AND routine.prokind = 'f'
    AND routine.prosecdef
    AND routine.prorettype <> 'trigger'::regtype
    AND routine.oid <> to_regprocedure('public.is_admin()')
    AND routine.oid <> to_regprocedure('public.is_account_approved()')
    AND routine.oid IS DISTINCT FROM to_regprocedure('public.list_account_approval_audit(integer,bigint)')
    AND pg_catalog.has_function_privilege('authenticated', routine.oid, 'EXECUTE')
),
checks AS (
  SELECT
    'At least one active approved owner' AS check_name,
    CASE WHEN EXISTS (
      SELECT 1
      FROM quote_studio_account_private.account_approvals AS approval
      JOIN public.profiles AS profile ON profile.id = approval.user_id
      WHERE profile.role = 'owner' AND approval.revoked_at IS NULL
    ) THEN 'PASS' ELSE 'FAIL' END AS result,
    'Owner approval exists; no account identifiers are returned.' AS detail
  UNION ALL
  SELECT
    'Bootstrap audit recorded',
    CASE WHEN EXISTS (
      SELECT 1
      FROM quote_studio_account_private.account_approval_audit AS audit
      WHERE audit.event_type = 'bootstrap'
    ) THEN 'PASS' ELSE 'FAIL' END,
    'At least one owner bootstrap event is recorded.'
  UNION ALL
  SELECT
    'All 20 business tables have RLS enabled',
    CASE WHEN count(*) = 20 AND count(oid) = 20 AND bool_and(relrowsecurity)
      THEN 'PASS' ELSE 'FAIL' END,
    format('Verified %s expected tables.', count(*))
  FROM business_tables
  UNION ALL
  SELECT
    'All 20 restrictive approval policies are installed',
    CASE WHEN count(*) = 20 AND bool_and(policy_ok)
      THEN 'PASS' ELSE 'FAIL' END,
    format('Verified %s expected restrictive policies.', count(*))
  FROM (
    SELECT
      expected.table_name,
      EXISTS (
        SELECT 1
        FROM pg_catalog.pg_policy AS policy
        WHERE policy.polrelid = to_regclass('public.' || expected.table_name)
          AND policy.polname = 'quote_studio_approved_account_gate'
          AND NOT policy.polpermissive
          AND policy.polcmd = '*'
          AND to_regrole('authenticated') = ANY(policy.polroles)
          AND pg_catalog.pg_get_expr(policy.polqual, policy.polrelid)
            LIKE '%is_account_approved%'
          AND pg_catalog.pg_get_expr(policy.polwithcheck, policy.polrelid)
            LIKE '%is_account_approved%'
      ) AS policy_ok
    FROM expected_business_tables AS expected
  ) AS policy_checks
  UNION ALL
  SELECT
    'No effective anonymous table privileges in public',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    format('Tables with effective anon privileges: %s.', count(*))
  FROM pg_catalog.pg_class AS relation
  JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname = 'public'
    AND relation.relkind IN ('r', 'p')
    AND (
      pg_catalog.has_table_privilege('anon', relation.oid, 'SELECT')
      OR pg_catalog.has_table_privilege('anon', relation.oid, 'INSERT')
      OR pg_catalog.has_table_privilege('anon', relation.oid, 'UPDATE')
      OR pg_catalog.has_table_privilege('anon', relation.oid, 'DELETE')
      OR pg_catalog.has_table_privilege('anon', relation.oid, 'TRUNCATE')
      OR pg_catalog.has_table_privilege('anon', relation.oid, 'REFERENCES')
      OR pg_catalog.has_table_privilege('anon', relation.oid, 'TRIGGER')
      OR pg_catalog.has_table_privilege('anon', relation.oid, 'MAINTAIN')
    )
  UNION ALL
  SELECT
    'All 30 authenticated SECURITY DEFINER RPCs contain approval guards',
    CASE WHEN count(*) = 30 AND bool_and(
      prosrc LIKE '%quote_studio_account_private.require_account_approved()%'
    ) THEN 'PASS' ELSE 'FAIL' END,
    format('Guarded targets found: %s.', count(*))
  FROM guarded_functions
  UNION ALL
  SELECT
    'Owner-only audit RPC has exact identity, guards and privileges',
    CASE WHEN
      (SELECT count(*) FROM pg_catalog.pg_proc AS audit_fn
        JOIN pg_catalog.pg_namespace AS audit_ns ON audit_ns.oid = audit_fn.pronamespace
        WHERE audit_ns.nspname = 'public' AND audit_fn.proname = 'list_account_approval_audit') = 1
      AND EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc AS audit_fn
        WHERE audit_fn.oid = to_regprocedure('public.list_account_approval_audit(integer,bigint)')
          AND audit_fn.prokind = 'f' AND audit_fn.prosecdef
          AND audit_fn.proowner = to_regrole('postgres')
          AND audit_fn.proconfig @> ARRAY['search_path=""']
          AND audit_fn.prosrc LIKE '%quote_studio_account_private.require_account_approved()%'
          AND audit_fn.prosrc LIKE '%caller.role = ''owner''%'
          AND audit_fn.prosrc LIKE '%least(p_limit, 200)%')
      AND pg_catalog.has_function_privilege('authenticated', 'public.list_account_approval_audit(integer,bigint)', 'EXECUTE')
      AND NOT pg_catalog.has_function_privilege('anon', 'public.list_account_approval_audit(integer,bigint)', 'EXECUTE')
      AND NOT pg_catalog.has_function_privilege('service_role', 'public.list_account_approval_audit(integer,bigint)', 'EXECUTE')
      AND NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc AS audit_fn,
          LATERAL aclexplode(coalesce(audit_fn.proacl, acldefault('f', audit_fn.proowner))) AS acl
        WHERE audit_fn.oid = to_regprocedure('public.list_account_approval_audit(integer,bigint)')
          AND acl.grantee = 0)
    THEN 'PASS' ELSE 'FAIL' END,
    'public.list_account_approval_audit(integer,bigint); authenticated only.'
  UNION ALL
  SELECT
    'Audit table is append-only (ENABLE ALWAYS triggers) and not directly granted',
    CASE WHEN (
      SELECT count(*) FROM pg_catalog.pg_trigger AS audit_trigger
      WHERE audit_trigger.tgrelid = to_regclass('quote_studio_account_private.account_approval_audit')
        AND NOT audit_trigger.tgisinternal AND audit_trigger.tgenabled = 'A'
        AND audit_trigger.tgname IN ('account_approval_audit_no_row_change', 'account_approval_audit_no_truncate')
    ) = 2
    AND NOT EXISTS (
      SELECT 1 FROM (VALUES ('anon'), ('authenticated'), ('service_role')) AS app_role(role_name)
      WHERE pg_catalog.has_table_privilege(app_role.role_name,
        'quote_studio_account_private.account_approval_audit',
        'SELECT, INSERT, UPDATE, DELETE, TRUNCATE'))
    THEN 'PASS' ELSE 'FAIL' END,
    'Triggers block UPDATE, DELETE and TRUNCATE; privileged owners can still bypass them.'
  UNION ALL
  SELECT
    'is_admin requires approved owner or admin',
    CASE WHEN EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc AS routine
      WHERE routine.oid = to_regprocedure('public.is_admin()')
        AND routine.prosecdef
        AND routine.prosrc LIKE '%quote_studio_account_private.is_account_approved()%'
        AND routine.prosrc LIKE '%owner%'
        AND routine.prosrc LIKE '%admin%'
    ) THEN 'PASS' ELSE 'FAIL' END,
    'is_admin() is SECURITY DEFINER and its body checks account approval and privileged roles.'
  UNION ALL
  SELECT
    'Profile role cannot be directly updated',
    CASE WHEN NOT pg_catalog.has_column_privilege(
      'authenticated', 'public.profiles', 'role', 'UPDATE'
    ) THEN 'PASS' ELSE 'FAIL' END,
    'Authenticated users do not have direct UPDATE privilege on profiles.role.'
  UNION ALL
  SELECT
    'Approval registry and audit have no direct app grants',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    format('Direct app table privileges found: %s.', count(*))
  FROM (
    SELECT role_row.role_name, relation_row.relation_name, privilege_row.privilege_name
    FROM (VALUES ('anon'), ('authenticated'), ('service_role')) AS role_row(role_name)
    CROSS JOIN (VALUES
      ('quote_studio_account_private.account_approvals'),
      ('quote_studio_account_private.account_approval_audit')
    ) AS relation_row(relation_name)
    CROSS JOIN (VALUES
      ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'),
      ('REFERENCES'), ('TRIGGER'), ('MAINTAIN')
    ) AS privilege_row(privilege_name)
    WHERE has_table_privilege(
      role_row.role_name,
      relation_row.relation_name,
      privilege_row.privilege_name
    )
  ) AS direct_app_privileges
)
SELECT check_name, result, detail
FROM checks
ORDER BY check_name;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT (
  set_config(
    'request.jwt.claim.sub',
    'REPLACE_WITH_VERIFIED_STAGING_OWNER_AUTH_UUID',
    true
  ) IS NOT NULL
  AND set_config('request.jwt.claim.role', 'authenticated', true) IS NOT NULL
  AND set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', 'REPLACE_WITH_VERIFIED_STAGING_OWNER_AUTH_UUID',
      'role', 'authenticated'
    )::text,
    true
  ) IS NOT NULL
) AS owner_claims_set;
SELECT
  'Approved owner can access business data' AS check_name,
  CASE WHEN public.is_account_approved()
    AND public.is_admin()
    AND EXISTS (SELECT 1 FROM public.products)
    THEN 'PASS' ELSE 'FAIL' END AS result,
  'Owner approval, admin authorization, and visibility of at least one product row through authenticated RLS are confirmed.' AS detail;

RESET ROLE;
SELECT (
  set_config(
    'request.jwt.claim.sub',
    'REPLACE_WITH_EXISTING_UNAPPROVED_STAGING_AUTH_UUID',
    true
  ) IS NOT NULL
  AND set_config('request.jwt.claim.role', 'authenticated', true) IS NOT NULL
  AND set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', 'REPLACE_WITH_EXISTING_UNAPPROVED_STAGING_AUTH_UUID',
      'role', 'authenticated'
    )::text,
    true
  ) IS NOT NULL
) AS pending_claims_set;
SET LOCAL ROLE authenticated;
SELECT
  'Unapproved account is denied business access' AS check_name,
  CASE WHEN NOT public.is_account_approved()
    AND NOT public.is_admin()
    AND (SELECT count(*) FROM public.products) = 0
    THEN 'PASS' ELSE 'FAIL' END AS result,
  'Approval and admin checks are false; the restrictive RLS gate returns no product rows.' AS detail;
RESET ROLE;
ROLLBACK;
