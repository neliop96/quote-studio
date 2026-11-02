-- REVIEW ONLY. Not applied to any database.
-- Requires 20261029010000_estimate_drafts_revisions.sql to be applied first.
--
-- Binds each quotation email log row to the exact saved version that was emailed
-- (quotes.updated_at at send time). sync_estimate_statuses() then promotes
-- Ready -> Sent only for that version, so an edit made while the email was in flight
-- can no longer be marked Sent. Rows written before this migration (NULL
-- quote_version_at) keep the previous created_at rule.
BEGIN;

DO $prereq$
BEGIN
  IF to_regclass('public.quotation_email_log') IS NULL THEN
    RAISE EXCEPTION 'public.quotation_email_log is missing';
  END IF;
  IF to_regprocedure('public.sync_estimate_statuses()') IS NULL THEN
    RAISE EXCEPTION 'Apply 20261029010000_estimate_drafts_revisions.sql first';
  END IF;
END;
$prereq$;

ALTER TABLE public.quotation_email_log
  ADD COLUMN IF NOT EXISTS quote_version_at timestamptz;

CREATE OR REPLACE FUNCTION public.sync_estimate_statuses()
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
        WHERE l.quote_id = q.id AND l.resend_id IS NOT NULL
          AND (
            (l.quote_version_at IS NOT NULL AND l.quote_version_at = q.updated_at)
            OR (l.quote_version_at IS NULL AND l.created_at >= q.updated_at)
          )
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

REVOKE ALL ON FUNCTION public.sync_estimate_statuses()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.sync_estimate_statuses() TO authenticated;

DO $postconditions$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'quotation_email_log'
      AND column_name = 'quote_version_at'
  ) THEN
    RAISE EXCEPTION 'quote_version_at was not created';
  END IF;
  IF pg_catalog.has_function_privilege('anon', 'public.sync_estimate_statuses()', 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated', 'public.sync_estimate_statuses()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Unexpected privileges on sync_estimate_statuses';
  END IF;
END;
$postconditions$;

COMMIT;
