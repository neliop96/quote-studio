\set ON_ERROR_STOP on
-- Requires 20261102010000 and 20261104010000 applied to a LOCAL Supabase database.
-- Everything runs in one transaction that is rolled back.
BEGIN;

SELECT set_config('quote_studio.test_owner', :'approved_owner_id', true);
SELECT set_config('quote_studio.test_admin', :'approved_admin_id', true);
SELECT set_config('quote_studio.test_employee', :'approved_employee_id', true);
SELECT set_config('quote_studio.test_pending', :'pending_user_id', true);

DO $local_fixture_preconditions$
BEGIN
  IF current_user <> 'postgres'
     OR inet_server_addr() IS NULL
     OR inet_server_addr() NOT IN ('127.0.0.1'::inet, '::1'::inet) THEN
    RAISE EXCEPTION 'Integration tests require a postgres session on loopback';
  END IF;
  IF to_regprocedure('public.list_account_approval_audit(integer,bigint)') IS NULL THEN
    RAISE EXCEPTION 'Apply 20261104010000_account_approval_audit_history.sql locally first';
  END IF;
  IF EXISTS (
    SELECT 1 FROM auth.users
    WHERE id IN (
      current_setting('quote_studio.test_owner')::uuid,
      current_setting('quote_studio.test_admin')::uuid,
      current_setting('quote_studio.test_employee')::uuid,
      current_setting('quote_studio.test_pending')::uuid
    ) AND email !~* '@[^@]+[.]test$'
  ) THEN
    RAISE EXCEPTION 'Integration fixtures must use reserved .test email addresses';
  END IF;
END;
$local_fixture_preconditions$;

INSERT INTO quote_studio_account_private.account_approvals (user_id, approved_by, approval_reason)
VALUES
  (current_setting('quote_studio.test_owner')::uuid, NULL, 'Local audit history owner fixture'),
  (current_setting('quote_studio.test_admin')::uuid, current_setting('quote_studio.test_owner')::uuid, 'Local audit history admin fixture'),
  (current_setting('quote_studio.test_employee')::uuid, current_setting('quote_studio.test_owner')::uuid, 'Local audit history employee fixture')
ON CONFLICT (user_id) DO UPDATE
SET approved_at = now(), approved_by = EXCLUDED.approved_by,
    approval_reason = EXCLUDED.approval_reason,
    revoked_at = NULL, revoked_by = NULL, revocation_reason = NULL;
DELETE FROM quote_studio_account_private.account_approvals
WHERE user_id = current_setting('quote_studio.test_pending')::uuid;

-- Rows written as the table owner: one for a deleted account, plus enough for paging.
INSERT INTO quote_studio_account_private.account_approval_audit (
  event_type, subject_user_id, actor_user_id, actor_database_role, reason
)
SELECT 'approve', gen_random_uuid(), gen_random_uuid(), 'authenticated',
       'Deleted-account history row ' || n
FROM generate_series(1, 5) AS n;

-- Owner: allowed, newest first, keyset pagination, capped page size, deleted users visible.
SELECT set_config('request.jwt.claim.sub', current_setting('quote_studio.test_owner'), true);
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('quote_studio.test_owner'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
DO $owner_reads_audit$
DECLARE
  first_page bigint[];
  second_page bigint[];
  deleted_visible boolean;
  invalid_limit_blocked boolean := false;
  total integer;
BEGIN
  SELECT array_agg(audit_id ORDER BY ordinality) INTO first_page
  FROM public.list_account_approval_audit(2) WITH ORDINALITY;
  IF cardinality(first_page) <> 2 OR first_page[1] <= first_page[2] THEN
    RAISE EXCEPTION 'Owner page must hold 2 rows, newest first';
  END IF;
  SELECT array_agg(audit_id ORDER BY ordinality) INTO second_page
  FROM public.list_account_approval_audit(2, first_page[2]) WITH ORDINALITY;
  IF second_page[1] >= first_page[2] OR second_page[1] IS NULL THEN
    RAISE EXCEPTION 'Keyset cursor must return strictly older rows';
  END IF;
  IF first_page && second_page THEN
    RAISE EXCEPTION 'Pages must not overlap';
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM public.list_account_approval_audit(200) AS audit
    WHERE audit.reason LIKE 'Deleted-account history row%'
      AND audit.actor_name IS NULL AND audit.actor_email IS NULL
      AND audit.subject_name IS NULL AND audit.subject_email IS NULL
      AND audit.actor_user_id IS NOT NULL AND audit.subject_user_id IS NOT NULL
  ) INTO deleted_visible;
  IF NOT deleted_visible THEN
    RAISE EXCEPTION 'Rows for deleted accounts must stay visible';
  END IF;
  SELECT count(*) INTO total FROM public.list_account_approval_audit(100000);
  IF total > 200 THEN
    RAISE EXCEPTION 'Page size must be capped at 200';
  END IF;
  BEGIN
    PERFORM * FROM public.list_account_approval_audit(0);
  EXCEPTION WHEN invalid_parameter_value THEN
    invalid_limit_blocked := true;
  END;
  IF NOT invalid_limit_blocked THEN
    RAISE EXCEPTION 'A non-positive page size must be rejected';
  END IF;
END;
$owner_reads_audit$;
RESET ROLE;

-- Administrator, employee, pending account, anon, and service_role must all be denied.
DO $denied_roles$
DECLARE
  who text;
  blocked boolean;
BEGIN
  FOREACH who IN ARRAY ARRAY['test_admin', 'test_employee', 'test_pending'] LOOP
    PERFORM set_config('request.jwt.claim.sub', current_setting('quote_studio.' || who), true);
    PERFORM set_config('request.jwt.claims', jsonb_build_object(
      'sub', current_setting('quote_studio.' || who), 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    blocked := false;
    BEGIN
      PERFORM * FROM public.list_account_approval_audit(1);
    EXCEPTION WHEN insufficient_privilege THEN
      blocked := true;
    END;
    RESET ROLE;
    IF NOT blocked THEN
      RAISE EXCEPTION '% read the audit history', who;
    END IF;
  END LOOP;
  IF has_function_privilege('anon', 'public.list_account_approval_audit(integer,bigint)', 'EXECUTE')
     OR has_function_privilege('service_role', 'public.list_account_approval_audit(integer,bigint)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.list_account_approval_audit(integer,bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Audit function EXECUTE grants are wrong';
  END IF;
  IF has_table_privilege('authenticated', 'quote_studio_account_private.account_approval_audit', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE')
     OR has_table_privilege('service_role', 'quote_studio_account_private.account_approval_audit', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE')
     OR has_table_privilege('anon', 'quote_studio_account_private.account_approval_audit', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE') THEN
    RAISE EXCEPTION 'Direct audit table privileges exist';
  END IF;
END;
$denied_roles$;

-- Append-only: even the table owner cannot UPDATE, DELETE, or TRUNCATE while triggers are active.
DO $append_only$
DECLARE
  blocked boolean;
BEGIN
  blocked := false;
  BEGIN
    UPDATE quote_studio_account_private.account_approval_audit SET reason = 'tampered reason text';
  EXCEPTION WHEN insufficient_privilege THEN blocked := true;
  END;
  IF NOT blocked THEN RAISE EXCEPTION 'UPDATE on the audit table was not blocked'; END IF;
  blocked := false;
  BEGIN
    DELETE FROM quote_studio_account_private.account_approval_audit;
  EXCEPTION WHEN insufficient_privilege THEN blocked := true;
  END;
  IF NOT blocked THEN RAISE EXCEPTION 'DELETE on the audit table was not blocked'; END IF;
  blocked := false;
  BEGIN
    TRUNCATE quote_studio_account_private.account_approval_audit;
  EXCEPTION WHEN insufficient_privilege THEN blocked := true;
  END;
  IF NOT blocked THEN RAISE EXCEPTION 'TRUNCATE on the audit table was not blocked'; END IF;
  blocked := false;
  SET LOCAL session_replication_role = replica;
  BEGIN
    DELETE FROM quote_studio_account_private.account_approval_audit;
  EXCEPTION WHEN insufficient_privilege THEN blocked := true;
  END;
  RESET session_replication_role;
  IF NOT blocked THEN RAISE EXCEPTION 'ENABLE ALWAYS trigger did not fire in replica mode'; END IF;
END;
$append_only$;

ROLLBACK;
