const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const E = require("../js/estimates.js");

const root = path.join(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const esc = (s) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const money = (n) => "$" + Number(n).toFixed(2);

const base = {
  quote_number: "EST1026002",
  project_name: "Dairy Flush",
  customer_snapshot: { name: "Acme Dairy", contact: "Pat", address: "1 Main", email: "pat@acme.test" },
  items: [{ part: "PLC-1", description: "Controller", qty: 2, cost: 100 }],
  labor_hours: 10,
  labor_rate: 75,
  markup: 20,
  tax_rate: 10,
  notes: "Scope notes",
  status: "Sent",
  revision_number: 0,
  validity_days: 30,
  original_estimate_date: "2026-10-01",
  revision_date: null,
  valid_until: "2026-10-31",
};

test("calendar date arithmetic is timezone independent", () => {
  assert.equal(E.addDays("2026-01-31", 30), "2026-03-02");
  assert.equal(E.addDays("2026-12-15", 30), "2027-01-14");
  assert.equal(E.addDays("2028-02-28", 1), "2028-02-29");
  assert.equal(E.addDays("2027-02-28", 1), "2027-03-01");
  assert.equal(E.addDays("2026-11-01", 30), "2026-12-01");
  assert.throws(() => E.addDays("2026-02-30", 1), /Invalid date/);
});

test("today is calculated in the business time zone, across midnight and DST", () => {
  // 2026-10-02 03:30 UTC is still Oct 1 in Los Angeles but already Oct 2 in UTC.
  const lateEvening = new Date("2026-10-02T03:30:00Z");
  assert.equal(E.todayInZone("America/Los_Angeles", lateEvening), "2026-10-01");
  assert.equal(E.todayInZone("UTC", lateEvening), "2026-10-02");
  // DST ended 2026-11-01 in the US; 07:30 UTC is 23:30 PDT Oct 31, 08:30 UTC is 00:30 PDT... check both sides.
  assert.equal(E.todayInZone("America/Los_Angeles", new Date("2026-11-01T07:30:00Z")), "2026-11-01");
  assert.equal(E.todayInZone("America/Los_Angeles", new Date("2026-11-02T07:59:00Z")), "2026-11-01");
  assert.equal(E.todayInZone("America/Los_Angeles", new Date("2026-11-02T08:00:00Z")), "2026-11-02");
});

test("validity defaults to 30 days and rejects invalid values", () => {
  assert.equal(E.DEFAULT_VALIDITY_DAYS, 30);
  assert.equal(E.normalizeValidityDays(""), 30);
  assert.equal(E.normalizeValidityDays("45"), 45);
  assert.equal(E.normalizeValidityDays(365), 365);
  for (const bad of [0, -1, 366, 1.5, "abc", NaN]) assert.throws(() => E.normalizeValidityDays(bad), /1 to 365/);
});

test("valid until follows the issue date of the relevant version", () => {
  assert.equal(E.validUntil(base), "2026-10-31");
  const revision = { ...base, revision_number: 1, revision_date: "2026-10-20", validity_days: 14 };
  assert.equal(E.validUntil(revision), "2026-11-03");
  assert.equal(E.validUntil({ ...base, status: "Draft", original_estimate_date: null }), null);
});

test("expiration is derived for Sent only and never overwrites Approved or Rejected", () => {
  assert.equal(E.effectiveStatus(base, "2026-10-31"), "Sent");
  assert.equal(E.effectiveStatus(base, "2026-11-01"), "Expired");
  assert.equal(E.effectiveStatus({ ...base, status: "Approved" }, "2027-01-01"), "Approved");
  assert.equal(E.effectiveStatus({ ...base, status: "Rejected" }, "2027-01-01"), "Rejected");
  assert.equal(E.effectiveStatus({ ...base, status: "Draft" }, "2027-01-01"), "Draft");
  assert.equal(E.effectiveStatus({ ...base, valid_until: null }, "2099-01-01"), "Sent"); // legacy rows
});

test("status filters and counts cover every status", () => {
  const quotes = [
    { ...base, id: 1, status: "Draft" },
    { ...base, id: 2, status: "Ready" },
    { ...base, id: 3, status: "Sent" },
    { ...base, id: 4, status: "Sent", valid_until: "2026-01-01" },
    { ...base, id: 5, status: "Approved" },
    { ...base, id: 6, status: "Rejected" },
  ];
  const counts = E.statusCounts(quotes, "2026-10-15");
  assert.deepEqual(counts, { All: 6, Draft: 1, Ready: 1, Sent: 1, Approved: 1, Rejected: 1, Expired: 1 });
  assert.deepEqual(E.filterQuotes(quotes, "Expired", "2026-10-15").map((q) => q.id), [4]);
  assert.deepEqual(E.filterQuotes(quotes, "Draft", "2026-10-15").map((q) => q.id), [1]);
  assert.equal(E.filterQuotes(quotes, "All", "2026-10-15").length, 6);
});

test("row actions respect status and ownership", () => {
  const today = "2026-10-15";
  const owner = { isAdmin: false, userId: "u1" };
  const draft = E.rowActions({ ...base, status: "Draft", created_by: "u1" }, today, owner);
  assert.equal(draft.edit, true);
  assert.equal(draft.send, false);
  assert.equal(draft.revise, false);
  const sent = E.rowActions({ ...base, created_by: "u1" }, today, owner);
  assert.equal(sent.edit, false);
  assert.equal(sent.send, true);
  assert.equal(sent.decide, true);
  assert.equal(sent.revise, true);
  const stranger = E.rowActions({ ...base, created_by: "u2" }, today, owner);
  assert.equal(stranger.revise, false);
  assert.equal(stranger.decide, false);
  assert.equal(E.rowActions({ ...base, created_by: "u2" }, today, { isAdmin: true, userId: "u1" }).revise, true);
  assert.equal(E.rowActions({ ...base, status: "Approved", created_by: "u1" }, today, owner).decide, false);
});

test("version labels and date summaries distinguish originals and revisions", () => {
  assert.equal(E.versionLabel(base), "Original");
  assert.equal(E.versionLabel({ ...base, revision_number: 2 }), "Revision 2");
  const original = E.dateSummary(base);
  assert.equal(original.original, "Oct 1, 2026");
  assert.equal(original.revision, "");
  assert.equal(original.validUntil, "Oct 31, 2026");
  const revised = E.dateSummary({ ...base, revision_number: 1, revision_date: "2026-10-20", valid_until: "2026-11-19" });
  assert.equal(revised.original, "Oct 1, 2026");
  assert.equal(revised.revision, "Oct 20, 2026");
  assert.equal(revised.validUntil, "Nov 19, 2026");
});

test("unsaved-change signature detects every editable field and ignores noise", () => {
  const draft = { ...base, validity_days: 30 };
  const sig = E.signature(draft);
  assert.equal(E.signature({ ...draft, status: "Ready", quote_number: "other" }), sig);
  assert.equal(E.signature({ ...draft, labor_hours: "10" }), sig);
  const changes = [
    { project_name: "x" },
    { customer_id: "c" },
    { labor_hours: 11 },
    { labor_rate: 80 },
    { markup: 25 },
    { tax_rate: 9 },
    { notes: "changed" },
    { validity_days: 45 },
    { items: [{ ...draft.items[0], qty: 3 }] },
    { items: [] },
  ];
  for (const change of changes) assert.notEqual(E.signature({ ...draft, ...change }), sig, JSON.stringify(change));
});

test("totals match the original quotation calculation", () => {
  const t = E.totals(base);
  assert.equal(t.material, 200);
  assert.equal(t.sell, 240);
  assert.equal(t.labor, 750);
  assert.equal(t.tax, 24);
  assert.equal(t.total, 1014);
});

test("detailed PDF shows number, dates, validity and pricing for an original", () => {
  const html = E.buildPdfHtml(base, { format: "detailed", esc, money });
  assert.match(html, /Estimate EST1026002/);
  assert.match(html, /Estimate Date:<\/b> Oct 1, 2026/);
  assert.match(html, /Valid Until:<\/b> Oct 31, 2026/);
  assert.doesNotMatch(html, /Revision/);
  assert.match(html, /Unit price/);
  assert.match(html, /Labor: \$750\.00/);
  assert.match(html, /Total: \$1014\.00/);
});

test("customer PDF is the default and preserves detailed printing as an internal option", () => {
  const html = read("index.html");
  assert.match(html, /<option value="customer" selected>Customer quotation/);
  assert.match(html, /<option value="detailed">Detailed quotation \(internal use only\)/);
});

test("revision PDF shows revision number, original date, revision date and validity", () => {
  const revision = {
    ...base,
    quote_number: "EST1026002-R1",
    revision_number: 1,
    revision_date: "2026-10-20",
    valid_until: "2026-11-19",
  };
  for (const format of ["detailed", "customer"]) {
    const html = E.buildPdfHtml(revision, { format, esc, money });
    assert.match(html, /EST1026002-R1/);
    assert.match(html, /Revision:<\/b> 1/);
    assert.match(html, /Original Estimate Date:<\/b> Oct 1, 2026/);
    assert.match(html, /Revision Date:<\/b> Oct 20, 2026/);
    assert.match(html, /Valid Until:<\/b> Nov 19, 2026/);
  }
});

test("customer PDF hides prices and keeps the material-visibility option", () => {
  const project = E.buildPdfHtml(base, { format: "customer", detail: "project", esc, money });
  assert.match(project, /Total Project Price: \$1014\.00/);
  assert.doesNotMatch(project, /Controller/);
  assert.doesNotMatch(project, /Unit price|Labor|Markup|\$200\.00|\$100\.00/);
  const materials = E.buildPdfHtml(base, { format: "customer", detail: "materials", esc, money });
  assert.match(materials, /Included Materials/);
  assert.match(materials, /Controller \(PLC-1\)/);
  assert.match(materials, /<th>Description<\/th><th>Quantity<\/th>/);
  assert.doesNotMatch(materials, /Unit price|\$100\.00|\$120\.00/);
  const named = E.buildPdfHtml(base, { format: "customer", projectName: "Custom Title", esc, money });
  assert.match(named, /Custom Title/);
});

test("customer print PDF excludes internal cost and pricing inputs", () => {
  const internal = {
    ...base,
    items: [{ part: "SAFE-1", description: "Test part", qty: 3, cost: 917321.41 }],
    markup: 37,
    labor_hours: 29,
    labor_rate: 8123.47,
  };
  const html = E.buildPdfHtml(internal, { format: "customer", detail: "materials", esc, money });
  for (const secretValue of ["917321.41", "37%", "29 hours", "8123.47", "Unit price", "Labor:"]) {
    assert.ok(!html.includes(secretValue), `customer print PDF exposed ${secretValue}`);
  }
  assert.match(html, /Test part \(SAFE-1\)/);
});

test("customer document uses saved customer snapshot and consistent project-title fallbacks", () => {
  const malformedSnapshot = E.buildPdfHtml(
    { ...base, customer_snapshot: ["not", "a", "record"] },
    { format: "customer", esc, money },
  );
  assert.doesNotMatch(malformedSnapshot, /Acme Dairy|pat@acme\.test/);
  assert.equal(E.customerProjectTitle(base), "Dairy Flush");
  assert.equal(E.customerProjectTitle({ ...base, project_name: "" }), "Scope notes");
  assert.equal(
    E.customerProjectTitle({ ...base, project_name: "", notes: "  First line  \r\nSecond line" }),
    "First line",
  );
  assert.equal(E.customerProjectTitle({ ...base, project_name: "", notes: "" }), "Automation Project");
  assert.equal(E.customerProjectTitle(base, "  Override  "), "Override");
  assert.equal(E.customerProjectTitle(base, "x".repeat(150)).length, 140);
});

test("PDF is built from the saved record and escapes content", () => {
  const html = E.buildPdfHtml({ ...base, notes: "<script>alert(1)</script>", project_name: "<b>x</b>" }, { format: "detailed", esc, money });
  assert.doesNotMatch(html, /<script>alert/);
  assert.match(html, /&lt;script&gt;alert/);
  const draft = E.buildPdfHtml(
    { ...base, status: "Draft", original_estimate_date: null, valid_until: null },
    { format: "detailed", esc, money },
  );
  assert.match(draft, /Not issued/);
  assert.match(draft, /30 days from the issue date/);
});

test("frontend wiring: drafts, filters, revisions, history and settings are present", () => {
  const html = read("index.html");
  const quotes = read("js/quotes.js");
  const auth = read("js/auth.js");
  const core = read("js/core.js");
  for (const id of ["saveDraft", "saveQuote", "createRevision", "quoteStatusFilters", "quoteHistoryPanel", "quoteValidity", "defaultValidityDays"])
    assert.match(html, new RegExp(`id="${id}"`), id);
  assert.match(html, /Saved Estimates/);
  assert.ok(html.indexOf("js/estimates.js") > -1 && html.indexOf("js/estimates.js") < html.indexOf("js/quotes.js"));
  assert.doesNotMatch(html, /<select id="quoteStatus"/);
  assert.match(quotes, /create_estimate_revision/);
  assert.match(quotes, /set_estimate_decision/);
  assert.match(quotes, /quote_status_history/);
  assert.match(quotes, /beforeunload/);
  assert.match(auth, /validity_days/);
  assert.match(core, /sync_estimate_statuses/);
});

test("email sending keeps its payload and only reports Sent from database state", () => {
  const quotes = read("js/quotes.js");
  const block = /db\.functions\.invoke\("send-quotation", \{\s*body: \{([\s\S]*?)\},\s*\}\)/.exec(quotes);
  assert.ok(block, "send-quotation invocation present");
  const keys = [...block[1].matchAll(/^\s*([a-z_]+):/gm)].map((m) => m[1]);
  assert.deepEqual(keys, ["quote_id", "detail", "project_title", "subject", "message"]);
  assert.doesNotMatch(quotes, /update\(\{\s*status:\s*"Sent"/);
  assert.match(quotes, /does not confirm delivery/);
  assert.match(quotes, /remains Ready/);
});

test("no service-role key or direct status writes to issued states in frontend", () => {
  for (const file of ["index.html", "js/quotes.js", "js/auth.js", "js/core.js", "js/estimates.js"]) {
    assert.doesNotMatch(read(file), /service_role|SERVICE_ROLE/, file);
  }
  const quotes = read("js/quotes.js");
  assert.doesNotMatch(quotes, /status:\s*"(Sent|Approved|Rejected|Expired)"/);
});
