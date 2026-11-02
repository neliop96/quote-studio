// Pure estimate logic (no DOM, no Supabase) so it can be tested directly.
(function (root) {
  const STATUSES = ["Draft", "Ready", "Sent", "Approved", "Rejected", "Expired"];
  const ISSUED = ["Sent", "Approved", "Rejected", "Expired"];
  const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const DEFAULT_TIME_ZONE = "America/Los_Angeles";
  const DEFAULT_VALIDITY_DAYS = 30;

  const isIssued = (status) => ISSUED.includes(status);

  function parseISODate(value) {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value ?? ""));
    if (!match) return null;
    const [year, month, day] = match.slice(1).map(Number);
    const date = new Date(Date.UTC(year, month - 1, day));
    if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day)
      return null;
    return date;
  }

  // Calendar-date arithmetic on YYYY-MM-DD strings; never touches local time zones.
  function addDays(iso, days) {
    const date = parseISODate(iso);
    if (!date) throw Error("Invalid date: " + iso);
    date.setUTCDate(date.getUTCDate() + Number(days));
    return date.toISOString().slice(0, 10);
  }

  function todayInZone(timeZone = DEFAULT_TIME_ZONE, now = new Date()) {
    const parts = Object.fromEntries(
      new Intl.DateTimeFormat("en-CA", {
        timeZone,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
      })
        .formatToParts(now)
        .map(({ type, value }) => [type, value]),
    );
    return `${parts.year}-${parts.month}-${parts.day}`;
  }

  function formatDate(iso) {
    if (!parseISODate(iso)) return "";
    const [year, month, day] = iso.split("-").map(Number);
    return `${MONTHS[month - 1]} ${day}, ${year}`;
  }

  function normalizeValidityDays(value, fallback = DEFAULT_VALIDITY_DAYS) {
    if (value === "" || value === null || value === undefined) return fallback;
    const days = Number(value);
    if (!Number.isInteger(days) || days < 1 || days > 365)
      throw Error("Validity period must be a whole number of days from 1 to 365");
    return days;
  }

  const issueDate = (q) => (Number(q.revision_number) > 0 ? q.revision_date : q.original_estimate_date);

  function customerSnapshot(q) {
    const snapshot = q?.customer_snapshot;
    return snapshot && typeof snapshot === "object" && !Array.isArray(snapshot) ? snapshot : {};
  }

  function customerProjectTitle(q, override = "") {
    return (
      String(override || "").trim().slice(0, 140) ||
      String(q?.project_name || "").trim().slice(0, 140) ||
      String(q?.notes || "").split(/\r?\n/, 1)[0].trim().slice(0, 140) ||
      "Automation Project"
    );
  }

  function validUntil(q) {
    const issued = issueDate(q);
    return issued ? addDays(issued, q.validity_days || DEFAULT_VALIDITY_DAYS) : null;
  }

  // Expiration is derived for Sent estimates only; Approved and Rejected never expire.
  function effectiveStatus(q, today) {
    if (q.status === "Sent" && q.valid_until && today && q.valid_until < today) return "Expired";
    return q.status;
  }

  const versionLabel = (q) =>
    Number(q.revision_number) > 0 ? `Revision ${q.revision_number}` : "Original";

  function dateSummary(q) {
    const revision = Number(q.revision_number) > 0;
    return {
      original: formatDate(q.original_estimate_date),
      revision: revision ? formatDate(q.revision_date) : "",
      validUntil: formatDate(q.valid_until),
      revisionNumber: revision ? Number(q.revision_number) : 0,
    };
  }

  function filterQuotes(quotes, status, today) {
    if (!status || status === "All") return quotes;
    return quotes.filter((q) => effectiveStatus(q, today) === status);
  }

  function statusCounts(quotes, today) {
    const counts = { All: quotes.length };
    STATUSES.forEach((status) => (counts[status] = 0));
    quotes.forEach((q) => (counts[effectiveStatus(q, today)] += 1));
    return counts;
  }

  function rowActions(q, today, { isAdmin = false, userId = null } = {}) {
    const status = effectiveStatus(q, today);
    const canManage = isAdmin || (userId && q.created_by === userId);
    return {
      edit: !isIssued(status),
      send: ["Ready", "Sent", "Approved"].includes(status),
      decide: status === "Sent" && canManage,
      revise: isIssued(status) && canManage,
      print: true,
      history: true,
    };
  }

  const totals = (q) => {
    const material = q.items.reduce((s, l) => s + Number(l.qty) * Number(l.cost), 0),
      sell = material * (1 + Number(q.markup) / 100),
      labor = Number(q.labor_hours) * Number(q.labor_rate),
      tax = (sell * Number(q.tax_rate)) / 100;
    return { material, sell, labor, tax, total: sell + labor + tax };
  };

  // Stable signature of the editable estimate contents, for unsaved-change detection.
  function signature(draft) {
    return JSON.stringify([
      draft.project_name || "",
      draft.customer_id || "",
      (draft.items || []).map((l) => [l.product_id, l.part, l.description, l.supplier, Number(l.qty), Number(l.cost)]),
      Number(draft.labor_hours),
      Number(draft.labor_rate),
      Number(draft.markup),
      Number(draft.tax_rate),
      draft.notes || "",
      Number(draft.validity_days),
    ]);
  }

  function datesHtml(q, esc) {
    const d = dateSummary(q);
    const issued = issueDate(q);
    const validity = d.validUntil
      ? esc(d.validUntil)
      : `${esc(q.validity_days || DEFAULT_VALIDITY_DAYS)} days from the issue date`;
    const lines = [];
    if (d.revisionNumber) {
      lines.push(`<b>Revision:</b> ${esc(d.revisionNumber)}`);
      lines.push(`<b>Original Estimate Date:</b> ${esc(d.original || "Not issued")}`);
      lines.push(`<b>Revision Date:</b> ${esc(issued ? d.revision : "Not issued")}`);
    } else {
      lines.push(`<b>Estimate Date:</b> ${esc(d.original || "Not issued")}`);
    }
    lines.push(`<b>Valid Until:</b> ${validity}`);
    return `<p>${lines.join("<br>")}</p>`;
  }

  // Builds the printable document from one saved quotation version.
  function buildPdfHtml(q, { format = "detailed", detail = "project", projectName = "", esc, money }) {
    const t = totals(q);
    const c = customerSnapshot(q);
    const customer = format === "customer";
    const name = customerProjectTitle(q, projectName);
    const title = customer ? "Project Quotation" : "Estimate";
    const head = `<!doctype html><html><head><meta charset="utf-8"><title>${esc(q.quote_number || title)}</title><style>body{font:14px Arial,sans-serif;margin:40px;color:#182336;line-height:1.5}h1{color:#164e93;margin-bottom:5px}h2{margin-top:10px}table{width:100%;border-collapse:collapse;margin:20px 0}td,th{padding:9px;border-bottom:1px solid #ccc;text-align:left}.total{text-align:right;font-size:24px;margin-top:24px}.muted{color:#53657b}.project{padding:16px 0;border-top:1px solid #dce3eb;border-bottom:1px solid #dce3eb;margin:24px 0;font-size:19px;font-weight:bold}p{white-space:pre-wrap}</style></head><body><h1>PRECISION AUTOMATION</h1><h2>${title} ${esc(q.quote_number)}</h2>${datesHtml(q, esc)}${!customer && q.project_name ? `<p><b>Project:</b> ${esc(q.project_name)}</p>` : ""}<p><b>Customer:</b> ${esc(c.name)}<br>${esc(c.contact)}<br>${esc(c.address)}<br>${esc(c.email)}</p>`;
    let content;
    if (customer) {
      const list =
        detail === "materials"
          ? `<h3>Included Materials</h3><table><thead><tr><th>Description</th><th>Quantity</th></tr></thead><tbody>${q.items.map((l) => `<tr><td>${esc(l.description)} (${esc(l.part)})</td><td>${esc(l.qty)}</td></tr>`).join("")}</tbody></table>`
          : "";
      content = `<div class="project">${esc(name)}</div>${list}<div class="total"><b>Total Project Price: ${money(t.total)}</b></div>${q.notes ? `<h3>Project Scope / Notes</h3><p>${esc(q.notes)}</p>` : ""}`;
    } else {
      content = `<table><thead><tr><th>Item</th><th>Qty</th><th>Unit price</th><th>Total</th></tr></thead><tbody>${q.items
        .map((l) => {
          const u = Number(l.cost) * (1 + Number(q.markup) / 100);
          return `<tr><td>${esc(l.description)} (${esc(l.part)})</td><td>${esc(l.qty)}</td><td>${money(u)}</td><td>${money(u * l.qty)}</td></tr>`;
        })
        .join(
          "",
        )}</tbody></table><p>Materials: ${money(t.sell)}<br>Labor: ${money(t.labor)}<br>Estimated tax: ${money(t.tax)}</p><div class="total"><b>Total: ${money(t.total)}</b></div><p>${esc(q.notes)}</p>`;
    }
    return head + content + "<script>window.print()<\/script></body></html>";
  }

  const api = {
    STATUSES,
    ISSUED,
    DEFAULT_TIME_ZONE,
    DEFAULT_VALIDITY_DAYS,
    isIssued,
    parseISODate,
    addDays,
    todayInZone,
    formatDate,
    normalizeValidityDays,
    issueDate,
    validUntil,
    effectiveStatus,
    versionLabel,
    dateSummary,
    customerSnapshot,
    customerProjectTitle,
    filterQuotes,
    statusCounts,
    rowActions,
    totals,
    signature,
    buildPdfHtml,
  };
  root.EstimateLogic = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof window !== "undefined" ? window : globalThis);
