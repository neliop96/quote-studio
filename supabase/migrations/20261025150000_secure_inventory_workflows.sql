-- Local preparation only. Requires the audited Quote Studio baseline and shift migrations.
-- Fail on a pre-existing schema rather than trusting its ownership or ACLs.
BEGIN;

-- Catalog checks only: no application functions or records are accessed.
DO $prerequisites$
DECLARE
  required_name text;
  required_column record;
BEGIN
  IF pg_catalog.to_regnamespace('quote_studio_inventory_private') IS NOT NULL THEN
    RAISE EXCEPTION 'Prerequisite failed: quote_studio_inventory_private already exists; review ownership and ACLs before proceeding';
  END IF;
  FOREACH required_name IN ARRAY ARRAY['public', 'auth'] LOOP
    IF pg_catalog.to_regnamespace(required_name) IS NULL THEN
      RAISE EXCEPTION 'Prerequisite failed: missing schema %', required_name;
    END IF;
  END LOOP;
  FOREACH required_name IN ARRAY ARRAY['postgres', 'anon', 'authenticated', 'service_role'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = required_name) THEN
      RAISE EXCEPTION 'Prerequisite failed: missing database role %', required_name;
    END IF;
  END LOOP;
  IF current_user <> 'postgres' THEN
    RAISE EXCEPTION 'Prerequisite failed: run this migration as postgres to ensure predictable ownership and default ACLs';
  END IF;
  IF NOT pg_catalog.has_database_privilege(current_user, current_database(), 'CREATE') THEN
    RAISE EXCEPTION 'Prerequisite failed: postgres requires database CREATE privilege for the private schema';
  END IF;
  FOREACH required_name IN ARRAY ARRAY[
    'public.profiles', 'public.products', 'public.inventory', 'public.stock_movements',
    'public.shift_reports', 'public.shift_alert_settings', 'public.shift_alerts', 'public.shift_alert_reads'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_class
      WHERE oid = pg_catalog.to_regclass(required_name) AND relkind IN ('r', 'p')
    ) THEN
      RAISE EXCEPTION 'Prerequisite failed: missing application table %; install the audited baseline and shift migrations', required_name;
    END IF;
  END LOOP;
  FOR required_column IN
    SELECT * FROM (VALUES
      ('public.profiles', 'id'), ('public.profiles', 'role'),
      ('public.products', 'id'), ('public.products', 'active'),
      ('public.inventory', 'product_id'), ('public.inventory', 'qty'),
      ('public.inventory', 'avg_cost'), ('public.inventory', 'reorder_level'),
      ('public.stock_movements', 'product_id'), ('public.stock_movements', 'movement_type'),
      ('public.stock_movements', 'delta'), ('public.stock_movements', 'qty_after'),
      ('public.stock_movements', 'unit_cost'), ('public.stock_movements', 'avg_cost_after'),
      ('public.stock_movements', 'reference'), ('public.stock_movements', 'notes'),
      ('public.stock_movements', 'actor'), ('public.shift_reports', 'id'),
      ('public.shift_reports', 'created_by'), ('public.shift_reports', 'status'),
      ('public.shift_reports', 'tasks'), ('public.shift_reports', 'shift_name'),
      ('public.shift_reports', 'submitted_by'), ('public.shift_reports', 'submitted_at'),
      ('public.shift_alert_settings', 'id'), ('public.shift_alert_settings', 'recipient_roles'),
      ('public.shift_alerts', 'report_id'), ('public.shift_alerts', 'task_index'),
      ('public.shift_alerts', 'recipient_role'), ('public.shift_alerts', 'task_title'),
      ('public.shift_alerts', 'handoff_note')
    ) AS required_columns(table_name, column_name)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_attribute
      WHERE attrelid = pg_catalog.to_regclass(required_column.table_name)
        AND attname = required_column.column_name AND attnum > 0 AND NOT attisdropped
    ) THEN
      RAISE EXCEPTION 'Prerequisite failed: missing column %.%', required_column.table_name, required_column.column_name;
    END IF;
  END LOOP;
  FOREACH required_name IN ARRAY ARRAY[
    'auth.uid()', 'public.is_admin()',
    'public.record_stock_movement(uuid,text,integer,numeric,text,text)',
    'public.submit_shift_report(uuid)', 'public.create_shift_alerts_for_submitted_report()'
  ] LOOP
    IF pg_catalog.to_regprocedure(required_name) IS NULL THEN
      RAISE EXCEPTION 'Prerequisite failed: missing function %', required_name;
    END IF;
  END LOOP;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc
    WHERE oid IN (
      pg_catalog.to_regprocedure('public.record_stock_movement(uuid,text,integer,numeric,text,text)'),
      pg_catalog.to_regprocedure('public.submit_shift_report(uuid)')
    ) AND proowner <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'postgres')
  ) THEN
    RAISE EXCEPTION 'Prerequisite failed: public inventory and submission functions must be owned by postgres';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger
    WHERE tgrelid = 'public.shift_reports'::pg_catalog.regclass
      AND tgname = 'create_shift_alerts_after_report_submission'
      AND tgfoid = pg_catalog.to_regprocedure('public.create_shift_alerts_for_submitted_report()')
      AND NOT tgisinternal AND tgenabled IN ('O', 'A')
      AND tgtype::integer = 17 -- AFTER UPDATE, FOR EACH ROW
  ) THEN
    RAISE EXCEPTION 'Prerequisite failed: expected enabled AFTER UPDATE row-level shift-report alert trigger is missing or incompatible';
  END IF;
END;
$prerequisites$;

CREATE SCHEMA quote_studio_inventory_private AUTHORIZATION postgres;
REVOKE ALL ON SCHEMA quote_studio_inventory_private FROM PUBLIC, anon, authenticated, service_role;

-- Invoker security: only the postgres-owned public wrappers may use this helper.
CREATE FUNCTION quote_studio_inventory_private.record_stock_movement(
  p_product uuid, p_type text, p_quantity integer,
  p_cost numeric DEFAULT NULL, p_reference text DEFAULT '', p_notes text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_stock public.inventory%rowtype;
  v_delta integer;
  v_qty integer;
  v_avg numeric(14,4);
  v_cost numeric(14,4);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = p_product AND active = true) THEN
    RAISE EXCEPTION 'Product not found or inactive';
  END IF;
  IF p_type IS NULL OR p_type NOT IN ('receive', 'issue', 'adjust')
     OR p_quantity IS NULL OR p_quantity < 0
     OR (p_type <> 'adjust' AND p_quantity = 0) THEN
    RAISE EXCEPTION 'Invalid transaction';
  END IF;
  IF p_type = 'adjust' AND length(trim(coalesce(p_notes, ''))) = 0 THEN
    RAISE EXCEPTION 'Adjustment reason required';
  END IF;

  INSERT INTO public.inventory(product_id) VALUES (p_product)
  ON CONFLICT (product_id) DO NOTHING;
  SELECT * INTO v_stock FROM public.inventory WHERE product_id = p_product FOR UPDATE;
  v_delta := CASE WHEN p_type = 'receive' THEN p_quantity
                  WHEN p_type = 'issue' THEN -p_quantity
                  ELSE p_quantity - v_stock.qty END;
  v_qty := v_stock.qty + v_delta;
  IF v_qty < 0 THEN RAISE EXCEPTION 'Insufficient stock'; END IF;
  v_avg := v_stock.avg_cost;
  v_cost := NULL;
  IF p_type = 'receive' THEN
    IF p_cost IS NULL OR p_cost < 0 THEN RAISE EXCEPTION 'Valid receipt unit cost required'; END IF;
    v_cost := round(p_cost, 4);
    v_avg := round((v_stock.qty * v_stock.avg_cost + p_quantity * v_cost) / v_qty, 4);
  END IF;
  IF v_qty = 0 THEN v_avg := 0; END IF;
  UPDATE public.inventory SET qty = v_qty, avg_cost = v_avg WHERE product_id = p_product;
  INSERT INTO public.stock_movements(
    product_id, movement_type, delta, qty_after, unit_cost, avg_cost_after, reference, notes, actor
  ) VALUES (
    p_product, p_type, v_delta, v_qty, v_cost, v_avg,
    coalesce(p_reference, ''), coalesce(p_notes, ''), auth.uid()
  );
  RETURN jsonb_build_object('qty', v_qty, 'avg_cost', v_avg, 'delta', v_delta);
END;
$$;
ALTER FUNCTION quote_studio_inventory_private.record_stock_movement(uuid, text, integer, numeric, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION quote_studio_inventory_private.record_stock_movement(uuid, text, integer, numeric, text, text)
FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.record_stock_movement(
  p_product uuid, p_type text, p_quantity integer,
  p_cost numeric DEFAULT NULL, p_reference text DEFAULT '', p_notes text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('owner', 'admin', 'manager')
  ) THEN
    RAISE EXCEPTION 'Inventory change permission required' USING ERRCODE = '42501';
  END IF;
  RETURN quote_studio_inventory_private.record_stock_movement(
    p_product, p_type, p_quantity, p_cost, p_reference, p_notes
  );
END;
$$;
ALTER FUNCTION public.record_stock_movement(uuid, text, integer, numeric, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.record_stock_movement(uuid, text, integer, numeric, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_stock_movement(uuid, text, integer, numeric, text, text) TO authenticated;

create or replace function public.submit_shift_report(p_report uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_report public.shift_reports%rowtype;
  v_task jsonb;
  v_item jsonb;
  v_product_id uuid;
  v_quantity integer;
  v_notes text;
  v_movement_count integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1 from public.profiles
    where id = auth.uid()
      and role in ('owner', 'admin', 'manager', 'supervisor', 'user', 'employee')
  ) then
    raise exception 'Shift submission permission required' using errcode = '42501';
  end if;

  select *
  into v_report
  from public.shift_reports
  where id = p_report
  for update;

  if not found then
    raise exception 'Shift report not found';
  end if;
  if v_report.created_by is distinct from auth.uid() then
    raise exception 'Only your own shift reports may be submitted' using errcode = '42501';
  end if;
  if v_report.status <> 'draft' then
    raise exception 'Only draft shift reports can be submitted';
  end if;
  if jsonb_typeof(v_report.tasks) is distinct from 'array'
     or jsonb_array_length(v_report.tasks) = 0 then
    raise exception 'Add at least one task before submitting';
  end if;

  for v_task in
    select task.value
    from jsonb_array_elements(v_report.tasks) as task(value)
  loop
    if coalesce(length(trim(v_task ->> 'title')), 0) = 0 then
      raise exception 'Each task must have a title';
    end if;
    if jsonb_typeof(v_task -> 'items') is distinct from 'array' then
      raise exception 'Each task must have a product list';
    end if;

    for v_item in
      select item.value
      from jsonb_array_elements(v_task -> 'items') as item(value)
    loop
      if coalesce(v_item ->> 'product_id', '') !~
         '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
         or coalesce(v_item ->> 'qty', '') !~ '^[1-9][0-9]*$' then
        raise exception 'Each product needs a valid ID and positive whole-number quantity';
      end if;

      v_product_id := (v_item ->> 'product_id')::uuid;
      v_quantity := (v_item ->> 'qty')::integer;

      if not exists (
        select 1
        from public.products
        where id = v_product_id
          and active = true
      ) then
        raise exception 'A report product is no longer active';
      end if;

      v_notes := left(
        'Shift: ' || v_report.shift_name || '; Task: ' || (v_task ->> 'title')
          || case
               when coalesce(v_task ->> 'notes', '') = '' then ''
               else '; ' || (v_task ->> 'notes')
             end,
        4000
      );

      perform quote_studio_inventory_private.record_stock_movement(
        v_product_id,
        'issue',
        v_quantity,
        null::numeric,
        left('Shift report ' || v_report.id::text, 120),
        v_notes
      );
      v_movement_count := v_movement_count + 1;
    end loop;
  end loop;

  update public.shift_reports
  set status = 'submitted',
      submitted_by = auth.uid(),
      submitted_at = now()
  where id = p_report;

  return jsonb_build_object(
    'report_id', p_report,
    'movement_count', v_movement_count,
    'submitted_at', now()
  );
end;
$$;

alter function public.submit_shift_report(uuid) owner to postgres;
revoke all on function public.submit_shift_report(uuid) from public, anon;
grant execute on function public.submit_shift_report(uuid) to authenticated;

COMMIT;

