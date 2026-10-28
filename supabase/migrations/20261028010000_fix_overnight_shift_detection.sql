-- Additive fix for Phase 1 shift scheduling.
--
-- Employee schedule results virtually generate regular shifts that an Owner/Admin
-- has not materialized yet. The generator started at today's local date, so an
-- overnight shift that began on the previous local day (for example a 3rd Shift
-- starting at 23:00 yesterday) was omitted while it was still running.
--
-- The generator now also considers the previous local day, but only for shifts
-- that have not ended yet. Completed historical shifts are never generated, and
-- materialized instances still take precedence (NOT EXISTS), so no duplicates are
-- produced. No data is written and no existing function other than
-- get_shift_schedule is changed.

CREATE OR REPLACE FUNCTION public.get_shift_schedule(
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
      GREATEST(p_start_date, today_local - 1)::timestamp without time zone,
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
      -- Past local days only contribute a shift that is still running.
      AND (
        calendar.day_value::date >= today_local
        OR interval_times.ends_at > pg_catalog.clock_timestamp()
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
