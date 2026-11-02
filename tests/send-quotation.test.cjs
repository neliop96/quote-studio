const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const E = require("../js/estimates.js");

const root = path.join(__dirname, "..");
const fnDir = path.join(root, "supabase", "functions", "send-quotation");
const indexSource = fs.readFileSync(path.join(fnDir, "index.ts"), "utf8");
let L;
test.before(async () => {
  // Node strips the TypeScript types; logic.ts has no Deno or remote imports.
  L = await import(require("node:url").pathToFileURL(path.join(fnDir, "logic.ts")).href);
});

const quote = {
  id: "11111111-1111-1111-1111-111111111111",
  quote_number: "EST1026002",
  status: "Ready",
  customer_snapshot: { name: "Snapshot Dairy", contact: "Pat", address: "1 Main", email: "pat@acme.test" },
  items: [{ part: "PLC-1", description: "Controller", qty: 2, cost: 100 }],
  labor_hours: 10,
  labor_rate: 75,
  markup: 20,
  tax_rate: 10,
  notes: "Scope notes",
  revision_number: 0,
  validity_days: 30,
  original_estimate_date: "2026-10-01",
  revision_date: null,
  valid_until: "2026-10-31",
  updated_at: "2026-10-02T10:00:00.123456+00:00",
};
const env = { QUOTATION_EMAIL_FROM: "Acme Quotes <quotes@example.com>" };

test("config requires a sender and reads optional addresses from secrets", () => {
  assert.match(L.parseConfig({}).error, /QUOTATION_EMAIL_FROM/);
  assert.match(L.parseConfig({ QUOTATION_EMAIL_FROM: "not-an-email" }).error, /QUOTATION_EMAIL_FROM/);
  const c = L.parseConfig({ ...env, QUOTATION_EMAIL_REPLY_TO: "r@example.com", QUOTATION_EMAIL_INTERNAL_COPY: "Boss <b@example.com>" });
  assert.equal(c.from, env.QUOTATION_EMAIL_FROM);
  assert.equal(c.replyTo, "r@example.com");
  assert.equal(c.internalCopy, "b@example.com");
  assert.match(L.parseConfig({ ...env, QUOTATION_EMAIL_REPLY_TO: "bad" }).error, /REPLY_TO/);
  const d = L.parseConfig(env);
  assert.deepEqual(d.allowedRoles, ["admin", "employee"]);
  assert.equal(d.cooldownSeconds, 60);
  assert.equal(d.hourlyLimit, 20);
  assert.equal(L.parseConfig({ ...env, QUOTATION_EMAIL_COOLDOWN_SECONDS: "x" }).cooldownSeconds, 60);
});

test("only explicitly allowed roles may send; future roles are not granted", () => {
  const roles = L.parseConfig(env).allowedRoles;
  assert.equal(L.roleAllowed("admin", roles), true);
  assert.equal(L.roleAllowed("Employee", roles), true);
  for (const r of ["owner", "user", "viewer", "", null, undefined]) assert.equal(L.roleAllowed(r, roles), false);
  assert.deepEqual(L.parseConfig({ ...env, QUOTATION_EMAIL_ROLES: "Owner, admin" }).allowedRoles, ["owner", "admin"]);
  assert.match(L.parseConfig({ ...env, QUOTATION_EMAIL_ROLES: " , " }).error, /ROLES/);
});

test("CORS config reads comma-separated origins and echoes only exact allowed origins", () => {
  const rawOrigins = "https://neliop96.github.io,http://127.0.0.1:4173";
  const allowed = L.allowedOriginsFromEnv({ QUOTATION_ALLOWED_ORIGINS: rawOrigins });
  assert.deepEqual(allowed, ["https://neliop96.github.io", "http://127.0.0.1:4173"]);
  assert.deepEqual(
    L.parseConfig({ ...env, QUOTATION_ALLOWED_ORIGINS: rawOrigins }).allowedOrigins,
    allowed,
  );
  assert.equal(L.corsHeaders("https://neliop96.github.io", allowed)["Access-Control-Allow-Origin"], "https://neliop96.github.io");
  assert.equal(L.corsHeaders("http://127.0.0.1:4173", allowed)["Access-Control-Allow-Origin"], "http://127.0.0.1:4173");
  assert.equal(L.corsHeaders("https://evil.example", allowed)["Access-Control-Allow-Origin"], undefined);
  assert.equal(L.corsHeaders("http://127.0.0.1:4174", allowed)["Access-Control-Allow-Origin"], undefined);
  assert.equal(L.corsHeaders(null, allowed).Vary, "Origin");
});

test("CORS headers cover preflight and are attached to OPTIONS and JSON responses", () => {
  const headers = L.corsHeaders(
    "http://127.0.0.1:4173",
    L.allowedOriginsFromEnv({ QUOTATION_ALLOWED_ORIGINS: "https://neliop96.github.io,http://127.0.0.1:4173" }),
  );
  assert.equal(headers["Access-Control-Allow-Origin"], "http://127.0.0.1:4173");
  assert.equal(headers["Access-Control-Allow-Methods"], "POST, OPTIONS");
  assert.equal(headers["Access-Control-Allow-Headers"], "authorization, x-client-info, apikey, content-type");

  const handler = indexSource.slice(indexSource.indexOf("Deno.serve("));
  assert.match(handler, /corsHeaders\(req\.headers\.get\('Origin'\), allowedOrigins\)/);
  assert.match(handler, /new Response\(null, \{ status: 204, headers \}\)/);
  assert.match(handler, /new Response\(JSON\.stringify\(body\), \{ status, headers: \{ \.\.\.headers, \.\.\.extra \} \}\)/);
  assert.match(handler, /global: \{ headers: \{ Authorization:/);
  assert.match(handler, /req\.method !== 'POST'/);
});

test("CORS still uses configured origins when another required setting is invalid", () => {
  const brokenConfig = L.parseConfig({
    QUOTATION_ALLOWED_ORIGINS: "https://neliop96.github.io,http://127.0.0.1:4173",
  });
  assert.ok("error" in brokenConfig);
  const headers = L.corsHeaders(
    "http://127.0.0.1:4173",
    L.allowedOriginsFromEnv({
      QUOTATION_ALLOWED_ORIGINS: "https://neliop96.github.io,http://127.0.0.1:4173",
    }),
  );
  assert.equal(headers["Access-Control-Allow-Origin"], "http://127.0.0.1:4173");
});

test("status eligibility rejects Draft, Rejected and Expired", () => {
  const today = "2026-10-15";
  for (const status of ["Draft", "Rejected", "Expired", "Bogus"]) {
    const r = L.checkEligibility({ ...quote, status }, today);
    assert.equal(r.ok, false, status);
    assert.equal(r.status, 409);
  }
  for (const status of ["Ready", "Sent", "Approved"]) assert.equal(L.checkEligibility({ ...quote, status }, today).ok, true, status);
});

test("validity is compared as calendar dates; Approved and legacy rows are unaffected", () => {
  assert.equal(L.checkEligibility({ ...quote, valid_until: "2026-10-15" }, "2026-10-15").ok, true);
  const late = L.checkEligibility({ ...quote, valid_until: "2026-10-14" }, "2026-10-15");
  assert.equal(late.ok, false);
  assert.match(late.error, /Valid for/);
  assert.match(L.checkEligibility({ ...quote, status: "Sent", valid_until: "2026-10-14" }, "2026-10-15").error, /revision/);
  assert.equal(L.checkEligibility({ ...quote, status: "Approved", valid_until: "2026-10-14" }, "2026-10-15").ok, true);
  assert.equal(L.checkEligibility({ ...quote, valid_until: null }, "2026-10-15").ok, true);
});

test("business date uses the configured zone across midnight", () => {
  const instant = new Date("2026-10-16T05:30:00Z");
  assert.equal(L.todayInZone("America/Los_Angeles", instant), "2026-10-15");
  assert.equal(L.todayInZone("UTC", instant), "2026-10-16");
  assert.equal(L.safeTimeZone("Not/AZone"), "America/Los_Angeles");
});

test("rate limits: per-quote cooldown and per-user hourly cap", () => {
  const now = new Date("2026-10-15T12:00:00Z");
  const base = { lastQuoteSendAt: null, userSendsLastHour: 0, now, cooldownSeconds: 60, hourlyLimit: 20 };
  assert.equal(L.evaluateSendLimits(base), null);
  const cool = L.evaluateSendLimits({ ...base, lastQuoteSendAt: "2026-10-15T11:59:30Z" });
  assert.equal(cool.status, 429);
  assert.equal(cool.retryAfter, 30);
  assert.equal(L.evaluateSendLimits({ ...base, lastQuoteSendAt: "2026-10-15T11:58:00Z" }), null);
  assert.equal(L.evaluateSendLimits({ ...base, userSendsLastHour: 20 }).status, 429);
  assert.equal(L.evaluateSendLimits({ ...base, userSendsLastHour: 19 }), null);
});

test("idempotency key is stable within a bucket and changes per version", () => {
  const now = new Date("2026-10-15T12:00:10Z");
  const a = L.idempotencyKey(quote, "project", now, 60);
  assert.equal(a, L.idempotencyKey(quote, "project", new Date("2026-10-15T12:00:40Z"), 60));
  assert.notEqual(a, L.idempotencyKey(quote, "project", new Date("2026-10-15T12:01:10Z"), 60));
  assert.notEqual(a, L.idempotencyKey({ ...quote, updated_at: "2026-10-03T00:00:00Z" }, "project", now, 60));
  assert.match(a, /^[A-Za-z0-9_.:-]+$/);
});

test("PDF for an original shows number, estimate date and Valid Until", () => {
  const lines = L.buildPdfLines(quote, L.pdfCustomer(quote), "project", "Dairy Flush").map((l) => l.text);
  assert.ok(lines.includes("PRECISION AUTOMATION"));
  assert.ok(lines.includes("Project Quotation EST1026002"));
  assert.ok(lines.includes("Estimate Date: Oct 1, 2026"));
  assert.ok(lines.includes("Valid Until: Oct 31, 2026"));
  assert.ok(!lines.some((l) => /Revision/.test(l)));
  assert.ok(lines.includes("Total Project Price: $1,014.00"));
});

test("PDF for a revision shows revision number, original and revision dates", () => {
  const rev = { ...quote, quote_number: "EST1026002-R1", revision_number: 1, revision_date: "2026-10-20", valid_until: "2026-11-19" };
  const lines = L.buildPdfLines(rev, L.pdfCustomer(rev), "project", "Dairy Flush").map((l) => l.text);
  assert.ok(lines.includes("Project Quotation EST1026002-R1"));
  assert.ok(lines.includes("Revision: 1"));
  assert.ok(lines.includes("Original Estimate Date: Oct 1, 2026"));
  assert.ok(lines.includes("Revision Date: Oct 20, 2026"));
  assert.ok(lines.includes("Valid Until: Nov 19, 2026"));
});

test("PDF dates match the dates shown in the app", () => {
  const rev = { ...quote, revision_number: 2, revision_date: "2026-10-20", valid_until: "2026-11-19" };
  const app = E.dateSummary(rev);
  const lines = L.dateLines(rev);
  assert.ok(lines.includes(`Original Estimate Date: ${app.original}`));
  assert.ok(lines.includes(`Revision Date: ${app.revision}`));
  assert.ok(lines.includes(`Valid Until: ${app.validUntil}`));
});

test("legacy quotes without dates still render", () => {
  const legacy = { ...quote, original_estimate_date: null, valid_until: null, validity_days: undefined };
  const lines = L.dateLines(legacy);
  assert.deepEqual(lines, ["Estimate Date: Not issued", "Valid Until: 30 days from the issue date"]);
});

test("PDF uses the saved customer snapshot, not the live record", () => {
  const live = { name: "Renamed Corp", email: "new@acme.test" };
  assert.equal(L.pdfCustomer(quote).name, "Snapshot Dairy");
  const lines = L.buildPdfLines(quote, L.pdfCustomer(quote), "project", "T").map((l) => l.text);
  assert.ok(lines.includes("Customer: Snapshot Dairy"));
  assert.ok(!lines.some((l) => l.includes("Renamed")));
  assert.deepEqual(L.pdfCustomer({ ...quote, customer_snapshot: {} }), {});
  assert.deepEqual(L.pdfCustomer({ ...quote, customer_snapshot: ["not", "a", "record"] }), {});
});

test("customer PDF options: materials listed without prices, project detail hides them", () => {
  const materials = L.buildPdfLines(quote, quote.customer_snapshot, "materials", "T");
  const withMaterials = materials.map((l) => l.text).join("\n");
  assert.match(withMaterials, /Included Materials/);
  assert.ok(materials.some((line) => line.table?.kind === "header" && line.table.quantity === "Quantity"));
  assert.ok(materials.some((line) => line.table?.kind === "row" && line.text === "Controller (PLC-1)" && line.table.quantity === "2"));
  assert.ok(!/\$200|\$100|markup|labor rate|labor hours|unit price/i.test(withMaterials));
  assert.ok(withMaterials.indexOf("Total Project Price") < withMaterials.indexOf("Project Scope / Notes"));
  const project = L.buildPdfLines(quote, quote.customer_snapshot, "project", "T").map((l) => l.text).join("\n");
  assert.ok(!/Included Materials/.test(project));
  assert.ok(!/\$200|\$100|markup|labor rate|labor hours|unit price/i.test(project));
  assert.match(project, /Total Project Price: \$1,014\.00/);
});

test("customer PDF never serializes internal cost, markup, labor, or breakdown fields", () => {
  const internal = {
    ...quote,
    items: [{ part: "SAFE-1", description: "Test part", qty: 3, cost: 917321.41 }],
    markup: 37,
    labor_hours: 29,
    labor_rate: 8123.47,
    tax_rate: 8,
  };
  const lines = L.buildPdfLines(internal, L.pdfCustomer(internal), "materials", "Safe Project");
  const pdfContent = lines.map((line) => `${line.text} ${line.table?.quantity || ""}`).join("\n");
  for (const secretValue of ["917321.41", "37", "29", "8123.47", "Materials:", "Labor:", "Markup"]) {
    assert.ok(!pdfContent.includes(secretValue), `customer PDF exposed ${secretValue}`);
  }
  assert.match(pdfContent, /Test part \(SAFE-1\)/);
  assert.match(pdfContent, /Total Project Price:/);
});

test("email PDF title fallback matches frontend and always uses saved customer data", () => {
  assert.match(indexSource, /const title = text\(input\.project_title, 140\);/);
  assert.equal(L.customerProjectTitle(quote, "  Override  "), "Override");
  assert.equal(L.customerProjectTitle(quote, ""), E.customerProjectTitle(quote));
  const firstNoteTitle = { ...quote, project_name: "", notes: "First line\nSecond line" };
  assert.equal(L.customerProjectTitle(firstNoteTitle), "First line");
  assert.equal(L.customerProjectTitle(firstNoteTitle), E.customerProjectTitle(firstNoteTitle));
  const defaultTitle = { ...quote, project_name: "", notes: "" };
  assert.equal(L.customerProjectTitle(defaultTitle), "Automation Project");
  assert.equal(L.customerProjectTitle(defaultTitle), E.customerProjectTitle(defaultTitle));
  assert.equal(L.customerProjectTitle(quote, "x".repeat(150)).length, 140);
});

test("PDF text is made safe for the standard fonts", () => {
  assert.equal(L.ascii("Café Nuñez\nLine"), "Cafe Nunez Line");
  assert.equal(L.ascii("Snowman \u2603"), "Snowman -");
});

test("totals match the frontend calculation and invalid prices are rejected", () => {
  const t = L.computeTotals(quote);
  const app = E.totals(quote);
  for (const key of ["material", "sell", "labor", "tax", "total"]) assert.equal(t[key], app[key]);
  assert.throws(() => L.computeTotals({ ...quote, items: [] }), L.QuoteDataError);
  assert.throws(() => L.computeTotals({ ...quote, markup: -1 }), L.QuoteDataError);
});

test("missing-column detection supports older databases without the version column", () => {
  assert.equal(L.isMissingColumnError({ code: "PGRST204", message: "x" }), true);
  assert.equal(L.isMissingColumnError({ code: "42703", message: "x" }), true);
  assert.equal(L.isMissingColumnError({ code: "23505", message: "dup" }), false);
  assert.equal(L.isMissingColumnError(null), false);
});

test("edge function source: auth headers intact, no secrets or hard-coded addresses", () => {
  assert.ok(indexSource.includes("`Bearer ${jwt}`"));
  assert.ok(indexSource.includes("`Bearer ${RESEND_API_KEY}`"));
  assert.ok(!/re_[A-Za-z0-9]{10,}/.test(indexSource));
  assert.ok(!/eyJ[A-Za-z0-9_-]{20,}/.test(indexSource));
  assert.ok(!/[\w.+-]+@[\w-]+\.[\w.]+/.test(indexSource.replace(/^import .*$/gm, "")), "no hard-coded email addresses");
  assert.ok(!/precisionautomation/i.test(fs.readFileSync(path.join(fnDir, "logic.ts"), "utf8").replace(/PRECISION AUTOMATION/g, "")));
  assert.ok(indexSource.includes("Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')"));
});

test("edge function source: eligibility, authorization and safe Sent transition", () => {
  assert.ok(indexSource.includes("roleAllowed(profile?.role, config.allowedRoles)"));
  assert.ok(indexSource.includes("checkEligibility(quote, today)"));
  assert.ok(indexSource.includes("evaluateSendLimits("));
  assert.ok(indexSource.includes("'Idempotency-Key'"));
  assert.ok(indexSource.includes(".eq('status', 'Ready').eq('updated_at', quote.updated_at)"));
  assert.ok(indexSource.includes("quote.status === 'Ready'"));
  assert.ok(!/status === 'Draft'/.test(indexSource), "no Draft-only transition");
  // The send happens before the log and status update, and Resend must have accepted it.
  assert.ok(indexSource.indexOf("api.resend.com") < indexSource.indexOf("quotation_email_log').insert"));
  assert.ok(indexSource.indexOf("if (!sent.ok)") < indexSource.indexOf("update({ status: 'Sent' })"));
});

test("frontend keeps the payload and surfaces function warnings", () => {
  const js = fs.readFileSync(path.join(root, "js", "quotes.js"), "utf8");
  assert.match(js, /data\.warning/);
  for (const key of ["quote_id", "detail", "project_title", "subject", "message"]) assert.ok(js.includes(key));
  assert.ok(!/service_role/.test(js));
});

test("version-binding migration is additive and review-only", () => {
  const sql = fs.readFileSync(path.join(root, "supabase", "migrations", "20261029020000_estimate_email_version_binding.sql"), "utf8");
  assert.match(sql, /ADD COLUMN IF NOT EXISTS quote_version_at timestamptz/);
  assert.ok(!/DROP\s+(TABLE|COLUMN)|DELETE\s+FROM|TRUNCATE/i.test(sql));
});
