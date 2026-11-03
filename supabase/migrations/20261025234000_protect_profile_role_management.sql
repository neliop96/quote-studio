-- Local staging proposal only. Apply after the existing 20261025233000 migration.
BEGIN;

DO $prerequisites$
DECLARE
  invalid_role text;
BEGIN
  IF current_user <> 'postgres' THEN
    RAISE EXCEPTION 'Prerequisite failed: run this migration as postgres';
  END IF;
  IF pg_catalog.to_regclass('public.profiles') IS NULL
     OR pg_catalog.to_regprocedure('auth.uid()') IS NULL
     OR pg_catalog.to_regprocedure('auth.jwt()') IS NULL
     OR pg_catalog.to_regprocedure('public.is_admin()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite failed: expected profiles, auth.uid(), auth.jwt(), and is_admin()';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class
    WHERE oid = 'public.profiles'::pg_catalog.regclass
      AND relrowsecurity
      AND NOT relforcerowsecurity
      AND relowner = 'postgres'::pg_catalog.regrole::oid
  ) THEN
    RAISE EXCEPTION 'Prerequisite failed: public.profiles must be postgres-owned, RLS-enabled, and not FORCE RLS';
  END IF;

  SELECT profile.role INTO invalid_role
  FROM public.profiles AS profile
  WHERE profile.role NOT IN (
    'owner', 'admin', 'manager', 'supervisor', 'user', 'viewer', 'employee'
  )
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Prerequisite failed: unsupported existing profile role %', invalid_role;
  END IF;
END;
$prerequisites$;

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_role_check;
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_role_check CHECK (
    role IN ('owner', 'admin', 'manager', 'supervisor', 'user', 'viewer', 'employee')
  );

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('owner', 'admin')
  );
$$;
ALTER FUNCTION public.is_admin() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_delete_quote(p_quote uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin permission required';
  END IF;
  IF p_quote IS NULL THEN RAISE EXCEPTION 'Quotation ID required'; END IF;
  DELETE FROM public.quotes WHERE id = p_quote;
  IF NOT FOUND THEN RAISE EXCEPTION 'Quotation not found'; END IF;
END;
$$;
ALTER FUNCTION public.admin_delete_quote(uuid) OWNER TO postgres;

CREATE OR REPLACE FUNCTION public.profile_role_write_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  actor_id uuid := auth.uid();
  request_role text := coalesce(auth.jwt() ->> 'role', '');
  actor_role text;
BEGIN
  IF TG_OP IN ('INSERT', 'UPDATE') AND (NEW.role IS NULL OR NEW.role NOT IN (
    'owner', 'admin', 'manager', 'supervisor', 'user', 'viewer', 'employee'
  )) THEN
    RAISE EXCEPTION 'Unsupported profile role';
  END IF;

  IF session_user = 'postgres' THEN
    IF TG_OP = 'UPDATE' AND NEW.id IS DISTINCT FROM OLD.id THEN
      RAISE EXCEPTION 'Profile user ID cannot be changed';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF actor_id IS NULL THEN
    RAISE EXCEPTION 'Authenticated profile operation or trusted postgres maintenance required'
      USING ERRCODE = '42501';
  END IF;
  IF request_role <> 'authenticated' THEN
    RAISE EXCEPTION 'Authenticated profile operation required' USING ERRCODE = '42501';
  END IF;

  SELECT profile.role INTO actor_role
  FROM public.profiles AS profile
  WHERE profile.id = actor_id;

  IF TG_OP = 'INSERT' THEN
    IF NEW.id = actor_id THEN
      RAISE EXCEPTION 'Users cannot create their own profile';
    END IF;
    IF actor_role IS NULL OR actor_role NOT IN ('owner', 'admin') THEN
      RAISE EXCEPTION 'Profile management permission required' USING ERRCODE = '42501';
    END IF;
    IF NEW.role IN ('owner', 'admin') AND actor_role IS DISTINCT FROM 'owner' THEN
      RAISE EXCEPTION 'Only an owner may create a privileged profile' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.id IS DISTINCT FROM OLD.id THEN
      RAISE EXCEPTION 'Profile user ID cannot be changed';
    END IF;
    IF NEW.id = actor_id AND NEW.role IS DISTINCT FROM OLD.role THEN
      RAISE EXCEPTION 'Users cannot change their own role' USING ERRCODE = '42501';
    END IF;
    IF OLD.role = 'owner' AND actor_role IS DISTINCT FROM 'owner' THEN
      RAISE EXCEPTION 'Only an owner may modify an owner profile' USING ERRCODE = '42501';
    END IF;
    IF NEW.id <> actor_id
       AND (OLD.role IN ('owner', 'admin') OR NEW.role IN ('owner', 'admin'))
      AND actor_role IS DISTINCT FROM 'owner' THEN
      RAISE EXCEPTION 'Only an owner may modify privileged profiles' USING ERRCODE = '42501';
    END IF;
    IF (actor_role IS NULL OR actor_role NOT IN ('owner', 'admin'))
       AND NEW.id <> actor_id THEN
      RAISE EXCEPTION 'Profile management permission required' USING ERRCODE = '42501';
    END IF;
    IF OLD.role = 'owner' AND NEW.role <> 'owner'
       AND (SELECT count(*) FROM public.profiles WHERE role = 'owner') <= 1 THEN
      RAISE EXCEPTION 'At least one owner profile must remain';
    END IF;
    RETURN NEW;
  ELSE
    IF OLD.id = actor_id THEN
      RAISE EXCEPTION 'Users cannot delete their own profile' USING ERRCODE = '42501';
    END IF;
    IF actor_role IS NULL OR actor_role NOT IN ('owner', 'admin') THEN
      RAISE EXCEPTION 'Profile management permission required' USING ERRCODE = '42501';
    END IF;
    IF OLD.role IN ('owner', 'admin') AND actor_role IS DISTINCT FROM 'owner' THEN
      RAISE EXCEPTION 'Only an owner may delete a privileged profile' USING ERRCODE = '42501';
    END IF;
    IF OLD.role = 'owner'
       AND (SELECT count(*) FROM public.profiles WHERE role = 'owner') <= 1 THEN
      RAISE EXCEPTION 'At least one owner profile must remain';
    END IF;
    RETURN OLD;
  END IF;
END;
$$;
ALTER FUNCTION public.profile_role_write_guard() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.profile_role_write_guard() FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS profile_role_write_guard ON public.profiles;
CREATE TRIGGER profile_role_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.profile_role_write_guard();

CREATE OR REPLACE FUNCTION public.manage_profile(
  p_user uuid, p_full_name text, p_role text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  actor_id uuid := auth.uid();
  request_role text := coalesce(auth.jwt() ->> 'role', '');
  actor_role text;
  existing_role text;
BEGIN
  IF actor_id IS NULL OR request_role <> 'authenticated' THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_user IS NULL OR p_full_name IS NULL OR p_role IS NULL OR p_role NOT IN (
    'owner', 'admin', 'manager', 'supervisor', 'user', 'viewer', 'employee'
  ) THEN
    RAISE EXCEPTION 'Valid user, name, and profile role required';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(73001, 1);

  SELECT profile.role INTO actor_role
  FROM public.profiles AS profile
  WHERE profile.id = actor_id
  FOR SHARE;
  IF actor_role IS NULL OR actor_role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'Profile management permission required' USING ERRCODE = '42501';
  END IF;

  SELECT profile.role INTO existing_role
  FROM public.profiles AS profile
  WHERE profile.id = p_user
  FOR UPDATE;

  IF NOT FOUND THEN
    IF p_user = actor_id THEN
      RAISE EXCEPTION 'Users cannot create their own profile' USING ERRCODE = '42501';
    END IF;
    IF p_role IN ('owner', 'admin') AND actor_role IS DISTINCT FROM 'owner' THEN
      RAISE EXCEPTION 'Only an owner may create a privileged profile' USING ERRCODE = '42501';
    END IF;
    INSERT INTO public.profiles(id, full_name, role)
    VALUES (p_user, p_full_name, p_role);
    RETURN;
  END IF;

  IF p_user = actor_id AND p_role IS DISTINCT FROM existing_role THEN
    RAISE EXCEPTION 'Users cannot change their own role' USING ERRCODE = '42501';
  END IF;
  IF existing_role = 'owner' AND actor_role IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Only an owner may modify an owner profile' USING ERRCODE = '42501';
  END IF;
  IF p_user <> actor_id
     AND (existing_role IN ('owner', 'admin') OR p_role IN ('owner', 'admin'))
    AND actor_role IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Only an owner may modify privileged profiles' USING ERRCODE = '42501';
  END IF;
  IF existing_role = 'owner' AND p_role <> 'owner'
     AND (SELECT count(*) FROM public.profiles WHERE role = 'owner') <= 1 THEN
    RAISE EXCEPTION 'At least one owner profile must remain';
  END IF;

  UPDATE public.profiles
  SET full_name = p_full_name, role = p_role
  WHERE id = p_user;
END;
$$;
ALTER FUNCTION public.manage_profile(uuid, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.manage_profile(uuid, text, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.manage_profile(uuid, text, text) TO authenticated;

DROP POLICY IF EXISTS "admin manage profiles" ON public.profiles;
DROP POLICY IF EXISTS "profile update own or admin" ON public.profiles;
DROP POLICY IF EXISTS "profile update own" ON public.profiles;
CREATE POLICY "profile update own" ON public.profiles
FOR UPDATE TO authenticated
USING (id = auth.uid())
WITH CHECK (id = auth.uid());
DROP POLICY IF EXISTS "profile updates restricted to self" ON public.profiles;
CREATE POLICY "profile updates restricted to self" ON public.profiles
AS RESTRICTIVE FOR UPDATE TO authenticated
USING (id = auth.uid())
WITH CHECK (id = auth.uid());

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.profiles
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE INSERT (id, full_name, role, created_at), UPDATE (id, full_name, role, created_at)
  ON TABLE public.profiles FROM PUBLIC, anon, authenticated, service_role;
GRANT UPDATE (full_name) ON TABLE public.profiles TO authenticated;

CREATE OR REPLACE FUNCTION public.set_stock_movement_archived(p_movement uuid, p_archived boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin permission required';
  END IF;
  IF p_archived IS NULL THEN RAISE EXCEPTION 'Archive flag required'; END IF;
  UPDATE public.stock_movements
  SET archived_at = CASE WHEN p_archived THEN now() ELSE NULL END,
      archived_by = CASE WHEN p_archived THEN auth.uid() ELSE NULL END
  WHERE id = p_movement;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory movement not found'; END IF;
END;
$$;
ALTER FUNCTION public.set_stock_movement_archived(uuid, boolean) OWNER TO postgres;

CREATE OR REPLACE FUNCTION public.save_estimate_number_settings(
  p_prefix text, p_serial_width integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  settings jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin required to change estimate numbering';
  END IF;
  p_prefix := upper(trim(p_prefix));
  IF p_prefix !~ '^[A-Z][A-Z0-9]{0,11}$' THEN
    RAISE EXCEPTION 'Prefix must start with a letter and contain only letters and numbers';
  END IF;
  IF p_serial_width IS NULL OR p_serial_width NOT BETWEEN 1 AND 8 THEN
    RAISE EXCEPTION 'Serial number digits must be between 1 and 8';
  END IF;
  UPDATE public.estimate_number_settings
  SET prefix = p_prefix, serial_width = p_serial_width
  WHERE id = 1
  RETURNING jsonb_build_object(
    'prefix', prefix, 'serial_width', serial_width, 'next_serial', next_serial
  ) INTO settings;
  RETURN settings;
END;
$$;
ALTER FUNCTION public.save_estimate_number_settings(text, integer) OWNER TO postgres;

CREATE OR REPLACE FUNCTION public.get_shift_alert_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT jsonb_build_object(
    'available_roles', coalesce((
      SELECT jsonb_agg(roles.role ORDER BY roles.role)
      FROM (
        SELECT DISTINCT profile.role::text AS role
        FROM public.profiles AS profile
        WHERE profile.role IS NOT NULL
          AND profile.role::text NOT IN ('owner', 'admin')
      ) AS roles
    ), '[]'::jsonb),
    'recipient_roles', coalesce(to_jsonb(settings.recipient_roles), '[]'::jsonb)
  )
  INTO result
  FROM public.shift_alert_settings AS settings
  WHERE settings.id = 1;
  IF result IS NULL THEN RAISE EXCEPTION 'Shift handoff alert settings are not initialized'; END IF;
  RETURN result;
END;
$$;
ALTER FUNCTION public.get_shift_alert_settings() OWNER TO postgres;

CREATE OR REPLACE FUNCTION public.save_shift_alert_settings(p_roles text[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  normalized_roles text[];
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin required to change handoff alert recipients';
  END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(coalesce(p_roles, array[]::text[])) AS requested(role)
    WHERE requested.role IS NULL OR length(trim(requested.role)) = 0
      OR trim(requested.role) IN ('owner', 'admin')
  ) THEN
    RAISE EXCEPTION 'Choose valid employee roles';
  END IF;
  SELECT coalesce(
    array_agg(DISTINCT trim(requested.role) ORDER BY trim(requested.role)),
    array[]::text[]
  ) INTO normalized_roles
  FROM unnest(coalesce(p_roles, array[]::text[])) AS requested(role);
  IF EXISTS (
    SELECT 1 FROM unnest(normalized_roles) AS requested(role)
    WHERE NOT EXISTS (
      SELECT 1 FROM public.profiles AS profile
      WHERE profile.role::text = requested.role
        AND profile.role::text NOT IN ('owner', 'admin')
    )
  ) THEN
    RAISE EXCEPTION 'Recipients must be roles currently assigned to employees';
  END IF;
  UPDATE public.shift_alert_settings
  SET recipient_roles = normalized_roles, updated_by = auth.uid(), updated_at = now()
  WHERE id = 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'Shift handoff alert settings are not initialized'; END IF;
  RETURN jsonb_build_object('recipient_roles', normalized_roles);
END;
$$;
ALTER FUNCTION public.save_shift_alert_settings(text[]) OWNER TO postgres;

CREATE OR REPLACE FUNCTION public.create_shift_alerts_for_submitted_report()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  recipient_roles text[];
  handoff_task record;
BEGIN
  IF NEW.status <> 'submitted' OR OLD.status = 'submitted' THEN RETURN NEW; END IF;
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF NEW.created_by <> auth.uid() AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only the report creator or an administrator can submit this report';
  END IF;
  SELECT settings.recipient_roles INTO recipient_roles
  FROM public.shift_alert_settings AS settings WHERE settings.id = 1;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(NEW.tasks) AS task(value)
    WHERE length(trim(coalesce(task.value ->> 'notes', ''))) > 0
  ) AND coalesce(cardinality(recipient_roles), 0) = 0 THEN
    RAISE EXCEPTION 'An administrator must select handoff alert recipients before submitting reports with notes';
  END IF;
  FOR handoff_task IN
    SELECT task.value, task.ordinality - 1 AS task_index
    FROM jsonb_array_elements(NEW.tasks) WITH ORDINALITY AS task(value, ordinality)
    WHERE length(trim(coalesce(task.value ->> 'notes', ''))) > 0
  LOOP
    INSERT INTO public.shift_alerts (
      report_id, task_index, recipient_role, task_title, handoff_note
    )
    SELECT NEW.id, handoff_task.task_index::integer, recipient.role,
      handoff_task.value ->> 'title', trim(handoff_task.value ->> 'notes')
    FROM unnest(recipient_roles) AS recipient(role);
  END LOOP;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.create_shift_alerts_for_submitted_report() OWNER TO postgres;

DO $function_acl_assertions$
BEGIN
  IF pg_catalog.has_function_privilege('anon', 'public.manage_profile(uuid,text,text)'::regprocedure, 'EXECUTE')
     OR pg_catalog.has_function_privilege('service_role', 'public.manage_profile(uuid,text,text)'::regprocedure, 'EXECUTE')
      OR pg_catalog.has_function_privilege('anon', 'public.profile_role_write_guard()'::regprocedure, 'EXECUTE')
      OR pg_catalog.has_function_privilege('anon', 'public.is_admin()'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'Unexpected anon/service_role profile-management execution remains effective';
  END IF;
    IF NOT pg_catalog.has_function_privilege('authenticated', 'public.manage_profile(uuid,text,text)'::regprocedure, 'EXECUTE')
      OR pg_catalog.has_function_privilege('authenticated', 'public.profile_role_write_guard()'::regprocedure, 'EXECUTE')
      OR pg_catalog.has_function_privilege('service_role', 'public.profile_role_write_guard()'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'Profile-management RPC grants are missing or trigger function is executable';
  END IF;
END;
$function_acl_assertions$;

DROP POLICY IF EXISTS "Project creators and admins can delete projects" ON public.projects;
CREATE POLICY "Project creators and admins can delete projects"
ON public.projects FOR DELETE TO authenticated
USING (created_by = auth.uid() OR public.is_admin());

DROP POLICY IF EXISTS "Admins insert quotation defaults" ON public.quote_settings;
CREATE POLICY "Admins insert quotation defaults" ON public.quote_settings
AS PERMISSIVE FOR INSERT TO authenticated
WITH CHECK (public.is_admin());
DROP POLICY IF EXISTS "Admins update quotation defaults" ON public.quote_settings;
CREATE POLICY "Admins update quotation defaults" ON public.quote_settings
AS PERMISSIVE FOR UPDATE TO authenticated
USING (public.is_admin()) WITH CHECK (public.is_admin());
DROP POLICY IF EXISTS "Team members read quotation defaults" ON public.quote_settings;
CREATE POLICY "Team members read quotation defaults" ON public.quote_settings
AS PERMISSIVE FOR SELECT TO authenticated
USING (
  public.is_admin()
  OR EXISTS (
    SELECT 1 FROM public.profiles AS profile
    WHERE profile.id = auth.uid()
      AND profile.role IN ('manager', 'supervisor', 'user', 'viewer', 'employee')
  )
);

DO $role_acl_assertions$
DECLARE
  quote_read_policy text;
BEGIN
  IF pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'INSERT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'DELETE')
     OR pg_catalog.has_column_privilege('authenticated', 'public.profiles', 'role', 'UPDATE')
     OR pg_catalog.has_column_privilege('authenticated', 'public.profiles', 'id', 'UPDATE')
     OR pg_catalog.has_column_privilege('authenticated', 'public.profiles', 'created_at', 'UPDATE')
     OR pg_catalog.has_table_privilege('anon', 'public.profiles', 'INSERT')
     OR pg_catalog.has_table_privilege('anon', 'public.profiles', 'UPDATE')
    OR pg_catalog.has_table_privilege('anon', 'public.profiles', 'DELETE')
    OR pg_catalog.has_table_privilege('anon', 'public.profiles', 'TRUNCATE')
    OR pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'TRUNCATE')
    OR pg_catalog.has_table_privilege('service_role', 'public.profiles', 'INSERT')
    OR pg_catalog.has_table_privilege('service_role', 'public.profiles', 'UPDATE')
    OR pg_catalog.has_table_privilege('service_role', 'public.profiles', 'DELETE')
    OR pg_catalog.has_table_privilege('service_role', 'public.profiles', 'TRUNCATE')
    OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'id', 'INSERT')
    OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'role', 'INSERT')
    OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'id', 'UPDATE')
    OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'role', 'UPDATE')
    OR pg_catalog.has_column_privilege('anon', 'public.profiles', 'role', 'UPDATE') THEN
    RAISE EXCEPTION 'Unsafe direct profile table privileges remain effective';
  END IF;
  IF NOT pg_catalog.has_column_privilege('authenticated', 'public.profiles', 'full_name', 'UPDATE')
     OR NOT pg_catalog.has_function_privilege('authenticated', 'public.is_admin()'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'Safe profile update or is_admin policy execution is unavailable';
  END IF;
  IF pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'SELECT') IS FALSE THEN
    RAISE EXCEPTION 'Authenticated profile SELECT privilege is unavailable';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_policy
    WHERE polrelid = 'public.profiles'::pg_catalog.regclass
      AND polname = 'profile read own or admin'
      AND polcmd = 'r'
      AND polroles @> ARRAY['authenticated'::pg_catalog.regrole::oid]
      AND pg_catalog.pg_get_expr(polqual, polrelid) ILIKE '%auth.uid%'
      AND pg_catalog.pg_get_expr(polqual, polrelid) ILIKE '%is_admin%'
  ) THEN
    RAISE EXCEPTION 'Expected authenticated own/admin profile SELECT policy is missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_policy
    WHERE polrelid = 'public.profiles'::pg_catalog.regclass
      AND polname = 'profile update own'
      AND polcmd = 'w'
      AND pg_catalog.pg_get_expr(polqual, polrelid) ILIKE '%auth.uid%'
      AND pg_catalog.pg_get_expr(polqual, polrelid) ILIKE '%id%'
      AND pg_catalog.pg_get_expr(polwithcheck, polrelid) ILIKE '%auth.uid%'
      AND pg_catalog.pg_get_expr(polwithcheck, polrelid) ILIKE '%id%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_policy
    WHERE polrelid = 'public.profiles'::pg_catalog.regclass
      AND polname = 'profile updates restricted to self'
      AND polcmd = 'w'
      AND NOT polpermissive
  ) THEN
    RAISE EXCEPTION 'Expected self-only profile UPDATE policies are missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_trigger AS tg
    JOIN pg_catalog.pg_proc AS proc ON proc.oid = tg.tgfoid
    WHERE tg.tgrelid = 'public.profiles'::pg_catalog.regclass
      AND tg.tgfoid = 'public.profile_role_write_guard()'::pg_catalog.regprocedure
      AND NOT tg.tgisinternal
      AND tg.tgenabled IN ('O', 'A')
      AND proc.proowner = 'postgres'::pg_catalog.regrole::oid
      AND proc.prosecdef
      AND EXISTS (
        SELECT 1
        FROM pg_catalog.unnest(proc.proconfig) AS setting(value)
        WHERE pg_catalog.split_part(setting.value, '=', 1) = 'search_path'
          AND pg_catalog.btrim(pg_catalog.split_part(setting.value, '=', 2), '"') = ''
      )
  ) THEN
    RAISE EXCEPTION 'Expected enabled postgres-owned SECURITY DEFINER profile guard trigger is missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS proc
    WHERE proc.oid = 'public.manage_profile(uuid,text,text)'::pg_catalog.regprocedure
      AND proc.proowner = 'postgres'::pg_catalog.regrole::oid
      AND proc.prosecdef
      AND EXISTS (
        SELECT 1
        FROM pg_catalog.unnest(proc.proconfig) AS setting(value)
        WHERE pg_catalog.split_part(setting.value, '=', 1) = 'search_path'
          AND pg_catalog.btrim(pg_catalog.split_part(setting.value, '=', 2), '"') = ''
      )
  ) THEN
    RAISE EXCEPTION 'Expected postgres-owned SECURITY DEFINER manage_profile with empty search_path';
  END IF;

  SELECT pg_catalog.pg_get_expr(policy.polqual, policy.polrelid)
  INTO quote_read_policy
  FROM pg_catalog.pg_policy AS policy
  WHERE policy.polrelid = 'public.quote_settings'::pg_catalog.regclass
    AND policy.polname = 'Team members read quotation defaults'
    AND policy.polcmd = 'r';
  IF quote_read_policy IS NULL
     OR quote_read_policy NOT ILIKE '%manager%'
     OR quote_read_policy NOT ILIKE '%supervisor%'
     OR quote_read_policy NOT ILIKE '%user%'
     OR quote_read_policy NOT ILIKE '%viewer%'
     OR quote_read_policy NOT ILIKE '%employee%' THEN
    RAISE EXCEPTION 'Quote-default SELECT policy does not cover all supported non-admin roles';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_policy AS policy
    WHERE policy.polrelid = 'public.quote_settings'::pg_catalog.regclass
      AND policy.polpermissive
      AND policy.polcmd IN ('a', 'w')
      AND policy.polname NOT IN (
        'Admins insert quotation defaults', 'Admins update quotation defaults'
      )
  ) THEN
    RAISE EXCEPTION 'Unexpected permissive quote-default write policy exists';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_policy AS policy
    WHERE policy.polrelid = 'public.quote_settings'::pg_catalog.regclass
      AND policy.polname = 'Admins insert quotation defaults'
      AND policy.polcmd = 'a'
      AND policy.polpermissive
      AND pg_catalog.pg_get_expr(policy.polwithcheck, policy.polrelid) ILIKE '%is_admin%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_policy AS policy
    WHERE policy.polrelid = 'public.quote_settings'::pg_catalog.regclass
      AND policy.polname = 'Admins update quotation defaults'
      AND policy.polcmd = 'w'
      AND policy.polpermissive
      AND pg_catalog.pg_get_expr(policy.polqual, policy.polrelid) ILIKE '%is_admin%'
      AND pg_catalog.pg_get_expr(policy.polwithcheck, policy.polrelid) ILIKE '%is_admin%'
  ) THEN
    RAISE EXCEPTION 'Quote-default writes are not restricted to owner/admin';
  END IF;
END;
$role_acl_assertions$;

COMMIT;