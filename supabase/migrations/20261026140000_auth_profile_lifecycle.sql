-- Quote Studio - STAGING ONLY.
-- Installs default profile provisioning and guarded Auth deletion lifecycle.
-- Review and test only against the isolated staging project. Do not apply to
-- Production. No existing users are backfilled or deleted.
--
-- This supersedes the unexecuted local proposal
-- 20261026121000_provision_auth_user_profiles.sql. That proposal creates
-- incompatible marker objects; this migration deliberately fails if they exist.
BEGIN;

DO $prerequisites$
DECLARE
  role_name text;
  role_oid oid;
  profile_guard_oid oid;
  profile_trigger_count integer;
  auth_trigger_count integer;
  profile_id_attnum smallint;
  auth_id_attnum smallint;
BEGIN
  IF current_user <> 'postgres' THEN
    RAISE EXCEPTION 'Prerequisite failed: run this migration as postgres';
  END IF;
  IF current_setting('server_version_num')::integer < 130000 THEN
    RAISE EXCEPTION 'Prerequisite failed: PostgreSQL 13 or newer is required for xid8';
  END IF;
  IF pg_catalog.to_regclass('auth.users') IS NULL
     OR pg_catalog.to_regclass('public.profiles') IS NULL
     OR pg_catalog.to_regprocedure('auth.uid()') IS NULL
     OR pg_catalog.to_regprocedure('auth.jwt()') IS NULL
     OR pg_catalog.to_regprocedure('public.profile_role_write_guard()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite failed: expected Auth users, auth.uid(), auth.jwt(), profiles, and the existing profile guard';
  END IF;

  IF pg_catalog.to_regnamespace('quote_studio_profile_private') IS NOT NULL
     OR pg_catalog.to_regprocedure(
       'public.provision_auth_user_profile()'
     ) IS NOT NULL
     OR pg_catalog.to_regprocedure(
       'public.delete_auth_user_profile()'
     ) IS NOT NULL
     OR pg_catalog.to_regprocedure(
       'quote_studio_profile_private.provision_auth_user_profile()'
     ) IS NOT NULL
     OR pg_catalog.to_regprocedure(
       'quote_studio_profile_private.delete_auth_user_profile()'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'Prerequisite failed: lifecycle helper objects already exist; reconcile them before applying';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS profiles
    WHERE profiles.oid = 'public.profiles'::pg_catalog.regclass
      AND profiles.relkind IN ('r', 'p')
      AND profiles.relowner = 'postgres'::pg_catalog.regrole::oid
      AND profiles.relrowsecurity
      AND NOT profiles.relforcerowsecurity
  ) THEN
    RAISE EXCEPTION 'Prerequisite failed: profiles must be a postgres-owned table with RLS enabled and not forced';
  END IF;

  profile_guard_oid :=
    'public.profile_role_write_guard()'::pg_catalog.regprocedure::oid;
  SELECT count(*) INTO profile_trigger_count
  FROM pg_catalog.pg_trigger
  WHERE tgrelid = 'public.profiles'::pg_catalog.regclass
    AND NOT tgisinternal;
  IF profile_trigger_count <> 1 OR NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_trigger AS trigger_row
    JOIN pg_catalog.pg_proc AS routine ON routine.oid = trigger_row.tgfoid
    WHERE trigger_row.tgrelid = 'public.profiles'::pg_catalog.regclass
      AND trigger_row.tgfoid = profile_guard_oid
      AND trigger_row.tgtype::integer = 31
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgenabled IN ('O', 'A')
      AND routine.proowner = 'postgres'::pg_catalog.regrole::oid
      AND routine.prosecdef
      AND EXISTS (
        SELECT 1
        FROM pg_catalog.unnest(routine.proconfig) AS setting(value)
        WHERE pg_catalog.split_part(setting.value, '=', 1) = 'search_path'
          AND pg_catalog.btrim(
            pg_catalog.split_part(setting.value, '=', 2), '"'
          ) = ''
      )
  ) THEN
    RAISE EXCEPTION 'Prerequisite failed: the only custom profiles trigger must be the enabled postgres-owned SECURITY DEFINER BEFORE INSERT/UPDATE/DELETE profile guard with empty search_path';
  END IF;

  SELECT count(*) INTO auth_trigger_count
  FROM pg_catalog.pg_trigger
  WHERE tgrelid = 'auth.users'::pg_catalog.regclass
    AND NOT tgisinternal;
  IF auth_trigger_count <> 0 THEN
    RAISE EXCEPTION 'Prerequisite failed: unexpected custom auth.users trigger exists; inspect its behavior and ordering first';
  END IF;

  SELECT attnum INTO profile_id_attnum
  FROM pg_catalog.pg_attribute
  WHERE attrelid = 'public.profiles'::pg_catalog.regclass
    AND attname = 'id' AND atttypid = 'uuid'::pg_catalog.regtype
    AND attnum > 0 AND NOT attisdropped;
  SELECT attnum INTO auth_id_attnum
  FROM pg_catalog.pg_attribute
  WHERE attrelid = 'auth.users'::pg_catalog.regclass
    AND attname = 'id' AND atttypid = 'uuid'::pg_catalog.regtype
    AND attnum > 0 AND NOT attisdropped;
  IF profile_id_attnum IS NULL OR auth_id_attnum IS NULL OR (
    SELECT count(*)
    FROM pg_catalog.pg_constraint AS constraint_row
    WHERE constraint_row.conrelid = 'public.profiles'::pg_catalog.regclass
      AND constraint_row.confrelid = 'auth.users'::pg_catalog.regclass
      AND constraint_row.contype = 'f'
      AND constraint_row.conkey = ARRAY[profile_id_attnum]::smallint[]
      AND constraint_row.confkey = ARRAY[auth_id_attnum]::smallint[]
      AND constraint_row.confdeltype = 'c'
      AND NOT constraint_row.condeferrable
      AND constraint_row.convalidated
  ) <> 1 THEN
    RAISE EXCEPTION 'Prerequisite failed: profiles.id must have one validated, non-deferrable ON DELETE CASCADE foreign key to auth.users.id';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_attribute AS attribute
    WHERE attribute.attrelid = 'public.profiles'::pg_catalog.regclass
      AND attribute.attname = 'full_name'
      AND attribute.atttypid = 'text'::pg_catalog.regtype
      AND attribute.attnotnull
      AND attribute.attnum > 0
      AND NOT attribute.attisdropped
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_attribute AS attribute
    WHERE attribute.attrelid = 'public.profiles'::pg_catalog.regclass
      AND attribute.attname = 'role'
      AND attribute.atttypid = 'text'::pg_catalog.regtype
      AND attribute.attnotnull
      AND attribute.attnum > 0
      AND NOT attribute.attisdropped
  ) THEN
    RAISE EXCEPTION 'Prerequisite failed: profiles.full_name and profiles.role must be non-null text columns';
  END IF;

  FOREACH role_name IN ARRAY ARRAY[
    'anon', 'authenticated', 'service_role', 'supabase_auth_admin'
  ] LOOP
    role_oid := pg_catalog.to_regrole(role_name);
    IF role_oid IS NULL THEN
      RAISE EXCEPTION 'Prerequisite failed: required Supabase role % is missing', role_name;
    END IF;
    IF pg_catalog.has_table_privilege(role_oid, 'public.profiles', 'INSERT')
       OR pg_catalog.has_table_privilege(role_oid, 'public.profiles', 'UPDATE')
       OR pg_catalog.has_table_privilege(role_oid, 'public.profiles', 'DELETE')
       OR pg_catalog.has_table_privilege(role_oid, 'public.profiles', 'TRUNCATE')
       OR EXISTS (
         SELECT 1
         FROM pg_catalog.pg_attribute AS attribute
         WHERE attribute.attrelid = 'public.profiles'::pg_catalog.regclass
           AND attribute.attnum > 0
           AND NOT attribute.attisdropped
           AND (
             pg_catalog.has_column_privilege(
               role_oid, 'public.profiles'::pg_catalog.regclass,
               attribute.attname, 'INSERT'
             )
             OR (
               pg_catalog.has_column_privilege(
                 role_oid, 'public.profiles'::pg_catalog.regclass,
                 attribute.attname, 'UPDATE'
               )
               AND NOT (
                 role_name = 'authenticated'
                 AND attribute.attname = 'full_name'
               )
             )
           )
       ) THEN
      RAISE EXCEPTION 'Prerequisite failed: role % has effective profile write/TRUNCATE privileges', role_name;
    END IF;
  END LOOP;
  IF NOT pg_catalog.has_column_privilege(
    'authenticated', 'public.profiles'::pg_catalog.regclass,
    'full_name', 'UPDATE'
  ) THEN
    RAISE EXCEPTION 'Prerequisite failed: authenticated must retain UPDATE(full_name) for self-profile edits';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_trigger AS trigger_row
    WHERE trigger_row.tgrelid = 'auth.users'::pg_catalog.regclass
      AND trigger_row.tgname IN (
        'quote_studio_auth_profile_after_insert',
        'quote_studio_auth_profile_before_delete'
      )
  ) THEN
    RAISE EXCEPTION 'Prerequisite failed: a lifecycle trigger name is already in use';
  END IF;
END;
$prerequisites$;

CREATE SCHEMA quote_studio_profile_private AUTHORIZATION postgres;
ALTER SCHEMA quote_studio_profile_private OWNER TO postgres;
REVOKE ALL ON SCHEMA quote_studio_profile_private
  FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;

CREATE TABLE quote_studio_profile_private.auth_profile_lifecycle_marker (
  user_id uuid NOT NULL,
  operation text NOT NULL
    CONSTRAINT auth_profile_lifecycle_marker_operation_check
    CHECK (operation IN ('insert', 'delete')),
  backend_pid integer NOT NULL,
  transaction_id xid8 NOT NULL,
  expected_trigger_depth integer NOT NULL
    CONSTRAINT auth_profile_lifecycle_marker_depth_check
    CHECK (expected_trigger_depth = 2),
  CONSTRAINT auth_profile_lifecycle_marker_pkey
    PRIMARY KEY (user_id, operation, backend_pid, transaction_id)
);
ALTER TABLE quote_studio_profile_private.auth_profile_lifecycle_marker
  OWNER TO postgres;
ALTER TABLE quote_studio_profile_private.auth_profile_lifecycle_marker
  ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE quote_studio_profile_private.auth_profile_lifecycle_marker
  FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;

-- Add only the private, exact-operation marker exception. All existing
-- owner/admin, self-update, and trusted-postgres checks remain unchanged.
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
  lifecycle_operation text;
BEGIN
  IF TG_OP IN ('INSERT', 'UPDATE') AND (NEW.role IS NULL OR NEW.role NOT IN (
    'owner', 'admin', 'manager', 'supervisor', 'user', 'viewer', 'employee'
  )) THEN
    RAISE EXCEPTION 'Unsupported profile role';
  END IF;

  IF TG_OP = 'INSERT' AND NEW.role = 'user' AND NEW.full_name = '' THEN
    DELETE FROM quote_studio_profile_private.auth_profile_lifecycle_marker AS marker
    WHERE marker.user_id = NEW.id
      AND marker.operation = 'insert'
      AND marker.backend_pid = pg_catalog.pg_backend_pid()
      AND marker.transaction_id = pg_catalog.pg_current_xact_id()
      AND marker.expected_trigger_depth = pg_catalog.pg_trigger_depth()
    RETURNING marker.operation INTO lifecycle_operation;
    IF FOUND THEN
      RETURN NEW;
    END IF;
  ELSIF TG_OP = 'DELETE' THEN
    DELETE FROM quote_studio_profile_private.auth_profile_lifecycle_marker AS marker
    WHERE marker.user_id = OLD.id
      AND marker.operation = 'delete'
      AND marker.backend_pid = pg_catalog.pg_backend_pid()
      AND marker.transaction_id = pg_catalog.pg_current_xact_id()
      AND marker.expected_trigger_depth = pg_catalog.pg_trigger_depth()
    RETURNING marker.operation INTO lifecycle_operation;
    IF FOUND THEN
      RETURN OLD;
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
  FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;

CREATE FUNCTION quote_studio_profile_private.provision_auth_user_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF pg_catalog.pg_trigger_depth() <> 1 THEN
    RAISE EXCEPTION 'Auth profile provisioning must run from a top-level Auth trigger';
  END IF;

  INSERT INTO quote_studio_profile_private.auth_profile_lifecycle_marker (
    user_id, operation, backend_pid, transaction_id, expected_trigger_depth
  )
  VALUES (
    NEW.id, 'insert', pg_catalog.pg_backend_pid(),
    pg_catalog.pg_current_xact_id(), 2
  );

  INSERT INTO public.profiles (id, full_name, role)
  VALUES (NEW.id, '', 'user');

  IF EXISTS (
    SELECT 1
    FROM quote_studio_profile_private.auth_profile_lifecycle_marker AS marker
    WHERE marker.user_id = NEW.id
      AND marker.operation = 'insert'
      AND marker.backend_pid = pg_catalog.pg_backend_pid()
      AND marker.transaction_id = pg_catalog.pg_current_xact_id()
  ) THEN
    RAISE EXCEPTION 'Auth profile provisioning marker was not consumed';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION quote_studio_profile_private.provision_auth_user_profile()
  OWNER TO postgres;
REVOKE ALL ON FUNCTION quote_studio_profile_private.provision_auth_user_profile()
  FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;

CREATE FUNCTION quote_studio_profile_private.delete_auth_user_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  existing_role text;
  deleted_profiles integer;
BEGIN
  IF pg_catalog.pg_trigger_depth() <> 1 THEN
    RAISE EXCEPTION 'Auth profile deletion must run from a top-level Auth trigger';
  END IF;

  SELECT profile.role INTO existing_role
  FROM public.profiles AS profile
  WHERE profile.id = OLD.id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN OLD;
  END IF;

  -- Preserve privileged-profile lifecycle rules: an owner must first use
  -- manage_profile to demote a privileged profile. This also prevents Auth
  -- deletion from removing the last owner.
  IF existing_role NOT IN ('manager', 'supervisor', 'user', 'viewer', 'employee') THEN
    RAISE EXCEPTION 'Auth deletion is permitted only for supported non-privileged profile roles; demote privileged profiles through owner-authorized profile management first'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO quote_studio_profile_private.auth_profile_lifecycle_marker (
    user_id, operation, backend_pid, transaction_id, expected_trigger_depth
  )
  VALUES (
    OLD.id, 'delete', pg_catalog.pg_backend_pid(),
    pg_catalog.pg_current_xact_id(), 2
  );

  DELETE FROM public.profiles
  WHERE id = OLD.id;
  GET DIAGNOSTICS deleted_profiles = ROW_COUNT;
  IF deleted_profiles <> 1 THEN
    RAISE EXCEPTION 'Auth profile deletion did not remove exactly one matching profile';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM quote_studio_profile_private.auth_profile_lifecycle_marker AS marker
    WHERE marker.user_id = OLD.id
      AND marker.operation = 'delete'
      AND marker.backend_pid = pg_catalog.pg_backend_pid()
      AND marker.transaction_id = pg_catalog.pg_current_xact_id()
  ) THEN
    RAISE EXCEPTION 'Auth profile deletion marker was not consumed';
  END IF;

  RETURN OLD;
END;
$$;
ALTER FUNCTION quote_studio_profile_private.delete_auth_user_profile()
  OWNER TO postgres;
REVOKE ALL ON FUNCTION quote_studio_profile_private.delete_auth_user_profile()
  FROM PUBLIC, anon, authenticated, service_role, supabase_auth_admin;

CREATE TRIGGER quote_studio_auth_profile_after_insert
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION quote_studio_profile_private.provision_auth_user_profile();

CREATE TRIGGER quote_studio_auth_profile_before_delete
BEFORE DELETE ON auth.users
FOR EACH ROW
EXECUTE FUNCTION quote_studio_profile_private.delete_auth_user_profile();

DO $postconditions$
DECLARE
  role_name text;
  marker_oid oid := 'quote_studio_profile_private.auth_profile_lifecycle_marker'::pg_catalog.regclass;
  marker_columns name[];
  trigger_count integer;
BEGIN
  SELECT pg_catalog.array_agg(attribute.attname ORDER BY attribute.attname)
    INTO marker_columns
  FROM pg_catalog.pg_attribute AS attribute
  WHERE attribute.attrelid = marker_oid
    AND attribute.attnum > 0
    AND NOT attribute.attisdropped;
  IF marker_columns IS DISTINCT FROM ARRAY[
    'backend_pid', 'expected_trigger_depth', 'operation',
    'transaction_id', 'user_id'
  ]::name[] OR EXISTS (
    SELECT 1
    FROM (
      VALUES
        ('user_id'::name, 'uuid'::text),
        ('operation'::name, 'text'::text),
        ('backend_pid'::name, 'integer'::text),
        ('transaction_id'::name, 'xid8'::text),
        ('expected_trigger_depth'::name, 'integer'::text)
    ) AS expected(column_name, type_name)
    WHERE NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_attribute AS attribute
      WHERE attribute.attrelid = marker_oid
        AND attribute.attname = expected.column_name
        AND NOT attribute.attisdropped
        AND attribute.attnotnull
        AND pg_catalog.format_type(attribute.atttypid, attribute.atttypmod)
          = expected.type_name
    )
  ) THEN
    RAISE EXCEPTION 'Postcondition failed: marker table columns or types are unsafe';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS marker_table
    WHERE marker_table.oid = marker_oid
      AND marker_table.relkind = 'r'
      AND marker_table.relowner = 'postgres'::pg_catalog.regrole::oid
      AND marker_table.relrowsecurity
      AND NOT marker_table.relforcerowsecurity
  ) OR (
    SELECT count(*) FROM pg_catalog.pg_constraint
    WHERE conrelid = marker_oid
  ) <> 3 OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_constraint
    WHERE conrelid = marker_oid
      AND conname = 'auth_profile_lifecycle_marker_pkey'
      AND contype = 'p'
      AND conkey = ARRAY[
        (SELECT attnum FROM pg_catalog.pg_attribute WHERE attrelid = marker_oid AND attname = 'user_id'),
        (SELECT attnum FROM pg_catalog.pg_attribute WHERE attrelid = marker_oid AND attname = 'operation'),
        (SELECT attnum FROM pg_catalog.pg_attribute WHERE attrelid = marker_oid AND attname = 'backend_pid'),
        (SELECT attnum FROM pg_catalog.pg_attribute WHERE attrelid = marker_oid AND attname = 'transaction_id')
      ]::smallint[]
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_constraint
    WHERE conrelid = marker_oid
      AND conname = 'auth_profile_lifecycle_marker_operation_check'
      AND contype = 'c'
      AND convalidated
      AND pg_catalog.pg_get_constraintdef(oid) ILIKE '%insert%'
      AND pg_catalog.pg_get_constraintdef(oid) ILIKE '%delete%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_constraint
    WHERE conrelid = marker_oid
      AND conname = 'auth_profile_lifecycle_marker_depth_check'
      AND contype = 'c'
      AND convalidated
      AND pg_catalog.pg_get_constraintdef(oid) ILIKE '%= 2%'
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_trigger
    WHERE tgrelid = marker_oid
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'Postcondition failed: marker owner, RLS, or exact constraints are unsafe';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_namespace AS schema_row
    WHERE schema_row.nspname = 'quote_studio_profile_private'
      AND schema_row.nspowner = 'postgres'::pg_catalog.regrole::oid
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_namespace AS schema_row
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      coalesce(schema_row.nspacl, pg_catalog.acldefault('n', schema_row.nspowner))
    ) AS acl
    WHERE schema_row.nspname = 'quote_studio_profile_private'
      AND acl.grantee = 0
      AND acl.privilege_type IN ('USAGE', 'CREATE')
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS marker_table
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      coalesce(marker_table.relacl, pg_catalog.acldefault('r', marker_table.relowner))
    ) AS acl
    WHERE marker_table.oid = marker_oid
      AND acl.grantee = 0
  ) THEN
    RAISE EXCEPTION 'Postcondition failed: PUBLIC has access to the private marker objects';
  END IF;

  FOREACH role_name IN ARRAY ARRAY[
    'anon', 'authenticated', 'service_role', 'supabase_auth_admin'
  ] LOOP
    IF pg_catalog.has_schema_privilege(
         role_name, 'quote_studio_profile_private', 'USAGE'
       )
       OR pg_catalog.has_table_privilege(
         role_name, marker_oid, 'SELECT'
       )
       OR pg_catalog.has_table_privilege(
         role_name, marker_oid, 'INSERT'
       )
       OR pg_catalog.has_table_privilege(
         role_name, marker_oid, 'UPDATE'
       )
       OR pg_catalog.has_table_privilege(
         role_name, marker_oid, 'DELETE'
       )
       OR pg_catalog.has_table_privilege(
         role_name, marker_oid, 'TRUNCATE'
       )
       OR pg_catalog.has_table_privilege(
         role_name, marker_oid, 'REFERENCES'
       )
       OR pg_catalog.has_table_privilege(
         role_name, marker_oid, 'TRIGGER'
       )
       OR pg_catalog.has_table_privilege(
         role_name, 'public.profiles', 'INSERT'
       )
       OR pg_catalog.has_table_privilege(
         role_name, 'public.profiles', 'UPDATE'
       )
       OR pg_catalog.has_table_privilege(
         role_name, 'public.profiles', 'DELETE'
       )
       OR pg_catalog.has_table_privilege(
         role_name, 'public.profiles', 'TRUNCATE'
       ) THEN
      RAISE EXCEPTION 'Postcondition failed: role % has unexpected private-marker or profile privileges', role_name;
    END IF;
  END LOOP;

  SELECT count(*) INTO trigger_count
  FROM pg_catalog.pg_trigger
  WHERE tgrelid = 'auth.users'::pg_catalog.regclass
    AND NOT tgisinternal;
  IF trigger_count <> 2 OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger
    WHERE tgrelid = 'auth.users'::pg_catalog.regclass
      AND tgname = 'quote_studio_auth_profile_after_insert'
      AND tgfoid =
        'quote_studio_profile_private.provision_auth_user_profile()'::pg_catalog.regprocedure
      AND tgtype::integer = 5
      AND NOT tgisinternal
      AND tgenabled IN ('O', 'A')
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger
    WHERE tgrelid = 'auth.users'::pg_catalog.regclass
      AND tgname = 'quote_studio_auth_profile_before_delete'
      AND tgfoid =
        'quote_studio_profile_private.delete_auth_user_profile()'::pg_catalog.regprocedure
      AND tgtype::integer = 11
      AND NOT tgisinternal
      AND tgenabled IN ('O', 'A')
  ) THEN
    RAISE EXCEPTION 'Postcondition failed: expected enabled Auth INSERT and BEFORE DELETE triggers are missing or altered';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS routine
    WHERE routine.oid IN (
      'public.profile_role_write_guard()'::pg_catalog.regprocedure,
      'quote_studio_profile_private.provision_auth_user_profile()'::pg_catalog.regprocedure,
      'quote_studio_profile_private.delete_auth_user_profile()'::pg_catalog.regprocedure
    )
      AND (
        routine.proowner <> 'postgres'::pg_catalog.regrole::oid
        OR NOT routine.prosecdef
        OR NOT EXISTS (
          SELECT 1
          FROM pg_catalog.unnest(routine.proconfig) AS setting(value)
          WHERE pg_catalog.split_part(setting.value, '=', 1) = 'search_path'
            AND pg_catalog.btrim(
              pg_catalog.split_part(setting.value, '=', 2), '"'
            ) = ''
        )
        OR pg_catalog.has_function_privilege('anon', routine.oid, 'EXECUTE')
        OR pg_catalog.has_function_privilege('authenticated', routine.oid, 'EXECUTE')
        OR pg_catalog.has_function_privilege('service_role', routine.oid, 'EXECUTE')
        OR pg_catalog.has_function_privilege('supabase_auth_admin', routine.oid, 'EXECUTE')
        OR EXISTS (
          SELECT 1
          FROM pg_catalog.aclexplode(
            coalesce(
              routine.proacl,
              pg_catalog.acldefault('f', routine.proowner)
            )
          ) AS acl
          WHERE acl.grantee = 0
            AND acl.privilege_type = 'EXECUTE'
        )
      )
  ) THEN
    RAISE EXCEPTION 'Postcondition failed: lifecycle function ownership, security, search_path, or execute ACL is unsafe';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (
      VALUES
        ('anon'::text),
        ('authenticated'::text),
        ('service_role'::text),
        ('supabase_auth_admin'::text)
    ) AS checked_roles(role_name)
    CROSS JOIN pg_catalog.pg_attribute AS attribute
    WHERE attribute.attrelid = 'public.profiles'::pg_catalog.regclass
      AND attribute.attnum > 0
      AND NOT attribute.attisdropped
      AND (
        pg_catalog.has_column_privilege(
          checked_roles.role_name, 'public.profiles'::pg_catalog.regclass,
          attribute.attname, 'INSERT'
        )
        OR (
          pg_catalog.has_column_privilege(
            checked_roles.role_name, 'public.profiles'::pg_catalog.regclass,
            attribute.attname, 'UPDATE'
          )
          AND NOT (
            checked_roles.role_name = 'authenticated'
            AND attribute.attname = 'full_name'
          )
        )
      )
  ) OR NOT pg_catalog.has_column_privilege(
    'authenticated', 'public.profiles'::pg_catalog.regclass,
    'full_name', 'UPDATE'
  ) THEN
    RAISE EXCEPTION 'Postcondition failed: only authenticated UPDATE(full_name) may be granted at column level';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM quote_studio_profile_private.auth_profile_lifecycle_marker
  ) THEN
    RAISE EXCEPTION 'Postcondition failed: lifecycle marker table must be empty after installation';
  END IF;
END;
$postconditions$;

COMMIT;

/*
STAGING-ONLY VERIFICATION (run separately after reviewing and applying this file
to the isolated staging project; never run against Production):

1. Catalog and privilege checks (read-only):

SELECT current_setting('server_version'), pg_catalog.pg_get_userbyid(c.relowner) AS marker_owner,
       c.relrowsecurity, c.relforcerowsecurity
FROM pg_catalog.pg_class AS c
WHERE c.oid =
  'quote_studio_profile_private.auth_profile_lifecycle_marker'::pg_catalog.regclass;

SELECT tg.tgname, tg.tgtype::integer AS trigger_bits, tg.tgenabled,
       p.oid::pg_catalog.regprocedure AS trigger_function
FROM pg_catalog.pg_trigger AS tg
JOIN pg_catalog.pg_proc AS p ON p.oid = tg.tgfoid
WHERE (tg.tgrelid = 'auth.users'::pg_catalog.regclass AND NOT tg.tgisinternal)
   OR (tg.tgrelid = 'public.profiles'::pg_catalog.regclass AND NOT tg.tgisinternal)
ORDER BY tg.tgrelid::regclass::text, tg.tgname;

SELECT role_name,
       pg_catalog.has_schema_privilege(role_name, 'quote_studio_profile_private', 'USAGE')
         AS marker_schema_usage,
       pg_catalog.has_table_privilege(
         role_name, 'quote_studio_profile_private.auth_profile_lifecycle_marker', 'SELECT'
       ) AS marker_select,
       pg_catalog.has_table_privilege(
         role_name, 'quote_studio_profile_private.auth_profile_lifecycle_marker', 'INSERT'
       ) AS marker_insert,
       pg_catalog.has_table_privilege(
         role_name, 'quote_studio_profile_private.auth_profile_lifecycle_marker', 'UPDATE'
       ) AS marker_update,
       pg_catalog.has_table_privilege(
         role_name, 'quote_studio_profile_private.auth_profile_lifecycle_marker', 'DELETE'
       ) AS marker_delete,
       pg_catalog.has_table_privilege(
         role_name, 'quote_studio_profile_private.auth_profile_lifecycle_marker', 'TRUNCATE'
       ) AS marker_truncate,
       pg_catalog.has_table_privilege(role_name, 'public.profiles', 'INSERT')
         AS profile_insert,
       pg_catalog.has_table_privilege(role_name, 'public.profiles', 'UPDATE')
         AS profile_update,
       pg_catalog.has_table_privilege(role_name, 'public.profiles', 'DELETE')
         AS profile_delete,
       pg_catalog.has_table_privilege(role_name, 'public.profiles', 'TRUNCATE')
         AS profile_truncate
FROM unnest(ARRAY['anon','authenticated','service_role','supabase_auth_admin']) AS roles(role_name);

2. Lifecycle integration test:
   - Create one disposable, unprivileged user using the staging Auth Dashboard/API
     only. Do not use any existing test, employee, owner, admin, or Production account.
   - Save only the new staging user UUID. Verify one profile exists with that ID,
     an empty full_name, and role='user':
       SELECT id, full_name, role FROM public.profiles WHERE id = '<new-staging-uuid>';
   - Delete only that disposable user through the staging Auth Dashboard/API.
     The BEFORE DELETE Auth trigger explicitly deletes its profile using the
     one-use marker; the existing ON DELETE CASCADE then finds no profile row.
     Verify both rows are absent:
       SELECT EXISTS (SELECT 1 FROM auth.users WHERE id = '<new-staging-uuid>') AS auth_exists,
              EXISTS (SELECT 1 FROM public.profiles WHERE id = '<new-staging-uuid>') AS profile_exists;
     Both results must be false. A clean disposable account must have no dependent
     Quote Studio business records; FK failures must remain atomic and must not be
     worked around by deleting unrelated rows.
   - A disposable Auth user deliberately created without a profile (only if the
     staging operator can safely arrange that before the migration is tested)
     should delete normally without a marker. Do not disable triggers to create
     this condition.

3. Unauthorized profile-write tests (separate disposable staging SQL session;
   each statement is expected to fail with permission denied; rollback each
   failed transaction before testing the next role):
       BEGIN; SET LOCAL ROLE anon;
       INSERT INTO public.profiles(id, full_name, role)
       VALUES ('00000000-0000-4000-8000-000000000001', '', 'user');
       ROLLBACK;
     Repeat with SET LOCAL ROLE authenticated and SET LOCAL ROLE service_role.
     These cases must not create profiles. Do not test with session_user=postgres
     and do not grant roles additional table or marker privileges to make tests run.
     The same no-write-privilege expectation applies to supabase_auth_admin.

4. Role protection test:
   - Confirm deleting a disposable Auth account whose profile role is owner/admin
     is rejected. Do not use a real or existing privileged account. For any future
     privileged-account removal, first use the existing owner-authorized profile
     management flow to demote it; the existing last-owner protection remains.

ROLLBACK (staging only):
1. Stop Auth user creation/deletion while rolling back.
2. Drop the two Auth triggers:
     DROP TRIGGER quote_studio_auth_profile_after_insert ON auth.users;
     DROP TRIGGER quote_studio_auth_profile_before_delete ON auth.users;
3. Restore public.profile_role_write_guard() exactly from the CREATE FUNCTION
   definition in 20261025234000_protect_profile_role_management.sql, including
   its postgres owner, SECURITY DEFINER, SET search_path='', and function REVOKEs.
   Do not restore from the older 20261026121000 proposal.
4. Confirm the marker table is empty. If any rows remain, stop and investigate
   before cleanup; never delete unexplained marker rows.
5. Drop the two private trigger functions, then the marker table, then the private
   schema only after confirming no other objects depend on them:
     DROP FUNCTION quote_studio_profile_private.provision_auth_user_profile();
     DROP FUNCTION quote_studio_profile_private.delete_auth_user_profile();
     DROP TABLE quote_studio_profile_private.auth_profile_lifecycle_marker;
     DROP SCHEMA quote_studio_profile_private;
6. Do not delete profiles created by this migration. Rollback does not backfill,
   remove accounts, or remove profile data.
*/
