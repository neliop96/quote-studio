const assert = require("node:assert/strict");
const test = require("node:test");
const { createStagingServer, HOST } = require("../scripts/serve-staging.cjs");

test("Staging server serves the Staging config and blocks LIVE config and sensitive files", async (t) => {
  const server = createStagingServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, HOST, resolve);
  });
  t.after(() => new Promise((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
  }));

  const address = server.address();
  const origin = `http://${HOST}:${address.port}`;
  const [page, stagingConfig, productionConfig] = await Promise.all([
    fetch(`${origin}/`),
    fetch(`${origin}/js/supabase-config.staging.local.js`),
    fetch(`${origin}/js/supabase-config.production.js`),
  ]);
  const pageHtml = await page.text();
  const stagingSource = await stagingConfig.text();

  assert.equal(page.status, 200);
  assert.match(pageHtml, /supabase-config\.staging\.local\.js/);
  assert.doesNotMatch(pageHtml, /supabase-config\.production\.js/);
  assert.equal(stagingConfig.status, 200);
  assert.match(stagingSource, /projectRef:\s*"bzejwackkozoqqrxfnrz"/);
  assert.equal(productionConfig.status, 404);

  for (const route of [
    "/.git/config",
    "/.env",
    "/supabase/migrations/20261029010000_estimate_drafts_revisions.sql",
    "/js/supabase-config.staging.template.js",
    "/js/supabase-config.staging.local.js/../../.env",
    "/%2e%2e/.env",
  ]) {
    assert.equal((await fetch(`${origin}${route}`)).status, 404, route);
  }
});
