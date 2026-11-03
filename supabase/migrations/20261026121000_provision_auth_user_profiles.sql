-- Additive profile provisioning for new Supabase Auth users.
-- Apply only after 20261025234000_protect_profile_role_management.sql.
-- Does not backfill existing auth.users rows or alter existing profiles.
BEGIN;

DO $prerequisites$
DECLARE
  profile_owner oid;
  guard_function oid;
  guard_trigger_count integer;
  auth_user_id_attribute smallint;
  profile_id_attribute smallint;
BEGIN
  IF current_user <> 'postgres' THEN
    RAISE EXCEPTION 'Prerequisite failed: run this migration as postgres';
  END IF;
  IF pg_catalog.to_regclass('auth.users') IS NULL
     OR pg_catalog.to_regclass('public.profiles') IS NULL
     OR pg_catalog.to_regprocedure('auth.uid()') IS NULL
     OR pg_catalog.to_regprocedure('public.profile_role_write_guard()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite failed: expected auth.users, profiles, auth.uid(), and profile_role_write_guard()';
  END IF;

  SELECT relowner INTO profile_owner
  FROM pg_catalog.pg_class
  WHERE oid = 'public.profiles'::pg_catalog.regclass
    AND relkind IN ('r', 'p')
    AND relrowsecurity
    AND NOT relforcerowsecurity;
  IF NOT FOUND OR profile_owner <> 'postgres'::pg_catalog.regrole::oid THEN
    RAISE EXCEPTION 'Prerequisite failed: public.profiles must be postgres-owned, RLS-enabled, and not FORCE RLS';
  END IF;

  guard_function :=
    'public.profile_role_write_guard()'::pg_catalog.regprocedure::oid;
  SELECT count(*) INTO guard_trigger_count
  FROM pg_catalog.pg_trigger
  WHERE tgrelid = 'public.profiles'::pg_catalog.regclass
    AND tgfoid = guard_function
    AND NOT tgisinternal
    AND tgenabled IN ('O', 'A')
    AND (tgtype::integer & 1) = 1
    AND (tgtype::integer & 2) = 2
    AND (tgtype::integer & 4) = 4
    AND (tgtype::integer & 8) = 8
    AND (tgtype::integer & 16) = 16;
  IF guard_trigger_count <> 1 THEN
    RAISE EXCEPTION 'Prerequisite failed: expected one enabled row-level BEFORE INSERT/UPDATE/DELETE profile guard trigger';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS routine
    WHERE routine.oid = guard_function
      AND routine.proowner = 'postgres'::pg_catalog.regrole::oid
      AND routine.prosecdef
      AND EXISTS (
        SELECT 1
        FROM pg_catalog.unnest(routine.proconfig) AS setting(value)
        WHERE pg_catalog.split_part(setting.value, '=', 1) = 'search_path'
          AND pg_catalog.btrim(pg_catalog.split_part(setting.value, '=', 2), '"') = ''
      )
  ) THEN
    RAISE EXCEPTION 'Prerequisite failed: profile_role_write_guard() must be postgres-owned SECURITY DEFINER with an empty search_path';
  END IF;

  SELECT attnum INTO profile_id_attribute
  FROM pg_catalog.pg_attribute
  WHERE attrelid = 'public.profiles'::pg_catalog.regclass
    AND attname = 'id' AND attnum > 0 AND NOT attisdropped;
  SELECT attnum INTO auth_user_id_attribute
  FROM pg_catalog.pg_attribute
  WHERE attrelid = 'auth.users'::pg_catalog.regclass
    AND attname = 'id' AND attnum > 0 AND NOT attisdropped;
  IF profile_id_attribute IS NULL OR auth_user_id_attribute IS NULL OR NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_constraint AS constraint_row
    WHERE constraint_row.conrelid = 'public.profiles'::pg_catalog.regclass
      AND constraint_row.confrelid = 'auth.users'::pg_catalog.regclass
      AND constraint_row.contype = 'f'
      AND constraint_row.conkey = ARRAY[profile_id_attribute]::smallint[]
      AND constraint_row.confkey = ARRAY[auth_user_id_attribute]::smallint[]
      AND constraint_row.confdeltype = 'c'
  ) THEN
    RAISE EXCEPTION 'Prerequisite failed: profiles.id must reference auth.users.id with ON DELETE CASCADE';
  END IF;

  IF pg_catalog.has_table_privilege('service_role', 'public.profiles', 'INSERT')
     OR pg_catalog.has_table_privilege('service_role', 'public.profiles', 'UPDATE')
     OR pg_catalog.has_table_privilege('service_role', 'public.profiles', 'DELETE')
     OR pg_catalog.has_table_privilege('service_role', 'public.profiles', 'TRUNCATE')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'id', 'INSERT')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'full_name', 'INSERT')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'role', 'INSERT')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'created_at', 'INSERT')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'id', 'UPDATE')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'full_name', 'UPDATE')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'role', 'UPDATE')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'created_at', 'UPDATE') THEN
    RAISE EXCEPTION 'Prerequisite failed: service_role profile write/TRUNCATE privileges must remain revoked';
  END IF;

  IF pg_catalog.to_regnamespace('quote_studio_profile_private') IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_namespace
       WHERE nspname = 'quote_studio_profile_private'
         AND nspowner = 'postgres'::pg_catalog.regrole::oid
     ) THEN
    RAISE EXCEPTION 'Prerequisite failed: quote_studio_profile_private already exists with an unexpected owner';
  END IF;
  IF pg_catalog.to_regclass('quote_studio_profile_private.auth_profile_provisioning') IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_class
       WHERE oid = 'quote_studio_profile_private.auth_profile_provisioning'::pg_catalog.regclass
         AND relkind = 'r'
         AND relowner = 'postgres'::pg_catalog.regrole::oid
     ) THEN
    RAISE EXCEPTION 'Prerequisite failed: existing auth_profile_provisioning relation is not a postgres-owned table';
  END IF;
END;
$prerequisites$;

CREATE SCHEMA IF NOT EXISTS quote_studio_profile_private AUTHORIZATION postgres;
ALTER SCHEMA quote_studio_profile_private OWNER TO postgres;
REVOKE ALL ON SCHEMA quote_studio_profile_private
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS quote_studio_profile_private.auth_profile_provisioning (
  user_id uuid NOT NULL,
  backend_pid integer NOT NULL,
  transaction_id bigint NOT NULL,
  PRIMARY KEY (user_id, backend_pid, transaction_id)
);
ALTER TABLE quote_studio_profile_private.auth_profile_provisioning OWNER TO postgres;
ALTER TABLE quote_studio_profile_private.auth_profile_provisioning ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE quote_studio_profile_private.auth_profile_provisioning
  FROM PUBLIC, anon, authenticated, service_role;

-- A one-use marker lets only this SECURITY DEFINER trigger pass the profile
-- guard when the Auth database session is not the trusted postgres session.
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
  auth_profile_provisioned boolean;
BEGIN
  IF TG_OP IN ('INSERT', 'UPDATE') AND (NEW.role IS NULL OR NEW.role NOT IN (
    'owner', 'admin', 'manager', 'supervisor', 'user', 'viewer', 'employee'
  )) THEN
    RAISE EXCEPTION 'Unsupported profile role';
  END IF;

  IF TG_OP = 'INSERT' AND NEW.role = 'user' THEN
    DELETE FROM quote_studio_profile_private.auth_profile_provisioning AS provision
    WHERE provision.user_id = NEW.id
      AND provision.backend_pid = pg_catalog.pg_backend_pid()
      AND provision.transaction_id = pg_catalog.txid_current()
    RETURNING true INTO auth_profile_provisioned;
    IF auth_profile_provisioned THEN
      RETURN NEW;
    END IF;
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
REVOKE ALL ON FUNCTION public.profile_role_write_guard()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.provision_auth_user_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO quote_studio_profile_private.auth_profile_provisioning (
    user_id, backend_pid, transaction_id
  )
  VALUES (
    NEW.id, pg_catalog.pg_backend_pid(), pg_catalog.txid_current()
  );

  INSERT INTO public.profiles (id, full_name, role)
  VALUES (NEW.id, '', 'user')
  ON CONFLICT (id) DO NOTHING;

  DELETE FROM quote_studio_profile_private.auth_profile_provisioning AS provision
  WHERE provision.user_id = NEW.id
    AND provision.backend_pid = pg_catalog.pg_backend_pid()
    AND provision.transaction_id = pg_catalog.txid_current();

  RETURN NEW;
END;
$$;
ALTER FUNCTION public.provision_auth_user_profile() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.provision_auth_user_profile()
  FROM PUBLIC, anon, authenticated, service_role;

DO $auth_trigger$
DECLARE
  auth_users_oid oid := 'auth.users'::pg_catalog.regclass;
  provision_function oid :=
    'public.provision_auth_user_profile()'::pg_catalog.regprocedure::oid;
  existing_trigger pg_catalog.pg_trigger%ROWTYPE;
BEGIN
  SELECT * INTO existing_trigger
  FROM pg_catalog.pg_trigger
  WHERE tgrelid = auth_users_oid
    AND tgname = 'quote_studio_provision_auth_user_profile'
    AND NOT tgisinternal;

  IF FOUND THEN
    IF existing_trigger.tgfoid <> provision_function
       OR existing_trigger.tgtype::integer <> 5
       OR existing_trigger.tgenabled NOT IN ('O', 'A') THEN
      RAISE EXCEPTION 'Conflicting trigger quote_studio_provision_auth_user_profile exists on auth.users';
    END IF;
  ELSE
    IF EXISTS (
      SELECT 1
      FROM pg_catalog.pg_trigger
      WHERE tgrelid = auth_users_oid
        AND tgfoid = provision_function
        AND NOT tgisinternal
    ) THEN
      RAISE EXCEPTION 'Provisioning function is already attached to auth.users under a different trigger name';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM pg_catalog.pg_trigger
      WHERE tgrelid = auth_users_oid
        AND NOT tgisinternal
    ) THEN
      RAISE EXCEPTION 'Unexpected user-defined trigger exists on auth.users; review it before adding profile provisioning';
    END IF;
    EXECUTE 'CREATE TRIGGER quote_studio_provision_auth_user_profile
      AFTER INSERT ON auth.users
      FOR EACH ROW EXECUTE FUNCTION public.provision_auth_user_profile()';
  END IF;
END;
$auth_trigger$;

DO $postconditions$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS marker_table
    WHERE marker_table.oid =
        'quote_studio_profile_private.auth_profile_provisioning'::pg_catalog.regclass
      AND marker_table.relkind = 'r'
      AND marker_table.relowner = 'postgres'::pg_catalog.regrole::oid
      AND marker_table.relrowsecurity
      AND NOT marker_table.relforcerowsecurity
      AND (
        SELECT pg_catalog.array_agg(attribute.attname ORDER BY attribute.attname)
        FROM pg_catalog.pg_attribute AS attribute
        WHERE attribute.attrelid = marker_table.oid
          AND attribute.attnum > 0
          AND NOT attribute.attisdropped
      ) = ARRAY['backend_pid', 'transaction_id', 'user_id']::name[]
      AND EXISTS (
        SELECT 1
        FROM pg_catalog.pg_constraint AS marker_pk
        WHERE marker_pk.conrelid = marker_table.oid
          AND marker_pk.contype = 'p'
          AND marker_pk.conkey = ARRAY[
            (SELECT attribute.attnum FROM pg_catalog.pg_attribute AS attribute
             WHERE attribute.attrelid = marker_table.oid AND attribute.attname = 'user_id'),
            (SELECT attribute.attnum FROM pg_catalog.pg_attribute AS attribute
             WHERE attribute.attrelid = marker_table.oid AND attribute.attname = 'backend_pid'),
            (SELECT attribute.attnum FROM pg_catalog.pg_attribute AS attribute
             WHERE attribute.attrelid = marker_table.oid AND attribute.attname = 'transaction_id')
          ]::smallint[]
      )
  ) THEN
    RAISE EXCEPTION 'Postcondition failed: private marker table shape, owner, or RLS is unsafe';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS routine
    WHERE routine.oid = 'public.profile_role_write_guard()'::pg_catalog.regprocedure
      AND routine.proowner = 'postgres'::pg_catalog.regrole::oid
      AND routine.prosecdef
      AND EXISTS (
        SELECT 1
        FROM pg_catalog.unnest(routine.proconfig) AS setting(value)
        WHERE pg_catalog.split_part(setting.value, '=', 1) = 'search_path'
          AND pg_catalog.btrim(pg_catalog.split_part(setting.value, '=', 2), '"') = ''
      )
      AND NOT pg_catalog.has_function_privilege(
        'anon', routine.oid, 'EXECUTE'
      )
      AND NOT pg_catalog.has_function_privilege(
        'authenticated', routine.oid, 'EXECUTE'
      )
      AND NOT pg_catalog.has_function_privilege(
        'service_role', routine.oid, 'EXECUTE'
      )
  ) THEN
    RAISE EXCEPTION 'Postcondition failed: profile guard ownership, security, search_path, or grants are unsafe';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS routine
    WHERE routine.oid = 'public.provision_auth_user_profile()'::pg_catalog.regprocedure
      AND routine.proowner = 'postgres'::pg_catalog.regrole::oid
      AND routine.prosecdef
      AND EXISTS (
        SELECT 1
        FROM pg_catalog.unnest(routine.proconfig) AS setting(value)
        WHERE pg_catalog.split_part(setting.value, '=', 1) = 'search_path'
          AND pg_catalog.btrim(pg_catalog.split_part(setting.value, '=', 2), '"') = ''
      )
      AND NOT pg_catalog.has_function_privilege(
        'anon', routine.oid, 'EXECUTE'
      )
      AND NOT pg_catalog.has_function_privilege(
        'authenticated', routine.oid, 'EXECUTE'
      )
      AND NOT pg_catalog.has_function_privilege(
        'service_role', routine.oid, 'EXECUTE'
      )
  ) THEN
    RAISE EXCEPTION 'Postcondition failed: provisioning function ownership, security, search_path, or grants are unsafe';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_trigger AS trigger_row
    WHERE trigger_row.tgrelid = 'auth.users'::pg_catalog.regclass
      AND trigger_row.tgname = 'quote_studio_provision_auth_user_profile'
      AND trigger_row.tgfoid = 'public.provision_auth_user_profile()'::pg_catalog.regprocedure
      AND trigger_row.tgtype::integer = 5
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgenabled IN ('O', 'A')
  ) THEN
    RAISE EXCEPTION 'Postcondition failed: expected enabled AFTER INSERT row trigger is missing';
  END IF;

  IF pg_catalog.has_schema_privilege('anon', 'quote_studio_profile_private', 'USAGE')
     OR pg_catalog.has_schema_privilege('authenticated', 'quote_studio_profile_private', 'USAGE')
     OR pg_catalog.has_schema_privilege('service_role', 'quote_studio_profile_private', 'USAGE')
     OR pg_catalog.has_table_privilege('anon', 'quote_studio_profile_private.auth_profile_provisioning', 'SELECT')
     OR pg_catalog.has_table_privilege('anon', 'quote_studio_profile_private.auth_profile_provisioning', 'INSERT')
     OR pg_catalog.has_table_privilege('anon', 'quote_studio_profile_private.auth_profile_provisioning', 'UPDATE')
     OR pg_catalog.has_table_privilege('anon', 'quote_studio_profile_private.auth_profile_provisioning', 'DELETE')
     OR pg_catalog.has_table_privilege('anon', 'quote_studio_profile_private.auth_profile_provisioning', 'TRUNCATE')
     OR pg_catalog.has_table_privilege('authenticated', 'quote_studio_profile_private.auth_profile_provisioning', 'SELECT')
     OR pg_catalog.has_table_privilege('authenticated', 'quote_studio_profile_private.auth_profile_provisioning', 'INSERT')
     OR pg_catalog.has_table_privilege('authenticated', 'quote_studio_profile_private.auth_profile_provisioning', 'UPDATE')
     OR pg_catalog.has_table_privilege('authenticated', 'quote_studio_profile_private.auth_profile_provisioning', 'DELETE')
     OR pg_catalog.has_table_privilege('authenticated', 'quote_studio_profile_private.auth_profile_provisioning', 'TRUNCATE')
     OR pg_catalog.has_table_privilege('service_role', 'quote_studio_profile_private.auth_profile_provisioning', 'SELECT')
     OR pg_catalog.has_table_privilege('service_role', 'quote_studio_profile_private.auth_profile_provisioning', 'INSERT')
     OR pg_catalog.has_table_privilege('service_role', 'quote_studio_profile_private.auth_profile_provisioning', 'UPDATE')
     OR pg_catalog.has_table_privilege('service_role', 'quote_studio_profile_private.auth_profile_provisioning', 'DELETE')
     OR pg_catalog.has_table_privilege('service_role', 'quote_studio_profile_private.auth_profile_provisioning', 'TRUNCATE') THEN
    RAISE EXCEPTION 'Postcondition failed: API roles have access to the private provisioning marker';
  END IF;

  IF pg_catalog.has_table_privilege('service_role', 'public.profiles', 'INSERT')
     OR pg_catalog.has_table_privilege('service_role', 'public.profiles', 'UPDATE')
     OR pg_catalog.has_table_privilege('service_role', 'public.profiles', 'DELETE')
     OR pg_catalog.has_table_privilege('service_role', 'public.profiles', 'TRUNCATE')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'id', 'INSERT')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'full_name', 'INSERT')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'role', 'INSERT')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'created_at', 'INSERT')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'id', 'UPDATE')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'full_name', 'UPDATE')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'role', 'UPDATE')
     OR pg_catalog.has_column_privilege('service_role', 'public.profiles', 'created_at', 'UPDATE') THEN
    RAISE EXCEPTION 'Postcondition failed: service_role profile write/TRUNCATE privileges changed';
  END IF;
END;
$postconditions$;

COMMIT;

-- Read-only verification (run separately after approved execution):
-- SELECT tgname, tgenabled, pg_catalog.pg_get_triggerdef(oid) AS trigger_definition
-- FROM pg_catalog.pg_trigger
-- WHERE tgrelid = 'auth.users'::pg_catalog.regclass
--   AND tgname = 'quote_studio_provision_auth_user_profile'
--   AND NOT tgisinternal;
--
-- SELECT routine.oid::pg_catalog.regprocedure AS function_name,
--        routine.proowner::pg_catalog.regrole AS function_owner,
--        routine.prosecdef AS security_definer,
--        routine.proconfig AS function_settings,
--        pg_catalog.has_function_privilege('anon', routine.oid, 'EXECUTE') AS anon_execute,
--        pg_catalog.has_function_privilege('authenticated', routine.oid, 'EXECUTE') AS authenticated_execute,
--        pg_catalog.has_function_privilege('service_role', routine.oid, 'EXECUTE') AS service_role_execute
-- FROM pg_catalog.pg_proc AS routine
-- WHERE routine.oid = 'public.provision_auth_user_profile()'::pg_catalog.regprocedure;
--
-- SELECT role_name,
--        pg_catalog.has_table_privilege(role_name, 'public.profiles', 'INSERT') AS can_insert,
--        pg_catalog.has_table_privilege(role_name, 'public.profiles', 'UPDATE') AS can_update,
--        pg_catalog.has_table_privilege(role_name, 'public.profiles', 'DELETE') AS can_delete,
--        pg_catalog.has_table_privilege(role_name, 'public.profiles', 'TRUNCATE') AS can_truncate
-- FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) AS roles(role_name);
--
-- Inspect installed Auth triggers before applying on a new target. This
-- migration intentionally aborts if any other user-defined trigger is on
-- auth.users, so existing trigger behavior is not overwritten or duplicated.
--
-- Safe rollback plan (perform only in an approved environment):
-- 1. DROP TRIGGER quote_studio_provision_auth_user_profile ON auth.users;
-- 2. Restore public.profile_role_write_guard() verbatim from
--    20261025234000_protect_profile_role_management.sql, then retain its
--    postgres ownership, SECURITY DEFINER, empty search_path, and revoked grants.
-- 3. DROP FUNCTION public.provision_auth_user_profile();
-- 4. After confirming the private marker table is empty, DROP TABLE
--    quote_studio_profile_private.auth_profile_provisioning and DROP SCHEMA
--    quote_studio_profile_private.
-- 5. Do not delete profile rows during rollback; this migration does not backfill.
