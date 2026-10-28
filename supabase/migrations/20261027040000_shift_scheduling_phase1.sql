-- Quote Studio Shift Scheduling - Phase 1.
-- Additive only: does not modify existing reports, alerts, or inventory records.
-- Requires 20261025234000_protect_profile_role_management.sql (public.is_admin()).
BEGIN;

DO $prerequisites$
BEGIN
  IF current_user <> 'postgres' THEN
    RAISE EXCEPTION 'Prerequisite failed: run this migration as postgres';
  END IF;
  IF current_setting('server_version_num')::integer < 170000 THEN
    RAISE EXCEPTION 'Prerequisite failed: shift scheduling privilege checks require PostgreSQL 17 or newer';
  END IF;
  IF pg_catalog.to_regprocedure('public.is_admin()') IS NULL
     OR pg_catalog.to_regclass('public.profiles') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite failed: apply profile role security before shift scheduling';
  END IF;
  IF pg_catalog.to_regnamespace('quote_studio_schedule_private') IS NOT NULL
     OR pg_catalog.to_regclass('public.shift_schedule_settings') IS NOT NULL
     OR pg_catalog.to_regclass('public.shift_schedule_time_zone_history') IS NOT NULL
     OR pg_catalog.to_regclass('public.shift_schedule_templates') IS NOT NULL
     OR pg_catalog.to_regclass('public.shift_schedule_instances') IS NOT NULL
     OR pg_catalog.to_regclass('public.employee_shift_default_history') IS NOT NULL
     OR pg_catalog.to_regclass('public.shift_assignment_override_history') IS NOT NULL THEN
    RAISE EXCEPTION 'Prerequisite failed: shift scheduling objects already exist; inspect before applying';
  END IF;
END;
$prerequisites$;

CREATE SCHEMA quote_studio_schedule_private AUTHORIZATION postgres;
REVOKE ALL ON SCHEMA quote_studio_schedule_private
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.shift_schedule_settings (
  id smallint PRIMARY KEY CHECK (id = 1),
  time_zone text NOT NULL,
  updated_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.shift_schedule_settings ENABLE ROW LEVEL SECURITY;
INSERT INTO public.shift_schedule_settings(id, time_zone)
VALUES (1, 'America/Los_Angeles');

CREATE TABLE public.shift_schedule_time_zone_history (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  time_zone text NOT NULL,
  effective_from date NOT NULL,
  changed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.shift_schedule_time_zone_history ENABLE ROW LEVEL SECURITY;
CREATE INDEX shift_schedule_time_zone_history_effective_idx
  ON public.shift_schedule_time_zone_history(effective_from DESC, created_at DESC);
INSERT INTO public.shift_schedule_time_zone_history(time_zone, effective_from)
VALUES (
  'America/Los_Angeles',
  (now() AT TIME ZONE 'America/Los_Angeles')::date
);

CREATE TABLE public.shift_schedule_templates (
  code text PRIMARY KEY CHECK (code IN ('first', 'second', 'third')),
  name text NOT NULL,
  start_local time NOT NULL,
  end_local time NOT NULL,
  CHECK (start_local <> end_local)
);
ALTER TABLE public.shift_schedule_templates ENABLE ROW LEVEL SECURITY;
INSERT INTO public.shift_schedule_templates(code, name, start_local, end_local)
VALUES
  ('third', '3rd Shift', '23:00', '07:00'),
  ('first', '1st Shift', '07:00', '15:00'),
  ('second', '2nd Shift', '15:00', '23:00');

CREATE TABLE public.shift_schedule_instances (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  schedule_kind text NOT NULL CHECK (schedule_kind IN ('regular', 'custom')),
  template_code text REFERENCES public.shift_schedule_templates(code),
  local_start_date date NOT NULL,
  name text NOT NULL CHECK (length(pg_catalog.btrim(name)) BETWEEN 1 AND 80),
  time_zone text NOT NULL,
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at),
  CHECK (
    (schedule_kind = 'regular' AND template_code IS NOT NULL)
    OR (schedule_kind = 'custom' AND template_code IS NULL)
  )
);
ALTER TABLE public.shift_schedule_instances ENABLE ROW LEVEL SECURITY;
CREATE UNIQUE INDEX shift_schedule_regular_slot_uq
  ON public.shift_schedule_instances(template_code, local_start_date)
  WHERE schedule_kind = 'regular';
ALTER TABLE public.shift_schedule_instances
  ADD CONSTRAINT shift_schedule_instances_no_overlap
  EXCLUDE USING gist ((tstzrange(starts_at, ends_at, '[)')) WITH &&);
CREATE INDEX shift_schedule_instances_local_date_idx
  ON public.shift_schedule_instances(local_start_date, starts_at);

CREATE TABLE public.employee_shift_default_history (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  employee_id uuid NOT NULL,
  template_code text REFERENCES public.shift_schedule_templates(code),
  effective_from timestamptz NOT NULL,
  effective_to timestamptz,
  changed_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (effective_to IS NULL OR effective_to > effective_from)
);
ALTER TABLE public.employee_shift_default_history ENABLE ROW LEVEL SECURITY;
CREATE UNIQUE INDEX employee_shift_default_one_open_period_uq
  ON public.employee_shift_default_history(employee_id)
  WHERE effective_to IS NULL;
CREATE INDEX employee_shift_default_period_idx
  ON public.employee_shift_default_history(employee_id, effective_from, effective_to);

CREATE TABLE public.shift_assignment_override_history (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  shift_instance_id uuid NOT NULL REFERENCES public.shift_schedule_instances(id),
  employee_id uuid NOT NULL,
  assigned boolean NOT NULL,
  effective_at timestamptz NOT NULL,
  changed_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.shift_assignment_override_history ENABLE ROW LEVEL SECURITY;
CREATE INDEX shift_assignment_override_history_lookup_idx
  ON public.shift_assignment_override_history(
    shift_instance_id, employee_id, effective_at DESC
  );

CREATE FUNCTION quote_studio_schedule_private.is_assigned(
  p_shift_id uuid,
  p_employee_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE
    WHEN latest_override.assigned IS NOT NULL THEN latest_override.assigned
    ELSE EXISTS (
      SELECT 1
      FROM public.shift_schedule_instances AS instance
      JOIN public.employee_shift_default_history AS assignment
        ON assignment.employee_id = p_employee_id
       AND assignment.template_code = instance.template_code
       AND instance.starts_at >= assignment.effective_from
       AND (assignment.effective_to IS NULL OR instance.starts_at < assignment.effective_to)
      WHERE instance.id = p_shift_id
    )
  END
  FROM public.shift_schedule_instances AS selected_shift
  LEFT JOIN LATERAL (
    SELECT history.assigned
    FROM public.shift_assignment_override_history AS history
    WHERE history.shift_instance_id = selected_shift.id
      AND history.employee_id = p_employee_id
      AND history.effective_at <= selected_shift.starts_at
    ORDER BY history.effective_at DESC, history.created_at DESC, history.id DESC
    LIMIT 1
  ) AS latest_override ON true
  WHERE selected_shift.id = p_shift_id;
$$;
ALTER FUNCTION quote_studio_schedule_private.is_assigned(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION quote_studio_schedule_private.is_assigned(uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION quote_studio_schedule_private.resolve_local_time(
  p_local_time timestamp without time zone,
  p_time_zone text
)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  resolved_time timestamptz;
  matching_instants integer;
BEGIN
  IF p_local_time IS NULL OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_timezone_names AS zone
    WHERE zone.name = p_time_zone
  ) THEN
    RAISE EXCEPTION 'Invalid local time or IANA time zone'
      USING ERRCODE = '22023';
  END IF;
  resolved_time := p_local_time AT TIME ZONE p_time_zone;
  SELECT count(*) INTO matching_instants
  FROM pg_catalog.generate_series(
    resolved_time - interval '14 hours',
    resolved_time + interval '14 hours',
    interval '1 minute'
  ) AS candidate(instant)
  WHERE candidate.instant AT TIME ZONE p_time_zone = p_local_time;
  IF matching_instants <> 1 THEN
    RAISE EXCEPTION
      'Local shift time is missing or ambiguous because of a daylight-saving transition'
      USING ERRCODE = '22007';
  END IF;
  RETURN resolved_time;
END;
$$;
ALTER FUNCTION quote_studio_schedule_private.resolve_local_time(
  timestamp without time zone, text
) OWNER TO postgres;
REVOKE ALL ON FUNCTION quote_studio_schedule_private.resolve_local_time(
  timestamp without time zone, text
) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION quote_studio_schedule_private.ensure_regular_shifts(
  p_start_date date,
  p_end_date date
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  local_date date;
  template_row record;
  local_start timestamp without time zone;
  local_end timestamp without time zone;
  shift_start timestamptz;
  shift_end timestamptz;
  weekday_number integer;
  schedule_time_zone text;
BEGIN
  FOR local_date IN
    SELECT series.day_value::date
    FROM pg_catalog.generate_series(
      p_start_date::timestamp,
      p_end_date::timestamp,
      interval '1 day'
    ) AS series(day_value)
  LOOP
    SELECT history.time_zone INTO schedule_time_zone
    FROM public.shift_schedule_time_zone_history AS history
    WHERE history.effective_from <= local_date
    ORDER BY history.effective_from DESC, history.created_at DESC, history.id DESC
    LIMIT 1;
    IF schedule_time_zone IS NULL THEN
      CONTINUE;
    END IF;
    weekday_number := extract(isodow FROM local_date);
    FOR template_row IN
      SELECT template.code, template.name, template.start_local, template.end_local
      FROM public.shift_schedule_templates AS template
      WHERE
        (weekday_number = 7 AND template.code = 'third')
        OR (weekday_number BETWEEN 1 AND 4)
        OR (weekday_number = 5 AND template.code IN ('first', 'second'))
      ORDER BY CASE template.code
        WHEN 'third' THEN 1 WHEN 'first' THEN 2 ELSE 3
      END
    LOOP
      local_start := local_date + template_row.start_local;
      local_end := (
        local_date
        + CASE WHEN template_row.end_local <= template_row.start_local THEN 1 ELSE 0 END
      ) + template_row.end_local;
      shift_start := quote_studio_schedule_private.resolve_local_time(
        local_start, schedule_time_zone
      );
      shift_end := quote_studio_schedule_private.resolve_local_time(
        local_end, schedule_time_zone
      );
      IF shift_end <= shift_start THEN
        RAISE EXCEPTION 'Regular shift has a non-positive interval'
          USING ERRCODE = '22007';
      END IF;
      INSERT INTO public.shift_schedule_instances(
        schedule_kind, template_code, local_start_date, name, time_zone,
        starts_at, ends_at, created_by
      )
      VALUES (
        'regular', template_row.code, local_date, template_row.name, schedule_time_zone,
        shift_start, shift_end, NULL
      )
      ON CONFLICT (template_code, local_start_date)
        WHERE schedule_kind = 'regular'
      DO NOTHING;
    END LOOP;
  END LOOP;
END;
$$;
ALTER FUNCTION quote_studio_schedule_private.ensure_regular_shifts(
  date, date
) OWNER TO postgres;
REVOKE ALL ON FUNCTION quote_studio_schedule_private.ensure_regular_shifts(
  date, date
) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION quote_studio_schedule_private.assert_no_regular_overlap(
  p_start timestamptz,
  p_end timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  local_date date;
  weekday_number integer;
  time_zone text;
  template_row record;
  regular_start timestamptz;
  regular_end timestamptz;
BEGIN
  FOR local_date IN
    SELECT day_value::date
    FROM pg_catalog.generate_series(
      ((p_start - interval '14 hours')::date - 1)::timestamp,
      ((p_end + interval '14 hours')::date + 1)::timestamp,
      interval '1 day'
    ) AS days(day_value)
  LOOP
    SELECT history.time_zone INTO time_zone
    FROM public.shift_schedule_time_zone_history AS history
    WHERE history.effective_from <= local_date
    ORDER BY history.effective_from DESC, history.created_at DESC, history.id DESC
    LIMIT 1;
    IF time_zone IS NULL THEN
      CONTINUE;
    END IF;
    weekday_number := extract(isodow FROM local_date);
    FOR template_row IN
      SELECT code, start_local, end_local
      FROM public.shift_schedule_templates
      WHERE
        (weekday_number = 7 AND code = 'third')
        OR weekday_number BETWEEN 1 AND 4
        OR (weekday_number = 5 AND code IN ('first', 'second'))
    LOOP
      regular_start := quote_studio_schedule_private.resolve_local_time(
        local_date + template_row.start_local, time_zone
      );
      regular_end := quote_studio_schedule_private.resolve_local_time(
        (
          local_date
          + CASE WHEN template_row.end_local <= template_row.start_local THEN 1 ELSE 0 END
        ) + template_row.end_local,
        time_zone
      );
      IF tstzrange(p_start, p_end, '[)') && tstzrange(regular_start, regular_end, '[)') THEN
        RAISE EXCEPTION 'Custom shift overlaps a regular scheduled shift'
          USING ERRCODE = '23P01';
      END IF;
    END LOOP;
  END LOOP;
END;
$$;
ALTER FUNCTION quote_studio_schedule_private.assert_no_regular_overlap(
  timestamptz, timestamptz
) OWNER TO postgres;
REVOKE ALL ON FUNCTION quote_studio_schedule_private.assert_no_regular_overlap(
  timestamptz, timestamptz
) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION quote_studio_schedule_private.validate_time_zone_cutover(
  p_time_zone text,
  p_effective_date date
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  local_date date;
  weekday_number integer;
  template_row record;
  starts_at timestamptz;
  ends_at timestamptz;
BEGIN
  FOR local_date IN
    SELECT day_value::date
    FROM pg_catalog.generate_series(
      p_effective_date::timestamp,
      (p_effective_date + 92)::timestamp,
      interval '1 day'
    ) AS days(day_value)
  LOOP
    weekday_number := extract(isodow FROM local_date);
    FOR template_row IN
      SELECT code, start_local, end_local
      FROM public.shift_schedule_templates
      WHERE
        (weekday_number = 7 AND code = 'third')
        OR weekday_number BETWEEN 1 AND 4
        OR (weekday_number = 5 AND code IN ('first', 'second'))
    LOOP
      starts_at := quote_studio_schedule_private.resolve_local_time(
        local_date + template_row.start_local, p_time_zone
      );
      ends_at := quote_studio_schedule_private.resolve_local_time(
        (
          local_date
          + CASE WHEN template_row.end_local <= template_row.start_local THEN 1 ELSE 0 END
        ) + template_row.end_local,
        p_time_zone
      );
      IF ends_at <= starts_at OR EXISTS (
        SELECT 1
        FROM public.shift_schedule_instances AS instance
        WHERE tstzrange(instance.starts_at, instance.ends_at, '[)')
          && tstzrange(starts_at, ends_at, '[)')
      ) THEN
        RAISE EXCEPTION
          'Time-zone change would overlap an existing shift; choose a later safe cutover'
          USING ERRCODE = '23P01';
      END IF;
    END LOOP;
  END LOOP;
END;
$$;
ALTER FUNCTION quote_studio_schedule_private.validate_time_zone_cutover(
  text, date
) OWNER TO postgres;
REVOKE ALL ON FUNCTION quote_studio_schedule_private.validate_time_zone_cutover(
  text, date
) FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON TABLE
  public.shift_schedule_settings,
  public.shift_schedule_time_zone_history,
  public.shift_schedule_templates,
  public.shift_schedule_instances,
  public.employee_shift_default_history,
  public.shift_assignment_override_history
FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.get_shift_schedule_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  SELECT jsonb_build_object(
    'time_zone', settings.time_zone,
    'today_local', (now() AT TIME ZONE settings.time_zone)::date,
    'effective_from', (
      SELECT history.effective_from
      FROM public.shift_schedule_time_zone_history AS history
      ORDER BY history.effective_from DESC, history.created_at DESC, history.id DESC
      LIMIT 1
    ),
    'templates', (
      SELECT jsonb_agg(jsonb_build_object(
        'code', template.code,
        'name', template.name,
        'start_local', template.start_local,
        'end_local', template.end_local
      ) ORDER BY CASE template.code
        WHEN 'third' THEN 1 WHEN 'first' THEN 2 ELSE 3
      END)
      FROM public.shift_schedule_templates AS template
    )
  )
  INTO result
  FROM public.shift_schedule_settings AS settings
  WHERE settings.id = 1;
  IF result IS NULL THEN
    RAISE EXCEPTION 'Shift schedule settings are not initialized'
      USING ERRCODE = '55000';
  END IF;
  RETURN result;
END;
$$;
ALTER FUNCTION public.get_shift_schedule_settings() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_shift_schedule_settings()
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_shift_schedule_settings() TO authenticated;

CREATE FUNCTION public.get_shift_schedule_admin_data()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Owner or Admin permission required' USING ERRCODE = '42501';
  END IF;
  SELECT jsonb_build_object(
    'employees', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', employee.id,
        'full_name', employee.full_name,
        'role', employee.role,
        'default_shift', (
          SELECT history.template_code
          FROM public.employee_shift_default_history AS history
          WHERE history.employee_id = employee.id
            AND history.effective_from <= now()
            AND (history.effective_to IS NULL OR history.effective_to > now())
          ORDER BY history.effective_from DESC
          LIMIT 1
        )
      ) ORDER BY employee.full_name, employee.id)
      FROM public.profiles AS employee
      WHERE employee.role IN ('manager', 'supervisor', 'user', 'viewer', 'employee')
    ), '[]'::jsonb),
    'default_history', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', history.id,
        'employee_id', history.employee_id,
        'employee_name', employee.full_name,
        'template_code', history.template_code,
        'effective_from', history.effective_from,
        'effective_to', history.effective_to,
        'changed_by', history.changed_by,
        'created_at', history.created_at
      ) ORDER BY history.effective_from DESC, history.created_at DESC)
      FROM public.employee_shift_default_history AS history
      LEFT JOIN public.profiles AS employee ON employee.id = history.employee_id
    ), '[]'::jsonb),
    'override_history', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', history.id,
        'shift_instance_id', history.shift_instance_id,
        'shift_name', instance.name,
        'starts_at', instance.starts_at,
        'employee_id', history.employee_id,
        'employee_name', employee.full_name,
        'assigned', history.assigned,
        'time_zone', instance.time_zone,
        'effective_at', history.effective_at,
        'changed_by', history.changed_by,
        'created_at', history.created_at
      ) ORDER BY history.effective_at DESC, history.created_at DESC)
      FROM public.shift_assignment_override_history AS history
      JOIN public.shift_schedule_instances AS instance
        ON instance.id = history.shift_instance_id
      LEFT JOIN public.profiles AS employee ON employee.id = history.employee_id
    ), '[]'::jsonb)
  )
  INTO result;
  RETURN result;
END;
$$;
ALTER FUNCTION public.get_shift_schedule_admin_data() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_shift_schedule_admin_data()
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_shift_schedule_admin_data() TO authenticated;

CREATE FUNCTION public.set_shift_schedule_time_zone(p_time_zone text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  configured_time_zone text;
  effective_date date;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Owner or Admin permission required' USING ERRCODE = '42501';
  END IF;
  IF p_time_zone IS NULL
     OR (p_time_zone <> 'UTC'
         AND p_time_zone !~ '^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$')
     OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_timezone_names AS zone
    WHERE zone.name = p_time_zone
  ) THEN
    RAISE EXCEPTION 'Choose a valid IANA time zone'
      USING ERRCODE = '22023';
  END IF;
  SELECT settings.time_zone INTO configured_time_zone
  FROM public.shift_schedule_settings AS settings
  WHERE settings.id = 1
  FOR UPDATE;
  IF configured_time_zone IS NULL THEN
    RAISE EXCEPTION 'Shift schedule settings are not initialized'
      USING ERRCODE = '55000';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.shift_schedule_time_zone_history AS history
    WHERE history.effective_from >
      (pg_catalog.clock_timestamp() AT TIME ZONE configured_time_zone)::date
  ) THEN
    RAISE EXCEPTION 'A time-zone change is already pending; wait for its effective date'
      USING ERRCODE = '55000';
  END IF;
  effective_date := (
    pg_catalog.clock_timestamp() AT TIME ZONE configured_time_zone
  )::date + 1;
  SELECT GREATEST(
    effective_date,
    COALESCE(
      max(((instance.ends_at + interval '72 hours') AT TIME ZONE configured_time_zone)::date + 1),
      effective_date
    )
  )
  INTO effective_date
  FROM public.shift_schedule_instances AS instance
  WHERE instance.ends_at > pg_catalog.clock_timestamp();
  effective_date := effective_date
    + ((6 - extract(isodow FROM effective_date)::integer + 7) % 7);
  PERFORM quote_studio_schedule_private.validate_time_zone_cutover(
    p_time_zone, effective_date
  );
  UPDATE public.shift_schedule_settings
  SET time_zone = p_time_zone, updated_by = auth.uid(), updated_at = now()
  WHERE id = 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shift schedule settings are not initialized';
  END IF;
  INSERT INTO public.shift_schedule_time_zone_history(
    time_zone, effective_from, changed_by
  )
  VALUES (p_time_zone, effective_date, auth.uid());
  RETURN pg_catalog.jsonb_build_object(
    'time_zone', p_time_zone,
    'effective_from', effective_date,
    'today_local', (pg_catalog.clock_timestamp() AT TIME ZONE p_time_zone)::date
  );
END;
$$;
ALTER FUNCTION public.set_shift_schedule_time_zone(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.set_shift_schedule_time_zone(text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.set_shift_schedule_time_zone(text) TO authenticated;

CREATE FUNCTION public.materialize_shift_schedule(
  p_start_date date,
  p_end_date date
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  configured_time_zone text;
  today_local date;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Owner or Admin permission required'
      USING ERRCODE = '42501';
  END IF;
  IF p_start_date IS NULL OR p_end_date IS NULL OR p_end_date < p_start_date
     OR p_end_date - p_start_date > 92 THEN
    RAISE EXCEPTION 'Choose a valid materialization range of at most 93 days'
      USING ERRCODE = '22023';
  END IF;
  SELECT settings.time_zone INTO configured_time_zone
  FROM public.shift_schedule_settings AS settings
  WHERE settings.id = 1
  FOR UPDATE;
  IF configured_time_zone IS NULL THEN
    RAISE EXCEPTION 'Shift schedule settings are not initialized'
      USING ERRCODE = '55000';
  END IF;
  today_local := (pg_catalog.clock_timestamp() AT TIME ZONE configured_time_zone)::date;
  IF p_start_date < today_local OR p_end_date > today_local + 92 THEN
    RAISE EXCEPTION 'Only shifts from today through 92 days ahead may be materialized'
      USING ERRCODE = '22023';
  END IF;
  PERFORM quote_studio_schedule_private.ensure_regular_shifts(
    p_start_date, p_end_date
  );
END;
$$;
ALTER FUNCTION public.materialize_shift_schedule(date, date) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.materialize_shift_schedule(date, date)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.materialize_shift_schedule(date, date)
  TO authenticated;

CREATE FUNCTION public.set_employee_default_shift(
  p_employee_id uuid,
  p_template_code text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  changed_at timestamptz;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Owner or Admin permission required' USING ERRCODE = '42501';
  END IF;
  IF p_employee_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles AS employee
    WHERE employee.id = p_employee_id
      AND employee.role IN ('manager', 'supervisor', 'user', 'viewer', 'employee')
  ) THEN
    RAISE EXCEPTION 'Choose a valid non-admin employee profile'
      USING ERRCODE = '22023';
  END IF;
  IF p_template_code IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.shift_schedule_templates AS template
    WHERE template.code = p_template_code
  ) THEN
    RAISE EXCEPTION 'Choose a valid regular shift'
      USING ERRCODE = '22023';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_employee_id::text, 7302701)
  );
  changed_at := pg_catalog.clock_timestamp();
  UPDATE public.employee_shift_default_history
  SET effective_to = changed_at
  WHERE employee_id = p_employee_id AND effective_to IS NULL;

  INSERT INTO public.employee_shift_default_history(
    employee_id, template_code, effective_from, changed_by
  )
  VALUES (p_employee_id, p_template_code, changed_at, auth.uid());
END;
$$;
ALTER FUNCTION public.set_employee_default_shift(uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.set_employee_default_shift(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.set_employee_default_shift(uuid, text) TO authenticated;

CREATE FUNCTION public.set_shift_instance_assignment(
  p_shift_instance_id uuid,
  p_employee_id uuid,
  p_assigned boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  changed_at timestamptz;
  shift_start timestamptz;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Owner or Admin permission required' USING ERRCODE = '42501';
  END IF;
  IF p_assigned IS NULL OR p_employee_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles AS employee
    WHERE employee.id = p_employee_id
      AND employee.role IN ('manager', 'supervisor', 'user', 'viewer', 'employee')
  ) THEN
    RAISE EXCEPTION 'Choose a valid employee and assignment state'
      USING ERRCODE = '22023';
  END IF;
  SELECT instance.starts_at INTO shift_start
  FROM public.shift_schedule_instances AS instance
  WHERE instance.id = p_shift_instance_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Scheduled shift not found' USING ERRCODE = '22023';
  END IF;
  changed_at := pg_catalog.clock_timestamp();
  IF shift_start <= changed_at THEN
    RAISE EXCEPTION 'Assignments can only be changed before a shift starts'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.shift_assignment_override_history(
    shift_instance_id, employee_id, assigned, effective_at, changed_by
  )
  VALUES (p_shift_instance_id, p_employee_id, p_assigned, changed_at, auth.uid());
END;
$$;
ALTER FUNCTION public.set_shift_instance_assignment(uuid, uuid, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.set_shift_instance_assignment(uuid, uuid, boolean)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.set_shift_instance_assignment(uuid, uuid, boolean)
  TO authenticated;

CREATE FUNCTION public.create_custom_shift(
  p_name text,
  p_start_local timestamp without time zone,
  p_end_local timestamp without time zone
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  configured_time_zone text;
  shift_start timestamptz;
  shift_end timestamptz;
  new_shift_id uuid;
  today_local date;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Owner or Admin permission required' USING ERRCODE = '42501';
  END IF;
  IF p_name IS NULL OR length(pg_catalog.btrim(p_name)) NOT BETWEEN 1 AND 80
     OR p_start_local IS NULL OR p_end_local IS NULL
     OR p_end_local <= p_start_local THEN
    RAISE EXCEPTION 'Enter a shift name and an increasing local start/end time'
      USING ERRCODE = '22023';
  END IF;
  PERFORM 1
  FROM public.shift_schedule_settings AS settings
  WHERE settings.id = 1
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shift schedule settings are not initialized'
      USING ERRCODE = '55000';
  END IF;
  SELECT history.time_zone INTO configured_time_zone
  FROM public.shift_schedule_time_zone_history AS history
  WHERE history.effective_from <= p_start_local::date
  ORDER BY history.effective_from DESC, history.created_at DESC, history.id DESC
  LIMIT 1;
  IF configured_time_zone IS NULL THEN
    RAISE EXCEPTION 'No time-zone history exists for the custom shift date'
      USING ERRCODE = '55000';
  END IF;
  today_local := (pg_catalog.clock_timestamp() AT TIME ZONE configured_time_zone)::date;
  IF p_end_local - p_start_local > interval '24 hours'
     OR p_start_local::date > today_local + 92 THEN
    RAISE EXCEPTION 'Custom shifts must be no longer than 24 hours and start within 93 days'
      USING ERRCODE = '22023';
  END IF;

  shift_start := quote_studio_schedule_private.resolve_local_time(
    p_start_local, configured_time_zone
  );
  shift_end := quote_studio_schedule_private.resolve_local_time(
    p_end_local, configured_time_zone
  );
  IF shift_end <= shift_start
     OR shift_start <= pg_catalog.clock_timestamp() THEN
    RAISE EXCEPTION 'Custom shifts must have a future start and a later end'
      USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.shift_schedule_instances AS instance
    WHERE tstzrange(instance.starts_at, instance.ends_at, '[)')
      && tstzrange(shift_start, shift_end, '[)')
  ) THEN
    RAISE EXCEPTION 'Custom shift overlaps an existing scheduled shift'
      USING ERRCODE = '23P01';
  END IF;
  PERFORM quote_studio_schedule_private.assert_no_regular_overlap(
    shift_start, shift_end
  );

  INSERT INTO public.shift_schedule_instances(
    schedule_kind, template_code, local_start_date, name, time_zone,
    starts_at, ends_at, created_by
  )
  VALUES (
    'custom', NULL, p_start_local::date, pg_catalog.btrim(p_name),
    configured_time_zone, shift_start, shift_end, auth.uid()
  )
  RETURNING id INTO new_shift_id;
  RETURN new_shift_id;
END;
$$;
ALTER FUNCTION public.create_custom_shift(
  text, timestamp without time zone, timestamp without time zone
) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.create_custom_shift(
  text, timestamp without time zone, timestamp without time zone
) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.create_custom_shift(
  text, timestamp without time zone, timestamp without time zone
) TO authenticated;

CREATE FUNCTION public.get_shift_schedule(
  p_start_date date,
  p_end_date date,
  p_admin_view boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  result jsonb;
  admin_view boolean;
  today_local date;
  active_time_zone text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_start_date IS NULL OR p_end_date IS NULL OR p_end_date < p_start_date
     OR p_end_date - p_start_date > 92 THEN
    RAISE EXCEPTION 'Choose a valid date range of at most 93 days'
      USING ERRCODE = '22023';
  END IF;
  admin_view := p_admin_view AND public.is_admin();

  IF admin_view THEN
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'id', instance.id,
        'kind', instance.schedule_kind,
        'template_code', instance.template_code,
        'local_date', instance.local_start_date,
        'name', instance.name,
        'time_zone', instance.time_zone,
        'starts_at', instance.starts_at,
        'ends_at', instance.ends_at,
        'assignments', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', employee.id,
            'full_name', employee.full_name,
            'role', employee.role
          ) ORDER BY employee.full_name, employee.id)
          FROM public.profiles AS employee
          WHERE employee.role IN ('manager', 'supervisor', 'user', 'viewer', 'employee')
            AND quote_studio_schedule_private.is_assigned(instance.id, employee.id)
        ), '[]'::jsonb)
      ) ORDER BY instance.starts_at
    ), '[]'::jsonb)
    INTO result
    FROM public.shift_schedule_instances AS instance
    WHERE instance.local_start_date BETWEEN p_start_date AND p_end_date;
    RETURN result;
  END IF;

  SELECT history.time_zone
  INTO active_time_zone
  FROM public.shift_schedule_time_zone_history AS history
  WHERE history.effective_from <= (now() AT TIME ZONE history.time_zone)::date
  ORDER BY history.effective_from DESC, history.created_at DESC, history.id DESC
  LIMIT 1;
  IF active_time_zone IS NULL THEN
    RAISE EXCEPTION 'Shift schedule settings are not initialized'
      USING ERRCODE = '55000';
  END IF;
  today_local := (now() AT TIME ZONE active_time_zone)::date;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', schedule_row.id,
      'kind', schedule_row.schedule_kind,
      'template_code', schedule_row.template_code,
      'local_date', schedule_row.local_start_date,
      'name', schedule_row.name,
      'time_zone', schedule_row.time_zone,
      'starts_at', schedule_row.starts_at,
      'ends_at', schedule_row.ends_at,
      'assignments', jsonb_build_array(jsonb_build_object(
        'id', auth.uid(),
        'full_name', profile.full_name,
        'role', profile.role
      ))
    ) ORDER BY schedule_row.starts_at
  ), '[]'::jsonb)
  INTO result
  FROM (
    SELECT
      instance.id,
      instance.schedule_kind,
      instance.template_code,
      instance.local_start_date,
      instance.name,
      instance.time_zone,
      instance.starts_at,
      instance.ends_at
    FROM public.shift_schedule_instances AS instance
    WHERE instance.local_start_date BETWEEN p_start_date AND p_end_date
      AND quote_studio_schedule_private.is_assigned(instance.id, auth.uid())

    UNION ALL

    SELECT
      NULL::uuid AS id,
      'regular'::text AS schedule_kind,
      template.code AS template_code,
      calendar.day_value::date AS local_start_date,
      template.name,
      zone.time_zone,
      interval_times.starts_at,
      interval_times.ends_at
    FROM pg_catalog.generate_series(
      GREATEST(p_start_date, today_local)::timestamp without time zone,
      LEAST(p_end_date, today_local + 92)::timestamp without time zone,
      interval '1 day'
    ) AS calendar(day_value)
    JOIN public.shift_schedule_templates AS template
      ON (
        (extract(isodow FROM calendar.day_value)::integer = 7 AND template.code = 'third')
        OR extract(isodow FROM calendar.day_value)::integer BETWEEN 1 AND 4
        OR (
          extract(isodow FROM calendar.day_value)::integer = 5
          AND template.code IN ('first', 'second')
        )
      )
    JOIN LATERAL (
      SELECT history.time_zone
      FROM public.shift_schedule_time_zone_history AS history
      WHERE history.effective_from <= calendar.day_value::date
      ORDER BY history.effective_from DESC, history.created_at DESC, history.id DESC
      LIMIT 1
    ) AS zone ON true
    CROSS JOIN LATERAL (
      SELECT
        quote_studio_schedule_private.resolve_local_time(
          calendar.day_value::date + template.start_local,
          zone.time_zone
        ) AS starts_at,
        quote_studio_schedule_private.resolve_local_time(
          calendar.day_value::date
            + CASE WHEN template.end_local <= template.start_local THEN 1 ELSE 0 END
            + template.end_local,
          zone.time_zone
        ) AS ends_at
    ) AS interval_times
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.shift_schedule_instances AS instance
      WHERE instance.schedule_kind = 'regular'
        AND instance.template_code = template.code
        AND instance.local_start_date = calendar.day_value::date
    )
      AND EXISTS (
        SELECT 1
        FROM public.employee_shift_default_history AS assignment
        WHERE assignment.employee_id = auth.uid()
          AND assignment.template_code = template.code
          AND interval_times.starts_at >= assignment.effective_from
          AND (
            assignment.effective_to IS NULL
            OR interval_times.starts_at < assignment.effective_to
          )
      )
  ) AS schedule_row
  JOIN public.profiles AS profile
    ON profile.id = auth.uid()
   AND profile.role IN ('manager', 'supervisor', 'user', 'viewer', 'employee');
  RETURN result;
END;
$$;
ALTER FUNCTION public.get_shift_schedule(date, date, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_shift_schedule(date, date, boolean)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_shift_schedule(date, date, boolean) TO authenticated;

CREATE FUNCTION public.get_scheduled_shift_at(p_at timestamptz DEFAULT now())
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  configured_time_zone text;
  local_date date;
  weekday_number integer;
  template_row record;
  local_start timestamp without time zone;
  local_end timestamp without time zone;
  shift_start timestamptz;
  shift_end timestamptz;
  result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_at IS NULL OR p_at < now() - interval '93 days'
     OR p_at > now() + interval '93 days' THEN
    RAISE EXCEPTION 'Shift detection time must be within 93 days of now'
      USING ERRCODE = '22023';
  END IF;
  SELECT history.time_zone INTO configured_time_zone
  FROM public.shift_schedule_time_zone_history AS history
  WHERE history.effective_from <= (p_at AT TIME ZONE history.time_zone)::date
  ORDER BY history.effective_from DESC, history.created_at DESC, history.id DESC
  LIMIT 1;
  IF configured_time_zone IS NULL THEN
    RAISE EXCEPTION 'Shift schedule settings are not initialized'
      USING ERRCODE = '55000';
  END IF;
  local_date := (p_at AT TIME ZONE configured_time_zone)::date;

  SELECT jsonb_build_object(
    'name', CASE
      WHEN instance.schedule_kind = 'custom' THEN 'Custom scheduled shift'
      ELSE instance.name
    END,
    'time_zone', instance.time_zone,
    'starts_at', instance.starts_at,
    'ends_at', instance.ends_at
  )
  INTO result
  FROM public.shift_schedule_instances AS instance
  WHERE instance.starts_at <= p_at AND p_at < instance.ends_at
  ORDER BY instance.starts_at
  LIMIT 1;
  IF result IS NOT NULL THEN
    RETURN result;
  END IF;

  FOR local_date IN
    SELECT day_value::date
    FROM pg_catalog.generate_series(
      (local_date - 1)::timestamp,
      (local_date + 1)::timestamp,
      interval '1 day'
    ) AS days(day_value)
  LOOP
    SELECT history.time_zone INTO configured_time_zone
    FROM public.shift_schedule_time_zone_history AS history
    WHERE history.effective_from <= local_date
    ORDER BY history.effective_from DESC, history.created_at DESC, history.id DESC
    LIMIT 1;
    IF configured_time_zone IS NULL THEN
      CONTINUE;
    END IF;
    weekday_number := extract(isodow FROM local_date);
    FOR template_row IN
      SELECT code, name, start_local, end_local
      FROM public.shift_schedule_templates
      WHERE
        (weekday_number = 7 AND code = 'third')
        OR weekday_number BETWEEN 1 AND 4
        OR (weekday_number = 5 AND code IN ('first', 'second'))
    LOOP
      local_start := local_date + template_row.start_local;
      local_end := (
        local_date
        + CASE WHEN template_row.end_local <= template_row.start_local THEN 1 ELSE 0 END
      ) + template_row.end_local;
      shift_start := quote_studio_schedule_private.resolve_local_time(
        local_start, configured_time_zone
      );
      shift_end := quote_studio_schedule_private.resolve_local_time(
        local_end, configured_time_zone
      );
      IF shift_start <= p_at AND p_at < shift_end THEN
        RETURN pg_catalog.jsonb_build_object(
          'name', template_row.name,
          'time_zone', configured_time_zone,
          'starts_at', shift_start,
          'ends_at', shift_end
        );
      END IF;
    END LOOP;
  END LOOP;
  RETURN result;
END;
$$;
ALTER FUNCTION public.get_scheduled_shift_at(timestamptz) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_scheduled_shift_at(timestamptz)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_scheduled_shift_at(timestamptz) TO authenticated;

DO $postconditions$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) AS role_row(role_name)
    CROSS JOIN unnest(ARRAY[
      'public.shift_schedule_settings',
      'public.shift_schedule_time_zone_history',
      'public.shift_schedule_templates',
      'public.shift_schedule_instances',
      'public.employee_shift_default_history',
      'public.shift_assignment_override_history'
    ]) AS table_row(table_name)
    CROSS JOIN unnest(ARRAY[
      'SELECT', 'INSERT', 'UPDATE', 'DELETE',
      'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN'
    ]) AS privilege_row(privilege_name)
    WHERE pg_catalog.has_table_privilege(
      role_row.role_name, table_row.table_name, privilege_row.privilege_name
    )
  ) THEN
    RAISE EXCEPTION 'Unexpected effective table privilege on a shift scheduling table';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) AS role_row(role_name)
    CROSS JOIN unnest(ARRAY[
      'public.shift_schedule_settings',
      'public.shift_schedule_time_zone_history',
      'public.shift_schedule_templates',
      'public.shift_schedule_instances',
      'public.employee_shift_default_history',
      'public.shift_assignment_override_history'
    ]) AS table_row(table_name)
    CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'REFERENCES']) AS column_privilege(privilege_name)
    WHERE pg_catalog.has_any_column_privilege(
      role_row.role_name, table_row.table_name, column_privilege.privilege_name
    )
  ) THEN
    RAISE EXCEPTION 'Unexpected column-level access privilege on a shift scheduling table';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'public.get_shift_schedule_settings()',
      'public.get_shift_schedule_admin_data()',
      'public.set_shift_schedule_time_zone(text)',
      'public.materialize_shift_schedule(date,date)',
      'public.set_employee_default_shift(uuid,text)',
      'public.set_shift_instance_assignment(uuid,uuid,boolean)',
      'public.create_custom_shift(text,timestamp without time zone,timestamp without time zone)',
      'public.get_shift_schedule(date,date,boolean)',
      'public.get_scheduled_shift_at(timestamptz)',
      'quote_studio_schedule_private.is_assigned(uuid,uuid)',
      'quote_studio_schedule_private.resolve_local_time(timestamp without time zone,text)',
      'quote_studio_schedule_private.ensure_regular_shifts(date,date)',
      'quote_studio_schedule_private.assert_no_regular_overlap(timestamptz,timestamptz)',
      'quote_studio_schedule_private.validate_time_zone_cutover(text,date)'
    ]) AS routine(signature)
    CROSS JOIN unnest(ARRAY['anon', 'service_role']) AS role_row(role_name)
    WHERE pg_catalog.has_function_privilege(
      role_row.role_name, routine.signature, 'EXECUTE'
    )
  ) THEN
    RAISE EXCEPTION 'anon or service_role retains EXECUTE on a shift scheduling RPC';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS routine
    JOIN pg_catalog.pg_namespace AS routine_schema
      ON routine_schema.oid = routine.pronamespace
    CROSS JOIN unnest(ARRAY['anon', 'authenticated', 'service_role']) AS role_row(role_name)
    WHERE routine_schema.nspname = 'quote_studio_schedule_private'
      AND pg_catalog.has_function_privilege(
        role_row.role_name, routine.oid, 'EXECUTE'
      )
  ) THEN
    RAISE EXCEPTION 'An API role retains effective EXECUTE on a private scheduling helper';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'public.get_shift_schedule_settings()',
      'public.get_shift_schedule_admin_data()',
      'public.set_shift_schedule_time_zone(text)',
      'public.materialize_shift_schedule(date,date)',
      'public.set_employee_default_shift(uuid,text)',
      'public.set_shift_instance_assignment(uuid,uuid,boolean)',
      'public.create_custom_shift(text,timestamp without time zone,timestamp without time zone)',
      'public.get_shift_schedule(date,date,boolean)',
      'public.get_scheduled_shift_at(timestamptz)'
    ]) AS routine(signature)
    WHERE NOT pg_catalog.has_function_privilege(
      'authenticated', routine.signature, 'EXECUTE'
    )
  ) THEN
    RAISE EXCEPTION 'Required authenticated EXECUTE grant is missing';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) AS role_row(role_name)
    CROSS JOIN unnest(ARRAY['CREATE', 'USAGE']) AS privilege_row(privilege_name)
    WHERE pg_catalog.has_schema_privilege(
      role_row.role_name, 'quote_studio_schedule_private', privilege_row.privilege_name
    )
  ) THEN
    RAISE EXCEPTION 'Unexpected effective CREATE or USAGE privilege on the private shift scheduling schema';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_namespace AS schema_row
    WHERE schema_row.nspname = 'quote_studio_schedule_private'
      AND schema_row.nspowner = 'postgres'::pg_catalog.regrole::oid
  ) THEN
    RAISE EXCEPTION 'Private shift scheduling schema must remain postgres-owned';
  END IF;
END;
$postconditions$;

COMMIT;

/*
Staging-only verification (run manually after applying to an isolated Staging project):

-- Confirm initial setting and templates.
SELECT id, time_zone FROM public.shift_schedule_settings;
SELECT code, name, start_local, end_local
FROM public.shift_schedule_templates ORDER BY code;

-- Exercise authenticated RPCs in the application with an employee account:
-- get_shift_schedule_settings(), get_shift_schedule(current_date, current_date + 14, false),
-- get_scheduled_shift_at(now()).

-- Exercise administrative RPCs as Owner/Admin:
-- set_shift_schedule_time_zone('America/Los_Angeles')
-- materialize_shift_schedule(current_date, current_date + 14)
-- set_employee_default_shift('<disposable-employee-uuid>', 'first')
-- create_custom_shift('Weekend 12-hour', '<future-local-start>', '<future-local-end>')
-- set_shift_instance_assignment('<future-shift-uuid>', '<disposable-employee-uuid>', true)

-- Confirm application roles have no direct DML/TRUNCATE on the new tables and
-- anon cannot execute the scheduling RPCs using catalog privilege inspection.
-- Confirm a non-admin direct write and non-admin administrative RPC call fail.
-- Confirm schedule queries show only an employee's own assignments, while
-- Owner/Admin can pass p_admin_view=true to view all assignments; false always
-- limits the result to the caller's own assigned shifts.
-- Confirm repeated schedule queries preserve existing instance IDs/timestamps,
-- a timezone change does not rewrite existing instances, and past shifts are
-- never backfilled or editable.

No existing reports, alerts, inventory movements, or profiles are migrated or deleted.
*/
