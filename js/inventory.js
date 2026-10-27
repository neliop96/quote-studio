      function inventoryStatus(qty, level) {
        if (Number(qty) <= 0) return "out";
        if (Number(qty) <= Number(level)) return "reorder";
        return "ok";
      }
      function renderInventory() {
        const canChange = canManuallyChangeInventory();
        for (const id of ["stockProduct", "stockType", "stockQty", "stockCost", "stockRef", "stockNote", "recordStock"]) {
          $(id).disabled = !canChange;
        }
        $("recordStock").title = canChange ? "" : "Owner, Admin, or Manager permission required";
        const map = new Map(inventory.map((r) => [r.product_id, r]));
        const entries = products.map((p) => {
          const r = map.get(p.id) || { qty: 0, avg_cost: 0, reorder_level: 0 };
          return { p, r, status: inventoryStatus(r.qty, r.reorder_level) };
        });
        $("stockUnits").textContent = inventory.reduce((s, r) => s + Number(r.qty || 0), 0);
        $("stockValue").textContent = money(
          inventory.reduce((s, r) => s + Number(r.qty || 0) * Number(r.avg_cost || 0), 0),
        );
        $("stockLow").textContent = entries.filter(
          (e) => e.status === "out" || e.status === "reorder",
        ).length;
        const filter = $("inventoryStatusFilter").value;
        const inventoryQuery = $("inventorySearch").value.trim().toLocaleLowerCase();
        const visible = entries.filter(
          ({ p, status }) =>
            (filter === "all" || status === filter) &&
            [p.part, p.description, p.category, p.subcategory, p.supplier].some((v) =>
              String(v ?? "")
                .toLocaleLowerCase()
                .includes(inventoryQuery),
            ),
        );
        $("inventoryShownCount").textContent =
          `Showing ${visible.length} of ${entries.length} products`;
        const labels = { ok: "OK", reorder: "Reorder", out: "Out of Stock" };
        $("stockRows").innerHTML =
          visible
            .map(
              ({ p, r, status }) =>
                `<tr><td>${esc(p.part)}</td><td>${esc(r.qty)}</td><td>${money(r.avg_cost)}</td><td>${money(r.qty * r.avg_cost)}</td><td>${esc(r.reorder_level)}</td><td><span class="stock-status stock-${status}">${labels[status]}</span></td><td>${isAdminRole(profile.role) ? `<button data-reorder="${esc(p.id)}">Set reorder</button>` : ""}</td></tr>`,
            )
            .join("") ||
          '<tr><td colspan="7" class="muted">No products match this filter.</td></tr>';
        const pmap = new Map(products.map((p) => [p.id, p.part]));
        const mf = $("movementArchiveFilter").value;
        const movementQuery = $("movementSearch").value.trim().toLocaleLowerCase();
        const shown = movements.filter((m) => {
          if (mf !== "all" && !(mf === "archived" ? !!m.archived_at : !m.archived_at)) return false;
          const actorName =
            movementActors[String(m.actor)] ||
            (String(m.actor) === String(user?.id) ? profile?.full_name || user?.email : null) ||
            m.actor ||
            "";
          return [
            pmap.get(m.product_id),
            m.movement_type,
            m.reference,
            actorName,
            m.notes,
            m.delta,
            m.qty_after,
          ].some((v) =>
            String(v ?? "")
              .toLocaleLowerCase()
              .includes(movementQuery),
          );
        });
        $("movementRows").innerHTML =
          shown
            .map(
              (m) =>
                `<tr><td>${esc(new Date(m.created_at).toLocaleString())}</td><td>${esc(pmap.get(m.product_id) || m.product_id)}</td><td>${esc(m.movement_type)}</td><td>${m.delta > 0 ? "+" : ""}${esc(m.delta)}</td><td>${esc(m.qty_after)}</td><td>${esc(m.reference)}</td><td>${esc(movementActors[String(m.actor)] || (String(m.actor) === String(user?.id) ? profile?.full_name || user?.email : null) || m.actor || "Unknown")}</td><td>${m.archived_at ? "Archived" : "Active"}</td><td>${isAdminRole(profile.role) ? `<button data-movement-id="${esc(m.id)}" data-movement-action="${m.archived_at ? "restore" : "archive"}">${m.archived_at ? "Restore" : "Archive"}</button>` : ""}</td></tr>`,
            )
            .join("") ||
          '<tr><td colspan="9" class="muted">No movements match this filter.</td></tr>';
      }
      $("movementArchiveFilter").onchange = renderInventory;
      $("movementRows").onclick = (e) =>
        safe(async () => {
          const b = e.target.closest("button[data-movement-id]");
          if (!b) return;
          if (!isAdminRole()) throw Error("Admin required");
          const id = b.dataset.movementId,
            action = b.dataset.movementAction;
          if (
            !confirm(
              `${action === "archive" ? "Archive" : "Restore"} this inventory movement? This will not change stock quantities.`,
            )
          )
            return;
          checked(
            await db.rpc("set_stock_movement_archived", {
              p_movement: id,
              p_archived: action === "archive",
            }),
          );
          await refresh();
          notify(`Movement ${action === "archive" ? "archived" : "restored"}`);
        });
      $("inventorySearch").oninput = renderInventory;
      $("movementSearch").oninput = renderInventory;
      $("inventoryStatusFilter").onchange = renderInventory;
      $("stockRows").onclick = (e) =>
        safe(async () => {
          const id = e.target.dataset.reorder;
          if (!id) return;
          const value = prompt("New minimum reorder quantity (whole number):");
          if (value === null) return;
          const n = Number(value);
          if (!Number.isSafeInteger(n) || n < 0) throw Error("Invalid reorder level");
          checked(await db.rpc("set_reorder_level", { p_product: id, p_level: n }));
          await refresh();
        });
      $("recordStock").onclick = () =>
        safe(async () => {
          if (!canManuallyChangeInventory()) throw Error("Owner, Admin, or Manager permission required");
          const type = $("stockType").value,
            qty = Number($("stockQty").value),
            cost = $("stockCost").value.trim() === "" ? null : Number($("stockCost").value);
          if (!Number.isSafeInteger(qty) || qty < 0 || (type !== "adjust" && qty === 0))
            throw Error("Enter a valid whole-number quantity");
          if (type === "receive" && (cost === null || !Number.isFinite(cost) || cost < 0))
            throw Error("Receipt cost per unit required");
          checked(
            await db.rpc("record_stock_movement", {
              p_product: $("stockProduct").value,
              p_type: type,
              p_quantity: qty,
              p_cost: cost,
              p_reference: $("stockRef").value,
              p_notes: $("stockNote").value,
            }),
          );
          await refresh();
          notify("Stock movement saved for everyone");
        });
      if (SUPABASE_URL.includes("YOUR_"))
        notify(
          "Setup needed: add your Supabase URL and publishable key in js/core.js, then host over HTTPS.",
          true,
        );
      else safe(loadSession);
    
