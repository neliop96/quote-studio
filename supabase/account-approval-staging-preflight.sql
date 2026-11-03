-- Read-only preflight for the account-approval migration.
-- Replace the owner UUID below with the independently verified STAGING Auth UUID.
-- Results contain PASS/FAIL and non-sensitive diagnostics; no email or UUID is returned.
-- This does not apply the migration or modify database objects.

WITH
parameters AS (
  SELECT '7b49f0ba-40e4-4ff1-8dec-eee9f8b012c7'::uuid AS owner_id
),
expected_tables(table_name) AS (
  VALUES
    ('customers'),
    ('employee_shift_default_history'),
    ('estimate_number_settings'),
    ('inventory'),
    ('products'),
    ('profiles'),
    ('projects'),
    ('quotation_email_log'),
    ('quote_settings'),
    ('quote_status_history'),
    ('quotes'),
    ('shift_alert_reads'),
    ('shift_alert_settings'),
    ('shift_alerts'),
    ('shift_assignment_override_history'),
    ('shift_reports'),
    ('shift_schedule_instances'),
    ('shift_schedule_settings'),
    ('shift_schedule_templates'),
    ('shift_schedule_time_zone_history'),
    ('stock_movements')
),
expected_functions(function_identity) AS (
  VALUES
    ('public.admin_delete_quote(uuid)'),
    ('public.create_custom_shift(text, timestamp without time zone, timestamp without time zone)'),
    ('public.create_estimate_revision(uuid)'),
    ('public.generate_estimate_number()'),
    ('public.get_estimate_number_settings()'),
    ('public.get_my_shift_alerts()'),
    ('public.get_scheduled_shift_at(timestamp with time zone)'),
    ('public.get_shift_alert_settings()'),
    ('public.get_shift_schedule(date, date, boolean)'),
    ('public.get_shift_schedule_admin_data()'),
    ('public.get_shift_schedule_settings()'),
    ('public.inventory_movement_actor_names()'),
    ('public.is_admin()'),
    ('public.manage_profile(uuid, text, text)'),
    ('public.mark_shift_alert_read(uuid)'),
    ('public.materialize_shift_schedule(date, date)'),
    ('public.quote_studio_business_date()'),
    ('public.record_stock_movement(uuid, text, integer, numeric, text, text)'),
    ('public.save_estimate_number_settings(text, integer)'),
    ('public.save_shift_alert_settings(text[])'),
    ('public.set_employee_default_shift(uuid, text)'),
    ('public.set_estimate_decision(uuid, text)'),
    ('public.set_reorder_level(uuid, integer)'),
    ('public.set_shift_instance_assignment(uuid, uuid, boolean)'),
    ('public.set_shift_schedule_time_zone(text)'),
    ('public.set_stock_movement_archived(uuid, boolean)'),
    ('public.submit_shift_report(uuid)'),
    ('public.sync_estimate_statuses()')
),
public_tables AS (
  SELECT
    relation.relname AS table_name,
    relation.relrowsecurity AS rls_enabled,
    relation.relowner
  FROM pg_catalog.pg_class AS relation
  JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname = 'public'
    AND relation.relkind IN ('r', 'p')
),
public_functions AS (
  SELECT
    routine.oid,
    routine.prokind,
    routine.prosecdef,
    routine.prorettype,
    routine.proowner,
    format(
      '%I.%I(%s)',
      namespace.nspname,
      routine.proname,
      coalesce((
        SELECT string_agg(
          pg_catalog.format_type(argument.type_oid, NULL),
          ', ' ORDER BY argument.ordinality
        )
        FROM unnest(routine.proargtypes::oid[])
          WITH ORDINALITY AS argument(type_oid, ordinality)
      ), '')
    ) AS identity
  FROM pg_catalog.pg_proc AS routine
  JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
  WHERE namespace.nspname = 'public'
),
function_targets AS (
  SELECT identity
  FROM public_functions
  WHERE prokind = 'f'
    AND prosecdef
    AND prorettype <> 'trigger'::regtype
    AND oid <> to_regprocedure('public.is_admin()')
    AND pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')
),
observed_functions AS (
  SELECT identity FROM function_targets
  UNION ALL
  SELECT identity
  FROM public_functions
  WHERE oid = to_regprocedure('public.is_admin()')
    AND prokind = 'f'
    AND prosecdef
    AND prorettype = 'boolean'::regtype
    AND pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')
),
function_differences AS (
  SELECT
    (SELECT array_agg(expected.function_identity ORDER BY expected.function_identity COLLATE "C")
     FROM expected_functions AS expected
     WHERE NOT EXISTS (
       SELECT 1 FROM observed_functions AS observed
       WHERE observed.identity = expected.function_identity
     )) AS missing_identities,
    (SELECT array_agg(observed.identity ORDER BY observed.identity COLLATE "C")
     FROM observed_functions AS observed
     WHERE NOT EXISTS (
       SELECT 1 FROM expected_functions AS expected
       WHERE expected.function_identity = observed.identity
     )) AS unexpected_identities
),
function_comparison AS (
  SELECT
    (SELECT count(*) FROM observed_functions) AS observed_count,
    (SELECT array_agg(function_identity ORDER BY function_identity COLLATE "C") FROM expected_functions)
      AS expected_identities,
    (SELECT array_agg(identity ORDER BY identity COLLATE "C") FROM observed_functions)
      AS observed_identities,
    coalesce(cardinality(function_differences.missing_identities), 0) AS missing_count,
    coalesce(cardinality(function_differences.unexpected_identities), 0) AS unexpected_count,
    function_differences.missing_identities,
    function_differences.unexpected_identities
  FROM function_differences
),
table_comparison AS (
  SELECT
    (SELECT count(*) FROM public_tables) AS observed_count,
    (
      SELECT count(*)
      FROM expected_tables AS expected
      WHERE NOT EXISTS (
        SELECT 1 FROM public_tables AS observed
        WHERE observed.table_name = expected.table_name
      )
    ) AS missing_count,
    (
      SELECT count(*)
      FROM public_tables AS observed
      WHERE NOT EXISTS (
        SELECT 1 FROM expected_tables AS expected
        WHERE expected.table_name = observed.table_name
      )
    ) AS unexpected_count
),
owner_readiness AS (
  SELECT EXISTS (
    SELECT 1
    FROM parameters
    JOIN public.profiles AS profile ON profile.id = parameters.owner_id
    JOIN auth.users AS auth_user ON auth_user.id = profile.id
    WHERE profile.role = 'owner'
      AND auth_user.email_confirmed_at IS NOT NULL
  ) AS verified_owner_exists
),
checks AS (
  SELECT
    'current_user is postgres' AS check_name,
    CASE WHEN current_user = 'postgres' THEN 'PASS' ELSE 'FAIL' END AS result,
    format('current_user is %I; migration requires postgres.', current_user) AS detail
  UNION ALL
  SELECT
    'session_user is postgres for bootstrap',
    CASE WHEN session_user = 'postgres' THEN 'PASS' ELSE 'FAIL' END,
    format('session_user is %I; bootstrap requires a direct postgres session.', session_user)
  UNION ALL
  SELECT
    'PostgreSQL 17 or newer',
    CASE WHEN current_setting('server_version_num')::integer >= 170000
      THEN 'PASS' ELSE 'FAIL' END,
    format('server_version_num is %s.', current_setting('server_version_num'))
  UNION ALL
  SELECT
    'Database CREATE privilege',
    CASE WHEN pg_catalog.has_database_privilege(
      current_user, current_database(), 'CREATE'
    ) THEN 'PASS' ELSE 'FAIL' END,
    'Requires CREATE on the current database.'
  UNION ALL
  SELECT
    'Public schema USAGE privilege',
    CASE WHEN pg_catalog.has_schema_privilege(
      current_user, 'public', 'USAGE'
    ) THEN 'PASS' ELSE 'FAIL' END,
    'Requires USAGE on the public schema.'
  UNION ALL
  SELECT
    'Public schema CREATE privilege',
    CASE WHEN pg_catalog.has_schema_privilege(
      current_user, 'public', 'CREATE'
    ) THEN 'PASS' ELSE 'FAIL' END,
    'Requires CREATE on the public schema.'
  UNION ALL
  SELECT
    'Postgres ownership and default-ACL authority',
    CASE
      WHEN current_user = 'postgres'
       AND to_regrole('postgres') IS NOT NULL
      THEN 'PASS' ELSE 'FAIL'
    END,
    'Run as postgres to alter postgres default privileges and set ownership.'
  UNION ALL
  SELECT
    'Current role owns all 21 public tables',
    CASE
      WHEN count(*) = 21
       AND bool_and(relowner = current_user::regrole::oid)
      THEN 'PASS' ELSE 'FAIL'
    END,
    format('Expected 21 tables owned by current_user; found %s.', count(*))
  FROM public_tables
  UNION ALL
  SELECT
    'Current role owns all authenticated-callable SECURITY DEFINER functions',
    CASE
      WHEN count(*) = 28
       AND bool_and(proowner = current_user::regrole::oid)
      THEN 'PASS' ELSE 'FAIL'
    END,
    format('Expected 28 target functions owned by current_user; found %s.', count(*))
  FROM public_functions
  WHERE prokind = 'f'
    AND prosecdef
    AND prorettype <> 'trigger'::regtype
    AND (
      oid = to_regprocedure('public.is_admin()')
      OR pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')
    )
  UNION ALL
  SELECT
    'Current role owns public functions and sequences affected by bulk ACL changes',
    CASE WHEN NOT EXISTS (
      SELECT 1
      FROM public_functions
      WHERE proowner <> current_user::regrole::oid
    ) AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_class AS relation
      JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      WHERE namespace.nspname = 'public'
        AND relation.relkind = 'S'
        AND relation.relowner <> current_user::regrole::oid
    ) THEN 'PASS' ELSE 'FAIL' END,
    'A non-owned public function/sequence can block the migration ACL revokes; inspect any ownership mismatch before proceeding.'
  UNION ALL
  SELECT
    'Supabase roles and core dependencies',
    CASE
      WHEN to_regrole('anon') IS NOT NULL
       AND to_regrole('authenticated') IS NOT NULL
       AND to_regrole('service_role') IS NOT NULL
       AND to_regclass('auth.users') IS NOT NULL
       AND to_regclass('public.profiles') IS NOT NULL
       AND to_regprocedure('auth.uid()') IS NOT NULL
       AND to_regprocedure('public.is_admin()') IS NOT NULL
       AND to_regprocedure('public.profile_role_write_guard()') IS NOT NULL
      THEN 'PASS' ELSE 'FAIL'
    END,
    'Requires Supabase roles, Auth users, profiles, auth.uid(), is_admin(), and profile_role_write_guard().'
  UNION ALL
  SELECT
    'Expected public table inventory',
    CASE
      WHEN table_comparison.observed_count = 21
       AND table_comparison.missing_count = 0
       AND table_comparison.unexpected_count = 0
      THEN 'PASS' ELSE 'FAIL'
    END,
    format(
      'Expected 21 exact tables; observed %s, missing %s, unexpected %s.',
      table_comparison.observed_count,
      table_comparison.missing_count,
      table_comparison.unexpected_count
    )
  FROM table_comparison
  UNION ALL
  SELECT
    'RLS enabled on all public tables',
    CASE
      WHEN NOT EXISTS (SELECT 1 FROM public_tables WHERE NOT rls_enabled)
      THEN 'PASS' ELSE 'FAIL'
    END,
    'Every public base/partitioned table must have RLS enabled.'
  UNION ALL
  SELECT
    'Exact authenticated SECURITY DEFINER function identities',
    CASE
      WHEN function_comparison.observed_count = 28
       AND function_comparison.missing_count = 0
       AND function_comparison.unexpected_count = 0
       AND function_comparison.observed_identities = function_comparison.expected_identities
      THEN 'PASS' ELSE 'FAIL'
    END,
    format(
      'Expected 28 canonical identities; observed %s, missing %s, unexpected %s.',
      function_comparison.observed_count,
      function_comparison.missing_count,
      function_comparison.unexpected_count
    )
  FROM function_comparison
  UNION ALL
  SELECT
    'Function manifest diagnostics',
    CASE
      WHEN function_comparison.missing_count = 0
       AND function_comparison.unexpected_count = 0
      THEN 'PASS' ELSE 'FAIL'
    END,
    CASE
      WHEN function_comparison.missing_count = 0
       AND function_comparison.unexpected_count = 0
      THEN 'No missing identities or unexpected overloads.'
      ELSE format(
        'Canonical identities use schema.function(input types), derived from catalog type OIDs; argument names and defaults are ignored. Missing signatures: %s. Unexpected signatures/overloads: %s.',
        coalesce(function_comparison.missing_identities::text, 'none'),
        coalesce(function_comparison.unexpected_identities::text, 'none')
      )
    END
  FROM function_comparison
  UNION ALL
  SELECT
    'Required admin-settings RPC dependencies',
    CASE
      WHEN EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc AS routine
        WHERE routine.oid = to_regprocedure('public.save_estimate_number_settings(text, integer)')
          AND routine.prosecdef
          AND routine.prosrc LIKE '%public.is_admin()%'
      )
      AND EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc AS routine
        WHERE routine.oid = to_regprocedure('public.save_shift_alert_settings(text[])')
          AND routine.prosecdef
          AND routine.prosrc LIKE '%public.is_admin()%'
      )
      THEN 'PASS' ELSE 'FAIL'
    END,
    'Both required SECURITY DEFINER RPC bodies must call public.is_admin().'
  UNION ALL
  SELECT
    'is_admin authenticated SECURITY DEFINER dependency',
    CASE
      WHEN EXISTS (
        SELECT 1
        FROM pg_catalog.pg_proc AS routine
        WHERE routine.oid = to_regprocedure('public.is_admin()')
          AND routine.prosecdef
          AND routine.prorettype = 'boolean'::regtype
          AND pg_catalog.has_function_privilege('authenticated', routine.oid, 'EXECUTE')
      )
      THEN 'PASS' ELSE 'FAIL'
    END,
    'The manifest requires authenticated EXECUTE on SECURITY DEFINER public.is_admin() returning boolean.'
  UNION ALL
  SELECT
    'Profile-role guard trigger',
    CASE
      WHEN EXISTS (
        SELECT 1
        FROM pg_catalog.pg_trigger AS trigger_row
        JOIN pg_catalog.pg_proc AS routine ON routine.oid = trigger_row.tgfoid
        WHERE trigger_row.tgrelid = to_regclass('public.profiles')
          AND NOT trigger_row.tgisinternal
          AND trigger_row.tgfoid = to_regprocedure('public.profile_role_write_guard()')
          AND trigger_row.tgtype::integer = 31
          AND trigger_row.tgenabled IN ('O', 'A')
          AND routine.prosecdef
          AND routine.proowner = 'postgres'::regrole::oid
      )
      THEN 'PASS' ELSE 'FAIL'
    END,
    'Requires one enabled postgres-owned BEFORE INSERT/UPDATE/DELETE row trigger.'
  UNION ALL
  SELECT
    'Trigger-only SECURITY DEFINER functions excluded',
    CASE
      WHEN (
        SELECT count(*)
        FROM pg_catalog.pg_proc AS routine
        JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
        WHERE namespace.nspname = 'public'
          AND routine.prokind = 'f'
          AND routine.prosecdef
          AND routine.prorettype = 'trigger'::regtype
      ) = 3
      THEN 'PASS' ELSE 'FAIL'
    END,
    'Expected three SECURITY DEFINER trigger-returning functions; migration target selection excludes trigger return types.'
  UNION ALL
  SELECT
    'Approval objects absent before migration',
    CASE
      WHEN to_regnamespace('quote_studio_account_private') IS NULL
       AND to_regprocedure('public.is_account_approved()') IS NULL
       AND to_regprocedure('public.approve_account_access(uuid, text)') IS NULL
       AND to_regprocedure('public.revoke_account_access(uuid, text)') IS NULL
      THEN 'PASS' ELSE 'FAIL'
    END,
    'Existing approval objects require reconciliation; do not rerun this migration.'
  UNION ALL
  SELECT
    'Verified owner exists for bootstrap',
    CASE
      WHEN owner_readiness.verified_owner_exists THEN 'PASS' ELSE 'FAIL'
    END,
    'The supplied UUID must match an existing owner profile with a confirmed Auth email; the UUID and email are not returned.'
  FROM owner_readiness
  UNION ALL
  SELECT
    'Owner bootstrap session readiness',
    CASE
      WHEN current_user = 'postgres'
       AND session_user = 'postgres'
       AND owner_readiness.verified_owner_exists
       AND to_regnamespace('quote_studio_account_private') IS NULL
      THEN 'PASS' ELSE 'FAIL'
    END,
    'Bootstrap is a separate postgres-only step immediately after migration commit. Stop if it cannot be run.'
  FROM owner_readiness
)
SELECT check_name, result, detail
FROM checks
ORDER BY check_name;
