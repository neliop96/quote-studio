-- Quote Studio - STAGING FIRST. Do not apply to LIVE without separate approval.
-- Adds estimate statuses, status history, revisions, dates, validity and
-- issued-version protection. Additive: existing quotations, numbers and rows are
-- preserved. Run as postgres. Requires the baseline quotes, quote_settings and
-- quotation_email_log tables and public.is_admin().
--
-- Model: every version is its own row in public.quotes. An original has
-- revision_number 0 and root_quote_id = id. A revision has revision_number > 0,
-- root_quote_id = the original's id and quote_number '<original>-R<n>'.
-- Draft and Ready are editable. Sent, Approved, Rejected and Expired are issued
-- and their contents are immutable; changes require a new revision.
BEGIN;

DO $prerequisites$
BEGIN
  IF current_user <> 'postgres' THEN
    RAISE EXCEPTION 'Prerequisite failed: run this migration as postgres';
  END IF;
  IF pg_catalog.to_regclass('public.quotes') IS NULL
     OR pg_catalog.to_regclass('public.quote_settings') IS NULL
     OR pg_catalog.to_regclass('public.quotation_email_log') IS NULL
     OR pg_catalog.to_regprocedure('public.is_admin()') IS NULL
     OR pg_catalog.to_regprocedure('auth.uid()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite failed: quotes, quote_settings, quotation_email_log, is_admin() and auth.uid() are required';
  END IF;
  IF pg_catalog.to_regclass('public.quote_status_history') IS NOT NULL
     OR EXISTS (
       SELECT 1 FROM pg_catalog.pg_attribute
       WHERE attrelid = 'public.quotes'::pg_catalog.regclass
         AND attname IN ('root_quote_id', 'revision_number', 'source_quote_id',
                         'original_estimate_date', 'revision_date', 'validity_days',
                         'valid_until', 'is_current_approved')
         AND NOT attisdropped
     )
     OR EXISTS (
       SELECT 1 FROM pg_catalog.pg_attribute
       WHERE attrelid = 'public.quote_settings'::pg_catalog.regclass
         AND attname IN ('validity_days', 'quote_time_zone')
         AND NOT attisdropped
     ) THEN
    RAISE EXCEPTION 'Prerequisite failed: estimate revision objects already exist; reconcile before applying';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.quotes
    WHERE status NOT IN ('Draft', 'Ready', 'Sent', 'Approved', 'Rejected', 'Expired')
  ) THEN
    RAISE EXCEPTION 'Prerequisite failed: quotes contain statuses outside Draft, Ready, Sent, Approved, Rejected, Expired';
  END IF;
END;
$prerequisites$;

-- Settings: default validity and the business time zone used for estimate dates.
ALTER TABLE public.quote_settings
  ADD COLUMN validity_days integer NOT NULL DEFAULT 30,
  ADD COLUMN quote_time_zone text NOT NULL DEFAULT 'America/Los_Angeles';
ALTER TABLE public.quote_settings
  ADD CONSTRAINT quote_settings_validity_days_check CHECK (validity_days BETWEEN 1 AND 365),
  ADD CONSTRAINT quote_settings_quote_time_zone_check
    CHECK ((pg_catalog.now() AT TIME ZONE quote_time_zone) IS NOT NULL);

ALTER TABLE public.quotes
  ADD COLUMN root_quote_id uuid,
  ADD COLUMN revision_number integer NOT NULL DEFAULT 0,
  ADD COLUMN source_quote_id uuid,
  ADD COLUMN original_estimate_date date,
  ADD COLUMN revision_date date,
  ADD COLUMN validity_days integer NOT NULL DEFAULT 30,
  ADD COLUMN valid_until date,
  ADD COLUMN is_current_approved boolean NOT NULL DEFAULT false;

-- Backfill. Legacy issued quotations keep their contents and numbers. Their
-- original date is the local creation date. valid_until stays NULL because no
-- validity period was promised when they were issued, so they never auto-expire.
UPDATE public.quotes AS q
SET root_quote_id = q.id,
    original_estimate_date = CASE
      WHEN q.status = 'Draft' THEN NULL
      ELSE (q.created_at AT TIME ZONE COALESCE(
        (SELECT s.quote_time_zone FROM public.quote_settings AS s WHERE s.id = 1),
        'America/Los_Angeles'))::date
    END,
    is_current_approved = (q.status = 'Approved');

ALTER TABLE public.quotes ALTER COLUMN root_quote_id SET NOT NULL;
ALTER TABLE public.quotes
  ADD CONSTRAINT quotes_root_quote_id_fkey
    FOREIGN KEY (root_quote_id) REFERENCES public.quotes(id),
  ADD CONSTRAINT quotes_source_quote_id_fkey
    FOREIGN KEY (source_quote_id) REFERENCES public.quotes(id),
  ADD CONSTRAINT quotes_status_check
    CHECK (status IN ('Draft', 'Ready', 'Sent', 'Approved', 'Rejected', 'Expired')),
  ADD CONSTRAINT quotes_revision_shape_check CHECK (
    (revision_number = 0 AND source_quote_id IS NULL AND root_quote_id = id AND revision_date IS NULL)
    OR (revision_number > 0 AND source_quote_id IS NOT NULL AND root_quote_id <> id)
  ),
  ADD CONSTRAINT quotes_validity_days_check CHECK (validity_days BETWEEN 1 AND 365),
  ADD CONSTRAINT quotes_family_revision_key UNIQUE (root_quote_id, revision_number);
CREATE UNIQUE INDEX quotes_one_current_approved_idx
  ON public.quotes (root_quote_id) WHERE is_current_approved;
CREATE INDEX quotes_root_quote_id_idx ON public.quotes (root_quote_id);
CREATE INDEX quotes_status_idx ON public.quotes (status);

CREATE TABLE public.quote_status_history (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  quote_id uuid NOT NULL REFERENCES public.quotes(id) ON DELETE CASCADE,
  from_status text,
  to_status text NOT NULL,
  changed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  changed_at timestamptz NOT NULL DEFAULT now(),
  note text NOT NULL DEFAULT ''
);
ALTER TABLE public.quote_status_history OWNER TO postgres;
ALTER TABLE public.quote_status_history ENABLE ROW LEVEL SECURITY;
CREATE INDEX quote_status_history_quote_id_idx
  ON public.quote_status_history (quote_id, changed_at);
CREATE POLICY "quote status history read" ON public.quote_status_history
  AS PERMISSIVE FOR SELECT TO authenticated USING (true);
REVOKE ALL ON TABLE public.quote_status_history FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.quote_status_history TO authenticated, service_role;

INSERT INTO public.quote_status_history (quote_id, from_status, to_status, changed_at, note)
SELECT q.id, NULL, q.status, q.updated_at, 'Recorded when estimate status history was introduced'
FROM public.quotes AS q;

CREATE FUNCTION public.quote_studio_business_date()
RETURNS date
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT (pg_catalog.now() AT TIME ZONE COALESCE(
    (SELECT s.quote_time_zone FROM public.quote_settings AS s WHERE s.id = 1),
    'America/Los_Angeles'))::date
$$;
ALTER FUNCTION public.quote_studio_business_date() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.quote_studio_business_date()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quote_studio_business_date() TO authenticated, service_role;

-- Invoker-security guard. current_user is 'postgres' only inside the SECURITY
-- DEFINER RPCs below (or a trusted administrative session), 'service_role' for
-- the Edge Function, and an API role otherwise.
CREATE FUNCTION public.quote_estimate_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_actor text := CASE current_user
    WHEN 'postgres' THEN 'trusted'
    WHEN 'service_role' THEN 'service'
    ELSE 'user' END;
  v_issued_status constant text[] := ARRAY['Sent', 'Approved', 'Rejected', 'Expired'];
  v_had_issue_date boolean;
  v_issue_date date;
  v_allowed boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF v_actor <> 'trusted' THEN
      IF NEW.status NOT IN ('Draft', 'Ready') THEN
        RAISE EXCEPTION 'New estimates must start as Draft or Ready' USING ERRCODE = '42501';
      END IF;
      IF NEW.quote_number ~ '-R[0-9]+$' THEN
        RAISE EXCEPTION 'Revision numbers are assigned automatically' USING ERRCODE = '42501';
      END IF;
      NEW.root_quote_id := NEW.id;
      NEW.revision_number := 0;
      NEW.source_quote_id := NULL;
      NEW.revision_date := NULL;
      NEW.original_estimate_date := NULL;
      NEW.valid_until := NULL;
      NEW.is_current_approved := false;
    END IF;
    IF NEW.root_quote_id IS NULL THEN
      NEW.root_quote_id := NEW.id;
    END IF;
    v_had_issue_date := false;
  ELSE
    IF v_actor <> 'trusted' THEN
      IF NEW.id IS DISTINCT FROM OLD.id
         OR NEW.root_quote_id IS DISTINCT FROM OLD.root_quote_id
         OR NEW.revision_number IS DISTINCT FROM OLD.revision_number
         OR NEW.source_quote_id IS DISTINCT FROM OLD.source_quote_id
         OR NEW.original_estimate_date IS DISTINCT FROM OLD.original_estimate_date
         OR NEW.revision_date IS DISTINCT FROM OLD.revision_date
         OR NEW.valid_until IS DISTINCT FROM OLD.valid_until
         OR NEW.is_current_approved IS DISTINCT FROM OLD.is_current_approved
         OR NEW.created_by IS DISTINCT FROM OLD.created_by
         OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'System-managed estimate fields cannot be changed directly'
          USING ERRCODE = '42501';
      END IF;
      NEW.updated_at := pg_catalog.now();
    END IF;

    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.root_quote_id IS DISTINCT FROM OLD.root_quote_id
       OR NEW.revision_number IS DISTINCT FROM OLD.revision_number
       OR NEW.source_quote_id IS DISTINCT FROM OLD.source_quote_id THEN
      RAISE EXCEPTION 'Estimate version identity cannot be changed' USING ERRCODE = '42501';
    END IF;

    IF OLD.status = ANY (v_issued_status) THEN
      IF NEW.quote_number IS DISTINCT FROM OLD.quote_number
         OR NEW.project_name IS DISTINCT FROM OLD.project_name
         OR NEW.customer_id IS DISTINCT FROM OLD.customer_id
         OR NEW.customer_snapshot IS DISTINCT FROM OLD.customer_snapshot
         OR NEW.items IS DISTINCT FROM OLD.items
         OR NEW.labor_hours IS DISTINCT FROM OLD.labor_hours
         OR NEW.labor_rate IS DISTINCT FROM OLD.labor_rate
         OR NEW.markup IS DISTINCT FROM OLD.markup
         OR NEW.tax_rate IS DISTINCT FROM OLD.tax_rate
         OR NEW.notes IS DISTINCT FROM OLD.notes
         OR NEW.validity_days IS DISTINCT FROM OLD.validity_days
         OR NEW.original_estimate_date IS DISTINCT FROM OLD.original_estimate_date
         OR NEW.revision_date IS DISTINCT FROM OLD.revision_date
         OR NEW.valid_until IS DISTINCT FROM OLD.valid_until
         OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        RAISE EXCEPTION 'Issued estimates are read-only; create a revision instead'
          USING ERRCODE = '42501';
      END IF;
    ELSIF NEW.quote_number IS DISTINCT FROM OLD.quote_number
          AND (OLD.revision_number > 0 OR NEW.quote_number ~ '-R[0-9]+$') THEN
      RAISE EXCEPTION 'Revision numbers are assigned automatically' USING ERRCODE = '42501';
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
      v_allowed :=
        (OLD.status = 'Draft' AND NEW.status = 'Ready')
        OR (OLD.status = 'Ready' AND NEW.status = 'Draft')
        OR (v_actor IN ('trusted', 'service')
            AND OLD.status IN ('Draft', 'Ready') AND NEW.status = 'Sent')
        OR (v_actor = 'trusted'
            AND OLD.status = 'Sent' AND NEW.status IN ('Approved', 'Rejected', 'Expired'));
      IF NOT v_allowed THEN
        RAISE EXCEPTION 'Invalid estimate status change from % to %', OLD.status, NEW.status
          USING ERRCODE = '42501';
      END IF;
    END IF;
    v_had_issue_date := CASE WHEN NEW.revision_number = 0
      THEN OLD.original_estimate_date IS NOT NULL
      ELSE OLD.revision_date IS NOT NULL END;
  END IF;

  IF NEW.is_current_approved AND NEW.status <> 'Approved' THEN
    RAISE EXCEPTION 'Only an Approved estimate can be the current approved version'
      USING ERRCODE = '23514';
  END IF;

  -- The issue date is assigned once, when the version is first marked Ready or
  -- Sent. Later edits never reset it. valid_until follows the issue date and the
  -- per-estimate validity period.
  IF NEW.status IN ('Ready', 'Sent') THEN
    IF NEW.revision_number = 0 THEN
      IF NEW.original_estimate_date IS NULL THEN
        NEW.original_estimate_date := public.quote_studio_business_date();
      END IF;
    ELSIF NEW.revision_date IS NULL THEN
      NEW.revision_date := public.quote_studio_business_date();
    END IF;
  END IF;
  v_issue_date := CASE WHEN NEW.revision_number = 0
    THEN NEW.original_estimate_date ELSE NEW.revision_date END;
  IF v_issue_date IS NOT NULL
     AND (TG_OP = 'INSERT'
          OR NOT v_had_issue_date
          OR NEW.validity_days IS DISTINCT FROM OLD.validity_days) THEN
    NEW.valid_until := v_issue_date + NEW.validity_days;
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION public.quote_estimate_guard() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.quote_estimate_guard()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.quote_estimate_truncate_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF current_user <> 'postgres' THEN
    RAISE EXCEPTION 'Estimates cannot be truncated' USING ERRCODE = '42501';
  END IF;
  RETURN NULL;
END;
$$;
ALTER FUNCTION public.quote_estimate_truncate_guard() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.quote_estimate_truncate_guard()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.quote_status_history_recorder()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.quote_status_history (quote_id, from_status, to_status, changed_by, note)
    VALUES (
      NEW.id,
      CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END,
      NEW.status,
      auth.uid(),
      COALESCE(pg_catalog.current_setting('quote_studio.status_note', true), '')
    );
  END IF;
  RETURN NULL;
END;
$$;
ALTER FUNCTION public.quote_status_history_recorder() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.quote_status_history_recorder()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER quotes_estimate_guard
BEFORE INSERT OR UPDATE ON public.quotes
FOR EACH ROW EXECUTE FUNCTION public.quote_estimate_guard();
CREATE TRIGGER quotes_estimate_truncate_guard
BEFORE TRUNCATE ON public.quotes
FOR EACH STATEMENT EXECUTE FUNCTION public.quote_estimate_truncate_guard();
CREATE TRIGGER quotes_status_history_recorder
AFTER INSERT OR UPDATE ON public.quotes
FOR EACH ROW EXECUTE FUNCTION public.quote_status_history_recorder();

-- Creates the next editable revision. Serialized per estimate family by locking
-- the original row, with a unique (root_quote_id, revision_number) backstop.
CREATE FUNCTION public.create_estimate_revision(p_quote uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_src public.quotes%ROWTYPE;
  v_root public.quotes%ROWTYPE;
  v_next integer;
  v_open text;
  v_id uuid;
  v_number text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_src FROM public.quotes WHERE id = p_quote;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Estimate not found';
  END IF;
  SELECT * INTO v_root FROM public.quotes WHERE id = v_src.root_quote_id FOR UPDATE;
  SELECT * INTO v_src FROM public.quotes WHERE id = p_quote;

  IF NOT (v_src.created_by = auth.uid() OR public.is_admin()) THEN
    RAISE EXCEPTION 'Only the estimate creator or an administrator can create a revision'
      USING ERRCODE = '42501';
  END IF;
  IF v_src.status NOT IN ('Sent', 'Approved', 'Rejected', 'Expired') THEN
    RAISE EXCEPTION 'Only issued estimates can be revised; edit this estimate directly';
  END IF;
  SELECT q.quote_number INTO v_open
  FROM public.quotes AS q
  WHERE q.root_quote_id = v_root.id AND q.revision_number > 0
    AND q.status IN ('Draft', 'Ready')
  LIMIT 1;
  IF v_open IS NOT NULL THEN
    RAISE EXCEPTION 'Unfinished revision % already exists; finish or send it first', v_open;
  END IF;

  SELECT COALESCE(MAX(q.revision_number), 0) + 1 INTO v_next
  FROM public.quotes AS q WHERE q.root_quote_id = v_root.id;
  v_number := v_root.quote_number || '-R' || v_next;

  PERFORM pg_catalog.set_config(
    'quote_studio.status_note', 'Revision ' || v_next || ' created from ' || v_src.quote_number, true);
  INSERT INTO public.quotes (
    quote_number, customer_id, customer_snapshot, items, labor_hours, labor_rate,
    markup, tax_rate, notes, status, created_by, project_name, validity_days,
    root_quote_id, revision_number, source_quote_id, original_estimate_date
  ) VALUES (
    v_number, v_src.customer_id, v_src.customer_snapshot, v_src.items, v_src.labor_hours,
    v_src.labor_rate, v_src.markup, v_src.tax_rate, v_src.notes, 'Draft', auth.uid(),
    v_src.project_name, v_src.validity_days,
    v_root.id, v_next, v_src.id, v_root.original_estimate_date
  ) RETURNING id INTO v_id;
  PERFORM pg_catalog.set_config('quote_studio.status_note', '', true);

  RETURN pg_catalog.jsonb_build_object(
    'id', v_id, 'quote_number', v_number, 'revision_number', v_next);
END;
$$;
ALTER FUNCTION public.create_estimate_revision(uuid) OWNER TO postgres;

-- Approve or reject a Sent estimate. Approval atomically makes this the only
-- current approved version of the estimate family.
CREATE FUNCTION public.set_estimate_decision(p_quote uuid, p_decision text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_src public.quotes%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('Approved', 'Rejected') THEN
    RAISE EXCEPTION 'Decision must be Approved or Rejected';
  END IF;
  SELECT * INTO v_src FROM public.quotes WHERE id = p_quote;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Estimate not found';
  END IF;
  PERFORM 1 FROM public.quotes WHERE id = v_src.root_quote_id FOR UPDATE;
  SELECT * INTO v_src FROM public.quotes WHERE id = p_quote;

  IF NOT (v_src.created_by = auth.uid() OR public.is_admin()) THEN
    RAISE EXCEPTION 'Only the estimate creator or an administrator can record a decision'
      USING ERRCODE = '42501';
  END IF;
  IF v_src.status <> 'Sent' THEN
    RAISE EXCEPTION 'Only Sent estimates can be approved or rejected';
  END IF;
  IF v_src.valid_until IS NOT NULL AND v_src.valid_until < public.quote_studio_business_date() THEN
    RAISE EXCEPTION 'This estimate has expired; create a revision instead';
  END IF;

  PERFORM pg_catalog.set_config('quote_studio.status_note', 'Customer decision recorded', true);
  IF p_decision = 'Approved' THEN
    UPDATE public.quotes SET is_current_approved = false
    WHERE root_quote_id = v_src.root_quote_id AND is_current_approved;
    UPDATE public.quotes SET status = 'Approved', is_current_approved = true
    WHERE id = p_quote;
  ELSE
    UPDATE public.quotes SET status = 'Rejected' WHERE id = p_quote;
  END IF;
  PERFORM pg_catalog.set_config('quote_studio.status_note', '', true);
  RETURN pg_catalog.jsonb_build_object('id', p_quote, 'status', p_decision);
END;
$$;
ALTER FUNCTION public.set_estimate_decision(uuid, text) OWNER TO postgres;

-- Applies the two derived transitions: Ready -> Sent only when the email
-- provider accepted a message for that exact saved version (a quotation_email_log
-- row with a provider id, written by the service-role Edge Function, newer than
-- the last edit), and Sent -> Expired after valid_until. Approved and Rejected
-- are never touched. Provider acceptance is not confirmed customer delivery.
CREATE FUNCTION public.sync_estimate_statuses()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sent integer;
  v_expired integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_catalog.set_config(
    'quote_studio.status_note', 'Email accepted by the provider (not confirmed delivery)', true);
  WITH moved AS (
    UPDATE public.quotes AS q SET status = 'Sent'
    WHERE q.status = 'Ready'
      AND EXISTS (
        SELECT 1 FROM public.quotation_email_log AS l
        WHERE l.quote_id = q.id AND l.resend_id IS NOT NULL AND l.created_at >= q.updated_at
      )
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_sent FROM moved;

  PERFORM pg_catalog.set_config('quote_studio.status_note', 'Validity period elapsed', true);
  WITH moved AS (
    UPDATE public.quotes AS q SET status = 'Expired'
    WHERE q.status = 'Sent' AND q.valid_until IS NOT NULL
      AND q.valid_until < public.quote_studio_business_date()
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_expired FROM moved;

  PERFORM pg_catalog.set_config('quote_studio.status_note', '', true);
  RETURN pg_catalog.jsonb_build_object('sent', v_sent, 'expired', v_expired);
END;
$$;
ALTER FUNCTION public.sync_estimate_statuses() OWNER TO postgres;

REVOKE ALL ON FUNCTION public.create_estimate_revision(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_estimate_decision(uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.sync_estimate_statuses()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_estimate_revision(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_estimate_decision(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_estimate_statuses() TO authenticated;

DO $postconditions$
BEGIN
  IF EXISTS (SELECT 1 FROM public.quotes WHERE root_quote_id IS NULL) THEN
    RAISE EXCEPTION 'Backfill failed: quotes without root_quote_id';
  END IF;
  IF (SELECT COUNT(*) FROM public.quote_status_history)
     <> (SELECT COUNT(*) FROM public.quotes) THEN
    RAISE EXCEPTION 'Status history backfill count mismatch';
  END IF;
  IF (SELECT COUNT(*) FROM pg_catalog.pg_trigger
      WHERE tgrelid = 'public.quotes'::pg_catalog.regclass
        AND tgname IN ('quotes_estimate_guard', 'quotes_estimate_truncate_guard',
                       'quotes_status_history_recorder')) <> 3 THEN
    RAISE EXCEPTION 'Estimate triggers are missing';
  END IF;
  IF pg_catalog.has_function_privilege(
       'anon', 'public.create_estimate_revision(uuid)', 'EXECUTE')
     OR pg_catalog.has_function_privilege(
       'anon', 'public.set_estimate_decision(uuid,text)', 'EXECUTE')
     OR pg_catalog.has_function_privilege(
       'anon', 'public.sync_estimate_statuses()', 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.create_estimate_revision(uuid)', 'EXECUTE')
     OR pg_catalog.has_table_privilege('anon', 'public.quote_status_history', 'SELECT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.quote_status_history', 'INSERT') THEN
    RAISE EXCEPTION 'Unexpected privileges on estimate revision objects';
  END IF;
END;
$postconditions$;

COMMIT;
