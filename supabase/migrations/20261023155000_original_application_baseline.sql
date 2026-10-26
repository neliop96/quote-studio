-- Quote Studio: schema-only reconstruction from the 15 approved production
-- metadata queries collected 2026-10-25. No production rows or credentials.
-- STAGING ONLY: target bzejwackkozoqqrxfnrz after separate execution approval.
-- Preserves audited broad ACLs intentionally; see STAGING_PRIVILEGE_REVIEW.md.
-- Apply once to an empty application schema, as postgres, before all six deltas.
BEGIN;
SET LOCAL search_path = public, pg_catalog;

DO $baseline_prerequisites$
DECLARE
  object_name text;
BEGIN
  IF current_user <> 'postgres' THEN
    RAISE EXCEPTION 'Baseline must run as postgres';
  END IF;
  IF current_setting('server_version_num')::integer < 170000 THEN
    RAISE EXCEPTION 'Audited MAINTAIN privileges require PostgreSQL 17 or newer; review compatibility before applying';
  END IF;
  IF pg_catalog.to_regclass('auth.users') IS NULL
     OR pg_catalog.to_regprocedure('auth.uid()') IS NULL
     OR pg_catalog.to_regprocedure('gen_random_uuid()') IS NULL THEN
    RAISE EXCEPTION 'Requires an initialized Supabase database: auth.users, auth.uid(), gen_random_uuid()';
  END IF;
  FOREACH object_name IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = object_name) THEN
      RAISE EXCEPTION 'Missing Supabase role: %', object_name;
    END IF;
  END LOOP;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
  ) OR EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_depend d
        WHERE d.classid = 'pg_catalog.pg_proc'::pg_catalog.regclass
          AND d.objid = p.oid AND d.deptype = 'e'
      )
  ) OR pg_catalog.to_regnamespace('quote_studio_inventory_private') IS NOT NULL THEN
    RAISE EXCEPTION 'Expected empty application schema; do not apply this baseline to production or an existing app';
  END IF;
END;
$baseline_prerequisites$;

-- Application permissions only; platform schema ownership and managed roles are
-- prerequisites, not recreated here. These are the audited postgres defaults.
GRANT USAGE ON SCHEMA public TO PUBLIC, postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN
  ON TABLES TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT SELECT, UPDATE, USAGE ON SEQUENCES TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO postgres, anon, authenticated, service_role;

CREATE TABLE public."profiles" (
  "id" uuid NOT NULL,
  "full_name" text COLLATE "default" DEFAULT ''::text NOT NULL,
  "role" text COLLATE "default" DEFAULT 'employee'::text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE public."profiles" OWNER TO postgres;
ALTER TABLE public."profiles" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."products" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "part" text COLLATE "default" NOT NULL,
  "category" text COLLATE "default" DEFAULT ''::text NOT NULL,
  "subcategory" text COLLATE "default" DEFAULT ''::text NOT NULL,
  "description" text COLLATE "default" DEFAULT ''::text NOT NULL,
  "supplier" text COLLATE "default" DEFAULT ''::text NOT NULL,
  "price" numeric(12,2) DEFAULT 0 NOT NULL,
  "active" boolean DEFAULT true NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE public."products" OWNER TO postgres;
ALTER TABLE public."products" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."customers" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "name" text COLLATE "default" NOT NULL,
  "contact" text COLLATE "default" DEFAULT ''::text NOT NULL,
  "email" text COLLATE "default" DEFAULT ''::text NOT NULL,
  "phone" text COLLATE "default" DEFAULT ''::text NOT NULL,
  "address" text COLLATE "default" DEFAULT ''::text NOT NULL,
  "notes" text COLLATE "default" DEFAULT ''::text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE public."customers" OWNER TO postgres;
ALTER TABLE public."customers" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."quote_settings" (
  "id" integer NOT NULL,
  "markup" numeric DEFAULT 20 NOT NULL,
  "labor_rate" numeric DEFAULT 75 NOT NULL,
  "tax_rate" numeric DEFAULT 8.625 NOT NULL,
  "labor_hours" numeric DEFAULT 0 NOT NULL
);
ALTER TABLE public."quote_settings" OWNER TO postgres;
ALTER TABLE public."quote_settings" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."quotes" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "quote_number" text COLLATE "default" NOT NULL,
  "customer_id" uuid,
  "customer_snapshot" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "items" jsonb DEFAULT '[]'::jsonb NOT NULL,
  "labor_hours" numeric(12,2) DEFAULT 0 NOT NULL,
  "labor_rate" numeric(12,2) DEFAULT 75 NOT NULL,
  "markup" numeric(8,3) DEFAULT 20 NOT NULL,
  "tax_rate" numeric(8,3) DEFAULT 8.625 NOT NULL,
  "notes" text COLLATE "default" DEFAULT ''::text NOT NULL,
  "status" text COLLATE "default" DEFAULT 'Draft'::text NOT NULL,
  "created_by" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE public."quotes" OWNER TO postgres;
ALTER TABLE public."quotes" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."inventory" (
  "product_id" uuid NOT NULL,
  "qty" integer DEFAULT 0 NOT NULL,
  "avg_cost" numeric(14,4) DEFAULT 0 NOT NULL,
  "reorder_level" integer DEFAULT 0 NOT NULL
);
ALTER TABLE public."inventory" OWNER TO postgres;
ALTER TABLE public."inventory" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."stock_movements" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "product_id" uuid NOT NULL,
  "movement_type" text COLLATE "default" NOT NULL,
  "delta" integer NOT NULL,
  "qty_after" integer NOT NULL,
  "unit_cost" numeric(14,4),
  "avg_cost_after" numeric(14,4) NOT NULL,
  "reference" text COLLATE "default" DEFAULT ''::text NOT NULL,
  "notes" text COLLATE "default" DEFAULT ''::text NOT NULL,
  "actor" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "archived_at" timestamp with time zone,
  "archived_by" uuid
);
ALTER TABLE public."stock_movements" OWNER TO postgres;
ALTER TABLE public."stock_movements" ENABLE ROW LEVEL SECURITY;

CREATE TABLE public."quotation_email_log" (
  "id" bigint GENERATED ALWAYS AS IDENTITY (SEQUENCE NAME public."quotation_email_log_id_seq" START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1 NO CYCLE) NOT NULL,
  "quote_id" uuid,
  "quote_number" text COLLATE "default" NOT NULL,
  "customer_email" text COLLATE "default" NOT NULL,
  "sent_by" uuid,
  "resend_id" text COLLATE "default",
  "subject" text COLLATE "default" NOT NULL,
  "detail" text COLLATE "default" NOT NULL,
  "delivery_status" text COLLATE "default" DEFAULT 'submitted'::text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE public."quotation_email_log" OWNER TO postgres;
ALTER TABLE public."quotation_email_log" ENABLE ROW LEVEL SECURITY;

ALTER TABLE public."customers" ADD CONSTRAINT "customers_pkey" PRIMARY KEY (id);
ALTER TABLE public."inventory" ADD CONSTRAINT "inventory_avg_cost_check" CHECK ((avg_cost >= (0)::numeric));
ALTER TABLE public."inventory" ADD CONSTRAINT "inventory_pkey" PRIMARY KEY (product_id);
ALTER TABLE public."inventory" ADD CONSTRAINT "inventory_qty_check" CHECK ((qty >= 0));
ALTER TABLE public."inventory" ADD CONSTRAINT "inventory_reorder_level_check" CHECK ((reorder_level >= 0));
ALTER TABLE public."products" ADD CONSTRAINT "products_part_key" UNIQUE (part);
ALTER TABLE public."products" ADD CONSTRAINT "products_pkey" PRIMARY KEY (id);
ALTER TABLE public."products" ADD CONSTRAINT "products_price_check" CHECK ((price >= (0)::numeric));
ALTER TABLE public."profiles" ADD CONSTRAINT "profiles_pkey" PRIMARY KEY (id);
ALTER TABLE public."profiles" ADD CONSTRAINT "profiles_role_check" CHECK (((role IS NOT NULL) AND (btrim(role) <> ''::text)));
ALTER TABLE public."quotation_email_log" ADD CONSTRAINT "quotation_email_log_detail_check" CHECK ((detail = ANY (ARRAY['project'::text, 'materials'::text])));
ALTER TABLE public."quotation_email_log" ADD CONSTRAINT "quotation_email_log_pkey" PRIMARY KEY (id);
ALTER TABLE public."quote_settings" ADD CONSTRAINT "quote_settings_id_check" CHECK ((id = 1));
ALTER TABLE public."quote_settings" ADD CONSTRAINT "quote_settings_labor_hours_check" CHECK ((labor_hours >= (0)::numeric));
ALTER TABLE public."quote_settings" ADD CONSTRAINT "quote_settings_labor_rate_check" CHECK ((labor_rate >= (0)::numeric));
ALTER TABLE public."quote_settings" ADD CONSTRAINT "quote_settings_markup_check" CHECK ((markup >= (0)::numeric));
ALTER TABLE public."quote_settings" ADD CONSTRAINT "quote_settings_pkey" PRIMARY KEY (id);
ALTER TABLE public."quote_settings" ADD CONSTRAINT "quote_settings_tax_rate_check" CHECK ((tax_rate >= (0)::numeric));
ALTER TABLE public."quotes" ADD CONSTRAINT "quotes_pkey" PRIMARY KEY (id);
ALTER TABLE public."quotes" ADD CONSTRAINT "quotes_quote_number_key" UNIQUE (quote_number);
ALTER TABLE public."stock_movements" ADD CONSTRAINT "stock_movements_movement_type_check" CHECK ((movement_type = ANY (ARRAY['receive'::text, 'issue'::text, 'adjust'::text])));
ALTER TABLE public."stock_movements" ADD CONSTRAINT "stock_movements_pkey" PRIMARY KEY (id);
ALTER TABLE public."inventory" ADD CONSTRAINT "inventory_product_id_fkey" FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE RESTRICT;
ALTER TABLE public."profiles" ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE public."quotation_email_log" ADD CONSTRAINT "quotation_email_log_sent_by_fkey" FOREIGN KEY (sent_by) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE public."quotes" ADD CONSTRAINT "quotes_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id);
ALTER TABLE public."quotes" ADD CONSTRAINT "quotes_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE SET NULL;
ALTER TABLE public."stock_movements" ADD CONSTRAINT "stock_movements_actor_fkey" FOREIGN KEY (actor) REFERENCES auth.users(id);
ALTER TABLE public."stock_movements" ADD CONSTRAINT "stock_movements_archived_by_fkey" FOREIGN KEY (archived_by) REFERENCES auth.users(id);
ALTER TABLE public."stock_movements" ADD CONSTRAINT "stock_movements_product_id_fkey" FOREIGN KEY (product_id) REFERENCES products(id);

-- Primary/unique indexes are created by their constraints above.
CREATE INDEX quotation_email_log_quote_id_idx ON public.quotation_email_log USING btree (quote_id);
CREATE INDEX quotes_date_idx ON public.quotes USING btree (created_at DESC);
CREATE INDEX stock_movements_date_idx ON public.stock_movements USING btree (created_at DESC);

-- Audited function bodies, preserved verbatim. The last migration replaces
-- record_stock_movement with the authorized inventory security implementation.

CREATE OR REPLACE FUNCTION public.admin_delete_quote(p_quote uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  ) then
    raise exception 'Admin permission required';
  end if;

  if p_quote is null then
    raise exception 'Quotation ID required';
  end if;

  delete from public.quotes where id = p_quote;
  if not found then
    raise exception 'Quotation not found';
  end if;
end;
$function$;
ALTER FUNCTION public."admin_delete_quote"(p_quote uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public."admin_delete_quote"(p_quote uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."admin_delete_quote"(p_quote uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public."admin_delete_quote"(p_quote uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.inventory_movement_actor_names()
 RETURNS TABLE(actor_id text, display_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select distinct m.actor::text as actor_id,
         nullif(btrim(p.full_name), '') as display_name
  from public.stock_movements as m
  join public.profiles as p on p.id::text = m.actor::text
  where auth.uid() is not null
    and exists (select 1 from public.profiles me where me.id = auth.uid())
    and nullif(btrim(p.full_name), '') is not null;
$function$;
ALTER FUNCTION public."inventory_movement_actor_names"() OWNER TO postgres;
REVOKE ALL ON FUNCTION public."inventory_movement_actor_names"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."inventory_movement_actor_names"() TO authenticated;
GRANT EXECUTE ON FUNCTION public."inventory_movement_actor_names"() TO service_role;

CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select exists(select 1 from public.profiles where id=auth.uid() and role='admin');
$function$;
ALTER FUNCTION public."is_admin"() OWNER TO postgres;
REVOKE ALL ON FUNCTION public."is_admin"() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."is_admin"() TO anon;
GRANT EXECUTE ON FUNCTION public."is_admin"() TO authenticated;
GRANT EXECUTE ON FUNCTION public."is_admin"() TO service_role;

CREATE OR REPLACE FUNCTION public.record_stock_movement(p_product uuid, p_type text, p_quantity integer, p_cost numeric DEFAULT NULL::numeric, p_reference text DEFAULT ''::text, p_notes text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_stock public.inventory%rowtype; v_delta integer; v_qty integer; v_avg numeric(14,4); v_cost numeric(14,4);
begin
 if auth.uid() is null then raise exception 'Login required'; end if;
 if not exists(select 1 from public.products where id=p_product and active=true) then raise exception 'Product not found or inactive'; end if;
 if p_type not in ('receive','issue','adjust') or p_quantity is null or p_quantity<0 or (p_type<>'adjust' and p_quantity=0) then raise exception 'Invalid transaction'; end if;
 if p_type='adjust' and length(trim(coalesce(p_notes,'')))=0 then raise exception 'Adjustment reason required'; end if;
 insert into public.inventory(product_id) values(p_product) on conflict(product_id) do nothing;
 select * into v_stock from public.inventory where product_id=p_product for update;
 v_delta := case when p_type='receive' then p_quantity when p_type='issue' then -p_quantity else p_quantity-v_stock.qty end;
 v_qty := v_stock.qty+v_delta;
 if v_qty<0 then raise exception 'Insufficient stock'; end if;
 v_avg := v_stock.avg_cost; v_cost:=null;
 if p_type='receive' then
   if p_cost is null or p_cost<0 then raise exception 'Valid receipt unit cost required'; end if;
   v_cost:=round(p_cost,4);
   v_avg:=round((v_stock.qty*v_stock.avg_cost+p_quantity*v_cost)/v_qty,4);
 end if;
 if v_qty=0 then v_avg:=0; end if;
 update public.inventory set qty=v_qty,avg_cost=v_avg where product_id=p_product;
 insert into public.stock_movements(product_id,movement_type,delta,qty_after,unit_cost,avg_cost_after,reference,notes,actor)
 values(p_product,p_type,v_delta,v_qty,v_cost,v_avg,coalesce(p_reference,''),coalesce(p_notes,''),auth.uid());
 return jsonb_build_object('qty',v_qty,'avg_cost',v_avg,'delta',v_delta);
end $function$;
ALTER FUNCTION public."record_stock_movement"(p_product uuid, p_type text, p_quantity integer, p_cost numeric, p_reference text, p_notes text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public."record_stock_movement"(p_product uuid, p_type text, p_quantity integer, p_cost numeric, p_reference text, p_notes text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."record_stock_movement"(p_product uuid, p_type text, p_quantity integer, p_cost numeric, p_reference text, p_notes text) TO anon;
GRANT EXECUTE ON FUNCTION public."record_stock_movement"(p_product uuid, p_type text, p_quantity integer, p_cost numeric, p_reference text, p_notes text) TO authenticated;
GRANT EXECUTE ON FUNCTION public."record_stock_movement"(p_product uuid, p_type text, p_quantity integer, p_cost numeric, p_reference text, p_notes text) TO service_role;

CREATE OR REPLACE FUNCTION public.set_reorder_level(p_product uuid, p_level integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null or not public.is_admin() then raise exception 'Admin required'; end if;
 if p_level is null or p_level<0 then raise exception 'Invalid reorder level'; end if;
 insert into public.inventory(product_id,reorder_level) values(p_product,p_level)
 on conflict(product_id) do update set reorder_level=excluded.reorder_level;
end $function$;
ALTER FUNCTION public."set_reorder_level"(p_product uuid, p_level integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public."set_reorder_level"(p_product uuid, p_level integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."set_reorder_level"(p_product uuid, p_level integer) TO anon;
GRANT EXECUTE ON FUNCTION public."set_reorder_level"(p_product uuid, p_level integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public."set_reorder_level"(p_product uuid, p_level integer) TO service_role;

CREATE OR REPLACE FUNCTION public.set_stock_movement_archived(p_movement uuid, p_archived boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  ) then
    raise exception 'Admin permission required';
  end if;

  if p_archived is null then
    raise exception 'Archive flag required';
  end if;

  update public.stock_movements
     set archived_at = case when p_archived then now() else null end,
         archived_by = case when p_archived then auth.uid() else null end
   where id = p_movement;

  if not found then
    raise exception 'Inventory movement not found';
  end if;
end;
$function$;
ALTER FUNCTION public."set_stock_movement_archived"(p_movement uuid, p_archived boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public."set_stock_movement_archived"(p_movement uuid, p_archived boolean) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public."set_stock_movement_archived"(p_movement uuid, p_archived boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public."set_stock_movement_archived"(p_movement uuid, p_archived boolean) TO service_role;

-- No auth.users profile-provisioning trigger was present in the audit.
-- The only audited application trigger belongs to the later handoff migration.

CREATE POLICY "customers admin delete" ON public."customers"
  AS PERMISSIVE FOR DELETE TO authenticated
  USING (is_admin());

CREATE POLICY "customers insert" ON public."customers"
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (true);

CREATE POLICY "customers read" ON public."customers"
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "customers update" ON public."customers"
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "inventory read" ON public."inventory"
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "products admin delete" ON public."products"
  AS PERMISSIVE FOR DELETE TO authenticated
  USING (is_admin());

CREATE POLICY "products admin insert" ON public."products"
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (is_admin());

CREATE POLICY "products admin update" ON public."products"
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (is_admin())
  WITH CHECK (is_admin());

CREATE POLICY "products read" ON public."products"
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "admin manage profiles" ON public."profiles"
  AS PERMISSIVE FOR ALL TO authenticated
  USING (is_admin())
  WITH CHECK (is_admin());

CREATE POLICY "profile read own or admin" ON public."profiles"
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (((id = auth.uid()) OR is_admin()));

CREATE POLICY "Admins insert quotation defaults" ON public."quote_settings"
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK ((EXISTS ( SELECT 1
   FROM profiles p
  WHERE ((p.id = auth.uid()) AND (p.role = 'admin'::text)))));

CREATE POLICY "Admins update quotation defaults" ON public."quote_settings"
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING ((EXISTS ( SELECT 1
   FROM profiles p
  WHERE ((p.id = auth.uid()) AND (p.role = 'admin'::text)))))
  WITH CHECK ((EXISTS ( SELECT 1
   FROM profiles p
  WHERE ((p.id = auth.uid()) AND (p.role = 'admin'::text)))));

CREATE POLICY "Team members read quotation defaults" ON public."quote_settings"
  AS PERMISSIVE FOR SELECT TO authenticated
  USING ((EXISTS ( SELECT 1
   FROM profiles p
  WHERE ((p.id = auth.uid()) AND (p.role = ANY (ARRAY['admin'::text, 'employee'::text]))))));

CREATE POLICY "quotes admin delete" ON public."quotes"
  AS PERMISSIVE FOR DELETE TO authenticated
  USING (is_admin());

CREATE POLICY "quotes insert" ON public."quotes"
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK ((created_by = auth.uid()));

CREATE POLICY "quotes read" ON public."quotes"
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "quotes update" ON public."quotes"
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((created_by = auth.uid()) OR is_admin()))
  WITH CHECK (((created_by = auth.uid()) OR is_admin()));

CREATE POLICY "movements read" ON public."stock_movements"
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (true);

-- Preserve audited object ACLs, including known unsafe privileges.
REVOKE ALL ON TABLE public."profiles" FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN
  ON TABLE public."profiles" TO anon, authenticated, service_role;
REVOKE ALL ON TABLE public."products" FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN
  ON TABLE public."products" TO anon, authenticated, service_role;
REVOKE ALL ON TABLE public."customers" FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN
  ON TABLE public."customers" TO anon, authenticated, service_role;
REVOKE ALL ON TABLE public."quote_settings" FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN
  ON TABLE public."quote_settings" TO authenticated, service_role;
REVOKE ALL ON TABLE public."quotes" FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN
  ON TABLE public."quotes" TO anon, authenticated, service_role;
REVOKE ALL ON TABLE public."inventory" FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN
  ON TABLE public."inventory" TO anon, authenticated, service_role;
REVOKE ALL ON TABLE public."stock_movements" FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN
  ON TABLE public."stock_movements" TO anon, authenticated, service_role;
REVOKE ALL ON TABLE public."quotation_email_log" FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN
  ON TABLE public."quotation_email_log" TO service_role;

REVOKE ALL ON SEQUENCE public.quotation_email_log_id_seq FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.quotation_email_log_id_seq TO anon, authenticated, service_role;

-- No settings rows, auth users, business data, or sequence current values copied.
COMMIT;

