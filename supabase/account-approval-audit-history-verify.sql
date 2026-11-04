-- Read-only verification for 20261104010000_account_approval_audit_history.sql.
-- Run on STAGING after the migration. Replace the two placeholders before running:
--   <OWNER_UUID>      an approved owner on that project
--   <NON_OWNER_UUID>  an approved non-owner (admin/employee) on that project
-- The whole script is rolled back; it changes nothing.
BEGIN READ ONLY;

SELECT 'function_definition' AS check_name,
       p.prosecdef AND p.proconfig @> ARRAY['search_path=""'] AS ok
FROM pg_proc p
WHERE p.oid = to_regprocedure('public.list_account_approval_audit(integer,bigint)')
UNION ALL
SELECT 'execute_authenticated_only',
       has_function_privilege('authenticated', 'public.list_account_approval_audit(integer,bigint)', 'EXECUTE')
       AND NOT has_function_privilege('anon', 'public.list_account_approval_audit(integer,bigint)', 'EXECUTE')
       AND NOT has_function_privilege('service_role', 'public.list_account_approval_audit(integer,bigint)', 'EXECUTE')
       AND NOT EXISTS (
         SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
         WHERE p.oid = to_regprocedure('public.list_account_approval_audit(integer,bigint)') AND a.grantee = 0)
UNION ALL
SELECT 'triggers_enable_always',
       (SELECT count(*) FROM pg_trigger
        WHERE tgrelid = 'quote_studio_account_private.account_approval_audit'::regclass
          AND tgname IN ('account_approval_audit_no_row_change', 'account_approval_audit_no_truncate')
          AND tgenabled = 'A') = 2
UNION ALL
SELECT 'no_direct_table_privileges',
       NOT (has_table_privilege('anon', 'quote_studio_account_private.account_approval_audit', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
         OR has_table_privilege('authenticated', 'quote_studio_account_private.account_approval_audit', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
         OR has_table_privilege('service_role', 'quote_studio_account_private.account_approval_audit', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'));

-- Owner allowed (expect rows or an empty set, no error).
SELECT set_config('request.jwt.claims', '{"sub":"<OWNER_UUID>","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT audit_id, recorded_at, event_type, actor_email, subject_email, left(reason, 60) AS reason_preview
FROM public.list_account_approval_audit(5);
RESET ROLE;

-- Non-owner must fail with 42501 "Approved owner required"; run separately after the owner check.
-- Uncomment, run on its own, and expect an error:
-- SELECT set_config('request.jwt.claims', '{"sub":"<NON_OWNER_UUID>","role":"authenticated"}', true);
-- SET LOCAL ROLE authenticated;
-- SELECT * FROM public.list_account_approval_audit(1);

ROLLBACK;
