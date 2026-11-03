-- Local proposal only. Apply after the migration ending in 20261025230000.
BEGIN;

DO $prerequisites$
DECLARE
  required_name text;
BEGIN
  IF current_user <> 'postgres' THEN
    RAISE EXCEPTION 'Prerequisite failed: run this migration as postgres';
  END IF;

  FOREACH required_name IN ARRAY ARRAY[
    'anon', 'authenticated', 'service_role', 'postgres'
  ] LOOP
    IF pg_catalog.to_regrole(required_name) IS NULL THEN
      RAISE EXCEPTION 'Prerequisite failed: missing database role %', required_name;
    END IF;
  END LOOP;

  FOREACH required_name IN ARRAY ARRAY[
    'public.admin_delete_quote(uuid)',
    'public.inventory_movement_actor_names()',
    'public.is_admin()',
    'public.record_stock_movement(uuid,text,integer,numeric,text,text)',
    'public.set_reorder_level(uuid,integer)',
    'public.set_stock_movement_archived(uuid,boolean)',
    'public.get_estimate_number_settings()',
    'public.save_estimate_number_settings(text,integer)',
    'public.generate_estimate_number()',
    'public.submit_shift_report(uuid)',
    'public.get_shift_alert_settings()',
    'public.save_shift_alert_settings(text[])',
    'public.get_my_shift_alerts()',
    'public.mark_shift_alert_read(uuid)',
    'public.create_shift_alerts_for_submitted_report()'
  ] LOOP
    IF pg_catalog.to_regprocedure(required_name) IS NULL THEN
      RAISE EXCEPTION 'Prerequisite failed: missing application function %', required_name;
    END IF;
  END LOOP;
END;
$prerequisites$;

REVOKE ALL ON FUNCTION public.admin_delete_quote(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.inventory_movement_actor_names()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.is_admin()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.record_stock_movement(uuid, text, integer, numeric, text, text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_reorder_level(uuid, integer)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_stock_movement_archived(uuid, boolean)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_estimate_number_settings()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.save_estimate_number_settings(text, integer)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.generate_estimate_number()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.submit_shift_report(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_shift_alert_settings()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.save_shift_alert_settings(text[])
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_my_shift_alerts()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.mark_shift_alert_read(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_shift_alerts_for_submitted_report()
  FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.admin_delete_quote(uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.inventory_movement_actor_names()
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_admin()
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_stock_movement(uuid, text, integer, numeric, text, text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_reorder_level(uuid, integer)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_stock_movement_archived(uuid, boolean)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_estimate_number_settings()
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.save_estimate_number_settings(text, integer)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.generate_estimate_number()
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.submit_shift_report(uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_shift_alert_settings()
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.save_shift_alert_settings(text[])
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_shift_alerts()
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_shift_alert_read(uuid)
  TO authenticated, service_role;

DO $acl_assertions$
DECLARE
  target_function regprocedure;
BEGIN
  FOREACH target_function IN ARRAY ARRAY[
    'public.admin_delete_quote(uuid)'::regprocedure,
    'public.inventory_movement_actor_names()'::regprocedure,
    'public.is_admin()'::regprocedure,
    'public.record_stock_movement(uuid,text,integer,numeric,text,text)'::regprocedure,
    'public.set_reorder_level(uuid,integer)'::regprocedure,
    'public.set_stock_movement_archived(uuid,boolean)'::regprocedure,
    'public.get_estimate_number_settings()'::regprocedure,
    'public.save_estimate_number_settings(text,integer)'::regprocedure,
    'public.generate_estimate_number()'::regprocedure,
    'public.submit_shift_report(uuid)'::regprocedure,
    'public.get_shift_alert_settings()'::regprocedure,
    'public.save_shift_alert_settings(text[])'::regprocedure,
    'public.get_my_shift_alerts()'::regprocedure,
    'public.mark_shift_alert_read(uuid)'::regprocedure,
    'public.create_shift_alerts_for_submitted_report()'::regprocedure
  ] LOOP
    IF pg_catalog.has_function_privilege('anon', target_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'Anonymous EXECUTE remains effective for %', target_function;
    END IF;
  END LOOP;

  FOREACH target_function IN ARRAY ARRAY[
    'public.admin_delete_quote(uuid)'::regprocedure,
    'public.inventory_movement_actor_names()'::regprocedure,
    'public.is_admin()'::regprocedure,
    'public.record_stock_movement(uuid,text,integer,numeric,text,text)'::regprocedure,
    'public.set_reorder_level(uuid,integer)'::regprocedure,
    'public.set_stock_movement_archived(uuid,boolean)'::regprocedure,
    'public.get_estimate_number_settings()'::regprocedure,
    'public.save_estimate_number_settings(text,integer)'::regprocedure,
    'public.generate_estimate_number()'::regprocedure,
    'public.submit_shift_report(uuid)'::regprocedure,
    'public.get_shift_alert_settings()'::regprocedure,
    'public.save_shift_alert_settings(text[])'::regprocedure,
    'public.get_my_shift_alerts()'::regprocedure,
    'public.mark_shift_alert_read(uuid)'::regprocedure
  ] LOOP
    IF NOT pg_catalog.has_function_privilege('authenticated', target_function, 'EXECUTE')
       OR NOT pg_catalog.has_function_privilege('service_role', target_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'Expected authenticated/service_role EXECUTE is missing for %', target_function;
    END IF;
  END LOOP;

  IF pg_catalog.has_function_privilege(
       'authenticated', 'public.create_shift_alerts_for_submitted_report()'::regprocedure, 'EXECUTE'
     ) OR pg_catalog.has_function_privilege(
       'service_role', 'public.create_shift_alerts_for_submitted_report()'::regprocedure, 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Trigger-only shift-alert function remains executable by an application role';
  END IF;
END;
$acl_assertions$;

COMMIT;