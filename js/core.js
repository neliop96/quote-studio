
      const $ = (id) => document.getElementById(id);
      const SUPABASE_CONFIG = window.QUOTE_STUDIO_SUPABASE_CONFIG;
      const PRODUCTION_PROJECT_REF = "fssyblwhkqfarpbjujsb";
      const validProjectRef = (value) => /^[a-z0-9]{20}$/.test(value);
      const configError = (message) => {
        const error = $("message");
        error.textContent = message;
        error.style.display = "block";
        error.style.background = "#702c36";
        throw Error(message);
      };
      if (
        !SUPABASE_CONFIG ||
        typeof SUPABASE_CONFIG !== "object" ||
        Array.isArray(SUPABASE_CONFIG) ||
        !["production", "staging"].includes(SUPABASE_CONFIG.environment) ||
        !validProjectRef(SUPABASE_CONFIG.projectRef) ||
        typeof SUPABASE_CONFIG.url !== "string" ||
        typeof SUPABASE_CONFIG.publishableKey !== "string" ||
        !/^sb_publishable_[A-Za-z0-9_-]+$/.test(SUPABASE_CONFIG.publishableKey)
      )
        configError("Supabase configuration is missing or malformed. App initialization stopped.");
      let configuredUrl;
      try {
        configuredUrl = new URL(SUPABASE_CONFIG.url);
      } catch {
        configError("Supabase configuration URL is malformed. App initialization stopped.");
      }
      if (
        configuredUrl.protocol !== "https:" ||
        configuredUrl.hostname !== `${SUPABASE_CONFIG.projectRef}.supabase.co` ||
        configuredUrl.origin !== `https://${SUPABASE_CONFIG.projectRef}.supabase.co` ||
        configuredUrl.pathname !== "/" ||
        configuredUrl.search ||
        configuredUrl.hash ||
        (SUPABASE_CONFIG.environment === "production" &&
          SUPABASE_CONFIG.projectRef !== PRODUCTION_PROJECT_REF) ||
        (SUPABASE_CONFIG.environment === "staging" &&
          SUPABASE_CONFIG.projectRef === PRODUCTION_PROJECT_REF)
      )
        configError(
          `Supabase ${SUPABASE_CONFIG.environment} configuration does not match its project reference. App initialization stopped.`,
        );
      if (!window.supabase?.createClient)
        configError("Supabase client library is unavailable. App initialization stopped.");
      const SUPABASE_URL = SUPABASE_CONFIG.url;
      const SUPABASE_PUBLISHABLE_KEY = SUPABASE_CONFIG.publishableKey;
      const esc = (s) =>
        String(s ?? "").replace(
          /[&<>"']/g,
          (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
        );
      const money = (n) =>
        Number(n || 0).toLocaleString("en-US", { style: "currency", currency: "USD" });
      const db = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
      // Capture the one-time link type before Supabase processes and cleans the URL.
      const initialLinkType =
        new URLSearchParams(location.hash.slice(1)).get("type") ||
        new URLSearchParams(location.search).get("type");
      let passwordSetupMode = ["recovery", "invite"].includes(initialLinkType);
      function showPasswordSetup() {
        if (!passwordSetupMode) return;
        $("login").classList.add("hidden");
        $("app").classList.add("hidden");
        $("passwordSetup").classList.remove("hidden");
        $("passwordSetupTitle").textContent =
          initialLinkType === "invite" ? "Create your password" : "Set new password";
      }

      let sendQuoteId = null;
      let quoteDefaults = { markup: 20, labor_rate: 75, tax_rate: 8.625, labor_hours: 0 };
      let user = null,
        profile = null,
        products = [],
        customers = [],
        quotes = [],
        projects = [],
        inventory = [],
        movements = [],
        movementActors = {},
        team = [],
        lines = [],
        editProduct = null,
        editCustomer = null,
        editQuote = null;
      const isAdminRole = (role = profile?.role) => ["owner", "admin"].includes(role);
      // UI hints only. The database independently enforces these permissions.
      const canManuallyChangeInventory = () =>
        ["owner", "admin", "manager"].includes(profile?.role);
      const canSubmitOwnShiftReport = () =>
        ["owner", "admin", "manager", "supervisor", "user", "employee"].includes(profile?.role);
      const notify = (s, error = false) => {
        const el = $("message");
        el.style.display = "block";
        el.style.background = error ? "#702c36" : "#153b55";
        el.textContent = s;
        setTimeout(() => (el.style.display = "none"), 6000);
      };
      const checked = ({ data, error }) => {
        if (error) throw error;
        return data;
      };
      const safe = async (fn) => {
        try {
          await fn();
        } catch (e) {
          notify(e.message || String(e), true);
          console.error(e);
        }
      };
      async function refresh() {
        [products, customers, quotes, projects, inventory, movements] = await Promise.all([
          db.from("products").select("*").eq("active", true).order("part").then(checked),
          db.from("customers").select("*").order("name").then(checked),
          db.from("quotes").select("*").order("created_at", { ascending: false }).then(checked),
          db.from("projects").select("*").order("name").then(checked),
          db.from("inventory").select("*").then(checked),
          db
            .from("stock_movements")
            .select("*")
            .order("created_at", { ascending: false })
            .limit(100)
            .then(checked),
        ]);
        const actorsResult = await db.rpc("inventory_movement_actor_names");
        if (actorsResult.error) {
          console.warn("Movement names unavailable:", actorsResult.error.message);
          movementActors = {};
        } else
          movementActors = Object.fromEntries(
            (actorsResult.data || []).map((r) => [String(r.actor_id), r.display_name]),
          );
        if (isAdminRole()) team = await db.from("profiles").select("*").then(checked);
        renderAll();
      }
