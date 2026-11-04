const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.join(__dirname, "..");
const read = (...parts) => fs.readFileSync(path.join(root, ...parts), "utf8");
const migrationPath = ["supabase", "migrations", "20261104010000_account_approval_audit_history.sql"];
const migration = read(...migrationPath);
const sql = migration.replace(/--.*$/gm, "");
const auditSource = read("js", "approval-audit.js");
const authSource = read("js", "auth.js");
const htmlSource = read("index.html");

const functionBody = (name) => {
  const start = sql.indexOf(`CREATE FUNCTION ${name}`);
  assert.ok(start >= 0, `${name} must be created`);
  const end = sql.indexOf("$function$;", sql.indexOf("$function$", start) + 10);
  return sql.slice(start, end);
};

test("previously deployed approval migration is unchanged", () => {
  const hash = crypto
    .createHash("sha256")
    .update(fs.readFileSync(path.join(root, "supabase", "migrations", "20261102010000_account_approval_hardening.sql")))
    .digest("hex")
    .toUpperCase();
  assert.equal(hash, "8B563DFE048C7E4151DB562DCB2FFE1C5AD413A0BA7A9DFDF09AD3F949714FAD");
});

test("audit function is SECURITY DEFINER, empty search_path, and enforces approved owner in SQL", () => {
  const body = functionBody("public.list_account_approval_audit");
  assert.match(body, /p_limit integer DEFAULT 100/);
  assert.match(body, /p_before bigint DEFAULT NULL/);
  assert.match(body, /SECURITY DEFINER\s+SET search_path = ''/);
  const approval = body.indexOf("quote_studio_account_private.require_account_approved()");
  const owner = body.indexOf("caller.role = 'owner'");
  const query = body.indexOf("RETURN QUERY");
  assert.ok(approval > 0 && owner > approval && query > owner, "approval and owner checks must run before any rows are read");
  assert.match(body, /caller\.id = auth\.uid\(\)/);
  assert.doesNotMatch(body, /IN \('owner', 'admin'\)/, "administrators must not read the audit history");
  assert.match(body, /Approved owner required' USING ERRCODE = '42501'/);
});

test("audit function returns identifiers, names, emails, times, events, and full reasons", () => {
  const body = functionBody("public.list_account_approval_audit");
  for (const column of [
    "audit_id bigint", "recorded_at timestamptz", "event_type text", "actor_user_id uuid",
    "actor_name text", "actor_email text", "subject_user_id uuid", "subject_name text",
    "subject_email text", "reason text",
  ]) assert.ok(body.includes(column), `missing ${column}`);
  assert.doesNotMatch(body, /left\(|substr|btrim\(audit\.reason|truncate/i, "reasons must not be shortened");
  assert.match(body, /audit\.reason\s+FROM/);
});

test("historical rows stay visible after account deletion (LEFT JOINs only)", () => {
  const body = functionBody("public.list_account_approval_audit");
  assert.equal((body.match(/LEFT JOIN/g) || []).length, 4);
  assert.doesNotMatch(body, /(?<!LEFT )\b(INNER |RIGHT |CROSS )?JOIN\b/);
  assert.match(body, /LEFT JOIN auth\.users AS actor_user ON actor_user\.id = audit\.actor_user_id/);
  assert.match(body, /LEFT JOIN auth\.users AS subject_user ON subject_user\.id = audit\.subject_user_id/);
});

test("pagination is keyset based on the audit id, newest first, with a capped page size", () => {
  const body = functionBody("public.list_account_approval_audit");
  assert.match(body, /WHERE p_before IS NULL OR audit\.id < p_before/);
  assert.match(body, /ORDER BY audit\.id DESC\s+LIMIT page_size/);
  assert.match(body, /page_size := least\(p_limit, 200\)/);
  assert.match(body, /p_limit IS NULL OR p_limit < 1/);
  assert.doesNotMatch(body, /OFFSET/i);
});

test("function execute privileges: authenticated only, none for PUBLIC, anon, or service_role", () => {
  assert.match(
    sql,
    /REVOKE ALL ON FUNCTION public\.list_account_approval_audit\(integer, bigint\)\s+FROM PUBLIC, anon, authenticated, service_role;/,
  );
  assert.match(
    sql,
    /GRANT EXECUTE ON FUNCTION public\.list_account_approval_audit\(integer, bigint\)\s+TO authenticated;/,
  );
  assert.equal((sql.match(/GRANT\b/g) || []).length, 1, "the only GRANT is the function EXECUTE grant");
  assert.match(sql, /ALTER FUNCTION public\.list_account_approval_audit\(integer, bigint\) OWNER TO postgres/);
});

test("no direct table privileges, policies, columns, or failed-attempt logging are added", () => {
  assert.doesNotMatch(sql, /GRANT[^;]*\bON TABLE/i);
  assert.doesNotMatch(sql, /CREATE POLICY|CREATE TABLE|ADD COLUMN|INSERT INTO|\bUPDATE\b[^;]*\bSET\b|DELETE FROM/i);
  assert.doesNotMatch(sql, /outcome|result\s+text|failed_attempt/i);
  assert.match(sql, /Application roles must not have direct audit table privileges/);
  assert.match(sql, /Direct audit table privileges were opened/);
});

test("audit table is append-only for UPDATE, DELETE, and TRUNCATE and the limits are documented", () => {
  assert.match(sql, /BEFORE UPDATE OR DELETE ON quote_studio_account_private\.account_approval_audit\s+FOR EACH ROW/);
  assert.match(sql, /BEFORE TRUNCATE ON quote_studio_account_private\.account_approval_audit\s+FOR EACH STATEMENT/);
  assert.match(sql, /ENABLE ALWAYS TRIGGER account_approval_audit_no_row_change/);
  assert.match(sql, /ENABLE ALWAYS TRIGGER account_approval_audit_no_truncate/);
  assert.match(sql, /Account approval audit records are append-only'\s+USING ERRCODE = '42501'/);
  assert.match(migration, /cannot stop the table owner or a\s*--\s*superuser/);
  assert.match(migration, /DISABLE TRIGGER,\s*--\s*DROP TRIGGER, or DROP TABLE/);
});

test("migration is fail-closed: preflight, single transaction, and postcondition assertions", () => {
  assert.match(sql, /^\s*BEGIN;/);
  assert.match(sql, /COMMIT;\s*$/);
  assert.match(sql, /must be installed first/);
  assert.match(sql, /Audit history objects already exist; reconcile instead of replaying/);
  assert.match(sql, /Audit history function EXECUTE privileges are not as expected/);
  assert.match(sql, /Append-only triggers are missing or not ENABLE ALWAYS/);
});

function createHarness({ role = "owner", rpc } = {}) {
  const elements = {};
  const element = (id) =>
    (elements[id] ??= {
      id, innerHTML: "", textContent: "", disabled: false, onclick: null,
      classes: new Set(id === "approvalAuditPanel" || id === "approvalAuditMore" ? ["hidden"] : []),
      classList: {
        add: (c) => elements[id].classes.add(c),
        remove: (c) => elements[id].classes.delete(c),
        toggle: (c, on) => (on ? elements[id].classes.add(c) : elements[id].classes.delete(c)),
      },
    });
  const calls = [];
  const plain = (value) => JSON.parse(JSON.stringify(value));
  const context = {
    $: element,
    esc: (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]),
    checked: ({ data, error }) => { if (error) throw error; return data; },
    profile: { role },
    db: { rpc: (name, params) => { calls.push({ name, params: plain(params) }); return Promise.resolve(rpc(name, params, calls.length)); } },
    console: { error() {} },
    Number, String, Date,
  };
  vm.createContext(context);
  vm.runInContext(
    `${auditSource}\nthis.api = { initApprovalAudit, loadApprovalAudit, refreshApprovalAudit, resetApprovalAudit };`,
    context,
  );
  return { elements, calls, api: context.api, element };
}

const makeRows = (from, to) =>
  Array.from({ length: from - to + 1 }, (_, i) => ({
    audit_id: from - i, recorded_at: "2026-11-04T09:00:00Z", event_type: "approve",
    actor_user_id: "a1", actor_name: "Owner", actor_email: "owner@example.test",
    subject_user_id: "s1", subject_name: "Pat", subject_email: "pat@example.test",
    reason: `Reason ${from - i}`,
  }));

test("non-owner roles never see the panel and never call the audit RPC", async () => {
  for (const role of ["admin", "manager", "employee", null]) {
    const h = createHarness({ role, rpc: () => ({ data: [], error: null }) });
    await h.api.initApprovalAudit();
    await h.api.loadApprovalAudit(true);
    assert.equal(h.calls.length, 0, `role ${role} must not call the RPC`);
    assert.ok(h.element("approvalAuditPanel").classes.has("hidden"));
    assert.equal(h.element("approvalAuditRows").innerHTML, "");
  }
});

test("owner sees the panel, loading state is cleared, and an empty history is explained", async () => {
  const h = createHarness({ rpc: () => ({ data: [], error: null }) });
  await h.api.initApprovalAudit();
  assert.ok(!h.element("approvalAuditPanel").classes.has("hidden"));
  assert.equal(h.element("approvalAuditStatus").textContent, "No approval events have been recorded yet.");
  assert.ok(h.element("approvalAuditMore").classes.has("hidden"));
  assert.deepEqual(h.calls[0], { name: "list_account_approval_audit", params: { p_limit: 51 } });
});

test("keyset pagination requests page size + 1, shows 50, and continues from the last audit id", async () => {
  const pages = [makeRows(120, 70), makeRows(70, 20), makeRows(20, 6)];
  const h = createHarness({ rpc: (_n, _p, n) => ({ data: pages[n - 1], error: null }) });
  await h.api.initApprovalAudit();
  assert.equal((h.element("approvalAuditRows").innerHTML.match(/<tr>/g) || []).length, 50);
  assert.ok(!h.element("approvalAuditMore").classes.has("hidden"), "51 rows returned means more exist");
  assert.ok(h.element("approvalAuditRows").innerHTML.indexOf("Reason 120") < h.element("approvalAuditRows").innerHTML.indexOf("Reason 71"));
  await h.element("approvalAuditMore").onclick();
  assert.deepEqual(h.calls[1].params, { p_limit: 51, p_before: 71 });
  assert.equal((h.element("approvalAuditRows").innerHTML.match(/<tr>/g) || []).length, 100);
  await h.element("approvalAuditMore").onclick();
  assert.deepEqual(h.calls[2].params, { p_limit: 51, p_before: 21 });
  assert.equal((h.element("approvalAuditRows").innerHTML.match(/<tr>/g) || []).length, 115);
  assert.ok(h.element("approvalAuditMore").classes.has("hidden"), "last page hides Load more");
});

test("deleted accounts and bootstrap events render safely", async () => {
  const rows = [
    { audit_id: 3, recorded_at: "2026-11-04T09:00:00Z", event_type: "revoke", actor_user_id: "gone-actor", actor_name: null, actor_email: null, subject_user_id: "gone-subject", subject_name: null, subject_email: null, reason: "Account closed for cause" },
    { audit_id: 1, recorded_at: "2026-11-01T09:00:00Z", event_type: "bootstrap", actor_user_id: null, actor_name: null, actor_email: null, subject_user_id: "owner-1", subject_name: "Owner", subject_email: "owner@example.test", reason: "Change reference LIVE bootstrap" },
  ];
  const h = createHarness({ rpc: () => ({ data: rows, error: null }) });
  await h.api.initApprovalAudit();
  const html = h.element("approvalAuditRows").innerHTML;
  assert.match(html, /Deleted account/);
  assert.match(html, /gone-subject/);
  assert.match(html, /Revoked/);
  assert.match(html, /Bootstrap/);
  assert.match(html, /Database administrator \(bootstrap\)/);
  assert.match(html, /Completed/);
});

test("all dynamic audit content is HTML-escaped", async () => {
  const hostile = `<img src=x onerror=alert(1)>"'&`;
  const rows = [{ ...makeRows(1, 1)[0], reason: hostile, actor_name: hostile, actor_email: hostile, subject_name: hostile, subject_email: hostile, event_type: hostile, subject_user_id: hostile }];
  const h = createHarness({ rpc: () => ({ data: rows, error: null }) });
  await h.api.initApprovalAudit();
  const html = h.element("approvalAuditRows").innerHTML;
  assert.doesNotMatch(html, /<img/);
  assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;&quot;&#39;&amp;/);
});

test("RPC failure shows an error state, keeps existing rows, and does not throw", async () => {
  let fail = false;
  const h = createHarness({ rpc: () => (fail ? { data: null, error: new Error("Approved owner required") } : { data: makeRows(60, 10), error: null }) });
  await h.api.initApprovalAudit();
  fail = true;
  await h.element("approvalAuditMore").onclick();
  assert.match(h.element("approvalAuditStatus").textContent, /Unable to load audit history: Approved owner required/);
  assert.equal((h.element("approvalAuditRows").innerHTML.match(/<tr>/g) || []).length, 50);
  fail = false;
  await h.element("approvalAuditRefresh").onclick();
  assert.equal(h.element("approvalAuditStatus").textContent, "");
});

test("frontend wiring: owner-only panel, escaped output, and approval workflows unchanged", () => {
  assert.match(htmlSource, /id="approvalAuditPanel" class="hidden"/);
  assert.match(htmlSource, /<script defer src="\.\/js\/approval-audit\.js"><\/script>/);
  assert.match(auditSource, /profile\?\.role !== "owner"/);
  assert.doesNotMatch(auditSource, /innerHTML\s*=\s*[^;]*(error|message)/, "error text must use textContent");
  assert.doesNotMatch(auditSource, /\.from\(["']/, "audit data must come only from the RPC");
  assert.match(authSource, /db\.rpc\(rpc, \{\s*p_user_id: button\.dataset\.userId,\s*p_reason: reason\.trim\(\),/);
  assert.match(authSource, /"approve_account_access"/);
  assert.match(authSource, /"revoke_account_access"/);
  assert.ok(authSource.indexOf("initApprovalAudit()") > authSource.indexOf('showOnlyAuth("app")'));
});

test("security regression: audit RPC is the only new application entry point", () => {
  assert.equal((sql.match(/CREATE FUNCTION public\./g) || []).length, 1);
  assert.doesNotMatch(sql, /GRANT[^;]*service_role/);
  assert.doesNotMatch(sql, /ALTER (TABLE|SCHEMA)[^;]*(DISABLE|NO FORCE)/i);
});

for (const [label, parts] of [
  ["STAGING", ["supabase", "account-approval-staging-post-deploy-check.sql"]],
  ["LIVE", ["supabase", "live-release", "05_security_post_deploy_check.sql"]],
]) {
  test(`${label} post-deploy check verifies the exact audit RPC without weakening the 30-RPC guard`, () => {
    const check = read(...parts);
    const code = check.replace(/--.*$/gm, "");
    assert.match(check, /count\(\*\) = 30 AND bool_and\(/, "baseline 30 guarded RPC assertion must remain");
    assert.match(code, /IS DISTINCT FROM (?:pg_catalog\.)?to_regprocedure\('public\.list_account_approval_audit\(integer,bigint\)'\)/);
    assert.match(code, /Owner-only audit RPC has exact identity, guards and privileges/);
    assert.match(code, /proname = 'list_account_approval_audit'\) = 1/);
    assert.match(code, /prosecdef/);
    assert.match(code, /proconfig @> ARRAY\['search_path=""'\]/);
    assert.match(code, /require_account_approved\(\)/);
    assert.match(code, /caller\.role = ''owner''/);
    assert.match(code, /has_function_privilege\('authenticated', 'public\.list_account_approval_audit\(integer,bigint\)', 'EXECUTE'\)/);
    assert.match(code, /NOT (?:pg_catalog\.)?has_function_privilege\('anon', 'public\.list_account_approval_audit/);
    assert.match(code, /NOT (?:pg_catalog\.)?has_function_privilege\('service_role', 'public\.list_account_approval_audit/);
    assert.match(code, /\b(?:acl|a)\.grantee = 0/);
    assert.match(code, /account_approval_audit_no_row_change/);
    assert.match(code, /account_approval_audit_no_truncate/);
    assert.match(code, /tgenabled = 'A'/);
    assert.doesNotMatch(
      code,
      /^\s*(?:CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|TRUNCATE|GRANT|REVOKE|CALL|DO)\b/im,
      "verification must stay read-only",
    );
  });
}
