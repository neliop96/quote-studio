const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "..");
const read = (...parts) => fs.readFileSync(path.join(root, ...parts), "utf8");
const html = read("index.html");
const css = read("css", "styles.css");
const nav = read("js", "navigation.js");
const catalog = read("js", "catalog.js");
const auth = read("js", "auth.js");

const normalizeNavigation = new Function(
  `${nav.slice(0, nav.indexOf("(() => {"))}; return normalizeNavigation;`,
)();

function attrValues(attr) {
  return [...html.matchAll(new RegExp(`${attr}="([^"]+)"`, "g"))].map((match) => match[1]);
}

test("main navigation has the requested order and no Team tab", () => {
  const mainNav = html.match(/<nav class="tabs main-nav"[\s\S]*?<\/nav\s*>/)[0];
  const labels = [...mainNav.matchAll(/<button[^>]*>([^<]+)<\/button/g)].map((m) => m[1]);
  assert.deepEqual(labels, [
    "Dashboard",
    "Projects &amp; Sales",
    "Products &amp; Inventory",
    "Customers",
    "Shift Reports",
    "Settings",
  ]);
  assert.doesNotMatch(html, /data-tab="team"/);
  assert.doesNotMatch(html, /<section id="team"/);
});

test("grouped sections expose every existing feature", () => {
  const sales = html.match(/data-subnav="sales"[\s\S]*?<\/nav\s*>/)[0];
  assert.match(sales, /data-tab="quotes">Estimates/);
  assert.match(sales, /data-tab="projects"/);
  const catalogGroup = html.match(/data-subnav="catalog"[\s\S]*?<\/nav\s*>/)[0];
  for (const tab of ["products", "inventory", "movements"]) {
    assert.match(catalogGroup, new RegExp(`data-tab="${tab}"`));
  }
  assert.doesNotMatch(html, /Invoices|Project Management/);
});

test("every navigation target resolves to exactly one section", () => {
  const sections = [...html.matchAll(/<section id="([^"]+)"/g)].map((m) => m[1]);
  for (const tab of new Set(attrValues("data-tab"))) {
    assert.equal(sections.filter((id) => id === tab).length, 1, tab);
  }
  for (const id of ["dashboard", "movements", "recordStock", "movementRows", "stockRows"]) {
    assert.equal(html.split(`id="${id}"`).length, 2, id);
  }
  for (const id of nav.match(/const NAV_SECTIONS = \[([\s\S]*?)\]/)[1].match(/"(\w+)"/g)) {
    assert.ok(sections.includes(id.replaceAll('"', "")), id);
  }
});

test("Settings has Account, Team Management, Shift Scheduling and Preferences", () => {
  const settings = html.match(/<section id="settings"[\s\S]*?<\/section>/)[0];
  for (const label of ["Account", "Team Management", "Shift Scheduling", "Preferences"]) {
    assert.match(settings, new RegExp(`data-settings-pane="[a-z]+"[^>]*>${label}<`));
  }
  const panes = (name) => settings.split(`data-pane="${name}"`).length - 1;
  assert.equal(panes("account"), 3); // account info, password, two-factor
  assert.equal(panes("team"), 1);
  assert.equal(panes("scheduling"), 1);
  assert.equal(panes("preferences"), 3); // defaults, numbering, handoff alerts
  assert.match(settings, /id="teamRows"/);
  assert.match(settings, /id="mfaEnroll"/);
  assert.match(settings, /id="shiftSchedulingAdminPanel"[^>]*data-pane="scheduling"/);
});

test("saved navigation is normalized and admin-only panes are protected", () => {
  assert.deepEqual(normalizeNavigation(null, false), { tab: "dashboard", pane: "account" });
  assert.deepEqual(normalizeNavigation({ tab: "bogus", pane: "x" }, true), {
    tab: "dashboard",
    pane: "account",
  });
  assert.deepEqual(normalizeNavigation({ tab: "settings", pane: "team" }, false), {
    tab: "settings",
    pane: "account",
  });
  assert.deepEqual(normalizeNavigation({ tab: "settings", pane: "scheduling" }, true), {
    tab: "settings",
    pane: "scheduling",
  });
  assert.equal(normalizeNavigation({ tab: "movements" }, false).tab, "movements");
});

test("navigation is restored after authentication and data load", () => {
  assert.match(auth, /await updateMfaStatus\(\);\s+window\.restoreNavigation\?\.\(\)/);
  assert.match(html, /js\/navigation\.js/);
  assert.match(nav, /sessionStorage/);
  assert.match(nav, /if \(!ready\) return;/);
  assert.doesNotMatch(nav, /location\.hash/);
});

test("technical IDs are not shown in the UI", () => {
  assert.doesNotMatch(html, /<th>User ID<\/th>/);
  assert.match(html, /<th>Name<\/th><th>Email<\/th><th>Role<\/th>/);
  assert.doesNotMatch(catalog, /<td>\$\{esc\(p\.id\)\}<\/td>/);
  for (const file of ["auth", "catalog", "inventory", "shift-reports"]) {
    const source = read("js", `${file}.js`);
    assert.doesNotMatch(source, /\|\| (person\.id|m\.actor|m\.product_id|entry\.employee_id)\b/, file);
  }
  assert.doesNotMatch(auth, /administrator to add your user ID/);
});

test("schedule load button aligns with the date inputs and layout is responsive", () => {
  assert.match(css, /\.inventory-controls > \.actions\s*{\s*margin: 0;/);
  assert.match(css, /\.inventory-controls \.actions button\s*{\s*height: 42px;/);
  assert.match(css, /@media \(max-width: 760px\)[\s\S]*\.tabs\.main-nav,[\s\S]*overflow-x: auto/);
  assert.match(css, /\.tabs\.sub-nav button\.active/);
});
