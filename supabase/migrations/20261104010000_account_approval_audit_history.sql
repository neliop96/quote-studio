-- Owner-only read access to the account approval audit trail, plus append-only
-- protection for the audit table. Requires 20261102010000_account_approval_hardening.sql.
-- No data is created, changed, or deleted. Only successful events exist in the audit table;
-- failed attempts are not recorded.
--
-- Append-only limits: the trigger below blocks UPDATE, DELETE, and TRUNCATE for every
-- role, including ordinary administrators and the Owner. It is ENABLE ALWAYS, so it also
-- fires when session_replication_role = replica. It cannot stop the table owner or a
-- superuser (the Supabase postgres role) from running ALTER TABLE ... DISABLE TRIGGER,
-- DROP TRIGGER, or DROP TABLE and then changing rows. Those bypasses are only detectable
-- through database logs or external backups.

BEGIN;

DO $preflight$
BEGIN
  IF current_user <> 'postgres' THEN
    RAISE EXCEPTION 'Run this migration as postgres' USING ERRCODE = '42501';
  END IF;
  IF to_regclass('quote_studio_account_private.account_approval_audit') IS NULL
     OR to_regclass('quote_studio_account_private.account_approvals') IS NULL
     OR to_regprocedure('quote_studio_account_private.require_account_approved()') IS NULL
     OR to_regprocedure('public.approve_account_access(uuid,text)') IS NULL
     OR to_regprocedure('public.revoke_account_access(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Account approval hardening (20261102010000) must be installed first';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class
    WHERE oid = 'quote_studio_account_private.account_approval_audit'::pg_catalog.regclass
      AND relowner = 'postgres'::pg_catalog.regrole::oid
      AND relrowsecurity AND relforcerowsecurity
  ) THEN
    RAISE EXCEPTION 'Audit table must be postgres-owned with forced RLS';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_attribute
    WHERE attrelid = 'quote_studio_account_private.account_approval_audit'::pg_catalog.regclass
      AND attnum > 0 AND NOT attisdropped
      AND attname NOT IN (
        'id', 'event_type', 'subject_user_id', 'actor_user_id',
        'actor_database_role', 'reason', 'recorded_at'
      )
  ) THEN
    RAISE EXCEPTION 'Audit table has unexpected columns; review before continuing';
  END IF;
  IF to_regprocedure('public.list_account_approval_audit(integer,bigint)') IS NOT NULL
     OR to_regprocedure('quote_studio_account_private.account_approval_audit_append_only()') IS NOT NULL
     OR EXISTS (
       SELECT 1 FROM pg_catalog.pg_trigger
       WHERE tgrelid = 'quote_studio_account_private.account_approval_audit'::pg_catalog.regclass
         AND NOT tgisinternal
     ) THEN
    RAISE EXCEPTION 'Audit history objects already exist; reconcile instead of replaying';
  END IF;
  IF has_table_privilege('authenticated', 'quote_studio_account_private.account_approval_audit', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE')
     OR has_table_privilege('service_role', 'quote_studio_account_private.account_approval_audit', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE')
     OR has_table_privilege('anon', 'quote_studio_account_private.account_approval_audit', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE') THEN
    RAISE EXCEPTION 'Application roles must not have direct audit table privileges';
  END IF;
END;
$preflight$;

CREATE FUNCTION quote_studio_account_private.account_approval_audit_append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  RAISE EXCEPTION 'Account approval audit records are append-only'
    USING ERRCODE = '42501';
END;
$function$;
ALTER FUNCTION quote_studio_account_private.account_approval_audit_append_only()
  OWNER TO postgres;
REVOKE ALL ON FUNCTION quote_studio_account_private.account_approval_audit_append_only()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER account_approval_audit_no_row_change
  BEFORE UPDATE OR DELETE ON quote_studio_account_private.account_approval_audit
  FOR EACH ROW
  EXECUTE FUNCTION quote_studio_account_private.account_approval_audit_append_only();
CREATE TRIGGER account_approval_audit_no_truncate
  BEFORE TRUNCATE ON quote_studio_account_private.account_approval_audit
  FOR EACH STATEMENT
  EXECUTE FUNCTION quote_studio_account_private.account_approval_audit_append_only();
ALTER TABLE quote_studio_account_private.account_approval_audit
  ENABLE ALWAYS TRIGGER account_approval_audit_no_row_change;
ALTER TABLE quote_studio_account_private.account_approval_audit
  ENABLE ALWAYS TRIGGER account_approval_audit_no_truncate;

CREATE FUNCTION public.list_account_approval_audit(
  p_limit integer DEFAULT 100,
  p_before bigint DEFAULT NULL
)
RETURNS TABLE (
  audit_id bigint,
  recorded_at timestamptz,
  event_type text,
  actor_user_id uuid,
  actor_name text,
  actor_email text,
  subject_user_id uuid,
  subject_name text,
  subject_email text,
  reason text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  page_size integer;
BEGIN
  -- Raises 42501 unless the caller has an active approval.
  PERFORM quote_studio_account_private.require_account_approved();
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles AS caller
    WHERE caller.id = auth.uid() AND caller.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'Approved owner required' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 THEN
    RAISE EXCEPTION 'p_limit must be a positive integer' USING ERRCODE = '22023';
  END IF;
  page_size := least(p_limit, 200);

  RETURN QUERY
  SELECT
    audit.id,
    audit.recorded_at,
    audit.event_type,
    audit.actor_user_id,
    actor_profile.full_name,
    actor_user.email::text,
    audit.subject_user_id,
    subject_profile.full_name,
    subject_user.email::text,
    audit.reason
  FROM quote_studio_account_private.account_approval_audit AS audit
  LEFT JOIN public.profiles AS actor_profile ON actor_profile.id = audit.actor_user_id
  LEFT JOIN auth.users AS actor_user ON actor_user.id = audit.actor_user_id
  LEFT JOIN public.profiles AS subject_profile ON subject_profile.id = audit.subject_user_id
  LEFT JOIN auth.users AS subject_user ON subject_user.id = audit.subject_user_id
  WHERE p_before IS NULL OR audit.id < p_before
  ORDER BY audit.id DESC
  LIMIT page_size;
END;
$function$;
ALTER FUNCTION public.list_account_approval_audit(integer, bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.list_account_approval_audit(integer, bigint)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_account_approval_audit(integer, bigint)
  TO authenticated;

COMMENT ON FUNCTION public.list_account_approval_audit(integer, bigint) IS
  'Owner-only, approved-account-only audit history; newest first, keyset paged by audit id, page size capped at 200.';
COMMENT ON FUNCTION quote_studio_account_private.account_approval_audit_append_only() IS
  'Blocks UPDATE, DELETE, and TRUNCATE on the audit table. The table owner or a superuser can still disable or drop the triggers.';

DO $postconditions$
DECLARE
  audit_table constant regclass :=
    'quote_studio_account_private.account_approval_audit'::pg_catalog.regclass;
  list_function constant regprocedure :=
    'public.list_account_approval_audit(integer,bigint)'::pg_catalog.regprocedure;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc
    WHERE oid = list_function AND prosecdef
      AND proowner = 'postgres'::pg_catalog.regrole::oid
      AND proconfig @> ARRAY['search_path=""']
      AND prosrc LIKE '%quote_studio_account_private.require_account_approved()%'
      AND prosrc LIKE '%caller.role = ''owner''%'
      AND prosrc LIKE '%least(p_limit, 200)%'
  ) THEN
    RAISE EXCEPTION 'Audit history function definition is not as expected';
  END IF;
  IF has_function_privilege('anon', list_function, 'EXECUTE')
     OR has_function_privilege('service_role', list_function, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', list_function, 'EXECUTE')
     OR EXISTS (
       SELECT 1 FROM pg_catalog.pg_proc AS routine,
         LATERAL aclexplode(coalesce(routine.proacl, acldefault('f', routine.proowner))) AS acl
       WHERE routine.oid = list_function AND acl.grantee = 0
     ) THEN
    RAISE EXCEPTION 'Audit history function EXECUTE privileges are not as expected';
  END IF;
  IF (
    SELECT count(*) FROM pg_catalog.pg_trigger
    WHERE tgrelid = audit_table AND NOT tgisinternal AND tgenabled = 'A'
      AND tgname IN ('account_approval_audit_no_row_change', 'account_approval_audit_no_truncate')
  ) <> 2 OR (
    SELECT count(*) FROM pg_catalog.pg_trigger
    WHERE tgrelid = audit_table AND NOT tgisinternal
  ) <> 2 THEN
    RAISE EXCEPTION 'Append-only triggers are missing or not ENABLE ALWAYS';
  END IF;
  IF has_table_privilege('authenticated', audit_table, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE')
     OR has_table_privilege('service_role', audit_table, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE')
     OR has_table_privilege('anon', audit_table, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE') THEN
    RAISE EXCEPTION 'Direct audit table privileges were opened';
  END IF;
END;
$postconditions$;

COMMIT;
