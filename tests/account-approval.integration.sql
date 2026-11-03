\set ON_ERROR_STOP on
BEGIN;

SELECT set_config('quote_studio.test_owner', :'approved_owner_id', true);
SELECT set_config('quote_studio.test_admin', :'approved_admin_id', true);
SELECT set_config('quote_studio.test_employee', :'approved_employee_id', true);
SELECT set_config('quote_studio.test_pending', :'pending_user_id', true);

DO $local_fixture_preconditions$
DECLARE
  local_address inet := inet_server_addr();
  owner_id uuid := current_setting('quote_studio.test_owner')::uuid;
  admin_id uuid := current_setting('quote_studio.test_admin')::uuid;
  employee_id uuid := current_setting('quote_studio.test_employee')::uuid;
  pending_id uuid := current_setting('quote_studio.test_pending')::uuid;
BEGIN
  IF current_user <> 'postgres'
     OR local_address IS NULL
     OR local_address NOT IN ('127.0.0.1'::inet, '::1'::inet) THEN
    RAISE EXCEPTION 'Integration tests require a postgres session on loopback';
  END IF;
  IF cardinality(ARRAY[owner_id, admin_id, employee_id, pending_id]) <> 4
     OR owner_id = admin_id OR owner_id = employee_id OR owner_id = pending_id
     OR admin_id = employee_id OR admin_id = pending_id OR employee_id = pending_id THEN
    RAISE EXCEPTION 'Provide four distinct local fixture accounts';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM auth.users
    WHERE id = ANY (ARRAY[owner_id, admin_id, employee_id, pending_id])
      AND email !~* '@[^@]+[.]test$'
  ) THEN
    RAISE EXCEPTION 'Integration fixtures must use reserved .test email addresses';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = owner_id AND role = 'owner'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = admin_id AND role = 'admin'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = employee_id AND role NOT IN ('owner', 'admin')
  ) OR NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = pending_id AND role NOT IN ('owner', 'admin')
  ) THEN
    RAISE EXCEPTION 'Fixtures must have owner, admin, employee, and pending profile roles';
  END IF;
END;
$local_fixture_preconditions$;

INSERT INTO quote_studio_account_private.account_approvals (
  user_id, approved_by, approval_reason
)
VALUES
  (current_setting('quote_studio.test_owner')::uuid, NULL, 'Local integration owner fixture'),
  (current_setting('quote_studio.test_admin')::uuid, current_setting('quote_studio.test_owner')::uuid, 'Local integration admin fixture'),
  (current_setting('quote_studio.test_employee')::uuid, current_setting('quote_studio.test_owner')::uuid, 'Local integration employee fixture')
ON CONFLICT (user_id) DO UPDATE
SET approved_at = now(),
    approved_by = EXCLUDED.approved_by,
    approval_reason = EXCLUDED.approval_reason,
    revoked_at = NULL,
    revoked_by = NULL,
    revocation_reason = NULL;

INSERT INTO quote_studio_account_private.account_approvals (
  user_id, approved_by, approval_reason, revoked_at, revoked_by, revocation_reason
)
VALUES (
  current_setting('quote_studio.test_pending')::uuid,
  current_setting('quote_studio.test_owner')::uuid,
  'Local integration pending fixture',
  now(),
  current_setting('quote_studio.test_owner')::uuid,
  'Local integration pending fixture'
)
ON CONFLICT (user_id) DO UPDATE
SET revoked_at = now(),
    revoked_by = current_setting('quote_studio.test_owner')::uuid,
    revocation_reason = 'Local integration pending fixture';

INSERT INTO public.products (part, description, active)
VALUES (
  'approval-test-' || current_setting('quote_studio.test_pending'),
  'Local account approval RLS sentinel',
  true
);

SELECT set_config(
  'request.jwt.claim.sub', current_setting('quote_studio.test_admin'), true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', current_setting('quote_studio.test_admin'),
    'role', 'authenticated'
  )::text,
  true
);
SET LOCAL ROLE authenticated;
DO $approved_admin$
DECLARE
  sentinel_count integer;
  registry_write_blocked boolean := false;
  privileged_approval_blocked boolean := false;
BEGIN
  IF public.is_account_approved() IS DISTINCT FROM true
     OR public.is_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Approved administrator must pass approval and admin checks';
  END IF;
  SELECT count(*) INTO sentinel_count FROM public.products
  WHERE part = 'approval-test-' || current_setting('quote_studio.test_pending');
  IF sentinel_count <> 1 THEN
    RAISE EXCEPTION 'Approved administrator could not read business data through RLS';
  END IF;
  PERFORM public.list_account_approvals();
  IF NOT has_function_privilege(
    'authenticated', 'public.approve_account_access(uuid,text)', 'EXECUTE'
  ) OR NOT has_function_privilege(
    'authenticated', 'public.revoke_account_access(uuid,text)', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Authenticated approval RPC execution grants are missing';
  END IF;
  IF has_table_privilege(
    'authenticated', 'quote_studio_account_private.account_approvals', 'SELECT'
  ) OR has_table_privilege(
    'authenticated', 'quote_studio_account_private.account_approval_audit', 'INSERT'
  ) THEN
    RAISE EXCEPTION 'Authenticated users must not access the private approval registry or audit';
  END IF;
  BEGIN
    INSERT INTO quote_studio_account_private.account_approvals (
      user_id, approval_reason
    )
    VALUES (
      current_setting('quote_studio.test_pending')::uuid,
      'attempted direct registry write'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    registry_write_blocked := true;
  END;
  IF NOT registry_write_blocked THEN
    RAISE EXCEPTION 'Authenticated user wrote directly to the approval registry';
  END IF;
  PERFORM public.approve_account_access(
    current_setting('quote_studio.test_pending')::uuid,
    'Local admin approval workflow'
  );
  PERFORM public.revoke_account_access(
    current_setting('quote_studio.test_pending')::uuid,
    'Local admin revocation workflow'
  );
  BEGIN
    PERFORM public.approve_account_access(
      current_setting('quote_studio.test_owner')::uuid,
      'Admin privileged approval test'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    privileged_approval_blocked := true;
  END;
  IF NOT privileged_approval_blocked THEN
    RAISE EXCEPTION 'An admin approved an owner account';
  END IF;
END;
$approved_admin$;
RESET ROLE;

SELECT set_config(
  'request.jwt.claim.sub', current_setting('quote_studio.test_employee'), true
);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', current_setting('quote_studio.test_employee'),
    'role', 'authenticated'
  )::text,
  true
);
SET LOCAL ROLE authenticated;
DO $approved_employee$
DECLARE
  sentinel_count integer;
BEGIN
  IF public.is_account_approved() IS DISTINCT FROM true
     OR public.is_admin() IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Approved employee approval and role checks are incorrect';
  END IF;
  SELECT count(*) INTO sentinel_count FROM public.products
  WHERE part = 'approval-test-' || current_setting('quote_studio.test_pending');
  IF sentinel_count <> 1 THEN
    RAISE EXCEPTION 'Approved employee could not read business data through RLS';
  END IF;
END;
$approved_employee$;
DO $employee_cannot_escalate$
BEGIN
  BEGIN
    UPDATE public.profiles SET role = 'admin'
    WHERE id = auth.uid();
  EXCEPTION WHEN insufficient_privilege THEN
    RETURN;
  END;
  RAISE EXCEPTION 'An approved employee changed their own profile role';
END;
$employee_cannot_escalate$;
RESET ROLE;

SELECT set_config(
  'request.jwt.claim.sub', current_setting('quote_studio.test_pending'), true
);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', current_setting('quote_studio.test_pending'),
    'role', 'authenticated'
  )::text,
  true
);
SET LOCAL ROLE authenticated;
DO $pending_user$
DECLARE
  sentinel_count integer;
  rpc_blocked boolean := false;
  self_approval_blocked boolean := false;
BEGIN
  IF public.is_account_approved() IS DISTINCT FROM false
     OR public.is_admin() IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Pending account must fail approval and admin checks';
  END IF;
  SELECT count(*) INTO sentinel_count FROM public.products
  WHERE part = 'approval-test-' || current_setting('quote_studio.test_pending');
  IF sentinel_count <> 0 THEN
    RAISE EXCEPTION 'Pending account read business data through RLS';
  END IF;

  BEGIN
    PERFORM public.generate_estimate_number();
  EXCEPTION WHEN insufficient_privilege THEN
    rpc_blocked := true;
  END;
  IF NOT rpc_blocked THEN
    RAISE EXCEPTION 'Pending account executed a privileged estimate RPC';
  END IF;

  BEGIN
    PERFORM public.approve_account_access(auth.uid(), 'self approval test');
  EXCEPTION WHEN insufficient_privilege THEN
    self_approval_blocked := true;
  END;
  IF NOT self_approval_blocked THEN
    RAISE EXCEPTION 'Pending account approved itself';
  END;

  BEGIN
    UPDATE public.profiles SET role = 'admin'
    WHERE id = auth.uid();
  EXCEPTION WHEN insufficient_privilege THEN
    RETURN;
  END;
  RAISE EXCEPTION 'A pending account changed its own profile role';
END;
$pending_user$;
RESET ROLE;

SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);
DO $anonymous_user$
BEGIN
  IF has_table_privilege('anon', 'public.products', 'SELECT')
     OR has_table_privilege('anon', 'public.customers', 'INSERT')
     OR has_table_privilege('anon', 'public.quotes', 'UPDATE')
     OR has_function_privilege('anon', 'public.is_account_approved()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Anonymous application privileges remain';
  END IF;
  BEGIN
    PERFORM count(*) FROM public.products;
  EXCEPTION WHEN insufficient_privilege THEN
    RETURN;
  END;
  RAISE EXCEPTION 'Anonymous user read business data';
END;
$anonymous_user$;
RESET ROLE;

DO $privilege_assertions$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_class AS relation
    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relkind IN ('r', 'p')
      AND (
        has_table_privilege('anon', relation.oid, 'SELECT')
        OR has_table_privilege('anon', relation.oid, 'INSERT')
        OR has_table_privilege('anon', relation.oid, 'UPDATE')
        OR has_table_privilege('anon', relation.oid, 'DELETE')
        OR has_table_privilege('anon', relation.oid, 'TRUNCATE')
        OR has_table_privilege('authenticated', relation.oid, 'TRUNCATE')
        OR has_table_privilege('anon', relation.oid, 'REFERENCES')
        OR has_table_privilege('authenticated', relation.oid, 'REFERENCES')
        OR has_table_privilege('anon', relation.oid, 'TRIGGER')
        OR has_table_privilege('authenticated', relation.oid, 'TRIGGER')
        OR has_table_privilege('anon', relation.oid, 'MAINTAIN')
        OR has_table_privilege('authenticated', relation.oid, 'MAINTAIN')
      )
  ) THEN
    RAISE EXCEPTION 'Anonymous or dangerous authenticated table privileges remain';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_proc AS routine
    JOIN pg_namespace AS namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public'
      AND has_function_privilege('anon', routine.oid, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'Anonymous function EXECUTE privileges remain';
  END IF;
  IF has_table_privilege(
    'service_role', 'quote_studio_account_private.account_approvals', 'SELECT'
  ) OR has_table_privilege(
    'service_role', 'quote_studio_account_private.account_approval_audit', 'INSERT'
  ) THEN
    RAISE EXCEPTION 'Service role must not write or read the private approval registry directly';
  END IF;
END;
$privilege_assertions$;

SELECT set_config(
  'request.jwt.claim.sub', current_setting('quote_studio.test_owner'), true
);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', current_setting('quote_studio.test_owner'),
    'role', 'authenticated'
  )::text,
  true
);
SET LOCAL ROLE authenticated;
DO $owner_approves_pending$
DECLARE
  employee_name text;
BEGIN
  SELECT full_name INTO employee_name
  FROM public.profiles
  WHERE id = current_setting('quote_studio.test_employee')::uuid;
  PERFORM public.manage_profile(
    current_setting('quote_studio.test_employee')::uuid,
    coalesce(employee_name, ''),
    'manager'
  );
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = current_setting('quote_studio.test_employee')::uuid
      AND role = 'manager'
  ) THEN
    RAISE EXCEPTION 'Owner profile management workflow was blocked';
  END IF;
  IF public.approve_account_access(
    current_setting('quote_studio.test_pending')::uuid,
    'Local integration approval'
  ) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Owner could not approve an invited employee fixture';
  END IF;
  BEGIN
    PERFORM public.approve_account_access(auth.uid(), 'self approval test');
  EXCEPTION WHEN insufficient_privilege THEN
    RETURN;
  END;
  RAISE EXCEPTION 'Owner approved their own account via the user RPC';
END;
$owner_approves_pending$;
RESET ROLE;

SELECT set_config(
  'request.jwt.claim.sub', current_setting('quote_studio.test_pending'), true
);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', current_setting('quote_studio.test_pending'),
    'role', 'authenticated'
  )::text,
  true
);
SET LOCAL ROLE authenticated;
DO $newly_approved_user$
DECLARE
  sentinel_count integer;
BEGIN
  IF public.is_account_approved() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Explicitly approved account remains blocked';
  END IF;
  SELECT count(*) INTO sentinel_count FROM public.products
  WHERE part = 'approval-test-' || current_setting('quote_studio.test_pending');
  IF sentinel_count <> 1 THEN
    RAISE EXCEPTION 'Newly approved account cannot read business data';
  END IF;
END;
$newly_approved_user$;
RESET ROLE;

SELECT set_config(
  'request.jwt.claim.sub', current_setting('quote_studio.test_owner'), true
);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', current_setting('quote_studio.test_owner'),
    'role', 'authenticated'
  )::text,
  true
);
SET LOCAL ROLE authenticated;
DO $owner_revokes_pending$
BEGIN
  IF public.revoke_account_access(
    current_setting('quote_studio.test_pending')::uuid,
    'Local integration revocation'
  ) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Owner could not revoke an approved account';
  END IF;
END;
$owner_revokes_pending$;
RESET ROLE;

SELECT set_config(
  'request.jwt.claim.sub', current_setting('quote_studio.test_pending'), true
);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', current_setting('quote_studio.test_pending'),
    'role', 'authenticated'
  )::text,
  true
);
SET LOCAL ROLE authenticated;
DO $revoked_user$
DECLARE
  sentinel_count integer;
BEGIN
  IF public.is_account_approved() IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Revoked account still passes the approval check';
  END IF;
  SELECT count(*) INTO sentinel_count FROM public.products
  WHERE part = 'approval-test-' || current_setting('quote_studio.test_pending');
  IF sentinel_count <> 0 THEN
    RAISE EXCEPTION 'Revoked account still reads business data through RLS';
  END IF;
END;
$revoked_user$;
RESET ROLE;

DO $audit_assertions$
BEGIN
  IF (
    SELECT count(*)
    FROM quote_studio_account_private.account_approval_audit
    WHERE subject_user_id = current_setting('quote_studio.test_pending')::uuid
      AND event_type IN ('approve', 'revoke')
  ) < 2 THEN
    RAISE EXCEPTION 'Approval and revocation audit entries were not recorded';
  END IF;
END;
$audit_assertions$;

ROLLBACK;
