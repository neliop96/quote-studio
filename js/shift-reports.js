      let shiftReports = [];
      let shiftReportTasks = [];
      let shiftTaskItems = [];
      let editingShiftReportId = null;
      let editingShiftReportCreatorId = null;
      let editingShiftReportStatus = null;
      let unreadShiftAlerts = [];
      let shiftAlertRoles = [];
      let scheduledShifts = [];
      let scheduleEmployees = [];
      let scheduleTimeZone = "America/Los_Angeles";
      let scheduleToday = "";
      let scheduleFeatureAvailable = false;

      const shiftDisplayNames = {
        first: "1st Shift",
        second: "2nd Shift",
        third: "3rd Shift",
      };

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
      $("myScheduleStartDate").value = localDate();
      $("myScheduleEndDate").value = localDate(new Date(Date.now() + 14 * 86400000));
      $("scheduleStartDate").value = localDate();
      $("scheduleEndDate").value = localDate(new Date(Date.now() + 14 * 86400000));
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
          await loadShiftScheduleSettings();
          await loadDetectedShift();
          await loadScheduleRange(
            $("myScheduleStartDate").value,
            $("myScheduleEndDate").value,
            false,
          );
        }),
      );
      document.querySelector('[data-tab="settings"]').addEventListener("click", () =>
        safe(async () => {
          await loadShiftScheduleSettings();
          if (isAdminRole()) {
            await loadOfficialSchedule();
          }
        }),
      );

      function formatRoleName(role) {
        return role
          .replace(/[_-]+/g, " ")
          .replace(/\b\w/g, (character) => character.toUpperCase());
      }

      function scheduleErrorMessage(error) {
        const code = String(error?.code || "").toUpperCase();
        const rawMessage = String(error?.message || "");
        if (
          code === "PGRST202" ||
          code === "42883" ||
          /function .* does not exist/i.test(rawMessage)
        )
          return "Shift scheduling is not installed yet. Ask an administrator to apply the approved migration.";
        if (error instanceof TypeError || /failed to fetch|network error/i.test(rawMessage))
          return "Could not reach the scheduling service. Check your connection and try again.";
        if (code === "42501")
          return "You do not have permission for this scheduling action.";
        if (code === "55000")
          return "Shift scheduling is not ready because its configuration or a previous time-zone cutover is pending.";
        if (code === "22007")
          return "That local time is missing or ambiguous during a daylight-saving transition. Choose a different time.";
        if (code === "22023" || code === "22008")
          return "The schedule request is invalid. Check the date range and IANA time zone.";
        if (code === "23P01" || /overlap|conflict/i.test(rawMessage))
          return "The requested shift conflicts with another scheduled shift. Choose a different time.";
        return "The scheduling service could not complete the request. Try again or contact an administrator.";
      }

      async function scheduleRpc(name, args = {}) {
        let response;
        try {
          response = await db.rpc(name, args);
        } catch (error) {
          throw Error(scheduleErrorMessage(error));
        }
        if (response.error) throw Error(scheduleErrorMessage(response.error));
        return response.data;
      }

      function shiftScheduleDateOffset(dateValue, offset) {
        const date = new Date(`${dateValue}T00:00:00Z`);
        date.setUTCDate(date.getUTCDate() + offset);
        return date.toISOString().slice(0, 10);
      }

      function formatScheduleTime(value, timeZone) {
        return new Intl.DateTimeFormat(undefined, {
          timeZone,
          dateStyle: "medium",
          timeStyle: "short",
        }).format(new Date(value));
      }

      // Uses absolute instants, so overnight and DST-shifted shifts are exact.
      function formatShiftDuration(startsAt, endsAt) {
        const minutes = Math.round((new Date(endsAt) - new Date(startsAt)) / 60000);
        if (!Number.isFinite(minutes) || minutes < 0) return "—";
        const hours = Math.floor(minutes / 60);
        const rest = minutes % 60;
        if (!hours) return `${rest}m`;
        return rest ? `${hours}h ${rest}m` : `${hours}h`;
      }

      // The caller's own assigned shifts only (get_shift_schedule with admin view off).
      function findMyShifts(shifts, now = new Date()) {
        const nowMs = new Date(now).getTime();
        const sorted = (Array.isArray(shifts) ? shifts : [])
          .map((shift) => ({
            shift,
            start: new Date(shift.starts_at).getTime(),
            end: new Date(shift.ends_at).getTime(),
          }))
          .filter((item) => Number.isFinite(item.start) && Number.isFinite(item.end))
          .sort((a, b) => a.start - b.start);
        return {
          current: sorted.find((item) => item.start <= nowMs && nowMs < item.end)?.shift || null,
          next: sorted.find((item) => item.start > nowMs)?.shift || null,
        };
      }

      function describeShift(shift) {
        const name = shift.kind === "custom" && !/custom/i.test(shift.name) ? `${shift.name} (custom)` : shift.name;
        return `${name} (${formatScheduleTime(shift.starts_at, shift.time_zone)}–${formatScheduleTime(shift.ends_at, shift.time_zone)})`;
      }

      async function loadDetectedShift() {
        const plantEl = $("currentPlantShift");
        const mineEl = $("myCurrentShift");
        const nextEl = $("myNextShift");
        if (!scheduleFeatureAvailable) {
          plantEl.textContent =
            "Current plant shift: unavailable until the scheduling migration is applied.";
          mineEl.textContent = "My current shift: unavailable.";
          nextEl.textContent = "My next scheduled shift: unavailable.";
          return;
        }
        const plant = await scheduleRpc("get_scheduled_shift_at");
        plantEl.textContent = plant
          ? `Current plant shift: ${describeShift(plant)}. This is the official shift active now, regardless of who is assigned.`
          : "Current plant shift: no official shift is scheduled at this time.";

        const baseDate = scheduleToday || new Date().toISOString().slice(0, 10);
        const mine = findMyShifts(
          await scheduleRpc("get_shift_schedule", {
            p_start_date: shiftScheduleDateOffset(baseDate, -1),
            p_end_date: shiftScheduleDateOffset(baseDate, 91),
            p_admin_view: false,
          }),
        );
        mineEl.textContent = mine.current
          ? `My current shift: ${describeShift(mine.current)}.`
          : "My current shift: none. You are not assigned to the shift active now.";
        nextEl.textContent = mine.next
          ? `My next scheduled shift: ${describeShift(mine.next)}.`
          : "My next scheduled shift: none assigned in the next 90 days.";
      }

      function formatLocalClock(value) {
        const [hour, minute] = value.split(":").map(Number);
        const period = hour >= 12 ? "PM" : "AM";
        const displayHour = hour % 12 || 12;
        return `${displayHour}:${String(minute).padStart(2, "0")} ${period}`;
      }

      function displayPersonName(person) {
        return person.full_name?.trim() || "Unnamed employee";
      }

      async function loadShiftScheduleSettings() {
        let data;
        try {
          data = await scheduleRpc("get_shift_schedule_settings");
        } catch (error) {
          scheduleFeatureAvailable = false;
          const message = error.message || scheduleErrorMessage(error);
          $("shiftScheduleTimeZoneHelp").textContent = message;
          $("myScheduleHelp").textContent = message;
          if (!message.startsWith("Shift scheduling is not installed yet.")) {
            notify(message, true);
          }
          return;
        }
        scheduleFeatureAvailable = true;
        scheduleTimeZone = data.time_zone;
        scheduleToday = data.today_local;
        $("shiftScheduleTimeZone").value = data.time_zone;
        $("shiftTemplateScheduleRows").innerHTML = (data.templates || [])
          .map((template) => {
            const days =
              template.code === "third"
                ? "Sunday–Thursday"
                : "Monday–Friday";
            const endTime = formatLocalClock(template.end_local);
            const overnight =
              template.end_local <= template.start_local ? " next day" : "";
            return `<tr><td>${esc(template.name)}</td><td>${esc(formatLocalClock(template.start_local))}</td><td>${esc(endTime + overnight)}</td><td>${days}</td></tr>`;
          })
          .join("");
        $("shiftScheduleTimeZone").disabled = !isAdminRole();
        $("saveShiftScheduleTimeZone").disabled = !isAdminRole();
        $("saveShiftScheduleTimeZone").classList.toggle("hidden", !isAdminRole());
        $("shiftScheduleTimeZoneHelp").textContent = isAdminRole()
          ? `IANA time zone changes take effect on ${data.effective_from}. Existing shifts remain unchanged; the system chooses a safe cutover after already-scheduled shifts.`
          : "Time zone changes are managed by an Owner or Admin.";
      }

      function renderScheduleEmployees() {
        const employeeOptions = scheduleEmployees
          .map(
            (employee) =>
              `<option value="${esc(employee.id)}">${esc(displayPersonName(employee))} (${esc(formatRoleName(employee.role))})</option>`,
          )
          .join("");
        $("scheduleEmployeeSelect").innerHTML =
          '<option value="">Select employee</option>' + employeeOptions;
        $("overrideEmployeeSelect").innerHTML =
          '<option value="">Select employee</option>' + employeeOptions;
        $("scheduleEmployeeRows").innerHTML =
          scheduleEmployees
            .map(
              (employee) =>
                `<tr><td>${esc(displayPersonName(employee))}</td><td>${esc(formatRoleName(employee.role))}</td><td>${esc(shiftDisplayNames[employee.default_shift] || "Unassigned")}</td></tr>`,
            )
            .join("") || '<tr><td colspan="3" class="muted">No eligible employee profiles.</td></tr>';
      }

      async function loadShiftScheduleAdminData() {
        if (!isAdminRole()) return;
        let data;
        try {
          data = await scheduleRpc("get_shift_schedule_admin_data");
        } catch (error) {
          $("officialScheduleHelp").textContent =
            "Schedule administration unavailable: " + error.message;
          return;
        }
        scheduleEmployees = Array.isArray(data?.employees) ? data.employees : [];
        renderScheduleEmployees();
        $("scheduleDefaultHistoryRows").innerHTML =
          (data.default_history || [])
            .map(
              (entry) =>
                `<tr><td>${esc(entry.employee_name || "Unknown employee")}</td><td>${esc(shiftDisplayNames[entry.template_code] || "Unassigned")}</td><td>${esc(entry.effective_from)}</td><td>${esc(entry.effective_to || "Current")}</td><td>${esc(entry.changed_by || "System")}</td></tr>`,
            )
            .join("") || '<tr><td colspan="5" class="muted">No assignment history yet.</td></tr>';
        $("scheduleOverrideHistoryRows").innerHTML =
          (data.override_history || [])
            .map(
              (entry) =>
                `<tr><td>${esc(entry.shift_name)}<br><small>${esc(formatScheduleTime(entry.starts_at, entry.time_zone))}</small></td><td>${esc(entry.employee_name || "Unknown employee")}</td><td>${entry.assigned ? "Assigned" : "Removed"}</td><td>${esc(formatScheduleTime(entry.created_at, entry.time_zone))}</td><td>${esc(entry.changed_by || "Admin")}</td></tr>`,
            )
            .join("") || '<tr><td colspan="5" class="muted">No date-specific overrides yet.</td></tr>';
      }

      async function loadScheduleRange(startDate, endDate, adminView) {
        if (!scheduleFeatureAvailable) return;
        if (!startDate || !endDate || endDate < startDate)
          throw Error("Choose a valid schedule date range");
        if (adminView && scheduleToday) {
          const materializeStart =
            startDate < scheduleToday ? scheduleToday : startDate;
          const materializeEnd = shiftScheduleDateOffset(scheduleToday, 92);
          const boundedEnd = endDate > materializeEnd ? materializeEnd : endDate;
          if (materializeStart <= boundedEnd) {
            await scheduleRpc("materialize_shift_schedule", {
              p_start_date: materializeStart,
              p_end_date: boundedEnd,
            });
          }
        }
        const data = await scheduleRpc("get_shift_schedule", {
          p_start_date: startDate,
          p_end_date: endDate,
          p_admin_view: adminView,
        });
        scheduledShifts = Array.isArray(data) ? data : [];
        const rows = scheduledShifts
          .map((shift) => {
            const assigned = (shift.assignments || [])
              .map((employee) => esc(displayPersonName(employee)))
              .join(", ");
            return `<tr><td>${esc(shift.name)}${shift.kind === "custom" ? " (custom)" : ""}</td><td>${esc(formatScheduleTime(shift.starts_at, shift.time_zone))}</td><td>${esc(formatScheduleTime(shift.ends_at, shift.time_zone))}</td>${adminView ? `<td>${esc(formatShiftDuration(shift.starts_at, shift.ends_at))}</td><td>${assigned || "Unassigned"}</td>` : `<td>${esc(shift.time_zone)}</td>`}${adminView ? "" : ""}</tr>`;
          })
          .join("");
        if (adminView) {
          $("officialScheduleRows").innerHTML =
            rows || '<tr><td colspan="5" class="muted">No scheduled shifts in this date range.</td></tr>';
          $("overrideShiftSelect").innerHTML =
            '<option value="">Select future shift</option>' +
            scheduledShifts
              .filter((shift) => new Date(shift.starts_at) > new Date())
              .map(
                (shift) =>
                  `<option value="${esc(shift.id)}">${esc(shift.name)} · ${esc(formatScheduleTime(shift.starts_at, shift.time_zone))}</option>`,
              )
              .join("");
          $("officialScheduleHelp").textContent =
            "Only Owner/Admin actions materialize regular shifts. Employee schedule and detection requests are read-only; existing instances are immutable.";
        } else {
          $("myScheduleRows").innerHTML =
            rows || '<tr><td colspan="4" class="muted">No assigned shifts in this range. You may still create a shift report.</td></tr>';
          $("myScheduleHelp").textContent = `${scheduledShifts.length} assigned shift(s) shown.`;
        }
      }

      async function loadOfficialSchedule() {
        await loadScheduleRange(
          $("scheduleStartDate").value,
          $("scheduleEndDate").value,
          true,
        );
        await loadShiftScheduleAdminData();
      }

      $("loadMySchedule").onclick = () =>
        safe(() =>
          loadScheduleRange(
            $("myScheduleStartDate").value,
            $("myScheduleEndDate").value,
            false,
          ),
        );
      $("loadOfficialSchedule").onclick = () =>
        safe(loadOfficialSchedule);
      $("saveShiftScheduleTimeZone").onclick = () =>
        safe(async () => {
          if (!isAdminRole()) throw Error("Owner or Admin permission required");
          const timeZone = $("shiftScheduleTimeZone").value.trim();
          const data = await scheduleRpc("set_shift_schedule_time_zone", {
            p_time_zone: timeZone,
          });
          scheduleTimeZone = data.time_zone;
          scheduleToday = data.today_local;
          $("shiftScheduleTimeZone").value = data.time_zone;
          $("shiftScheduleTimeZoneHelp").textContent =
            `Saved. Newly generated regular shifts use ${data.time_zone} starting ${data.effective_from}. The cutover is delayed as needed to preserve existing shifts.`;
          await loadOfficialSchedule();
          notify("Shift scheduling time zone saved");
        });
      $("saveEmployeeDefaultShift").onclick = () =>
        safe(async () => {
          if (!isAdminRole()) throw Error("Owner or Admin permission required");
          const employeeId = $("scheduleEmployeeSelect").value;
          if (!employeeId) throw Error("Select an employee");
          await scheduleRpc("set_employee_default_shift", {
            p_employee_id: employeeId,
            p_template_code: $("scheduleDefaultShift").value || null,
          });
          await loadShiftScheduleAdminData();
          await loadScheduleRange($("scheduleStartDate").value, $("scheduleEndDate").value, true);
          notify("Default employee shift assignment saved");
        });
      $("scheduleEmployeeSelect").onchange = () => {
        const selected = scheduleEmployees.find(
          (employee) => employee.id === $("scheduleEmployeeSelect").value,
        );
        $("scheduleDefaultShift").value = selected?.default_shift || "";
      };
      $("saveShiftAssignmentOverride").onclick = () =>
        safe(async () => {
          if (!isAdminRole()) throw Error("Owner or Admin permission required");
          const shiftId = $("overrideShiftSelect").value;
          const employeeId = $("overrideEmployeeSelect").value;
          if (!shiftId || !employeeId) throw Error("Select a scheduled shift and employee");
          await scheduleRpc("set_shift_instance_assignment", {
            p_shift_instance_id: shiftId,
            p_employee_id: employeeId,
            p_assigned: $("overrideAssignmentState").value === "true",
          });
          await loadOfficialSchedule();
          notify("Date-specific assignment override saved");
        });
      $("createCustomShift").onclick = () =>
        safe(async () => {
          if (!isAdminRole()) throw Error("Owner or Admin permission required");
          const name = $("customShiftName").value.trim();
          const start = $("customShiftStart").value;
          const end = $("customShiftEnd").value;
          if (!name || !start || !end) throw Error("Enter a name and local start/end times");
          const data = await scheduleRpc("create_custom_shift", {
            p_name: name,
            p_start_local: start.replace("T", " "),
            p_end_local: end.replace("T", " "),
          });
          $("customShiftName").value = "";
          await loadOfficialSchedule();
          notify(`Custom shift created: ${data}`);
        });

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
