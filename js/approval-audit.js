      // Owner-only account approval audit history. The database independently enforces the
      // owner and approved-account requirement; hiding the panel is only a UI convenience.
      const APPROVAL_AUDIT_PAGE_SIZE = 50;
      const APPROVAL_AUDIT_ACTIONS = { bootstrap: "Bootstrap", approve: "Approved", revoke: "Revoked" };
      let approvalAuditRows = [];
      let approvalAuditHasMore = false;
      let approvalAuditLoading = false;
      let approvalAuditError = "";

      function approvalAuditPerson(name, email, id, missingLabel) {
        if (!id) return esc(missingLabel);
        const label = name || email;
        if (!label) return `${esc("Deleted account")}<br><small class="muted">${esc(id)}</small>`;
        return `${esc(label)}${name && email ? `<br><small class="muted">${esc(email)}</small>` : ""}`;
      }
      function approvalAuditRowHtml(row) {
        const when = new Date(row.recorded_at);
        const time = Number.isNaN(when.getTime()) ? String(row.recorded_at ?? "") : when.toLocaleString();
        const action = APPROVAL_AUDIT_ACTIONS[row.event_type] || String(row.event_type ?? "");
        return `<tr><td>${esc(time)}</td><td>${esc(action)}</td><td>${approvalAuditPerson(row.subject_name, row.subject_email, row.subject_user_id, "Unknown account")}</td><td>${approvalAuditPerson(row.actor_name, row.actor_email, row.actor_user_id, "Database administrator (bootstrap)")}</td><td class="audit-reason">${esc(row.reason)}</td><td>Completed</td></tr>`;
      }
      function renderApprovalAudit() {
        const status = $("approvalAuditStatus");
        $("approvalAuditRows").innerHTML = approvalAuditRows.map(approvalAuditRowHtml).join("");
        status.textContent = approvalAuditLoading
          ? "Loading audit history…"
          : approvalAuditError
            ? approvalAuditError
            : approvalAuditRows.length
              ? ""
              : "No approval events have been recorded yet.";
        $("approvalAuditMore").classList.toggle("hidden", !approvalAuditHasMore || approvalAuditLoading);
        $("approvalAuditMore").disabled = approvalAuditLoading;
        $("approvalAuditRefresh").disabled = approvalAuditLoading;
      }
      function resetApprovalAudit() {
        approvalAuditRows = [];
        approvalAuditHasMore = false;
        approvalAuditError = "";
        $("approvalAuditPanel").classList.add("hidden");
        $("approvalAuditRows").innerHTML = "";
        $("approvalAuditStatus").textContent = "";
      }
      // Never throws: failures are shown in the panel so approval workflows are unaffected.
      async function loadApprovalAudit(reset) {
        if (profile?.role !== "owner" || approvalAuditLoading) return;
        const cursor = !reset && approvalAuditRows.length
          ? approvalAuditRows[approvalAuditRows.length - 1].audit_id
          : null;
        approvalAuditLoading = true;
        approvalAuditError = "";
        renderApprovalAudit();
        try {
          const params = { p_limit: APPROVAL_AUDIT_PAGE_SIZE + 1 };
          if (cursor !== null) params.p_before = cursor;
          const data = (await db.rpc("list_account_approval_audit", params).then(checked)) || [];
          const page = data.slice(0, APPROVAL_AUDIT_PAGE_SIZE);
          approvalAuditHasMore = data.length > APPROVAL_AUDIT_PAGE_SIZE;
          approvalAuditRows = cursor === null ? page : approvalAuditRows.concat(page);
        } catch (error) {
          console.error(error);
          approvalAuditError = `Unable to load audit history: ${error?.message || "unexpected error"}`;
        } finally {
          approvalAuditLoading = false;
          renderApprovalAudit();
        }
      }
      async function initApprovalAudit() {
        resetApprovalAudit();
        if (profile?.role !== "owner") return;
        $("approvalAuditPanel").classList.remove("hidden");
        await loadApprovalAudit(true);
      }
      const refreshApprovalAudit = () => loadApprovalAudit(true);
      $("approvalAuditMore").onclick = () => loadApprovalAudit(false);
      $("approvalAuditRefresh").onclick = () => loadApprovalAudit(true);
