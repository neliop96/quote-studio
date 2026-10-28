const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "..");
const migration = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20261027040000_shift_scheduling_phase1.sql"),
  "utf8",
);
const fixMigration = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20261028010000_fix_overnight_shift_detection.sql"),
  "utf8",
);
const frontend = fs.readFileSync(path.join(root, "js", "shift-reports.js"), "utf8");
const authFrontend = fs.readFileSync(path.join(root, "js", "auth.js"), "utf8");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
const reportsMigration = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20261023163000_add_shift_reports.sql"),
  "utf8",
);
const inventoryMigration = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20261025150000_secure_inventory_workflows.sql"),
  "utf8",
);

function functionDefinition(source, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = source.match(
    new RegExp(`CREATE FUNCTION ${escaped}\\([\\s\\S]*?\\n\\$\\$;`),
  );
  assert.ok(match, `Expected function ${name} to exist`);
  return match[0];
}

function localTimeInstants(timeZone, localDateTime) {
  const [date, time] = localDateTime.split(" ");
  const [year, month, day] = date.split("-").map(Number);
  const [hour, minute] = time.split(":").map(Number);
  const wallClock = Date.UTC(year, month - 1, day, hour, minute);
  const formatter = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  });
  const matches = [];
  for (
    let instant = wallClock - 14 * 60 * 60 * 1000;
    instant <= wallClock + 14 * 60 * 60 * 1000;
    instant += 60 * 1000
  ) {
    const parts = Object.fromEntries(
      formatter.formatToParts(instant).map(({ type, value }) => [type, value]),
    );
    const representedWallClock = Date.UTC(
      Number(parts.year),
      Number(parts.month) - 1,
      Number(parts.day),
      Number(parts.hour),
      Number(parts.minute),
    );
    if (representedWallClock === wallClock) matches.push(instant);
  }
  return matches;
}

test("schedule tables deny direct application access and all rows use RLS", () => {
  const tableNames = [
    "shift_schedule_settings",
    "shift_schedule_time_zone_history",
    "shift_schedule_templates",
    "shift_schedule_instances",
    "employee_shift_default_history",
    "shift_assignment_override_history",
  ];
  for (const tableName of tableNames) {
    assert.match(
      migration,
      new RegExp(`ALTER TABLE public\\.${tableName} ENABLE ROW LEVEL SECURITY`),
    );
    assert.match(migration, new RegExp(`'public\\.${tableName}'`));
  }
  assert.match(migration, /has_table_privilege\(/);
  assert.match(migration, /table_row\.table_name, privilege_row\.privilege_name/);
  assert.match(migration, /has_any_column_privilege\(/);
  assert.match(migration, /has_schema_privilege\(/);
});

test("all SECURITY DEFINER functions pin an empty search_path", () => {
  const definitions = [
    ...migration.matchAll(/CREATE FUNCTION [\s\S]*?\n\$\$;/g),
  ].map(([definition]) => definition);
  assert.ok(definitions.length >= 14);
  for (const definition of definitions) {
    assert.match(definition, /SECURITY DEFINER/);
    assert.match(definition, /SET search_path = ''/);
  }
});

test("only the bounded Owner/Admin materialization RPC writes regular instances", () => {
  const materializer = functionDefinition(migration, "public.materialize_shift_schedule");
  const employeeSchedule = functionDefinition(migration, "public.get_shift_schedule");
  const shiftDetection = functionDefinition(migration, "public.get_scheduled_shift_at");

  assert.match(materializer, /auth\.uid\(\) IS NULL OR NOT public\.is_admin\(\)/);
  assert.match(materializer, /p_end_date - p_start_date > 92/);
  assert.match(materializer, /today_local \+ 92/);
  assert.match(materializer, /ensure_regular_shifts/);
  assert.doesNotMatch(employeeSchedule, /ensure_regular_shifts|INSERT INTO/);
  assert.doesNotMatch(shiftDetection, /ensure_regular_shifts|INSERT INTO/);
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.materialize_shift_schedule\(date, date\)\s+FROM PUBLIC, anon, service_role/,
  );
});

test("employee schedule results are caller-scoped and admin visibility is server checked", () => {
  const schedule = functionDefinition(migration, "public.get_shift_schedule");
  const adminData = functionDefinition(migration, "public.get_shift_schedule_admin_data");
  assert.match(schedule, /admin_view := p_admin_view AND public\.is_admin\(\)/);
  assert.match(schedule, /profile\.id = auth\.uid\(\)/);
  assert.match(schedule, /assignment\.employee_id = auth\.uid\(\)/);
  assert.match(schedule, /quote_studio_schedule_private\.is_assigned/);
  assert.match(adminData, /auth\.uid\(\) IS NULL OR NOT public\.is_admin\(\)/);
  assert.match(frontend, /p_admin_view: adminView/);
});

test("employee upcoming schedule is calculated read-only without admin materialization", () => {
  const schedule = functionDefinition(migration, "public.get_shift_schedule");
  const materializer = functionDefinition(migration, "public.materialize_shift_schedule");
  assert.match(schedule, /IF admin_view THEN/);
  assert.match(schedule, /generate_series\(\s*GREATEST\(p_start_date, today_local\)::timestamp without time zone,\s*LEAST\(p_end_date, today_local \+ 92\)::timestamp without time zone/);
  assert.match(schedule, /employee_shift_default_history AS assignment/);
  assert.match(schedule, /assignment\.employee_id = auth\.uid\(\)/);
  assert.match(schedule, /instance\.local_start_date = calendar\.day_value::date/);
  assert.match(schedule, /calendar\.day_value::date AS local_start_date/);
  assert.match(schedule, /'id', schedule_row\.id/);
  assert.match(schedule, /'assignments', jsonb_build_array/);
  assert.doesNotMatch(schedule, /ensure_regular_shifts|INSERT INTO|UPDATE public\.shift_schedule_instances/);
  assert.match(materializer, /auth\.uid\(\) IS NULL OR NOT public\.is_admin\(\)/);
  assert.match(frontend, /scheduleRpc\("materialize_shift_schedule"/);
});

test("regular schedule generation covers Sunday night through Friday night", () => {
  const generator = functionDefinition(
    migration,
    "quote_studio_schedule_private.ensure_regular_shifts",
  );
  assert.match(generator, /weekday_number = 7 AND template\.code = 'third'/);
  assert.match(generator, /weekday_number BETWEEN 1 AND 4/);
  assert.match(generator, /weekday_number = 5 AND template\.code IN \('first', 'second'\)/);
  assert.match(migration, /'third', '3rd Shift', '23:00', '07:00'/);
  assert.match(migration, /'first', '1st Shift', '07:00', '15:00'/);
  assert.match(migration, /'second', '2nd Shift', '15:00', '23:00'/);
  assert.match(migration, /ON CONFLICT \(template_code, local_start_date\)[\s\S]*?DO NOTHING/);

  const scheduledCodes = (isoDay) => {
    if (isoDay === 7) return ["third"];
    if (isoDay >= 1 && isoDay <= 4) return ["first", "second", "third"];
    if (isoDay === 5) return ["first", "second"];
    return [];
  };
  assert.deepEqual(scheduledCodes(7), ["third"]);
  for (let day = 1; day <= 4; day += 1)
    assert.deepEqual(scheduledCodes(day), ["first", "second", "third"]);
  assert.deepEqual(scheduledCodes(5), ["first", "second"]);
  assert.deepEqual(scheduledCodes(6), []);
});

test("custom shifts check stored and not-yet-materialized regular intervals", () => {
  const customShift = functionDefinition(migration, "public.create_custom_shift");
  assert.match(
    migration,
    /EXCLUDE USING gist \(\(tstzrange\(starts_at, ends_at, '\[\)'\)\) WITH &&\)/,
  );
  assert.match(customShift, /tstzrange\(instance\.starts_at, instance\.ends_at, '\[\)'\)/);
  assert.match(customShift, /assert_no_regular_overlap/);
  assert.match(migration, /Custom shift overlaps a regular scheduled shift/);
  assert.match(customShift, /interval '24 hours'/);
});

test("time-zone cutovers preserve existing shifts and validate future intervals", () => {
  const setter = functionDefinition(migration, "public.set_shift_schedule_time_zone");
  const validator = functionDefinition(
    migration,
    "quote_studio_schedule_private.validate_time_zone_cutover",
  );
  assert.match(setter, /max\(\(\(instance\.ends_at \+ interval '72 hours'\)/);
  assert.match(setter, /validate_time_zone_cutover/);
  assert.match(setter, /effective_date := effective_date\s*\+\s*\(\(6 - extract\(isodow FROM effective_date\)/);
  assert.match(setter, /A time-zone change is already pending/);
  assert.match(validator, /generate_series/);
  assert.match(validator, /tstzrange\(starts_at, ends_at, '\[\)'\)/);
  assert.doesNotMatch(setter, /UPDATE public\.shift_schedule_instances/);
});

test("date-specific and default assignment changes preserve history and reject completed shifts", () => {
  const defaultAssignment = functionDefinition(migration, "public.set_employee_default_shift");
  const override = functionDefinition(migration, "public.set_shift_instance_assignment");
  assert.match(defaultAssignment, /pg_advisory_xact_lock/);
  assert.match(defaultAssignment, /SET effective_to = changed_at/);
  assert.match(defaultAssignment, /INSERT INTO public\.employee_shift_default_history/);
  assert.match(override, /FOR UPDATE/);
  assert.match(override, /shift_start <= changed_at/);
  assert.match(override, /INSERT INTO public\.shift_assignment_override_history/);
  assert.doesNotMatch(defaultAssignment, /DELETE FROM/);
  assert.doesNotMatch(override, /DELETE FROM/);
});

test("DST resolution rejects missing and ambiguous times in standard and unusual zones", () => {
  const resolver = functionDefinition(
    migration,
    "quote_studio_schedule_private.resolve_local_time",
  );
  assert.match(resolver, /matching_instants <> 1/);
  assert.match(migration, /resolve_local_time\(\s*local_start, schedule_time_zone/);
  assert.match(migration, /resolve_local_time\(\s*p_start_local, configured_time_zone/);

  assert.equal(localTimeInstants("America/Los_Angeles", "2026-03-08 02:30").length, 0);
  assert.equal(localTimeInstants("America/Los_Angeles", "2026-11-01 01:30").length, 2);
  assert.equal(localTimeInstants("Australia/Lord_Howe", "2026-10-04 02:15").length, 0);
  assert.equal(localTimeInstants("Australia/Lord_Howe", "2026-04-05 01:45").length, 2);

  const springStart = localTimeInstants("America/Los_Angeles", "2026-03-07 23:00");
  const springEnd = localTimeInstants("America/Los_Angeles", "2026-03-08 07:00");
  const fallStart = localTimeInstants("America/Los_Angeles", "2026-10-31 23:00");
  const fallEnd = localTimeInstants("America/Los_Angeles", "2026-11-01 07:00");
  assert.equal((springEnd[0] - springStart[0]) / 3600000, 7);
  assert.equal((fallEnd[0] - fallStart[0]) / 3600000, 9);
});

test("weekend custom 12-hour shifts are supported and UI submits local times", () => {
  assert.match(migration, /p_end_local - p_start_local > interval '24 hours'/);
  assert.match(migration, /create_custom_shift/);
  assert.match(frontend, /p_start_local: start\.replace\("T", " "\)/);
  assert.match(frontend, /p_end_local: end\.replace\("T", " "\)/);
  const start = localTimeInstants("America/Los_Angeles", "2026-10-31 08:00");
  const end = localTimeInstants("America/Los_Angeles", "2026-10-31 20:00");
  assert.equal((end[0] - start[0]) / 3600000, 12);
});

test("official schedule shows a Duration column computed from absolute instants", () => {
  assert.match(html, /<th>End<\/th><th>Duration<\/th><th>Assigned employees<\/th>/);
  const source = frontend.match(/function formatShiftDuration[\s\S]*?\r?\n\s*}\r?\n/);
  assert.ok(source);
  const formatShiftDuration = new Function(`${source[0]}; return formatShiftDuration;`)();
  const la = "America/Los_Angeles";
  const iso = (value) => new Date(localTimeInstants(la, value)[0]).toISOString();
  const duration = (a, b) => formatShiftDuration(iso(a), iso(b));
  assert.equal(duration("2026-10-26 08:00", "2026-10-26 16:00"), "8h");
  assert.equal(duration("2026-10-31 08:00", "2026-10-31 20:00"), "12h");
  assert.equal(duration("2026-10-31 23:00", "2026-11-01 07:00"), "9h");
  assert.equal(duration("2026-03-07 23:00", "2026-03-08 07:00"), "7h");
  assert.equal(duration("2026-10-26 08:00", "2026-10-26 16:30"), "8h 30m");
});

test("employee page separates plant shift, my current shift and my next shift", () => {
  for (const id of ["currentPlantShift", "myCurrentShift", "myNextShift"]) {
    assert.equal(html.split(`id="${id}"`).length, 2);
  }
  assert.doesNotMatch(html + frontend, /currentScheduledShift/);
  const detect = frontend.slice(frontend.indexOf("async function loadDetectedShift"));
  assert.match(detect, /get_scheduled_shift_at/);
  assert.match(detect, /p_admin_view: false/);

  const source = frontend.match(/function findMyShifts[\s\S]*?\r?\n      }\r?\n/);
  assert.ok(source);
  const findMyShifts = new Function(`${source[0]}; return findMyShifts;`)();
  const la = "America/Los_Angeles";
  const shift = (name, start, end, kind = "regular") => ({
    name,
    kind,
    starts_at: new Date(localTimeInstants(la, start)[0]).toISOString(),
    ends_at: new Date(localTimeInstants(la, end)[0]).toISOString(),
    time_zone: la,
  });
  const at = (value) => new Date(localTimeInstants(la, value)[0]);
  const first = shift("1st Shift", "2026-10-28 07:00", "2026-10-28 15:00");
  const nextFirst = shift("1st Shift", "2026-10-29 07:00", "2026-10-29 15:00");

  // Plant is on 3rd shift at 02:00 but the employee is only on 1st: no current, next is 1st.
  let result = findMyShifts([nextFirst, first], at("2026-10-28 02:00"));
  assert.equal(result.current, null);
  assert.equal(result.next, first);

  result = findMyShifts([first, nextFirst], at("2026-10-28 09:00"));
  assert.equal(result.current, first);
  assert.equal(result.next, nextFirst);

  // Overnight shift crossing midnight and a weekend custom 12-hour shift.
  const third = shift("3rd Shift", "2026-10-27 23:00", "2026-10-28 07:00");
  assert.equal(findMyShifts([third], at("2026-10-28 01:30")).current, third);
  const custom = shift("Weekend", "2026-10-31 08:00", "2026-10-31 20:00", "custom");
  result = findMyShifts([custom], at("2026-10-31 12:00"));
  assert.equal(result.current, custom);
  assert.equal(result.next, null);

  // Fall Back: 01:30 occurs twice; instants decide, and the end boundary is exclusive.
  const fall = shift("3rd Shift", "2026-10-31 23:00", "2026-11-01 07:00");
  assert.equal(findMyShifts([fall], new Date(Date.parse(fall.ends_at) - 1)).current, fall);
  assert.equal(findMyShifts([fall], new Date(fall.ends_at)).current, null);
  assert.equal(findMyShifts([], new Date()).current, null);
});

test("unmaterialized overnight shifts from the previous local day are returned while running", () => {
  assert.doesNotMatch(fixMigration, /DROP |ALTER TABLE|INSERT INTO|UPDATE public|DELETE/i);
  assert.match(fixMigration, /CREATE OR REPLACE FUNCTION public\.get_shift_schedule\(/);
  assert.match(
    fixMigration,
    /generate_series\(\s*GREATEST\(p_start_date, today_local - 1\)::timestamp without time zone,\s*LEAST\(p_end_date, today_local \+ 92\)::timestamp without time zone/,
  );
  assert.match(
    fixMigration,
    /calendar\.day_value::date >= today_local\s+OR interval_times\.ends_at > pg_catalog\.clock_timestamp\(\)/,
  );
  // Duplicate protection, employee scoping and admin gating are preserved.
  assert.match(fixMigration, /WHERE instance\.schedule_kind = 'regular'\s+AND instance\.template_code = template\.code\s+AND instance\.local_start_date = calendar\.day_value::date/);
  assert.match(fixMigration, /assignment\.employee_id = auth\.uid\(\)/);
  assert.match(fixMigration, /admin_view := p_admin_view AND public\.is_admin\(\)/);
  assert.match(fixMigration, /ON profile\.id = auth\.uid\(\)/);
  assert.match(fixMigration, /SECURITY DEFINER\s+SET search_path = ''/);
  assert.match(fixMigration, /REVOKE ALL ON FUNCTION public\.get_shift_schedule\(date, date, boolean\)\s+FROM PUBLIC, anon, service_role;\s+GRANT EXECUTE ON FUNCTION public\.get_shift_schedule\(date, date, boolean\) TO authenticated;/);
  assert.doesNotMatch(fixMigration, /shift_reports|shift_alerts|stock_movements|inventory/i);

  // Model of the new generator window against real instants (America/Los_Angeles).
  const la = "America/Los_Angeles";
  const inst = (value) => localTimeInstants(la, value)[0];
  const generated = (todayLocal, localDate, startLocal, endLocal, nowMs) => {
    const start = inst(startLocal);
    const end = inst(endLocal);
    const included = localDate >= todayLocal || end > nowMs;
    return included ? { start, end } : null;
  };
  // Tuesday 02:00: Monday's 3rd shift (23:00-07:00) is still running.
  const running = generated("2026-10-27", "2026-10-26", "2026-10-26 23:00", "2026-10-27 07:00", inst("2026-10-27 02:00"));
  assert.ok(running);
  assert.ok(running.start <= inst("2026-10-27 02:00") && inst("2026-10-27 02:00") < running.end);
  // Once it ends, or for completed earlier shifts, it is not generated.
  assert.equal(generated("2026-10-27", "2026-10-26", "2026-10-26 23:00", "2026-10-27 07:00", inst("2026-10-27 07:00")), null);
  assert.equal(generated("2026-10-27", "2026-10-26", "2026-10-26 07:00", "2026-10-26 15:00", inst("2026-10-27 02:00")), null);
  // Sunday-night 3rd shift (weekend) running early Monday.
  assert.ok(generated("2026-10-26", "2026-10-25", "2026-10-25 23:00", "2026-10-26 07:00", inst("2026-10-26 01:00")));
  // Fall Back: Oct 31 23:00 shift still running at 01:30 PDT and at the repeated 01:30 PST.
  const fall = generated("2026-11-01", "2026-10-31", "2026-10-31 23:00", "2026-11-01 07:00", inst("2026-11-01 01:30"));
  assert.ok(fall);
  assert.equal((fall.end - fall.start) / 3600000, 9);
  // Spring Forward: shift lasts 7 hours and is still running at 03:30 PDT.
  const spring = generated("2026-03-08", "2026-03-07", "2026-03-07 23:00", "2026-03-08 07:00", inst("2026-03-08 03:30"));
  assert.ok(spring);
  assert.equal((spring.end - spring.start) / 3600000, 7);
});

test("detection still resolves the previous local day for the plant shift", () => {
  const detection = functionDefinition(migration, "public.get_scheduled_shift_at");
  assert.match(detection, /\(local_date - 1\)::timestamp/);
});

test("RPC execute grants are least-privilege and effective access is asserted", () => {
  assert.match(migration, /ARRAY\['anon', 'service_role'\]/);
  assert.match(migration, /has_function_privilege\(\s*role_row\.role_name, routine\.signature, 'EXECUTE'/);
  assert.match(migration, /'authenticated', routine\.signature, 'EXECUTE'/);
  assert.match(migration, /FROM PUBLIC, anon, service_role/);
  assert.match(migration, /quote_studio_schedule_private\.resolve_local_time/);
  assert.match(migration, /'SELECT', 'INSERT', 'UPDATE', 'DELETE',\s*'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN'/);
  assert.match(migration, /has_table_privilege\(\s*role_row\.role_name, table_row\.table_name, privilege_row\.privilege_name/);
  assert.match(migration, /ARRAY\['SELECT', 'INSERT', 'UPDATE', 'REFERENCES'\]/);
  assert.match(migration, /ARRAY\['CREATE', 'USAGE'\]/);
  assert.match(migration, /has_schema_privilege\(\s*role_row\.role_name, 'quote_studio_schedule_private', privilege_row\.privilege_name/);
  assert.match(migration, /server_version_num'\)::integer < 170000/);
});

test("schedule metadata and employee assignment rendering exclude other identities", () => {
  const detection = functionDefinition(migration, "public.get_scheduled_shift_at");
  const schedule = functionDefinition(migration, "public.get_shift_schedule");
  assert.doesNotMatch(detection, /employee_id|full_name|assignments/);
  assert.match(detection, /'name', CASE\s+WHEN instance\.schedule_kind = 'custom' THEN 'Custom scheduled shift'/);
  assert.doesNotMatch(detection, /'kind', instance\.schedule_kind|'name', instance\.name/);
  assert.match(schedule, /JOIN public\.profiles AS profile\s+ON profile\.id = auth\.uid\(\)/);
  assert.match(schedule, /assignment\.employee_id = auth\.uid\(\)/);
  assert.match(schedule, /quote_studio_schedule_private\.is_assigned\(instance\.id, auth\.uid\(\)\)/);
  assert.match(frontend, /Current plant shift:/);
});

test("Phase 1 migration leaves report, alert and inventory workflows untouched", () => {
  assert.doesNotMatch(migration, /(?:INSERT|UPDATE|DELETE|TRUNCATE)\s+(?:INTO\s+|FROM\s+)?public\.(?:shift_reports|shift_alerts|stock_movements|inventory)\b/i);
  assert.match(reportsMigration, /submit_shift_report/);
  assert.match(inventoryMigration, /submit_shift_report/);
  assert.match(inventoryMigration, /create_shift_alerts_after_report_submission/);
});

test("frontend maps migration, network, authorization, configuration and overlap errors safely", () => {
  assert.match(frontend, /code === "PGRST202"/);
  assert.match(frontend, /Could not reach the scheduling service/);
  assert.match(frontend, /You do not have permission for this scheduling action/);
  assert.match(frontend, /daylight-saving transition/);
  assert.match(frontend, /IANA time zone/);
  assert.match(frontend, /conflicts with another scheduled shift/);
  assert.match(frontend, /scheduleRpc\("materialize_shift_schedule"/);
  assert.match(frontend, /configuration or a previous time-zone cutover is pending/);
});

test("scheduling UI elements exist once and admin panel uses the existing role gate", () => {
  const referencedIds = new Set(
    [...`${frontend}\n${authFrontend}`.matchAll(/\$\("([A-Za-z][A-Za-z0-9]*)"\)/g)].map(
      ([, id]) => id,
    ),
  );
  const htmlIds = [...html.matchAll(/\bid="([^"]+)"/g)].map(([, id]) => id);
  const htmlIdSet = new Set(htmlIds);
  assert.deepEqual([...referencedIds].filter((id) => !htmlIdSet.has(id)), []);
  assert.equal(htmlIds.length, htmlIdSet.size);
  assert.match(authFrontend, /shiftSchedulingAdminPanel"\)\.classList\.toggle\("hidden", !isAdminRole\(\)\)/);
});
