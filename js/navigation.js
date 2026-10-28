// UI-only navigation: grouped main sections and Settings sub-sections.
const NAV_SECTIONS = [
  "dashboard",
  "quotes",
  "projects",
  "products",
  "inventory",
  "movements",
  "customers",
  "shiftReports",
  "settings",
];
const NAV_GROUP = {
  dashboard: "dashboard",
  quotes: "sales",
  projects: "sales",
  products: "catalog",
  inventory: "catalog",
  movements: "catalog",
  customers: "customers",
  shiftReports: "shiftReports",
  settings: "settings",
};
const SETTINGS_PANES = ["account", "team", "scheduling", "preferences"];
const ADMIN_ONLY_PANES = ["team", "scheduling"];
const NAV_STORAGE_KEY = "quoteStudio.navigation";

// Validates a saved location so refresh never lands on a section the user cannot use.
function normalizeNavigation(saved, isAdmin) {
  const tab = NAV_SECTIONS.includes(saved?.tab) ? saved.tab : "dashboard";
  let pane = SETTINGS_PANES.includes(saved?.pane) ? saved.pane : "account";
  if (!isAdmin && ADMIN_ONLY_PANES.includes(pane)) pane = "account";
  return { tab, pane };
}

(() => {
  const canAdmin = () => typeof isAdminRole === "function" && isAdminRole();
  let current = { tab: "dashboard", pane: "account" };
  const lastTabInGroup = {};

  let ready = false;

  function save() {
    if (!ready) return;
    try {
      sessionStorage.setItem(NAV_STORAGE_KEY, JSON.stringify(current));
    } catch {
      // Storage can be unavailable (private mode); navigation still works.
    }
  }

  function updateDashboard() {
    const count = (list) => (Array.isArray(list) ? String(list.length) : "—");
    $("dashQuotes").textContent = count(typeof quotes === "undefined" ? null : quotes);
    $("dashProducts").textContent = count(typeof products === "undefined" ? null : products);
    $("dashCustomers").textContent = count(typeof customers === "undefined" ? null : customers);
  }

  function showTab(tab) {
    const group = NAV_GROUP[tab];
    current.tab = tab;
    lastTabInGroup[group] = tab;
    NAV_SECTIONS.forEach((id) => $(id).classList.toggle("hidden", id !== tab));
    document
      .querySelectorAll("[data-tab]")
      .forEach((button) => button.classList.toggle("active", button.dataset.tab === tab));
    document
      .querySelectorAll("[data-group]")
      .forEach((button) => button.classList.toggle("active", button.dataset.group === group));
    document
      .querySelectorAll("[data-subnav]")
      .forEach((nav) => nav.classList.toggle("hidden", nav.dataset.subnav !== group));
    if (tab === "dashboard") updateDashboard();
    save();
  }

  function showPane(pane) {
    pane = normalizeNavigation({ tab: "settings", pane }, canAdmin()).pane;
    current.pane = pane;
    document
      .querySelectorAll("[data-pane]")
      .forEach((panel) => panel.classList.toggle("pane-off", panel.dataset.pane !== pane));
    document
      .querySelectorAll("[data-settings-pane]")
      .forEach((button) => button.classList.toggle("active", button.dataset.settingsPane === pane));
    save();
  }

  function applyRoleVisibility() {
    document.querySelectorAll("[data-settings-pane]").forEach((button) => {
      if (ADMIN_ONLY_PANES.includes(button.dataset.settingsPane))
        button.classList.toggle("hidden", !canAdmin());
    });
  }

  // Leaf buttons are clicked (not called directly) so existing per-tab data loaders still run.
  function openTab(tab) {
    document.querySelector(`[data-tab="${tab}"]`).click();
  }

  document.querySelectorAll("[data-tab]").forEach((button) => {
    button.addEventListener("click", () => showTab(button.dataset.tab));
  });
  document.querySelectorAll("[data-group][data-default]").forEach((button) => {
    button.addEventListener("click", () =>
      openTab(lastTabInGroup[button.dataset.group] || button.dataset.default),
    );
  });
  document.querySelectorAll("[data-goto]").forEach((button) => {
    button.addEventListener("click", () => openTab(button.dataset.goto));
  });
  document.querySelectorAll("[data-settings-pane]").forEach((button) => {
    button.addEventListener("click", () => showPane(button.dataset.settingsPane));
  });

  window.restoreNavigation = () => {
    applyRoleVisibility();
    let saved = null;
    try {
      saved = JSON.parse(sessionStorage.getItem(NAV_STORAGE_KEY) || "null");
    } catch {
      saved = null;
    }
    const target = normalizeNavigation(saved, canAdmin());
    ready = true;
    showPane(target.pane);
    openTab(target.tab);
  };

  showPane("account");
})();
