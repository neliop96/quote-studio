      function totals(q) {
        const material = q.items.reduce((s, l) => s + Number(l.qty) * Number(l.cost), 0),
          sell = material * (1 + Number(q.markup) / 100),
          labor = Number(q.labor_hours) * Number(q.labor_rate),
          tax = (sell * Number(q.tax_rate)) / 100;
        return { material, sell, labor, tax, total: sell + labor + tax };
      }
      function quoteItemSnapshots() {
        return lines.map((line) => ({
          product_id: line.product_id,
          part: line.part,
          description: line.description,
          supplier: line.supplier,
          qty: Number(line.qty),
          cost: Number(line.cost),
        }));
      }
      function quoteDraft() {
        return {
          quote_number: $("quoteNo").value.trim(),
          project_name: $("quoteProjectName").value.trim(),
          customer_id: $("quoteCustomer").value || null,
          customer_snapshot: customers.find((c) => c.id === $("quoteCustomer").value) || {},
          items: quoteItemSnapshots(),
          labor_hours: Number($("laborHours").value),
          labor_rate: Number($("laborRate").value),
          markup: Number($("markup").value),
          tax_rate: Number($("tax").value),
          notes: $("quoteNotes").value,
          status: $("quoteStatus").value,
        };
      }
      function renderLines() {
        $("lineRows").innerHTML = lines
          .map(
            (l, i) =>
              `<tr><td>${esc(l.part)}</td><td>${esc(l.description)}</td><td>${l.qty}</td><td>${money(l.cost)}</td><td>${money(l.qty * l.cost)}</td><td><button data-edit-qty="${i}">Edit</button> <button data-remove="${i}">Remove</button></td></tr>`,
          )
          .join("");
        $("quoteTotal").textContent = money(totals(quoteDraft()).total);
      }
      $("lineRows").onclick = (e) => {
        const editIndex = e.target.dataset.editQty;
        if (editIndex !== undefined) {
          const index = Number(editIndex),
            line = lines[index];
          if (!line) return;
          const value = prompt(
            "Edit quantity for " + line.part + " (whole number):",
            String(line.qty),
          );
          if (value === null) return;
          const trimmed = value.trim(),
            qty = Number(trimmed);
          if (!trimmed || !Number.isSafeInteger(qty) || qty <= 0)
            return notify("Enter a positive whole-number quantity", true);
          line.qty = qty;
          renderLines();
          notify("Quantity updated. Save quotation to keep this change.");
          return;
        }
        const removeIndex = e.target.dataset.remove;
        if (removeIndex !== undefined) {
          lines.splice(Number(removeIndex), 1);
          renderLines();
        }
      };
      ["markup", "laborHours", "laborRate", "tax"].forEach((x) => ($(x).oninput = renderLines));
      $("clearQuote").onclick = () => {
        editQuote = null;
        lines = [];
        $("quoteNo").value = "";
        $("quoteProjectName").value = "";
        $("quoteNotes").value = "";
        $("quoteStatus").value = "Draft";
        applyQuoteDefaults();
      };
      $("saveAsProject").onclick = () =>
        safe(async () => {
          await saveProjectTemplate($("quoteProjectName").value, lines);
          await refresh();
          notify("Quotation items saved as a shared project");
        });
      $("saveQuote").onclick = () =>
        safe(async () => {
          const q = quoteDraft();
          if ((editQuote && !q.quote_number) || !q.customer_id || !q.items.length)
            throw Error("Estimate number, customer and at least one product required");
          if (
            [q.markup, q.tax_rate, q.labor_hours, q.labor_rate].some(
              (n) => !Number.isFinite(n) || n < 0,
            )
          )
            throw Error("Invalid quote values");
          if (
            q.items.some(
              (l) =>
                !Number.isSafeInteger(l.qty) ||
                l.qty <= 0 ||
                !Number.isFinite(l.cost) ||
                l.cost < 0,
            )
          )
            throw Error("Invalid line quantity or saved unit cost");
          if (!editQuote && !q.quote_number) {
            q.quote_number = checked(await db.rpc("generate_estimate_number"));
            if (!q.quote_number) throw Error("Supabase did not return an estimate number");
            $("quoteNo").value = q.quote_number;
          }
          if (editQuote) {
            checked(
              await db
                .from("quotes")
                .update({ ...q, updated_at: new Date().toISOString() })
                .eq("id", editQuote),
            );
          } else {
            checked(await db.from("quotes").insert({ ...q, created_by: user.id }));
          }
          await refresh();
          notify("Quote saved to cloud");
        });
      function renderQuotes() {
        $("quoteRows").innerHTML = quotes
          .map(
            (q) =>
              `<tr><td>${esc(q.quote_number)}</td><td>${esc(q.project_name)}</td><td>${esc(q.customer_snapshot?.name)}</td><td>${esc(q.status)}</td><td>${esc(new Date(q.created_at).toLocaleDateString())}</td><td><button data-load-quote="${q.id}">Open</button> <button data-email-quote="${q.id}">Send Email</button>${profile?.role === "admin" ? ` <button class="danger" data-delete-quote="${q.id}">Delete</button>` : ""}</td></tr>`,
          )
          .join("");
      }
      $("quoteRows").onclick = (e) =>
        safe(async () => {
          const emailId = e.target.closest("[data-email-quote]")?.dataset.emailQuote;
          if (emailId) {
            openSendQuote(emailId);
            return;
          }
          const deleteId = e.target.closest("[data-delete-quote]")?.dataset.deleteQuote;
          if (deleteId) {
            if (profile?.role !== "admin") throw Error("Admin permission required");
            const q = quotes.find((x) => x.id === deleteId);
            if (!q) return;
            const answer = prompt(
              `Permanently delete quotation ${q.quote_number}? This cannot be undone.\n\nType the quotation number to confirm:`,
            );
            if (answer === null) return;
            if (answer.trim() !== q.quote_number) {
              notify("Deletion cancelled: quotation number did not match.", true);
              return;
            }
            checked(await db.rpc("admin_delete_quote", { p_quote: deleteId }));
            if (editQuote === deleteId) $("clearQuote").click();
            await refresh();
            notify(`Quotation ${q.quote_number} permanently deleted`);
            return;
          }
          const loadId = e.target.closest("[data-load-quote]")?.dataset.loadQuote;
          const q = quotes.find((x) => x.id === loadId);
          if (!q) return;
          editQuote = q.id;
          lines = q.items || [];
          $("quoteNo").value = q.quote_number;
          $("quoteProjectName").value = q.project_name || "";
          $("quoteCustomer").value = q.customer_id || "";
          $("quoteStatus").value = q.status;
          $("markup").value = q.markup;
          $("laborHours").value = q.labor_hours;
          $("laborRate").value = q.labor_rate;
          $("tax").value = q.tax_rate;
          $("quoteNotes").value = q.notes;
          renderLines();
          scrollTo({ top: 0, behavior: "smooth" });
        });
      function openSendQuote(id) {
        const q = quotes.find((x) => x.id === id);
        if (!q) return;
        const c = customers.find((x) => x.id === q.customer_id) || q.customer_snapshot || {};
        const email = String(c.email || "").trim();
        if (!email) return notify("Customer has no email. Add an email in Customers first.", true);
        sendQuoteId = id;
        $("sendQuoteNumber").value = q.quote_number;
        $("sendQuoteTo").value = email;
        $("sendQuoteProject").value =
          String(q.project_name || q.notes || "")
            .trim()
            .split("\n")[0]
            .slice(0, 140) || "Automation Project";
        $("sendQuoteSubject").value = `Precision Automation — Quotation ${q.quote_number}`;
        $("sendQuoteMessage").value =
          `Hello,\n\nPlease find attached our quotation for your automation project.\n\nPlease let us know if you have any questions.\n\nBest regards,\nPrecision Automation`;
        $("sendQuoteInfo").textContent =
          "The PDF is generated securely from the saved quotation. Unsaved edits are not included.";
        $("sendQuotePanel").classList.remove("hidden");
        $("sendQuotePanel").scrollIntoView({ behavior: "smooth", block: "start" });
      }
      $("sendQuoteCancel").onclick = () => {
        $("sendQuotePanel").classList.add("hidden");
        sendQuoteId = null;
      };
      $("sendQuoteNow").onclick = () =>
        safe(async () => {
          if (!sendQuoteId) throw Error("Choose a saved quotation");
          if (
            !confirm(`Send quotation ${$("sendQuoteNumber").value} to ${$("sendQuoteTo").value}?`)
          )
            return;
          const btn = $("sendQuoteNow");
          btn.disabled = true;
          btn.textContent = "Sending...";
          try {
            const { data, error } = await db.functions.invoke("send-quotation", {
              body: {
                quote_id: sendQuoteId,
                detail: $("sendQuoteDetail").value,
                project_title: $("sendQuoteProject").value.trim(),
                subject: $("sendQuoteSubject").value.trim(),
                message: $("sendQuoteMessage").value.trim(),
              },
            });
            if (error) {
              let msg = error.message;
              try {
                const body = await error.context?.json();
                msg = body?.error || msg;
              } catch {}
              throw Error(msg);
            }
            if (!data?.ok) throw Error(data?.error || "Email was not accepted");
            notify("Quotation submitted to Resend. Check delivery status in Resend.");
            $("sendQuotePanel").classList.add("hidden");
            sendQuoteId = null;
            await refresh();
          } finally {
            btn.disabled = false;
            btn.textContent = "Send quotation PDF";
          }
        });
      $("printFormat").onchange = () => {
        const customer = $("printFormat").value === "customer";
        $("customerPrintOptions").classList.toggle("hidden", !customer);
        $("projectNameField").classList.toggle("hidden", !customer);
      };
      $("printQuote").onclick = () => {
        const q = quoteDraft(),
          t = totals(q),
          c = q.customer_snapshot || {};
        if (!q.items.length) return notify("Add at least one quotation item before printing", true);
        const customer = $("printFormat").value === "customer";
        const projectName =
          $("printProjectName").value.trim() ||
          q.project_name ||
          q.notes.trim().split("\n")[0].slice(0, 100) ||
          "Automation Project";
        const title = customer ? "Project Quotation" : "Estimate";
        const head = `<!doctype html><html><head><meta charset="utf-8"><title>${esc(q.quote_number || title)}</title><style>body{font:14px Arial,sans-serif;margin:40px;color:#182336;line-height:1.5}h1{color:#164e93;margin-bottom:5px}h2{margin-top:10px}table{width:100%;border-collapse:collapse;margin:20px 0}td,th{padding:9px;border-bottom:1px solid #ccc;text-align:left}.total{text-align:right;font-size:24px;margin-top:24px}.muted{color:#53657b}.project{padding:16px 0;border-top:1px solid #dce3eb;border-bottom:1px solid #dce3eb;margin:24px 0;font-size:19px;font-weight:bold}p{white-space:pre-wrap}</style></head><body><h1>PRECISION AUTOMATION</h1><h2>${title} ${esc(q.quote_number)}</h2>${!customer && q.project_name ? `<p><b>Project:</b> ${esc(q.project_name)}</p>` : ""}<p><b>Customer:</b> ${esc(c.name)}<br>${esc(c.contact)}<br>${esc(c.address)}<br>${esc(c.email)}</p>`;
        let content;
        if (customer) {
          const materials = $("customerPrintDetail").value === "materials";
          const list = materials
            ? `<h3>Included Materials</h3><table><thead><tr><th>Description</th><th>Quantity</th></tr></thead><tbody>${q.items.map((l) => `<tr><td>${esc(l.description)} (${esc(l.part)})</td><td>${esc(l.qty)}</td></tr>`).join("")}</tbody></table>`
            : "";
          content = `<div class="project">${esc(projectName)}</div>${list}<div class="total"><b>Total Project Price: ${money(t.total)}</b></div>${q.notes ? `<h3>Project Scope / Notes</h3><p>${esc(q.notes)}</p>` : ""}`;
        } else {
          content = `<table><thead><tr><th>Item</th><th>Qty</th><th>Unit price</th><th>Total</th></tr></thead><tbody>${q.items
            .map((l) => {
              const u = Number(l.cost) * (1 + q.markup / 100);
              return `<tr><td>${esc(l.description)} (${esc(l.part)})</td><td>${esc(l.qty)}</td><td>${money(u)}</td><td>${money(u * l.qty)}</td></tr>`;
            })
            .join(
              "",
            )}</tbody></table><p>Materials: ${money(t.sell)}<br>Labor: ${money(t.labor)}<br>Estimated tax: ${money(t.tax)}</p><div class="total"><b>Total: ${money(t.total)}</b></div><p>${esc(q.notes)}</p>`;
        }
        const w = window.open("", "_blank");
        if (!w) return notify("Allow popups to print", true);
        w.document.write(head + content + "<script>window.print()<\/script></body></html>");
        w.document.close();
      };
