-- Quote Studio account approval and business-data authorization.
-- Apply only after reviewing the verified owner bootstrap procedure.
BEGIN;

DO $preflight$
DECLARE
  missing_tables text[];
  table_name text;
  role_name text;
  guard_trigger_count integer;
BEGIN
  IF current_user <> 'postgres' THEN
    RAISE EXCEPTION 'Run this migration as postgres';
  END IF;
  IF current_setting('server_version_num')::integer < 170000 THEN
    RAISE EXCEPTION 'PostgreSQL 17 or newer is required';
  END IF;
  IF to_regclass('auth.users') IS NULL
     OR to_regclass('public.profiles') IS NULL
     OR to_regprocedure('auth.uid()') IS NULL
     OR to_regprocedure('public.is_admin()') IS NULL
     OR to_regprocedure('public.profile_role_write_guard()') IS NULL THEN
    RAISE EXCEPTION 'Expected initialized Supabase Auth and the installed profile role guard';
  END IF;
  IF to_regnamespace('quote_studio_account_private') IS NOT NULL
     OR to_regclass('quote_studio_account_private.account_approvals') IS NOT NULL
     OR to_regclass('quote_studio_account_private.account_approval_audit') IS NOT NULL
     OR to_regprocedure('public.is_account_approved()') IS NOT NULL
     OR to_regprocedure('public.approve_account_access(uuid,text)') IS NOT NULL
     OR to_regprocedure('public.revoke_account_access(uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Account approval objects already exist; reconcile them before applying';
  END IF;

  SELECT array_agg(expected.name ORDER BY expected.name)
  INTO missing_tables
  FROM unnest(ARRAY[
    'products', 'customers', 'quote_settings', 'quotes', 'inventory',
    'stock_movements', 'quotation_email_log', 'estimate_number_settings',
    'projects', 'shift_reports', 'shift_alert_settings', 'shift_alerts',
    'shift_alert_reads', 'shift_schedule_settings',
    'shift_schedule_time_zone_history', 'shift_schedule_templates',
    'shift_schedule_instances', 'employee_shift_default_history',
    'shift_assignment_override_history', 'quote_status_history'
  ]) AS expected(name)
  WHERE to_regclass('public.' || expected.name) IS NULL;
  IF missing_tables IS NOT NULL THEN
    RAISE EXCEPTION 'Missing expected business tables: %', missing_tables;
  END IF;

  IF (
    SELECT count(*)
    FROM pg_class AS relation
    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relkind IN ('r', 'p')
  ) <> 21 THEN
    RAISE EXCEPTION 'Expected exactly 21 public application tables; review the schema before applying';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_class AS relation
    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relkind IN ('r', 'p')
      AND NOT relation.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'Every public application table must already have RLS enabled';
  END IF;

  SELECT count(*) INTO guard_trigger_count
  FROM pg_trigger AS trigger_row
  JOIN pg_proc AS routine ON routine.oid = trigger_row.tgfoid
  WHERE trigger_row.tgrelid = 'public.profiles'::regclass
    AND NOT trigger_row.tgisinternal
    AND trigger_row.tgfoid = 'public.profile_role_write_guard()'::regprocedure
    AND trigger_row.tgtype::integer = 31
    AND trigger_row.tgenabled IN ('O', 'A')
    AND routine.prosecdef
    AND routine.proowner = 'postgres'::regrole::oid;
  IF guard_trigger_count <> 1 THEN
    RAISE EXCEPTION 'The enabled postgres-owned profile role protection trigger is required';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc AS routine
    WHERE routine.oid = 'public.save_estimate_number_settings(text,integer)'::regprocedure
      AND routine.prosecdef
      AND routine.prosrc LIKE '%public.is_admin()%'
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_proc AS routine
    WHERE routine.oid = 'public.save_shift_alert_settings(text[])'::regprocedure
      AND routine.prosecdef
      AND routine.prosrc LIKE '%public.is_admin()%'
  ) THEN
    RAISE EXCEPTION 'Owner-aware estimate and alert settings RPCs are required; reconcile the installed profile-role protections first';
  END IF;

  FOREACH role_name IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF to_regrole(role_name) IS NULL THEN
      RAISE EXCEPTION 'Required Supabase role is missing: %', role_name;
    END IF;
  END LOOP;
END;
$preflight$;

CREATE TEMP TABLE account_approval_secdef_targets ON COMMIT DROP AS
SELECT
  routine.oid AS routine_oid,
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
  ) AS routine_identity,
  language.lanname AS routine_language,
  routine.prosrc AS routine_source
FROM pg_proc AS routine
JOIN pg_namespace AS namespace ON namespace.oid = routine.pronamespace
JOIN pg_language AS language ON language.oid = routine.prolang
WHERE namespace.nspname = 'public'
  AND routine.prokind = 'f'
  AND routine.prosecdef
  AND routine.prorettype <> 'trigger'::regtype
  AND routine.oid <> 'public.is_admin()'::regprocedure
  AND has_function_privilege('authenticated', routine.oid, 'EXECUTE');

DO $function_preflight$
DECLARE
  target_count integer;
  observed_identities text[];
  expected_identities constant text[] := ARRAY[
    'public.admin_delete_quote(uuid)',
    'public.create_custom_shift(text, timestamp without time zone, timestamp without time zone)',
    'public.create_estimate_revision(uuid)',
    'public.generate_estimate_number()',
    'public.get_estimate_number_settings()',
    'public.get_my_shift_alerts()',
    'public.get_scheduled_shift_at(timestamp with time zone)',
    'public.get_shift_alert_settings()',
    'public.get_shift_schedule(date, date, boolean)',
    'public.get_shift_schedule_admin_data()',
    'public.get_shift_schedule_settings()',
    'public.inventory_movement_actor_names()',
    'public.is_admin()',
    'public.manage_profile(uuid, text, text)',
    'public.mark_shift_alert_read(uuid)',
    'public.materialize_shift_schedule(date, date)',
    'public.quote_studio_business_date()',
    'public.record_stock_movement(uuid, text, integer, numeric, text, text)',
    'public.save_estimate_number_settings(text, integer)',
    'public.save_shift_alert_settings(text[])',
    'public.set_employee_default_shift(uuid, text)',
    'public.set_estimate_decision(uuid, text)',
    'public.set_reorder_level(uuid, integer)',
    'public.set_shift_instance_assignment(uuid, uuid, boolean)',
    'public.set_shift_schedule_time_zone(text)',
    'public.set_stock_movement_archived(uuid, boolean)',
    'public.submit_shift_report(uuid)',
    'public.sync_estimate_statuses()'
  ];
  unsupported text[];
BEGIN
  SELECT count(*) INTO target_count FROM pg_temp.account_approval_secdef_targets;
  IF target_count <> cardinality(expected_identities) - 1 THEN
    RAISE EXCEPTION 'Expected % reviewed authenticated-callable SECURITY DEFINER functions, found %',
      cardinality(expected_identities) - 1, target_count;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc AS routine
    WHERE routine.oid = 'public.is_admin()'::regprocedure
      AND routine.prosecdef
      AND routine.prorettype = 'boolean'::regtype
      AND has_function_privilege('authenticated', routine.oid, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'Expected public.is_admin() to be an authenticated-callable SECURITY DEFINER boolean function';
  END IF;
  SELECT array_agg(identity ORDER BY identity COLLATE "C")
  INTO observed_identities
  FROM (
    SELECT target.routine_identity AS identity
    FROM pg_temp.account_approval_secdef_targets AS target
    UNION ALL
    SELECT format(
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
    )
    FROM pg_proc AS routine
    JOIN pg_namespace AS namespace ON namespace.oid = routine.pronamespace
    WHERE routine.oid = 'public.is_admin()'::regprocedure
  ) AS observed;
  IF observed_identities IS DISTINCT FROM expected_identities THEN
    RAISE EXCEPTION 'SECURITY DEFINER identity manifest differs from the installed functions. Expected %, found %',
      expected_identities, observed_identities;
  END IF;
  SELECT array_agg(routine_identity ORDER BY routine_identity)
  INTO unsupported
  FROM pg_temp.account_approval_secdef_targets
  WHERE routine_language NOT IN ('plpgsql', 'sql')
     OR routine_source IS NULL
     OR length(btrim(routine_source)) = 0;
  IF unsupported IS NOT NULL THEN
    RAISE EXCEPTION 'Review unsupported SECURITY DEFINER routines before applying: %', unsupported;
  END IF;
END;
$function_preflight$;

CREATE SCHEMA quote_studio_account_private;
ALTER SCHEMA quote_studio_account_private OWNER TO postgres;
REVOKE ALL ON SCHEMA quote_studio_account_private FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA quote_studio_account_private TO authenticated;

CREATE TABLE quote_studio_account_private.account_approvals (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  approved_at timestamptz NOT NULL DEFAULT now(),
  approved_by uuid,
  approval_reason text NOT NULL,
  revoked_at timestamptz,
  revoked_by uuid,
  revocation_reason text,
  CONSTRAINT account_approvals_reason_valid
    CHECK (length(btrim(approval_reason)) BETWEEN 8 AND 500),
  CONSTRAINT account_approvals_revocation_consistent
    CHECK (
      (revoked_at IS NULL AND revoked_by IS NULL AND revocation_reason IS NULL)
      OR
      (revoked_at IS NOT NULL AND revoked_by IS NOT NULL
        AND length(btrim(revocation_reason)) BETWEEN 8 AND 500)
    )
);
ALTER TABLE quote_studio_account_private.account_approvals OWNER TO postgres;
ALTER TABLE quote_studio_account_private.account_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE quote_studio_account_private.account_approvals FORCE ROW LEVEL SECURITY;

CREATE TABLE quote_studio_account_private.account_approval_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_type text NOT NULL CHECK (event_type IN ('bootstrap', 'approve', 'revoke')),
  subject_user_id uuid NOT NULL,
  actor_user_id uuid,
  actor_database_role name NOT NULL,
  reason text NOT NULL CHECK (length(btrim(reason)) BETWEEN 8 AND 500),
  recorded_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE quote_studio_account_private.account_approval_audit OWNER TO postgres;
ALTER TABLE quote_studio_account_private.account_approval_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE quote_studio_account_private.account_approval_audit FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE
  quote_studio_account_private.account_approvals,
  quote_studio_account_private.account_approval_audit
FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON SEQUENCE
  quote_studio_account_private.account_approval_audit_id_seq
FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION quote_studio_account_private.is_account_approved()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT auth.uid() IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM quote_studio_account_private.account_approvals AS approval
      WHERE approval.user_id = auth.uid()
        AND approval.revoked_at IS NULL
    )
    AND EXISTS (
      SELECT 1
      FROM public.profiles AS profile
      WHERE profile.id = auth.uid()
    );
$function$;
ALTER FUNCTION quote_studio_account_private.is_account_approved() OWNER TO postgres;
REVOKE ALL ON FUNCTION quote_studio_account_private.is_account_approved()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION quote_studio_account_private.is_account_approved()
  TO authenticated;

CREATE FUNCTION quote_studio_account_private.require_account_approved()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NOT quote_studio_account_private.is_account_approved() THEN
    RAISE EXCEPTION 'Approved account required' USING ERRCODE = '42501';
  END IF;
  RETURN true;
END;
$function$;
ALTER FUNCTION quote_studio_account_private.require_account_approved() OWNER TO postgres;
REVOKE ALL ON FUNCTION quote_studio_account_private.require_account_approved()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION quote_studio_account_private.bootstrap_verified_owner(
  p_owner_id uuid,
  p_verification_reference text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  owner_role text;
  owner_email_confirmed timestamptz;
  clean_reference text := btrim(coalesce(p_verification_reference, ''));
BEGIN
  IF session_user <> 'postgres' THEN
    RAISE EXCEPTION 'Owner bootstrap is restricted to a postgres session'
      USING ERRCODE = '42501';
  END IF;
  IF p_owner_id IS NULL OR length(clean_reference) < 12 OR length(clean_reference) > 500 THEN
    RAISE EXCEPTION 'Provide an owner UUID and an independent verification reference';
  END IF;

  PERFORM pg_advisory_xact_lock(73002, 1);
  IF EXISTS (
    SELECT 1
    FROM quote_studio_account_private.account_approvals AS approval
    JOIN public.profiles AS profile ON profile.id = approval.user_id
    WHERE profile.role = 'owner'
      AND approval.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'An approved owner already exists; bootstrap or recovery is not available';
  END IF;

  SELECT profile.role, auth_user.email_confirmed_at
  INTO owner_role, owner_email_confirmed
  FROM public.profiles AS profile
  JOIN auth.users AS auth_user ON auth_user.id = profile.id
  WHERE profile.id = p_owner_id;
  IF NOT FOUND OR owner_role <> 'owner' OR owner_email_confirmed IS NULL THEN
    RAISE EXCEPTION 'Target must be an existing owner profile with a confirmed Auth email';
  END IF;

  INSERT INTO quote_studio_account_private.account_approvals (
    user_id, approved_by, approval_reason
  )
  VALUES (p_owner_id, NULL, clean_reference)
  ON CONFLICT (user_id) DO UPDATE
  SET approved_at = now(),
      approved_by = NULL,
      approval_reason = EXCLUDED.approval_reason,
      revoked_at = NULL,
      revoked_by = NULL,
      revocation_reason = NULL;

  INSERT INTO quote_studio_account_private.account_approval_audit (
    event_type, subject_user_id, actor_user_id, actor_database_role, reason
  )
  VALUES ('bootstrap', p_owner_id, NULL, session_user, clean_reference);
END;
$function$;
ALTER FUNCTION quote_studio_account_private.bootstrap_verified_owner(uuid, text)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION
  quote_studio_account_private.bootstrap_verified_owner(uuid, text)
FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION
  quote_studio_account_private.bootstrap_verified_owner(uuid, text)
TO postgres;

CREATE FUNCTION public.is_account_approved()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT quote_studio_account_private.is_account_approved();
$function$;
ALTER FUNCTION public.is_account_approved() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.is_account_approved()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_account_approved() TO authenticated;

CREATE OR REPLACE FUNCTION public.quote_studio_business_date()
RETURNS date
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF session_user <> 'postgres'
     AND coalesce(auth.role(), '') <> 'service_role' THEN
    PERFORM quote_studio_account_private.require_account_approved();
  END IF;
  RETURN (
    pg_catalog.now() AT TIME ZONE coalesce(
      (SELECT settings.quote_time_zone
       FROM public.quote_settings AS settings
       WHERE settings.id = 1),
      'America/Los_Angeles'
    )
  )::date;
END;
$function$;
ALTER FUNCTION public.quote_studio_business_date() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.quote_studio_business_date()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quote_studio_business_date()
  TO authenticated, service_role;

CREATE FUNCTION public.list_account_approvals()
RETURNS TABLE (
  user_id uuid,
  full_name text,
  role text,
  email text,
  approved boolean,
  revoked_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  actor_id uuid := auth.uid();
BEGIN
  IF NOT quote_studio_account_private.require_account_approved()
     OR NOT EXISTS (
       SELECT 1 FROM public.profiles AS actor
       WHERE actor.id = actor_id AND actor.role IN ('owner', 'admin')
     ) THEN
    RAISE EXCEPTION 'Approved administrator required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    profile.id,
    profile.full_name,
    profile.role,
    auth_user.email::text,
    approval.user_id IS NOT NULL AND approval.revoked_at IS NULL,
    approval.revoked_at
  FROM public.profiles AS profile
  JOIN auth.users AS auth_user ON auth_user.id = profile.id
  LEFT JOIN quote_studio_account_private.account_approvals AS approval
    ON approval.user_id = profile.id
  ORDER BY profile.full_name, profile.id;
END;
$function$;
ALTER FUNCTION public.list_account_approvals() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.list_account_approvals()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_account_approvals() TO authenticated;

CREATE FUNCTION public.approve_account_access(p_user_id uuid, p_reason text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  actor_id uuid := auth.uid();
  actor_role text;
  target_role text;
  clean_reason text := btrim(coalesce(p_reason, ''));
BEGIN
  IF actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  PERFORM quote_studio_account_private.require_account_approved();
  PERFORM pg_advisory_xact_lock(73002, 1);

  IF p_user_id IS NULL OR p_user_id = actor_id
     OR length(clean_reason) < 8 OR length(clean_reason) > 500 THEN
    RAISE EXCEPTION 'A different target account and an audit reason are required'
      USING ERRCODE = '42501';
  END IF;

  SELECT profile.role INTO actor_role
  FROM public.profiles AS profile WHERE profile.id = actor_id;
  SELECT profile.role INTO target_role
  FROM public.profiles AS profile WHERE profile.id = p_user_id;
  IF actor_role NOT IN ('owner', 'admin') OR target_role IS NULL THEN
    RAISE EXCEPTION 'Administrator and target profile are required'
      USING ERRCODE = '42501';
  END IF;
  IF target_role IN ('owner', 'admin') AND actor_role <> 'owner' THEN
    RAISE EXCEPTION 'Only an owner may approve an owner or administrator'
      USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1 FROM quote_studio_account_private.account_approvals AS approval
    WHERE approval.user_id = p_user_id AND approval.revoked_at IS NULL
  ) THEN
    RETURN false;
  END IF;

  INSERT INTO quote_studio_account_private.account_approvals (
    user_id, approved_by, approval_reason, revoked_at, revoked_by, revocation_reason
  )
  VALUES (p_user_id, actor_id, clean_reason, NULL, NULL, NULL)
  ON CONFLICT (user_id) DO UPDATE
  SET approved_at = now(),
      approved_by = EXCLUDED.approved_by,
      approval_reason = EXCLUDED.approval_reason,
      revoked_at = NULL,
      revoked_by = NULL,
      revocation_reason = NULL;

  INSERT INTO quote_studio_account_private.account_approval_audit (
    event_type, subject_user_id, actor_user_id, actor_database_role, reason
  )
  VALUES ('approve', p_user_id, actor_id, coalesce(auth.role(), 'unknown')::name, clean_reason);
  RETURN true;
END;
$function$;
ALTER FUNCTION public.approve_account_access(uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.approve_account_access(uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_account_access(uuid, text) TO authenticated;

CREATE FUNCTION public.revoke_account_access(p_user_id uuid, p_reason text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  actor_id uuid := auth.uid();
  actor_role text;
  target_role text;
  clean_reason text := btrim(coalesce(p_reason, ''));
BEGIN
  IF actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  PERFORM quote_studio_account_private.require_account_approved();
  PERFORM pg_advisory_xact_lock(73002, 1);

  IF p_user_id IS NULL OR p_user_id = actor_id
     OR length(clean_reason) < 8 OR length(clean_reason) > 500 THEN
    RAISE EXCEPTION 'A different target account and an audit reason are required'
      USING ERRCODE = '42501';
  END IF;

  SELECT profile.role INTO actor_role
  FROM public.profiles AS profile WHERE profile.id = actor_id;
  SELECT profile.role INTO target_role
  FROM public.profiles AS profile WHERE profile.id = p_user_id;
  IF actor_role NOT IN ('owner', 'admin') OR target_role IS NULL THEN
    RAISE EXCEPTION 'Administrator and target profile are required'
      USING ERRCODE = '42501';
  END IF;
  IF target_role IN ('owner', 'admin') AND actor_role <> 'owner' THEN
    RAISE EXCEPTION 'Only an owner may revoke an owner or administrator'
      USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM quote_studio_account_private.account_approvals AS approval
    WHERE approval.user_id = p_user_id AND approval.revoked_at IS NULL
  ) THEN
    RETURN false;
  END IF;
  IF target_role = 'owner' AND (
    SELECT count(*)
    FROM quote_studio_account_private.account_approvals AS approval
    JOIN public.profiles AS profile ON profile.id = approval.user_id
    WHERE profile.role = 'owner' AND approval.revoked_at IS NULL
  ) <= 1 THEN
    RAISE EXCEPTION 'The last approved owner cannot be revoked'
      USING ERRCODE = '42501';
  END IF;

  UPDATE quote_studio_account_private.account_approvals
  SET revoked_at = now(),
      revoked_by = actor_id,
      revocation_reason = clean_reason
  WHERE user_id = p_user_id AND revoked_at IS NULL;

  INSERT INTO quote_studio_account_private.account_approval_audit (
    event_type, subject_user_id, actor_user_id, actor_database_role, reason
  )
  VALUES ('revoke', p_user_id, actor_id, coalesce(auth.role(), 'unknown')::name, clean_reason);
  RETURN true;
END;
$function$;
ALTER FUNCTION public.revoke_account_access(uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.revoke_account_access(uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.revoke_account_access(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT quote_studio_account_private.is_account_approved()
    AND EXISTS (
      SELECT 1
      FROM public.profiles AS profile
      WHERE profile.id = auth.uid()
        AND profile.role IN ('owner', 'admin')
    );
$function$;
ALTER FUNCTION public.is_admin() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.is_admin()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated, service_role;

DO $table_hardening$
DECLARE
  table_name text;
  business_tables text[] := ARRAY[
    'products', 'customers', 'quote_settings', 'quotes', 'inventory',
    'stock_movements', 'quotation_email_log', 'estimate_number_settings',
    'projects', 'shift_reports', 'shift_alert_settings', 'shift_alerts',
    'shift_alert_reads', 'shift_schedule_settings',
    'shift_schedule_time_zone_history', 'shift_schedule_templates',
    'shift_schedule_instances', 'employee_shift_default_history',
    'shift_assignment_override_history', 'quote_status_history'
  ];
BEGIN
  FOREACH table_name IN ARRAY business_tables LOOP
    EXECUTE format(
      'CREATE POLICY quote_studio_approved_account_gate ON public.%I '
      'AS RESTRICTIVE FOR ALL TO authenticated '
      'USING (quote_studio_account_private.is_account_approved()) '
      'WITH CHECK (quote_studio_account_private.is_account_approved())',
      table_name
    );
    EXECUTE format(
      'REVOKE ALL PRIVILEGES ON TABLE public.%I FROM PUBLIC, anon',
      table_name
    );
    EXECUTE format(
      'REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE public.%I '
      'FROM PUBLIC, anon, authenticated',
      table_name
    );
  END LOOP;

  REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, anon;
  REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon;

  REVOKE ALL PRIVILEGES ON TABLE public.profiles FROM PUBLIC, anon;
  REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN
    ON TABLE public.profiles FROM PUBLIC, anon, authenticated;
  GRANT SELECT ON TABLE public.profiles TO authenticated;
  GRANT UPDATE (full_name) ON TABLE public.profiles TO authenticated;

  ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON TABLES FROM PUBLIC, anon;
  ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLES
    FROM PUBLIC, anon, authenticated;
  ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON SEQUENCES FROM PUBLIC, anon;
  ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;
END;
$table_hardening$;

DO $function_hardening$
DECLARE
  target record;
  function_definition text;
  function_body_start integer;
  function_body_end integer;
  begin_position integer;
  body_tag text;
  tag_match text[];
  guarded_source text;
  replacement text;
  unguarded text[];
BEGIN
  FOR target IN
    SELECT * FROM pg_temp.account_approval_secdef_targets
    ORDER BY routine_identity
  LOOP
    IF target.routine_identity = 'public.quote_studio_business_date()' THEN
      CONTINUE;
    END IF;
    function_definition := pg_get_functiondef(target.routine_oid);

    IF target.routine_language = 'plpgsql' THEN
      begin_position := regexp_instr(
        target.routine_source,
        '(^|[[:space:]])(BEGIN)([[:space:]]|$)',
        1, 1, 0, 'i', 2
      );
      IF begin_position = 0 THEN
        RAISE EXCEPTION 'Could not locate the PL/pgSQL entry block for %',
          target.routine_identity;
      END IF;
      guarded_source :=
        substr(target.routine_source, 1, begin_position + 4)
        || E'\n  PERFORM quote_studio_account_private.require_account_approved();\n'
        || substr(target.routine_source, begin_position + 5);
      tag_match := regexp_match(
        function_definition,
        'AS[[:space:]]+(\$[A-Za-z0-9_]*\$)'
      );
      IF tag_match IS NULL THEN
        RAISE EXCEPTION 'Could not locate the function body delimiter for %',
          target.routine_identity;
      END IF;
      body_tag := tag_match[1];
      function_body_start := strpos(function_definition, 'AS ' || body_tag);
      IF function_body_start = 0 THEN
        RAISE EXCEPTION 'Could not locate the function body for %',
          target.routine_identity;
      END IF;
      function_body_start :=
        function_body_start + length('AS ' || body_tag) - 1;
      function_body_end := strpos(
        substr(function_definition, function_body_start + 1),
        body_tag
      );
      IF function_body_end = 0 THEN
        RAISE EXCEPTION 'Could not locate the end of the function body for %',
          target.routine_identity;
      END IF;
      replacement :=
        substr(function_definition, 1, function_body_start)
        || guarded_source
        || substr(function_definition, function_body_start + function_body_end);
      EXECUTE replacement;
    ELSE
      tag_match := regexp_match(
        function_definition,
        'AS[[:space:]]+(\$[A-Za-z0-9_]*\$)'
      );
      IF tag_match IS NULL THEN
        RAISE EXCEPTION 'Could not locate the SQL function body delimiter for %',
          target.routine_identity;
      END IF;
      body_tag := tag_match[1];
      function_body_start := strpos(function_definition, 'AS ' || body_tag);
      IF function_body_start = 0 THEN
        RAISE EXCEPTION 'Could not locate the SQL function body for %',
          target.routine_identity;
      END IF;
      function_body_start :=
        function_body_start + length('AS ' || body_tag) - 1;
      function_body_end := strpos(
        substr(function_definition, function_body_start + 1),
        body_tag
      );
      IF function_body_end = 0 THEN
        RAISE EXCEPTION 'Could not locate the end of the SQL function body for %',
          target.routine_identity;
      END IF;
      guarded_source :=
        'WITH account_approval AS ('
        || 'SELECT quote_studio_account_private.require_account_approved() AS allowed'
        || ') SELECT guarded_result.* FROM account_approval'
        || ' CROSS JOIN LATERAL ('
        || regexp_replace(btrim(target.routine_source), ';[[:space:]]*$', '')
        || ') AS guarded_result WHERE account_approval.allowed';
      replacement :=
        substr(function_definition, 1, function_body_start)
        || guarded_source
        || substr(function_definition, function_body_start + function_body_end);
      EXECUTE replacement;
    END IF;
  END LOOP;

  SELECT array_agg(secdef_target.routine_identity ORDER BY secdef_target.routine_identity)
  INTO unguarded
  FROM pg_temp.account_approval_secdef_targets AS secdef_target
  JOIN pg_proc AS routine ON routine.oid = secdef_target.routine_oid
  WHERE routine.prosrc NOT LIKE '%quote_studio_account_private.require_account_approved()%'
     OR NOT has_function_privilege('authenticated', routine.oid, 'EXECUTE');
  IF unguarded IS NOT NULL THEN
    RAISE EXCEPTION 'SECURITY DEFINER approval guard verification failed: %', unguarded;
  END IF;
END;
$function_hardening$;

DO $table_postconditions$
DECLARE
  ungated text[];
  anonymous_access text[];
BEGIN
  SELECT array_agg(table_name ORDER BY table_name)
  INTO ungated
  FROM unnest(ARRAY[
    'products', 'customers', 'quote_settings', 'quotes', 'inventory',
    'stock_movements', 'quotation_email_log', 'estimate_number_settings',
    'projects', 'shift_reports', 'shift_alert_settings', 'shift_alerts',
    'shift_alert_reads', 'shift_schedule_settings',
    'shift_schedule_time_zone_history', 'shift_schedule_templates',
    'shift_schedule_instances', 'employee_shift_default_history',
    'shift_assignment_override_history', 'quote_status_history'
  ]) AS business(table_name)
  WHERE NOT EXISTS (
    SELECT 1
    FROM pg_policy AS policy
    WHERE policy.polrelid = to_regclass('public.' || business.table_name)
      AND policy.polname = 'quote_studio_approved_account_gate'
      AND policy.polpermissive = false
      AND policy.polcmd = '*'
  );
  IF ungated IS NOT NULL THEN
    RAISE EXCEPTION 'Missing restrictive account gates: %', ungated;
  END IF;

  SELECT array_agg(relation.relname ORDER BY relation.relname)
  INTO anonymous_access
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
      OR has_table_privilege('anon', relation.oid, 'REFERENCES')
      OR has_table_privilege('anon', relation.oid, 'TRIGGER')
      OR has_table_privilege('anon', relation.oid, 'MAINTAIN')
    );
  IF anonymous_access IS NOT NULL THEN
    RAISE EXCEPTION 'Anonymous table privileges remain on: %', anonymous_access;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_class AS relation
    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relkind = 'S'
      AND (
        has_sequence_privilege('anon', relation.oid, 'SELECT')
        OR has_sequence_privilege('anon', relation.oid, 'USAGE')
        OR has_sequence_privilege('anon', relation.oid, 'UPDATE')
      )
  ) THEN
    RAISE EXCEPTION 'Anonymous sequence privileges remain in public';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_proc AS routine
    JOIN pg_namespace AS namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public'
      AND has_function_privilege('anon', routine.oid, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'Anonymous function EXECUTE privileges remain in public';
  END IF;
  IF NOT has_column_privilege(
       'authenticated', 'public.profiles', 'full_name', 'UPDATE'
     )
     OR has_column_privilege(
       'authenticated', 'public.profiles', 'role', 'UPDATE'
     )
     OR has_table_privilege('authenticated', 'public.profiles', 'INSERT')
     OR has_table_privilege('authenticated', 'public.profiles', 'DELETE')
     OR has_table_privilege('authenticated', 'public.profiles', 'TRUNCATE') THEN
    RAISE EXCEPTION 'Profiles must allow self full_name updates but prevent role updates';
  END IF;
END;
$table_postconditions$;

COMMENT ON SCHEMA quote_studio_account_private IS
  'Private account approval registry and append-only application audit data.';
COMMENT ON TABLE quote_studio_account_private.account_approvals IS
  'Explicit account approvals independent of public.profiles.role; absent or revoked rows deny business access.';
COMMENT ON TABLE quote_studio_account_private.account_approval_audit IS
  'Approval, revocation, and verified-owner bootstrap audit events; not directly writable by application roles.';

COMMIT;
