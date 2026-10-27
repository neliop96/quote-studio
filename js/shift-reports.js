      let shiftReports = [];
      let shiftReportTasks = [];
      let shiftTaskItems = [];
      let editingShiftReportId = null;
      let editingShiftReportCreatorId = null;
      let editingShiftReportStatus = null;
      let unreadShiftAlerts = [];
      let shiftAlertRoles = [];

      const localDate = (date = new Date()) =>
        `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;

      function renderShiftTaskItems() {
        $("shiftTaskItems").innerHTML = shiftTaskItems.length
          ? shiftTaskItems
              .map((item) => {
                const product = products.find((entry) => entry.id === item.product_id);
                return `<div>${esc(item.part || product?.part || "Unavailable product")} — ${esc(item.description || product?.description || "")} × ${esc(item.qty)} <button type="button" data-remove-shift-item="${esc(item.product_id)}">Remove</button></div>`;
              })
              .join("")
          : "No products added to this task.";
      }

      function renderShiftReportTasks() {
        $("shiftReportTaskRows").innerHTML =
          shiftReportTasks
            .map((task, index) => {
              const items = (Array.isArray(task.items) ? task.items : [])
                .map((item) => {
                  const product = products.find((entry) => entry.id === item.product_id);
                  return `${esc(item.part || product?.part || "Unavailable product")} × ${esc(item.qty)}`;
                })
                .join("<br>");
              return `<tr><td>${esc(task.title)}</td><td>${esc(task.notes || "")}</td><td>${items || "—"}</td><td>${editingShiftReportStatus === "submitted" ? "" : `<button data-remove-shift-task="${index}">Remove</button>`}</td></tr>`;
            })
            .join("") ||
          '<tr><td colspan="4" class="muted">No tasks have been added to this report.</td></tr>';
        $("shiftReportStatus").textContent = editingShiftReportStatus === "submitted"
          ? "Submitted report: read-only. Inventory was deducted when it was submitted."
          : editingShiftReportId
            ? "Editing a saved draft. Inventory has not been deducted."
            : "Unsaved report. Inventory will be deducted when submitted.";
        for (const id of [
          "shiftReportDate",
          "shiftReportShift",
          "shiftTaskTitle",
          "shiftTaskNotes",
          "shiftTaskProduct",
          "shiftTaskQty",
          "addShiftTaskProduct",
          "addShiftTask",
          "saveShiftDraft",
          "submitShiftReport",
        ]) {
          $(id).disabled = editingShiftReportStatus === "submitted";
        }
        $("shiftTaskItems").querySelectorAll("[data-remove-shift-item]").forEach((button) => {
          button.disabled = editingShiftReportStatus === "submitted";
        });
        $("submitShiftReport").disabled =
          editingShiftReportStatus === "submitted" || !canSubmitOwnShiftReport() ||
          (editingShiftReportId !== null && editingShiftReportCreatorId !== user?.id);
      }

      function renderSavedShiftReports() {
        $("savedShiftReportRows").innerHTML =
          shiftReports
            .map((report) => {
              const tasks = Array.isArray(report.tasks) ? report.tasks : [];
              const submitted = report.status === "submitted";
              const submitter =
                report.submitted_by === user?.id
                  ? profile?.full_name || user?.email || "You"
                  : submitted
                    ? "Team member"
                    : "—";
              return `<tr><td>${esc(report.report_date)}</td><td>${esc(report.shift_name)}</td><td>${tasks.length}</td><td>${submitted ? "Submitted" : "Draft"}</td><td>${report.submitted_at ? esc(new Date(report.submitted_at).toLocaleString()) : "—"}</td><td>${esc(submitter)}</td><td><button data-open-shift-report="${esc(report.id)}">${submitted ? "View" : "Open draft"}</button></td></tr>`;
            })
            .join("") || '<tr><td colspan="7" class="muted">No reports for this month.</td></tr>';
      }

      async function loadShiftReports() {
        const month = $("shiftReportMonth").value;
        if (!/^\d{4}-\d{2}$/.test(month)) throw Error("Choose a report month");
        const [year, monthNumber] = month.split("-").map(Number);
        const startDate = `${month}-01`;
        const endDate = `${month}-${String(new Date(year, monthNumber, 0).getDate()).padStart(2, "0")}`;
        shiftReports = checked(
          await db
            .from("shift_reports")
            .select("*")
            .gte("report_date", startDate)
            .lte("report_date", endDate)
            .order("report_date", { ascending: false })
            .order("created_at", { ascending: false }),
        );
        renderSavedShiftReports();
        renderShiftReportTasks();
      }

      function validateShiftReport() {
        const reportDate = $("shiftReportDate").value;
        const shiftName = $("shiftReportShift").value.trim();
        if (!reportDate || !shiftName) throw Error("Report date and shift are required");
        if (!shiftReportTasks.length) throw Error("Add at least one task to the report");
        const tasks = shiftReportTasks.map((task) => {
          if (typeof task.title !== "string" || !task.title.trim())
            throw Error("Each task needs a title");
          if (!Array.isArray(task.items)) throw Error("Each task needs a product list");
          const items = task.items.map((item) => {
            const product = products.find((entry) => entry.id === item.product_id);
            const qty = Number(item.qty);
            if (!product || !Number.isSafeInteger(qty) || qty <= 0)
              throw Error("Every task product must be active and have a positive whole-number quantity");
            return {
              product_id: product.id,
              part: product.part,
              description: product.description,
              qty,
            };
          });
          return { title: task.title.trim(), notes: task.notes || "", items };
        });
        return {
          report_date: reportDate,
          shift_name: shiftName,
          tasks,
        };
      }

      async function saveShiftReportDraft() {
        if (editingShiftReportStatus === "submitted")
          throw Error("Submitted reports cannot be changed");
        const report = validateShiftReport();
        if (editingShiftReportId) {
          const saved = checked(
            await db
              .from("shift_reports")
              .update(report)
              .eq("id", editingShiftReportId)
              .eq("status", "draft")
              .select("id")
              .maybeSingle(),
          );
          if (!saved) throw Error("This report is no longer an editable draft");
        } else {
          const saved = checked(
            await db
              .from("shift_reports")
              .insert({ ...report, created_by: user.id })
              .select("id")
              .single(),
          );
          editingShiftReportId = saved.id;
          editingShiftReportCreatorId = user.id;
        }
        shiftReportTasks = report.tasks;
        editingShiftReportStatus = "draft";
        renderShiftReportTasks();
        return report;
      }

      function resetShiftReport() {
        editingShiftReportId = null;
        editingShiftReportCreatorId = null;
        editingShiftReportStatus = null;
        shiftReportTasks = [];
        shiftTaskItems = [];
        $("shiftReportDate").value = localDate();
        $("shiftReportShift").value = "";
        $("shiftTaskTitle").value = "";
        $("shiftTaskNotes").value = "";
        $("shiftTaskQty").value = "1";
        renderShiftTaskItems();
        renderShiftReportTasks();
      }

      function hasShiftReportEditorChanges() {
        return Boolean(
          editingShiftReportId ||
            shiftReportTasks.length ||
            shiftTaskItems.length ||
            $("shiftTaskTitle").value.trim() ||
            $("shiftTaskNotes").value.trim(),
        );
      }

      $("shiftTaskProduct").innerHTML =
        '<option value="">Select product</option>' +
        products
          .map(
            (product) =>
              `<option value="${esc(product.id)}">${esc(product.part)} — ${esc(product.description)}</option>`,
          )
          .join("");
      $("shiftReportDate").value = localDate();
      $("shiftReportMonth").value = localDate().slice(0, 7);
      renderShiftTaskItems();
      renderShiftReportTasks();

      $("shiftTaskProduct").onfocus = () => {
        const selected = $("shiftTaskProduct").value;
        $("shiftTaskProduct").innerHTML =
          '<option value="">Select product</option>' +
          products
            .map(
              (product) =>
                `<option value="${esc(product.id)}">${esc(product.part)} — ${esc(product.description)}</option>`,
            )
            .join("");
        $("shiftTaskProduct").value = selected;
      };
      $("addShiftTaskProduct").onclick = () => {
        const productId = $("shiftTaskProduct").value;
        const qty = Number($("shiftTaskQty").value);
        if (!products.some((product) => product.id === productId))
          return notify("Select an active product", true);
        if (!Number.isSafeInteger(qty) || qty <= 0)
          return notify("Enter a positive whole-number quantity", true);
        const existing = shiftTaskItems.find((item) => item.product_id === productId);
        if (existing) existing.qty += qty;
        else {
          const product = products.find((entry) => entry.id === productId);
          shiftTaskItems.push({
            product_id: product.id,
            part: product.part,
            description: product.description,
            qty,
          });
        }
        $("shiftTaskQty").value = "1";
        renderShiftTaskItems();
      };
      $("shiftTaskItems").onclick = (event) => {
        const productId = event.target.dataset.removeShiftItem;
        if (!productId) return;
        shiftTaskItems = shiftTaskItems.filter((item) => item.product_id !== productId);
        renderShiftTaskItems();
      };
      $("addShiftTask").onclick = () => {
        const title = $("shiftTaskTitle").value.trim();
        if (!title) return notify("Enter a task or work order", true);
        shiftReportTasks.push({
          title,
          notes: $("shiftTaskNotes").value.trim(),
          items: shiftTaskItems.map((item) => ({ ...item })),
        });
        shiftTaskItems = [];
        $("shiftTaskTitle").value = "";
        $("shiftTaskNotes").value = "";
        $("shiftTaskQty").value = "1";
        renderShiftTaskItems();
        renderShiftReportTasks();
      };
      $("shiftReportTaskRows").onclick = (event) => {
        const index = event.target.dataset.removeShiftTask;
        if (index === undefined) return;
        shiftReportTasks.splice(Number(index), 1);
        renderShiftReportTasks();
      };
      $("saveShiftDraft").onclick = () =>
        safe(async () => {
          const report = await saveShiftReportDraft();
          $("shiftReportMonth").value = report.report_date.slice(0, 7);
          await loadShiftReports();
          notify("Shift report draft saved. Inventory has not been deducted.");
        });
      $("submitShiftReport").onclick = () =>
        safe(async () => {
          if (!canSubmitOwnShiftReport()) throw Error("Your role cannot submit shift reports");
          if (editingShiftReportId !== null && editingShiftReportCreatorId !== user?.id)
            throw Error("Only your own shift reports may be submitted");
          const report = await saveShiftReportDraft();
          if (!confirm("Submit this shift report and deduct its listed products from inventory?"))
            return;
          checked(await db.rpc("submit_shift_report", { p_report: editingShiftReportId }));
          editingShiftReportStatus = "submitted";
          $("shiftReportMonth").value = report.report_date.slice(0, 7);
          await refresh();
          await loadShiftReports();
          await loadShiftAlerts();
          notify("Shift report submitted and inventory deducted");
          resetShiftReport();
          $("shiftReportDate").value = report.report_date;
        });
      $("newShiftReport").onclick = () => {
        if (hasShiftReportEditorChanges() &&
            !confirm("Start a new report? Changes in the current editor will be lost."))
          return;
        resetShiftReport();
      };
      $("shiftReportMonth").onchange = () =>
        safe(async () => {
          await loadShiftReports();
        });
      $("savedShiftReportRows").onclick = (event) =>
        safe(async () => {
          const id = event.target.closest("[data-open-shift-report]")?.dataset.openShiftReport;
          if (!id) return;
          const report = shiftReports.find((entry) => entry.id === id);
          if (!report) return;
          if (hasShiftReportEditorChanges() &&
              !confirm("Open this report? Changes in the current editor will be lost."))
            return;
          editingShiftReportId = report.id;
          editingShiftReportCreatorId = report.created_by;
          editingShiftReportStatus = report.status;
          shiftReportTasks = Array.isArray(report.tasks) ? report.tasks : [];
          shiftTaskItems = [];
          $("shiftReportDate").value = report.report_date;
          $("shiftReportShift").value = report.shift_name;
          $("shiftTaskTitle").value = "";
          $("shiftTaskNotes").value = "";
          renderShiftTaskItems();
          renderShiftReportTasks();
          document.querySelector('[data-tab="shiftReports"]').click();
        });
      $("exportShiftReports").onclick = () =>
        safe(async () => {
          await loadShiftReports();
          if (!shiftReports.length) throw Error("There are no shift reports to export for this month");
          const rows = [["Report date", "Shift", "Status", "Task", "Handoff notes", "Product", "Part", "Quantity"]];
          for (const report of shiftReports) {
            for (const task of report.tasks || []) {
              const taskItems = Array.isArray(task.items) ? task.items : [];
              if (!taskItems.length) {
                rows.push([report.report_date, report.shift_name, report.status, task.title, task.notes || "", "", "", ""]);
                continue;
              }
              for (const item of taskItems) {
                const product = products.find((entry) => entry.id === item.product_id);
                rows.push([
                  report.report_date,
                  report.shift_name,
                  report.status,
                  task.title,
                  task.notes || "",
                  item.description || product?.description || "",
                  item.part || product?.part || item.product_id,
                  item.qty,
                ]);
              }
            }
          }
          const csv = rows
            .map((row) => row.map((value) => `"${String(value ?? "").replace(/"/g, '""')}"`).join(","))
            .join("\r\n");
          const blob = new Blob([`\uFEFF${csv}`], { type: "text/csv;charset=utf-8" });
          const url = URL.createObjectURL(blob);
          const link = document.createElement("a");
          link.href = url;
          link.download = `shift-reports-${$("shiftReportMonth").value}.csv`;
          link.click();
          setTimeout(() => URL.revokeObjectURL(url), 1000);
        });

      document.querySelector('[data-tab="shiftReports"]').addEventListener("click", () =>
        safe(async () => {
          $("shiftTaskProduct").innerHTML =
            '<option value="">Select product</option>' +
            products
              .map(
                (product) =>
                  `<option value="${esc(product.id)}">${esc(product.part)} — ${esc(product.description)}</option>`,
              )
              .join("");
          await loadShiftReports();
        }),
      );

      function formatRoleName(role) {
        return role
          .replace(/[_-]+/g, " ")
          .replace(/\b\w/g, (character) => character.toUpperCase());
      }

      function renderShiftAlertRoles(selectedRoles = []) {
        const selected = new Set(selectedRoles);
        const isAdmin = isAdminRole();
        $("shiftAlertRoleOptions").innerHTML =
          shiftAlertRoles
            .map(
              (role) =>
                `<label class="shift-alert-role"><input type="checkbox" value="${esc(role)}" ${selected.has(role) ? "checked" : ""} ${isAdmin ? "" : "disabled"} />${esc(formatRoleName(role))}</label>`,
            )
            .join("") || '<p class="muted">No employee roles are available yet.</p>';
        $("saveShiftAlertSettings").disabled = !isAdmin;
        $("saveShiftAlertSettings").classList.toggle("hidden", !isAdmin);
      }

      async function loadShiftAlertSettings() {
        const { data, error } = await db.rpc("get_shift_alert_settings");
        if (error) {
          $("shiftAlertSettingsHelp").textContent =
            "Handoff alerts unavailable: apply the handoff-alert migration in Supabase.";
          notify("Handoff alert settings could not load: " + error.message, true);
          return;
        }
        shiftAlertRoles = Array.isArray(data?.available_roles) ? data.available_roles : [];
        const selectedRoles = Array.isArray(data?.recipient_roles) ? data.recipient_roles : [];
        renderShiftAlertRoles(selectedRoles);
        $("shiftAlertSettingsHelp").textContent =
          !selectedRoles.length && isAdminRole()
            ? "No roles are selected. Choose recipients before submitting any report with handoff notes."
            : isAdminRole()
              ? "Recipients are based on roles currently assigned to employee profiles."
              : "Only an administrator can choose alert recipients.";
      }

      $("saveShiftAlertSettings").onclick = () =>
        safe(async () => {
          if (!isAdminRole()) throw Error("Admin required to change alert recipients");
          const roles = [
            ...$("shiftAlertRoleOptions").querySelectorAll('input[type="checkbox"]:checked'),
          ].map((checkbox) => checkbox.value);
          const { data, error } = await db.rpc("save_shift_alert_settings", {
            p_roles: roles,
          });
          if (error) throw error;
          renderShiftAlertRoles(data.recipient_roles || []);
          $("shiftAlertSettingsHelp").textContent =
            roles.length
              ? `Saved. New handoff alerts will go to: ${roles.map(formatRoleName).join(", ")}.`
              : "Saved. No roles are selected; reports with handoff notes cannot be submitted until recipients are chosen.";
          notify("Shift handoff alert recipients saved");
        });

      function renderShiftAlerts() {
        const count = unreadShiftAlerts.length;
        $("shiftAlertCount").textContent = count > 99 ? "99+" : String(count);
        $("shiftAlertCount").classList.toggle("hidden", count === 0);
        $("shiftAlertBell").setAttribute("aria-label", `${count} unread handoff alerts`);
        $("shiftAlertList").innerHTML =
          unreadShiftAlerts
            .map(
              (alert) =>
                `<article class="shift-alert"><strong>${esc(alert.shift_name)} — ${esc(alert.task_title)}</strong><small class="muted">${esc(alert.report_date)}</small><p>${esc(alert.handoff_note)}</p><button data-read-shift-alert="${esc(alert.id)}">Mark as read</button></article>`,
            )
            .join("") || '<p class="muted">You have no unread handoff alerts.</p>';
      }

      async function loadShiftAlerts() {
        const { data, error } = await db.rpc("get_my_shift_alerts");
        if (error) {
          notify("Handoff alerts could not load: " + error.message, true);
          return;
        }
        unreadShiftAlerts = Array.isArray(data) ? data : [];
        renderShiftAlerts();
      }

      $("shiftAlertBell").onclick = () =>
        safe(async () => {
          const panel = $("shiftAlertPanel");
          const open = panel.classList.contains("hidden");
          panel.classList.toggle("hidden", !open);
          $("shiftAlertBell").setAttribute("aria-expanded", String(open));
          if (open) await loadShiftAlerts();
        });
      $("shiftAlertList").onclick = (event) =>
        safe(async () => {
          const id = event.target.closest("[data-read-shift-alert]")?.dataset.readShiftAlert;
          if (!id) return;
          checked(await db.rpc("mark_shift_alert_read", { p_alert: id }));
          await loadShiftAlerts();
          notify("Handoff alert marked as read");
        });
      document.addEventListener("click", (event) => {
        const container = $("shiftAlertBell").parentElement;
        if (!container.contains(event.target)) {
          $("shiftAlertPanel").classList.add("hidden");
          $("shiftAlertBell").setAttribute("aria-expanded", "false");
        }
      });
      window.addEventListener("focus", () =>
        safe(async () => {
          if (user) await loadShiftAlerts();
        }),
      );
      document.addEventListener("visibilitychange", () => {
        if (document.visibilityState === "visible" && user)
          safe(async () => {
            await loadShiftAlerts();
          });
      });
