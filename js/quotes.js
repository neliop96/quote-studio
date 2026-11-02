      function totals(q) {
        return EstimateLogic.totals(q);
      }
      const editorFields = [
        "quoteProjectName",
        "quoteCustomer",
        "markup",
        "laborHours",
        "laborRate",
        "tax",
        "quoteNotes",
        "quoteValidity",
      ];
      let quoteBaseline = null;
      let quoteHistoryId = null;
      let quoteFilter = "All";
      let quoteTimeZone = () => quoteDefaults.quote_time_zone || EstimateLogic.DEFAULT_TIME_ZONE;
      const todayISO = () => EstimateLogic.todayInZone(quoteTimeZone());
      const savedQuote = () => quotes.find((q) => q.id === editQuote) || null;
      const quoteIsLocked = () => {
        const saved = savedQuote();
        return Boolean(saved && EstimateLogic.isIssued(saved.status));
      };
      function currentSignature() {
        return EstimateLogic.signature({
          ...quoteDraft(),
          validity_days: $("quoteValidity").value,
        });
      }
      function markQuoteClean() {
        quoteBaseline = currentSignature();
      }
      function quoteIsDirty() {
        return !quoteIsLocked() && quoteBaseline !== null && currentSignature() !== quoteBaseline;
      }
      function confirmDiscardChanges() {
        return (
          !quoteIsDirty() ||
          confirm("You have unsaved changes to this estimate. Discard them and continue?")
        );
      }
      window.addEventListener("beforeunload", (event) => {
        if (!quoteIsDirty()) return;
        event.preventDefault();
        event.returnValue = "";
      });
      function renderQuoteMeta() {
        const saved = savedQuote();
        const locked = quoteIsLocked();
        const status = saved ? EstimateLogic.effectiveStatus(saved, todayISO()) : "Draft";
        $("quoteStatus").value = status;
        editorFields.forEach((id) => ($(id).disabled = locked));
        ["addLine", "saveDraft", "saveQuote", "pickQty", "cat", "sub", "pickProduct"].forEach(
          (id) => $(id) && ($(id).disabled = locked),
        );
        $("lineRows")
          .querySelectorAll("button")
          .forEach((button) => (button.disabled = locked));
        $("createRevision").classList.toggle("hidden", !saved || !locked);
        const banner = $("quoteIssuedBanner");
        banner.classList.toggle("hidden", !locked);
        if (locked) {
          banner.textContent = `${saved.quote_number} is ${status} and cannot be edited. Use Create Revision to make changes in a new draft; this version is preserved.`;
        }
        const d = saved ? EstimateLogic.dateSummary(saved) : null;
        $("quoteDates").textContent = !d
          ? "Dates are assigned when the estimate is marked Ready."
          : [
              d.original ? `Original estimate date: ${d.original}` : "Not yet issued",
              d.revisionNumber ? `Revision ${d.revisionNumber} date: ${d.revision || "Not yet issued"}` : "",
              d.validUntil ? `Valid until: ${d.validUntil}` : "",
            ]
              .filter(Boolean)
              .join(" · ");
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
        };
      }
      function loadQuoteIntoEditor(q) {
        editQuote = q.id;
        lines = (q.items || []).map((line) => ({ ...line }));
        $("quoteNo").value = q.quote_number;
        $("quoteProjectName").value = q.project_name || "";
        $("quoteCustomer").value = q.customer_id || "";
        $("markup").value = q.markup;
        $("laborHours").value = q.labor_hours;
        $("laborRate").value = q.labor_rate;
        $("tax").value = q.tax_rate;
        $("quoteNotes").value = q.notes;
        $("quoteValidity").value = q.validity_days || quoteDefaults.validity_days || 30;
        renderLines();
        renderQuoteMeta();
        markQuoteClean();
      }
      function renderLines() {
        $("lineRows").innerHTML = lines
          .map(
            (l, i) =>
              `<tr><td>${esc(l.part)}</td><td>${esc(l.description)}</td><td>${l.qty}</td><td>${money(l.cost)}</td><td>${money(l.qty * l.cost)}</td><td><button data-edit-qty="${i}">Edit</button> <button data-remove="${i}">Remove</button></td></tr>`,
          )
          .join("");
        $("quoteTotal").textContent = money(totals(quoteDraft()).total);
        if (quoteIsLocked())
          $("lineRows")
            .querySelectorAll("button")
            .forEach((button) => (button.disabled = true));
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
        if (!confirmDiscardChanges()) return;
        editQuote = null;
        lines = [];
        $("quoteNo").value = "";
        $("quoteProjectName").value = "";
        $("quoteNotes").value = "";
        $("quoteCustomer").value = "";
        applyQuoteDefaults();
        renderQuoteMeta();
        markQuoteClean();
      };
      $("saveAsProject").onclick = () =>
        safe(async () => {
          await saveProjectTemplate($("quoteProjectName").value, lines);
          await refresh();
          notify("Quotation items saved as a shared project");
        });
      function validateQuotePayload(q, forReady) {
        if (forReady && (!q.customer_id || !q.items.length))
          throw Error("Customer and at least one product required before marking Ready");
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
      }
      async function persistQuote(targetStatus) {
        if (quoteIsLocked())
          throw Error("This estimate has been issued and cannot be edited. Create a revision instead.");
        const saved = savedQuote();
        const q = quoteDraft();
        validateQuotePayload(q, targetStatus === "Ready");
        q.validity_days = EstimateLogic.normalizeValidityDays($("quoteValidity").value);
        if (saved && saved.status === "Ready" && targetStatus === "Draft" && !confirm(
          "This estimate is marked Ready. Saving it as a Draft moves it back to Draft status. Continue?",
        ))
          return;
        if (!saved && !q.quote_number) {
          q.quote_number = checked(await db.rpc("generate_estimate_number"));
          if (!q.quote_number) throw Error("Supabase did not return an estimate number");
          $("quoteNo").value = q.quote_number;
        }
        if (!saved && !q.quote_number) throw Error("Estimate number required");
        let id = editQuote;
        if (saved) {
          const payload = { ...q, status: targetStatus };
          if (Number(saved.revision_number) > 0) delete payload.quote_number;
          const rows = checked(await db.from("quotes").update(payload).eq("id", editQuote).select("id"));
          if (!rows || !rows.length) throw Error("You can only edit estimates you created");
        } else {
          const row = checked(
            await db
              .from("quotes")
              .insert({ ...q, status: targetStatus, created_by: user.id })
              .select("id")
              .single(),
          );
          id = row.id;
        }
        await refresh();
        const fresh = quotes.find((x) => x.id === id);
        if (fresh) loadQuoteIntoEditor(fresh);
        notify(targetStatus === "Ready" ? "Estimate saved and marked Ready" : "Draft saved");
      }
      $("saveDraft").onclick = () => safe(() => persistQuote("Draft"));
      $("saveQuote").onclick = () => safe(() => persistQuote("Ready"));
      $("createRevision").onclick = () =>
        safe(async () => {
          const saved = savedQuote();
          if (!saved) return;
          await createRevision(saved.id);
        });
      async function createRevision(id) {
        if (!confirmDiscardChanges()) return;
        const source = quotes.find((x) => x.id === id);
        if (!source || !confirm(`Create a new editable revision of ${source.quote_number}? The issued version stays unchanged.`))
          return;
        const newId = checked(await db.rpc("create_estimate_revision", { p_quote: id }));
        const revisionId = typeof newId === "object" && newId ? newId.id || newId.quote_id : newId;
        await refresh();
        const revision = quotes.find((x) => x.id === revisionId);
        if (revision) {
          loadQuoteIntoEditor(revision);
          scrollTo({ top: 0, behavior: "smooth" });
        }
        notify(`Revision ${revision ? revision.quote_number : ""} created as a Draft`);
      }
      function renderQuoteFilters() {
        const today = todayISO();
        const counts = EstimateLogic.statusCounts(quotes, today);
        $("quoteStatusFilters").innerHTML = ["All", ...EstimateLogic.STATUSES]
          .map(
            (status) =>
              `<button type="button" class="${status === quoteFilter ? "active" : ""}" data-quote-filter="${status}" aria-pressed="${status === quoteFilter}">${status} (${counts[status]})</button>`,
          )
          .join("");
      }
      function renderQuotes() {
        const today = todayISO();
        renderQuoteFilters();
        const userId = user?.id || null;
        $("quoteRows").innerHTML = EstimateLogic.filterQuotes(quotes, quoteFilter, today)
          .map((q) => {
            const status = EstimateLogic.effectiveStatus(q, today);
            const a = EstimateLogic.rowActions(q, today, { isAdmin: isAdminRole(), userId });
            const d = EstimateLogic.dateSummary(q);
            const current = q.is_current_approved ? ' <span class="status-badge status-current">Current approved</span>' : "";
            return `<tr><td>${esc(q.quote_number)}</td><td>${esc(EstimateLogic.versionLabel(q))}</td><td>${esc(q.project_name)}</td><td>${esc(q.customer_snapshot?.name)}</td><td><span class="status-badge status-${status.toLowerCase()}">${esc(status)}</span>${current}</td><td>${esc(d.original || "—")}</td><td>${esc(d.revision || "—")}</td><td>${esc(d.validUntil || "—")}</td><td class="row-actions"><button data-load-quote="${q.id}">${a.edit ? "Open" : "View"}</button>${a.send ? ` <button data-email-quote="${q.id}">Send Email</button>` : ""}${a.decide ? ` <button data-decide-quote="${q.id}" data-decision="Approved">Approve</button> <button data-decide-quote="${q.id}" data-decision="Rejected">Reject</button>` : ""}${a.revise ? ` <button data-revise-quote="${q.id}">Create Revision</button>` : ""} <button data-print-quote="${q.id}">Print</button> <button data-history-quote="${q.id}">History</button>${isAdminRole() ? ` <button class="danger" data-delete-quote="${q.id}">Delete</button>` : ""}</td></tr>`;
          })
          .join("");
        renderQuoteMeta();
      }
      $("quoteStatusFilters").onclick = (e) => {
        const status = e.target.closest("[data-quote-filter]")?.dataset.quoteFilter;
        if (!status) return;
        quoteFilter = status;
        renderQuotes();
      };
      async function showQuoteHistory(id) {
        const q = quotes.find((x) => x.id === id);
        if (!q) return;
        const rows = checked(
          await db
            .from("quote_status_history")
            .select("from_status,to_status,changed_at,note")
            .eq("quote_id", id)
            .order("changed_at", { ascending: true })
            .order("id", { ascending: true }),
        );
        quoteHistoryId = id;
        $("quoteHistoryTitle").textContent = `Status history — ${q.quote_number}`;
        $("quoteHistoryRows").innerHTML =
          (rows || [])
            .map(
              (r) =>
                `<tr><td>${esc(new Date(r.changed_at).toLocaleString())}</td><td>${esc(r.from_status || "—")}</td><td>${esc(r.to_status)}</td><td>${esc(r.note || "")}</td></tr>`,
            )
            .join("") || '<tr><td colspan="4">No history recorded</td></tr>';
        $("quoteHistoryPanel").classList.remove("hidden");
        $("quoteHistoryPanel").scrollIntoView({ behavior: "smooth", block: "start" });
      }
      $("quoteHistoryClose").onclick = () => {
        $("quoteHistoryPanel").classList.add("hidden");
        quoteHistoryId = null;
      };
      function printSavedQuote(q, format, detail, projectName) {
        if (!q.items?.length) return notify("Add at least one quotation item before printing", true);
        const html = EstimateLogic.buildPdfHtml(q, { format, detail, projectName, esc, money });
        const w = window.open("", "_blank");
        if (!w) return notify("Allow popups to print", true);
        w.document.write(html);
        w.document.close();
      }
      $("quoteRows").onclick = (e) =>
        safe(async () => {
          const reviseId = e.target.closest("[data-revise-quote]")?.dataset.reviseQuote;
          if (reviseId) return createRevision(reviseId);
          const decideButton = e.target.closest("[data-decide-quote]");
          if (decideButton) {
            const q = quotes.find((x) => x.id === decideButton.dataset.decideQuote);
            const decision = decideButton.dataset.decision;
            if (!q || !confirm(`Mark ${q.quote_number} as ${decision}? This is recorded in the status history.`))
              return;
            checked(await db.rpc("set_estimate_decision", { p_quote: q.id, p_decision: decision }));
            await refresh();
            notify(`${q.quote_number} marked ${decision}`);
            return;
          }
          const historyId = e.target.closest("[data-history-quote]")?.dataset.historyQuote;
          if (historyId) return showQuoteHistory(historyId);
          const printId = e.target.closest("[data-print-quote]")?.dataset.printQuote;
          if (printId) {
            const q = quotes.find((x) => x.id === printId);
            if (q)
              printSavedQuote(
                q,
                $("printFormat").value,
                $("customerPrintDetail").value,
                $("printProjectName").value,
              );
            return;
          }
          const emailId = e.target.closest("[data-email-quote]")?.dataset.emailQuote;
          if (emailId) {
            openSendQuote(emailId);
            return;
          }
          const deleteId = e.target.closest("[data-delete-quote]")?.dataset.deleteQuote;
          if (deleteId) {
            if (!isAdminRole()) throw Error("Admin permission required");
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
            if (editQuote === deleteId) {
              quoteBaseline = null;
              editQuote = null;
              $("clearQuote").click();
            }
            await refresh();
            notify(`Quotation ${q.quote_number} permanently deleted`);
            return;
          }
          const loadId = e.target.closest("[data-load-quote]")?.dataset.loadQuote;
          const q = quotes.find((x) => x.id === loadId);
          if (!q) return;
          if (q.id !== editQuote && !confirmDiscardChanges()) return;
          loadQuoteIntoEditor(q);
          scrollTo({ top: 0, behavior: "smooth" });
        });
      function openSendQuote(id) {
        const q = quotes.find((x) => x.id === id);
        if (!q) return;
        if (id === editQuote && quoteIsDirty())
          return notify("Save your changes before sending. The PDF is generated from the saved estimate.", true);
        if (!["Ready", "Sent", "Approved"].includes(q.status))
          return notify("Mark the estimate Ready before sending it.", true);
        const c = customers.find((x) => x.id === q.customer_id) || q.customer_snapshot || {};
        const email = String(c.email || "").trim();
        if (!email) return notify("Customer has no email. Add an email in Customers first.", true);
        sendQuoteId = id;
        $("sendQuoteNumber").value = q.quote_number;
        $("sendQuoteTo").value = email;
        $("sendQuoteProject").value = EstimateLogic.customerProjectTitle(q);
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
            const sentId = sendQuoteId;
            $("sendQuotePanel").classList.add("hidden");
            sendQuoteId = null;
            // Sent is only recorded when the database sees the provider's acceptance.
            const sync = await db.rpc("sync_estimate_statuses");
            if (sync.error) console.warn("Estimate status sync unavailable:", sync.error.message);
            await refresh();
            const after = quotes.find((x) => x.id === sentId);
            if (data.warning)
              notify(`Email accepted by the provider. ${data.warning}`, true);
            else if (after && after.status === "Ready")
              notify(
                "Email was accepted for sending, but the Sent status could not be confirmed. The estimate remains Ready.",
                true,
              );
            else
              notify(
                "Quotation accepted by the email provider. This does not confirm delivery to the customer.",
              );
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
        const saved = savedQuote();
        if (!saved) return notify("Save the estimate before printing so the PDF matches a saved version", true);
        if (quoteIsDirty())
          return notify("Save your changes before printing. The PDF uses the saved estimate.", true);
        printSavedQuote(saved, $("printFormat").value, $("customerPrintDetail").value, $("printProjectName").value);
      };
