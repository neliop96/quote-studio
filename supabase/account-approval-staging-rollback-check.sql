-- Read-only checks for effects that must be absent after a failed migration.
-- Run only after SQL Editor has ended/rolled back the failed transaction,
-- preferably in a fresh query/session. This does not inspect or reveal accounts.
-- PostgreSQL transaction rollback is the authority for reverting prior ACL/body
-- changes; this query verifies that migration-created objects/policies are absent.

WITH checks AS (
  SELECT
    'Private approval schema absent' AS check_name,
    CASE WHEN to_regnamespace('quote_studio_account_private') IS NULL
      THEN 'PASS' ELSE 'FAIL' END AS result,
    'The migration-created private schema should not exist after rollback.' AS detail
  UNION ALL
  SELECT
    'Migration-created public RPCs absent',
    CASE WHEN to_regprocedure('public.is_account_approved()') IS NULL
      AND to_regprocedure('public.list_account_approvals()') IS NULL
      AND to_regprocedure('public.approve_account_access(uuid, text)') IS NULL
      AND to_regprocedure('public.revoke_account_access(uuid, text)') IS NULL
      THEN 'PASS' ELSE 'FAIL' END,
    'Approval RPCs should not exist after rollback.'
  UNION ALL
  SELECT
    'Restrictive account policies absent',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    format('Migration approval policies remaining: %s.', count(*))
  FROM pg_catalog.pg_policy AS policy
  JOIN pg_catalog.pg_class AS relation ON relation.oid = policy.polrelid
  JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname = 'public'
    AND policy.polname = 'quote_studio_approved_account_gate'
  UNION ALL
  SELECT
    'No public routine retains injected approval guard',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    format('Public routines containing the migration guard: %s.', count(*))
  FROM pg_catalog.pg_proc AS routine
  JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
  WHERE namespace.nspname = 'public'
    AND routine.prosrc LIKE '%quote_studio_account_private.require_account_approved()%'
  UNION ALL
  SELECT
    'Temporary target table absent in this session',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    format('Temporary target tables remaining: %s.', count(*))
  FROM pg_catalog.pg_class AS relation
  WHERE relation.relnamespace = pg_catalog.pg_my_temp_schema()
    AND relation.relname = 'account_approval_secdef_targets'
)
SELECT check_name, result, detail
FROM checks
ORDER BY check_name;
