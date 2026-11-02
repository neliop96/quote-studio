const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

// Executes the real migration against an in-process PostgreSQL (PGlite). Skipped
// when @electric-sql/pglite is not installed (it is not a project dependency).
// Run with NODE_PATH pointing at a directory whose node_modules contains it.
let PGlite = null;
try {
  ({ PGlite } = require("@electric-sql/pglite"));
} catch {}
const maybe = PGlite ? test : test.skip;

const migrationSql = fs.readFileSync(
  path.resolve(__dirname, "..", "supabase", "migrations", "20261029010000_estimate_drafts_revisions.sql"),
  "utf8",
);

const ADMIN = "00000000-0000-0000-0000-0000000000a1";
const ALICE = "00000000-0000-0000-0000-0000000000b1";
const BOB = "00000000-0000-0000-0000-0000000000b2";

const baseline = `
CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN BYPASSRLS;
CREATE SCHEMA auth;
CREATE TABLE auth.users (id uuid PRIMARY KEY);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
GRANT USAGE ON SCHEMA auth, public TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;
CREATE TABLE public.profiles (id uuid PRIMARY KEY REFERENCES auth.users(id), role text NOT NULL DEFAULT 'employee');
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.profiles TO authenticated;
CREATE POLICY "profile read" ON public.profiles FOR SELECT TO authenticated USING (true);
CREATE FUNCTION public.is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS
  $$ SELECT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') $$;
CREATE TABLE public.customers (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text);
CREATE TABLE public.quote_settings (
  id integer PRIMARY KEY CHECK (id = 1), markup numeric NOT NULL DEFAULT 20,
  labor_rate numeric NOT NULL DEFAULT 75, tax_rate numeric NOT NULL DEFAULT 8.625,
  labor_hours numeric NOT NULL DEFAULT 0);
ALTER TABLE public.quote_settings ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON public.quote_settings TO authenticated, service_role;
CREATE POLICY "settings read" ON public.quote_settings FOR SELECT TO authenticated USING (true);
CREATE POLICY "settings write" ON public.quote_settings FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE TABLE public.quotes (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY, quote_number text NOT NULL UNIQUE,
  customer_id uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  customer_snapshot jsonb NOT NULL DEFAULT '{}', items jsonb NOT NULL DEFAULT '[]',
  labor_hours numeric(12,2) NOT NULL DEFAULT 0, labor_rate numeric(12,2) NOT NULL DEFAULT 75,
  markup numeric(8,3) NOT NULL DEFAULT 20, tax_rate numeric(8,3) NOT NULL DEFAULT 8.625,
  notes text NOT NULL DEFAULT '', status text NOT NULL DEFAULT 'Draft',
  created_by uuid REFERENCES auth.users(id), created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), project_name text);
ALTER TABLE public.quotes ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON public.quotes TO authenticated, service_role;
GRANT SELECT ON public.quotes TO anon;
CREATE POLICY "quotes read" ON public.quotes FOR SELECT TO authenticated USING (true);
CREATE POLICY "quotes insert" ON public.quotes FOR INSERT TO authenticated WITH CHECK (created_by = auth.uid());
CREATE POLICY "quotes update" ON public.quotes FOR UPDATE TO authenticated
  USING (created_by = auth.uid() OR public.is_admin()) WITH CHECK (created_by = auth.uid() OR public.is_admin());
CREATE POLICY "quotes delete" ON public.quotes FOR DELETE TO authenticated USING (public.is_admin());
CREATE TABLE public.quotation_email_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, quote_id uuid, quote_number text NOT NULL,
  customer_email text NOT NULL, sent_by uuid, resend_id text, subject text NOT NULL,
  detail text NOT NULL, delivery_status text NOT NULL DEFAULT 'submitted',
  created_at timestamptz NOT NULL DEFAULT now());
GRANT SELECT, INSERT ON public.quotation_email_log TO service_role;
INSERT INTO auth.users VALUES ('${ADMIN}'), ('${ALICE}'), ('${BOB}');
INSERT INTO public.profiles VALUES ('${ADMIN}', 'admin'), ('${ALICE}', 'employee'), ('${BOB}', 'employee');
`;

const lit = (value) => `'${String(value).replace(/'/g, "''")}'`;

async function setup({ legacy = false } = {}) {
  const db = new PGlite();
  await db.exec(baseline);
  if (legacy) {
    await db.exec(`
      INSERT INTO public.quote_settings (id) VALUES (1);
      INSERT INTO public.quotes (quote_number, status, created_by, created_at, notes, items) VALUES
        ('EST1026001', 'Draft', '${ALICE}', '2026-10-01 12:00-07', 'old draft', '[]'),
        ('EST1026002', 'Sent', '${ALICE}', '2026-10-02 23:30-07', 'old sent', '[{"qty":1,"cost":10}]'),
        ('EST1026003', 'Approved', '${BOB}', '2026-09-01 12:00-07', 'old approved', '[]');
    `);
  }
  const as = async (uid, sql, role = "authenticated") => {
    await db.exec(`SET ROLE ${role}; SELECT set_config('request.jwt.claim.sub', ${lit(uid || "")}, false);`);
    try {
      return await db.query(sql);
    } finally {
      await db.exec("RESET ROLE;");
    }
  };
  const q = async (sql) => (await db.query(sql)).rows;
  await db.exec(migrationSql);
  return { db, as, q };
}

const insertDraft = (number, extra = "") =>
  `INSERT INTO public.quotes (quote_number, status, created_by, items, customer_snapshot, notes, project_name, validity_days${extra ? ", " + extra.split("|")[0] : ""})
   VALUES (${lit(number)}, 'Draft', ${lit(ALICE)}, '[{"part":"P1","description":"Part","qty":2,"cost":50}]', '{"name":"Acme"}', 'scope', 'Line A', 30${extra ? ", " + extra.split("|")[1] : ""})
   RETURNING *`;

maybe("migration preserves legacy quotations and backfills safely", async () => {
  const { q } = await setup({ legacy: true });
  const rows = await q("SELECT * FROM public.quotes ORDER BY quote_number");
  assert.equal(rows.length, 3);
  assert.ok(rows.every((r) => r.root_quote_id === r.id && r.revision_number === 0));
  assert.equal(rows[0].original_estimate_date, null);
  assert.equal(String(rows[1].original_estimate_date.toISOString?.().slice(0, 10) ?? rows[1].original_estimate_date).slice(0, 10), "2026-10-02");
  assert.equal(rows[1].valid_until, null);
  assert.deepEqual(rows.map((r) => r.is_current_approved), [false, false, true]);
  assert.equal(rows[1].notes, "old sent");
  assert.equal((await q("SELECT count(*)::int AS n FROM public.quote_status_history"))[0].n, 3);
  assert.equal((await q("SELECT validity_days FROM public.quote_settings"))[0].validity_days, 30);
});

maybe("legacy Sent quotation is immutable and never auto-expires", async () => {
  const { as, q } = await setup({ legacy: true });
  await assert.rejects(() => as(ALICE, "UPDATE public.quotes SET notes = 'edit' WHERE quote_number = 'EST1026002'"), /read-only/);
  await as(ALICE, "SELECT public.sync_estimate_statuses()");
  assert.equal((await q("SELECT status FROM public.quotes WHERE quote_number = 'EST1026002'"))[0].status, "Sent");
});

maybe("saves, reopens and edits multiple drafts without resetting dates", async () => {
  const { as, q } = await setup();
  await as(ALICE, insertDraft("EST1029001"));
  await as(ALICE, insertDraft("EST1029002"));
  const drafts = await q("SELECT * FROM public.quotes WHERE status = 'Draft' ORDER BY quote_number");
  assert.equal(drafts.length, 2);
  assert.equal(drafts[0].original_estimate_date, null);
  assert.equal(drafts[0].valid_until, null);
  assert.equal(drafts[0].items[0].qty, 2);
  assert.equal(drafts[0].customer_snapshot.name, "Acme");
  await as(ALICE, "UPDATE public.quotes SET notes = 'changed', markup = 35 WHERE quote_number = 'EST1029001'");
  const edited = (await q("SELECT * FROM public.quotes WHERE quote_number = 'EST1029001'"))[0];
  assert.equal(edited.notes, "changed");
  assert.equal(Number(edited.markup), 35);

  await as(ALICE, "UPDATE public.quotes SET status = 'Ready', validity_days = 14 WHERE quote_number = 'EST1029001'");
  const ready = (await q("SELECT original_estimate_date::text AS d, valid_until::text AS v FROM public.quotes WHERE quote_number = 'EST1029001'"))[0];
  assert.ok(ready.d);
  const expected = (await q(`SELECT (${lit(ready.d)}::date + 14)::text AS v`))[0].v;
  assert.equal(ready.v, expected);

  // Returning to Draft and editing keeps the issue date; changing validity recalculates from it.
  await as(ALICE, "UPDATE public.quotes SET status = 'Draft', notes = 'again' WHERE quote_number = 'EST1029001'");
  await as(ALICE, "UPDATE public.quotes SET validity_days = 45 WHERE quote_number = 'EST1029001'");
  const again = (await q("SELECT original_estimate_date::text AS d, valid_until::text AS v FROM public.quotes WHERE quote_number = 'EST1029001'"))[0];
  assert.equal(again.d, ready.d);
  assert.equal(again.v, (await q(`SELECT (${lit(ready.d)}::date + 45)::text AS v`))[0].v);
});

maybe("estimate dates use the configured business time zone", async () => {
  const { db, as, q } = await setup();
  await db.exec("INSERT INTO public.quote_settings (id, quote_time_zone) VALUES (1, 'Pacific/Kiritimati')");
  await as(ALICE, insertDraft("EST1029003"));
  await as(ALICE, "UPDATE public.quotes SET status = 'Ready' WHERE quote_number = 'EST1029003'");
  const row = (await q("SELECT original_estimate_date::text AS d FROM public.quotes WHERE quote_number = 'EST1029003'"))[0];
  const kiritimati = (await q("SELECT (now() AT TIME ZONE 'Pacific/Kiritimati')::date::text AS d"))[0].d;
  assert.equal(row.d, kiritimati);
});

maybe("direct writes cannot bypass status, identity or issued-version protection", async () => {
  const { as, q } = await setup();
  await assert.rejects(() => as(ALICE, "INSERT INTO public.quotes (quote_number, status, created_by) VALUES ('EST9', 'Sent', '" + ALICE + "')"), /Draft or Ready/);
  await assert.rejects(() => as(ALICE, "INSERT INTO public.quotes (quote_number, created_by) VALUES ('EST1-R4', '" + ALICE + "')"), /assigned automatically/);
  const inserted = (await as(ALICE, "INSERT INTO public.quotes (quote_number, created_by, revision_number, is_current_approved, valid_until) VALUES ('EST1029004', '" + ALICE + "', 0, true, '2030-01-01') RETURNING *")).rows[0];
  assert.equal(inserted.is_current_approved, false);
  assert.equal(inserted.valid_until, null);
  assert.equal(inserted.root_quote_id, inserted.id);

  await as(ALICE, "UPDATE public.quotes SET status = 'Ready', customer_snapshot = '{\"name\":\"A\"}' WHERE quote_number = 'EST1029004'");
  await assert.rejects(() => as(ALICE, "UPDATE public.quotes SET status = 'Sent' WHERE quote_number = 'EST1029004'"), /Invalid estimate status change/);
  await assert.rejects(() => as(ALICE, "UPDATE public.quotes SET valid_until = '2099-01-01' WHERE quote_number = 'EST1029004'"), /System-managed/);
  await assert.rejects(() => as(ALICE, "UPDATE public.quotes SET is_current_approved = true WHERE quote_number = 'EST1029004'"), /System-managed/);
  await assert.rejects(() => as(ALICE, "UPDATE public.quotes SET revision_number = 3 WHERE quote_number = 'EST1029004'"), /System-managed/);
  await assert.rejects(() => as(ALICE, "UPDATE public.quotes SET status = 'Approved' WHERE quote_number = 'EST1029004'"), /Invalid estimate status change/);
  await assert.rejects(() => as(ALICE, "UPDATE public.quotes SET quote_number = 'EST1-R1' WHERE quote_number = 'EST1029004'"), /assigned automatically/);
  await as(BOB, "UPDATE public.quotes SET notes = 'x' WHERE quote_number = 'EST1029004'");
  assert.equal((await q("SELECT notes FROM public.quotes WHERE quote_number = 'EST1029004'"))[0].notes, "");
  await assert.rejects(() => as(ALICE, "TRUNCATE public.quotes"), /cannot be truncated|cannot truncate a table referenced/);
});

maybe("only provider-accepted emails move Ready to Sent, and Sent is then immutable", async () => {
  const { db, as, q } = await setup();
  const id = (await as(ALICE, insertDraft("EST1029005"))).rows[0].id;
  await as(ALICE, "UPDATE public.quotes SET status = 'Ready' WHERE quote_number = 'EST1029005'");

  await as(ALICE, "SELECT public.sync_estimate_statuses()");
  assert.equal((await q("SELECT status FROM public.quotes WHERE id = " + lit(id)))[0].status, "Ready");

  // A failed send that logged no provider id must not mark the estimate Sent.
  await db.exec(`INSERT INTO public.quotation_email_log (quote_id, quote_number, customer_email, subject, detail, resend_id)
                 VALUES (${lit(id)}, 'EST1029005', 'a@b.c', 's', 'project', NULL)`);
  await as(ALICE, "SELECT public.sync_estimate_statuses()");
  assert.equal((await q("SELECT status FROM public.quotes WHERE id = " + lit(id)))[0].status, "Ready");

  // Accepted for an earlier saved state is stale after a later edit.
  await db.exec(`INSERT INTO public.quotation_email_log (quote_id, quote_number, customer_email, subject, detail, resend_id, created_at)
                 VALUES (${lit(id)}, 'EST1029005', 'a@b.c', 's', 'project', 're_old', now() - interval '1 hour')`);
  await as(ALICE, "UPDATE public.quotes SET notes = 'edited after send' WHERE id = " + lit(id));
  await as(ALICE, "SELECT public.sync_estimate_statuses()");
  assert.equal((await q("SELECT status FROM public.quotes WHERE id = " + lit(id)))[0].status, "Ready");

  await db.exec(`INSERT INTO public.quotation_email_log (quote_id, quote_number, customer_email, subject, detail, resend_id)
                 VALUES (${lit(id)}, 'EST1029005', 'a@b.c', 's', 'project', 're_new')`);
  const synced = (await as(ALICE, "SELECT public.sync_estimate_statuses() AS r")).rows[0].r;
  assert.equal(synced.sent, 1);
  assert.equal((await q("SELECT status FROM public.quotes WHERE id = " + lit(id)))[0].status, "Sent");

  await assert.rejects(() => as(ALICE, "UPDATE public.quotes SET notes = 'tamper' WHERE id = " + lit(id)), /read-only/);
  await assert.rejects(() => as(ALICE, "UPDATE public.quotes SET status = 'Draft' WHERE id = " + lit(id)), /Invalid estimate status change/);
  await assert.rejects(() => as(null, "UPDATE public.quotes SET notes = 'tamper' WHERE id = " + lit(id), "service_role"), /read-only/);
  const history = await q("SELECT from_status, to_status, note FROM public.quote_status_history WHERE quote_id = " + lit(id) + " ORDER BY id");
  assert.deepEqual(history.map((h) => h.to_status), ["Draft", "Ready", "Sent"]);
  assert.match(history[2].note, /not confirmed delivery/);
});

maybe("the Edge Function service role may mark an issued draft Sent but nothing else", async () => {
  const { as, q } = await setup();
  const id = (await as(ALICE, insertDraft("EST1029006"))).rows[0].id;
  await as(null, "UPDATE public.quotes SET status = 'Sent' WHERE id = " + lit(id), "service_role");
  const row = (await q("SELECT status, original_estimate_date IS NOT NULL AS dated FROM public.quotes WHERE id = " + lit(id)))[0];
  assert.equal(row.status, "Sent");
  assert.equal(row.dated, true);
  await assert.rejects(() => as(null, "UPDATE public.quotes SET status = 'Approved' WHERE id = " + lit(id), "service_role"), /Invalid estimate status change/);
});

async function sentEstimate(ctx, number) {
  const id = (await ctx.as(ALICE, insertDraft(number))).rows[0].id;
  await ctx.as(ALICE, "UPDATE public.quotes SET status = 'Ready' WHERE id = " + lit(id));
  await ctx.db.exec(`INSERT INTO public.quotation_email_log (quote_id, quote_number, customer_email, subject, detail, resend_id)
                     VALUES (${lit(id)}, ${lit(number)}, 'a@b.c', 's', 'project', 're_${number}')`);
  await ctx.as(ALICE, "SELECT public.sync_estimate_statuses()");
  return id;
}

maybe("revisions copy the estimate, preserve originals and number safely", async () => {
  const ctx = await setup();
  const { as, q } = ctx;
  const id = await sentEstimate(ctx, "EST1026002");
  const original = (await q("SELECT * FROM public.quotes WHERE id = " + lit(id)))[0];

  await assert.rejects(() => as(BOB, "SELECT public.create_estimate_revision(" + lit(id) + ")"), /creator or an administrator/);
  await assert.rejects(() => as(null, "SELECT public.create_estimate_revision(" + lit(id) + ")", "anon"), /permission denied/);

  const r1 = (await as(ALICE, "SELECT public.create_estimate_revision(" + lit(id) + ") AS r")).rows[0].r;
  assert.equal(r1.quote_number, "EST1026002-R1");
  assert.equal(r1.revision_number, 1);
  const rev = (await q("SELECT * FROM public.quotes WHERE id = " + lit(r1.id)))[0];
  assert.equal(rev.status, "Draft");
  assert.deepEqual(rev.items, original.items);
  assert.deepEqual(rev.customer_snapshot, original.customer_snapshot);
  assert.equal(rev.notes, original.notes);
  assert.equal(rev.project_name, original.project_name);
  assert.equal(rev.root_quote_id, id);
  assert.equal(rev.source_quote_id, id);
  assert.equal(String(rev.original_estimate_date), String(original.original_estimate_date));
  assert.equal(rev.revision_date, null);
  assert.equal(rev.valid_until, null);

  // Original is untouched and cannot be edited.
  const after = (await q("SELECT * FROM public.quotes WHERE id = " + lit(id)))[0];
  assert.deepEqual(after, original);

  // One unfinished revision at a time.
  await assert.rejects(() => as(ALICE, "SELECT public.create_estimate_revision(" + lit(id) + ")"), /Unfinished revision EST1026002-R1/);
  // A draft cannot be revised.
  await assert.rejects(() => as(ALICE, "SELECT public.create_estimate_revision(" + lit(r1.id) + ")"), /Only issued estimates/);

  // The draft revision is editable; issuing it dates the revision, not the original.
  await as(ALICE, "UPDATE public.quotes SET notes = 'revised scope', status = 'Ready', validity_days = 10 WHERE id = " + lit(r1.id));
  const issued = (await q("SELECT original_estimate_date::text AS o, revision_date::text AS r, valid_until::text AS v FROM public.quotes WHERE id = " + lit(r1.id)))[0];
  assert.equal(issued.o, String((await q("SELECT original_estimate_date::text AS o FROM public.quotes WHERE id = " + lit(id)))[0].o));
  assert.ok(issued.r);
  assert.equal(issued.v, (await q(`SELECT (${lit(issued.r)}::date + 10)::text AS v`))[0].v);

  await ctx.db.exec(`INSERT INTO public.quotation_email_log (quote_id, quote_number, customer_email, subject, detail, resend_id)
                     VALUES (${lit(r1.id)}, 'EST1026002-R1', 'a@b.c', 's', 'project', 're_r1')`);
  await as(ALICE, "SELECT public.sync_estimate_statuses()");
  const r2 = (await as(ADMIN, "SELECT public.create_estimate_revision(" + lit(r1.id) + ") AS r")).rows[0].r;
  assert.equal(r2.quote_number, "EST1026002-R2");
  assert.equal((await q("SELECT source_quote_id FROM public.quotes WHERE id = " + lit(r2.id)))[0].source_quote_id, r1.id);

  const history = await q("SELECT note FROM public.quote_status_history WHERE quote_id = " + lit(r2.id));
  assert.match(history[0].note, /Revision 2 created from EST1026002-R1/);

  // Family cannot be deleted from the root while revisions exist.
  await assert.rejects(() => ctx.as(ADMIN, "DELETE FROM public.quotes WHERE id = " + lit(id)), /foreign key|violates/);
});

maybe("revision numbers are unique per family and never duplicated", async () => {
  const ctx = await setup();
  const id = await sentEstimate(ctx, "EST1026010");
  await ctx.db.exec(`INSERT INTO public.quotes (quote_number, status, created_by, root_quote_id, revision_number, source_quote_id)
                     VALUES ('EST1026010-R1', 'Draft', ${lit(ALICE)}, ${lit(id)}, 1, ${lit(id)})`);
  await assert.rejects(
    () => ctx.db.exec(`INSERT INTO public.quotes (quote_number, status, created_by, root_quote_id, revision_number, source_quote_id)
                       VALUES ('EST1026010-R1b', 'Draft', ${lit(ALICE)}, ${lit(id)}, 1, ${lit(id)})`),
    /quotes_family_revision_key/,
  );
});

maybe("only one revision can be the current approved version", async () => {
  const ctx = await setup();
  const { as, q } = ctx;
  const id = await sentEstimate(ctx, "EST1026020");
  await assert.rejects(() => as(BOB, "SELECT public.set_estimate_decision(" + lit(id) + ", 'Approved')"), /creator or an administrator/);
  await assert.rejects(() => as(ALICE, "SELECT public.set_estimate_decision(" + lit(id) + ", 'Maybe')"), /Approved or Rejected/);
  await as(ALICE, "SELECT public.set_estimate_decision(" + lit(id) + ", 'Approved')");
  assert.equal((await q("SELECT is_current_approved FROM public.quotes WHERE id = " + lit(id)))[0].is_current_approved, true);

  const r1 = (await as(ALICE, "SELECT public.create_estimate_revision(" + lit(id) + ") AS r")).rows[0].r;
  await as(ALICE, "UPDATE public.quotes SET status = 'Ready' WHERE id = " + lit(r1.id));
  await ctx.db.exec(`INSERT INTO public.quotation_email_log (quote_id, quote_number, customer_email, subject, detail, resend_id)
                     VALUES (${lit(r1.id)}, 'EST1026020-R1', 'a@b.c', 's', 'project', 're_r1')`);
  await as(ALICE, "SELECT public.sync_estimate_statuses()");
  await as(ALICE, "SELECT public.set_estimate_decision(" + lit(r1.id) + ", 'Approved')");

  const rows = await q("SELECT quote_number, status, is_current_approved FROM public.quotes WHERE root_quote_id = " + lit(id) + " ORDER BY revision_number");
  assert.deepEqual(rows.map((r) => [r.status, r.is_current_approved]), [["Approved", false], ["Approved", true]]);
  await assert.rejects(
    () => ctx.db.exec(`UPDATE public.quotes SET is_current_approved = true WHERE id = ${lit(id)}`),
    /idx|unique/,
  );
  await assert.rejects(() => as(ALICE, "SELECT public.set_estimate_decision(" + lit(r1.id) + ", 'Rejected')"), /Only Sent/);
});

maybe("expiration only affects Sent estimates and never overwrites Approved or Rejected", async () => {
  const { db, as, q } = await setup();
  const past = "(current_date - 60)";
  for (const [number, status] of [["EST-X1", "Sent"], ["EST-X2", "Sent"], ["EST-X3", "Sent"]]) {
    await db.exec(`INSERT INTO public.quotes (quote_number, status, created_by, original_estimate_date, validity_days)
                   VALUES (${lit(number)}, ${lit(status)}, ${lit(ALICE)}, ${past}, 30)`);
  }
  await as(ALICE, "SELECT public.set_estimate_decision((SELECT id FROM public.quotes WHERE quote_number = 'EST-X3'), 'Approved')").catch(() => {});
  // Decisions on lapsed estimates are refused; settle X2 as Approved/Rejected via trusted path first.
  await db.exec("UPDATE public.quotes SET status = 'Approved', is_current_approved = true WHERE quote_number = 'EST-X2'");
  await db.exec("INSERT INTO public.quotes (quote_number, status, created_by, original_estimate_date, validity_days) VALUES ('EST-X4', 'Sent', " + lit(ALICE) + ", " + past + ", 30)");
  await db.exec("UPDATE public.quotes SET status = 'Rejected' WHERE quote_number = 'EST-X4'");
  const ready = (await as(ALICE, insertDraft("EST-X5"))).rows[0].id;
  await as(ALICE, "UPDATE public.quotes SET status = 'Ready' WHERE id = " + lit(ready));

  const result = (await as(ALICE, "SELECT public.sync_estimate_statuses() AS r")).rows[0].r;
  assert.equal(result.expired, 2);
  const byNumber = Object.fromEntries((await q("SELECT quote_number, status FROM public.quotes")).map((r) => [r.quote_number, r.status]));
  assert.equal(byNumber["EST-X1"], "Expired");
  assert.equal(byNumber["EST-X3"], "Expired");
  assert.equal(byNumber["EST-X2"], "Approved");
  assert.equal(byNumber["EST-X4"], "Rejected");
  assert.equal(byNumber["EST-X5"], "Ready");
  const x1 = (await q("SELECT id FROM public.quotes WHERE quote_number = 'EST-X1'"))[0].id;
  // An expired estimate can be revised, giving a fresh validity period.
  const rev = (await as(ALICE, "SELECT public.create_estimate_revision(" + lit(x1) + ") AS r")).rows[0].r;
  assert.equal(rev.quote_number, "EST-X1-R1");
  await assert.rejects(() => as(ALICE, "SELECT public.set_estimate_decision(" + lit(x1) + ", 'Approved')"), /Only Sent/);
});

maybe("status history is read-only for application roles", async () => {
  const { as } = await setup();
  await as(ALICE, "SELECT count(*) FROM public.quote_status_history");
  await assert.rejects(() => as(ALICE, "INSERT INTO public.quote_status_history (quote_id, to_status) VALUES (gen_random_uuid(), 'Sent')"), /permission denied/);
  await assert.rejects(() => as(null, "SELECT count(*) FROM public.quote_status_history", "anon"), /permission denied/);
});

maybe("migration refuses to run twice or over unsupported statuses", async () => {
  const { db } = await setup();
  await assert.rejects(() => db.exec(migrationSql), /already exist/);
  const fresh = new PGlite();
  await fresh.exec(baseline);
  await fresh.exec("INSERT INTO public.quotes (quote_number, status) VALUES ('X', 'Pending')");
  await assert.rejects(() => fresh.exec(migrationSql), /statuses outside/);
});

const bindingSql = fs.readFileSync(
  path.resolve(__dirname, "..", "supabase", "migrations", "20261029020000_estimate_email_version_binding.sql"),
  "utf8",
);

maybe("version-bound email log: an edit during the send cannot be marked Sent", async () => {
  const { db, as, q } = await setup();
  await db.exec(bindingSql);
  const id = (await as(ALICE, insertDraft("EST1029020"))).rows[0].id;
  await as(ALICE, "UPDATE public.quotes SET status = 'Ready' WHERE id = " + lit(id));
  const v1 = (await q("SELECT updated_at FROM public.quotes WHERE id = " + lit(id)))[0].updated_at.toISOString();

  // The user edits while the email is in flight; the log row is written afterwards for version v1.
  await as(ALICE, "UPDATE public.quotes SET notes = 'edited during send' WHERE id = " + lit(id));
  await db.exec(`INSERT INTO public.quotation_email_log (quote_id, quote_number, customer_email, subject, detail, resend_id, quote_version_at)
                 VALUES (${lit(id)}, 'EST1029020', 'a@b.c', 's', 'project', 're_v1', ${lit(v1)})`);
  await as(ALICE, "SELECT public.sync_estimate_statuses()");
  assert.equal((await q("SELECT status FROM public.quotes WHERE id = " + lit(id)))[0].status, "Ready");

  // The conditional update used by the Edge Function also refuses the stale version.
  const stale = await as(null, `UPDATE public.quotes SET status = 'Sent' WHERE id = ${lit(id)} AND status = 'Ready' AND updated_at = ${lit(v1)} RETURNING id`, "service_role");
  assert.equal(stale.rows.length, 0);

  const v2 = (await q("SELECT updated_at FROM public.quotes WHERE id = " + lit(id)))[0].updated_at.toISOString();
  await db.exec(`INSERT INTO public.quotation_email_log (quote_id, quote_number, customer_email, subject, detail, resend_id, quote_version_at)
                 VALUES (${lit(id)}, 'EST1029020', 'a@b.c', 's', 'project', 're_v2', ${lit(v2)})`);
  assert.equal((await as(ALICE, "SELECT public.sync_estimate_statuses() AS r")).rows[0].r.sent, 1);
  assert.equal((await q("SELECT status FROM public.quotes WHERE id = " + lit(id)))[0].status, "Sent");
});

maybe("version-bound migration keeps legacy log rows and the service-role Ready to Sent update working", async () => {
  const { db, as, q } = await setup();
  await db.exec(bindingSql);
  const legacy = (await as(ALICE, insertDraft("EST1029021"))).rows[0].id;
  await as(ALICE, "UPDATE public.quotes SET status = 'Ready' WHERE id = " + lit(legacy));
  await db.exec(`INSERT INTO public.quotation_email_log (quote_id, quote_number, customer_email, subject, detail, resend_id)
                 VALUES (${lit(legacy)}, 'EST1029021', 'a@b.c', 's', 'project', 're_legacy')`);
  await as(ALICE, "SELECT public.sync_estimate_statuses()");
  assert.equal((await q("SELECT status FROM public.quotes WHERE id = " + lit(legacy)))[0].status, "Sent");

  const fresh = (await as(ALICE, insertDraft("EST1029022"))).rows[0].id;
  await as(ALICE, "UPDATE public.quotes SET status = 'Ready' WHERE id = " + lit(fresh));
  const v = (await q("SELECT updated_at FROM public.quotes WHERE id = " + lit(fresh)))[0].updated_at.toISOString();
  const moved = await as(null, `UPDATE public.quotes SET status = 'Sent' WHERE id = ${lit(fresh)} AND status = 'Ready' AND updated_at = ${lit(v)} RETURNING id`, "service_role");
  assert.equal(moved.rows.length, 1);
  assert.equal((await q("SELECT status FROM public.quotes WHERE id = " + lit(fresh)))[0].status, "Sent");
  assert.equal((await q("SELECT has_function_privilege('anon','public.sync_estimate_statuses()','EXECUTE') AS a"))[0].a, false);
});

maybe("version-bound migration requires the estimates migration first", async () => {
  const fresh = new PGlite();
  await fresh.exec(baseline);
  await assert.rejects(() => fresh.exec(bindingSql), /Apply 20261029010000/);
});
