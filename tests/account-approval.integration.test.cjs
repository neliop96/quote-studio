const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const path = require("node:path");

const connectionString = process.env.LOCAL_SUPABASE_DB_URL;

test(
  "account approval PostgreSQL integration checks run only against local Supabase",
  { skip: !connectionString && "Set LOCAL_SUPABASE_DB_URL to run real PostgreSQL integration tests." },
  () => {
    const connection = new URL(connectionString);
    assert.ok(["postgres:", "postgresql:"].includes(connection.protocol), "Use a PostgreSQL URL");
    assert.ok(
      ["127.0.0.1", "[::1]"].includes(connection.hostname),
      "Refusing a non-loopback database host",
    );
    assert.equal(connection.port, "54322", "Refusing a database port other than local Supabase 54322");
    assert.equal(decodeURIComponent(connection.username), "postgres", "Use the local postgres role");
    assert.equal(connection.pathname, "/postgres", "Use the local postgres database");

    const fixtureIds = {
      approved_owner_id: process.env.LOCAL_TEST_APPROVED_OWNER_ID,
      approved_admin_id: process.env.LOCAL_TEST_APPROVED_ADMIN_ID,
      approved_employee_id: process.env.LOCAL_TEST_APPROVED_EMPLOYEE_ID,
      pending_user_id: process.env.LOCAL_TEST_PENDING_USER_ID,
    };
    for (const [name, value] of Object.entries(fixtureIds)) {
      assert.match(value || "", /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, `${name} must be a local fixture UUID`);
    }

    const version = spawnSync("psql", ["--version"], { encoding: "utf8" });
    assert.equal(version.status, 0, "psql must be installed to run PostgreSQL integration tests");

    const env = {
      ...process.env,
      PGHOST: connection.hostname.replace(/^\[|\]$/g, ""),
      PGPORT: connection.port,
      PGUSER: decodeURIComponent(connection.username),
      PGDATABASE: connection.pathname.slice(1),
      PGSSLMODE: "disable",
    };
    delete env.LOCAL_SUPABASE_DB_URL;
    if (connection.password) env.PGPASSWORD = decodeURIComponent(connection.password);

    const script = path.join(__dirname, "account-approval.integration.sql");
    const args = ["-X", "--set=ON_ERROR_STOP=1"];
    for (const [name, value] of Object.entries(fixtureIds)) args.push(`--set=${name}=${value}`);
    args.push("--file", script);
    const result = spawnSync("psql", args, { encoding: "utf8", env });
    assert.equal(
      result.status,
      0,
      `PostgreSQL integration checks failed.\n${result.stdout || ""}${result.stderr || ""}`,
    );
  },
);
