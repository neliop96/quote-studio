
      // SET THESE TWO VALUES. The publishable/anon key is safe in frontend code when RLS is enabled.
      // NEVER put a Supabase service_role or secret key here.
      const SUPABASE_URL = "https://fssyblwhkqfarpbjujsb.supabase.co";
      const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_1Uvxy8DcztEjPYgojk9-fQ_HEGhUBUZ";
      const $ = (id) => document.getElementById(id),
        esc = (s) =>
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
        if (profile?.role === "admin") team = await db.from("profiles").select("*").then(checked);
        renderAll();
      }
