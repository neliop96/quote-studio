const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");

const HOST = "127.0.0.1";
const PORT = 4173;
const STAGING_PROJECT_REF = "bzejwackkozoqqrxfnrz";
const PRODUCTION_CONFIG_ROUTE = "/js/supabase-config.production.js";
const PRODUCTION_CONFIG_TAG =
  '<script defer src="./js/supabase-config.production.js"></script>';
const STAGING_CONFIG_TAG =
  '<script defer src="./js/supabase-config.staging.local.js"></script>';

const FRONTEND_FILES = new Map([
  ["/index.html", "index.html"],
  ["/css/styles.css", "css/styles.css"],
  ["/assets/PrecisionAutomationLogos.png", "assets/PrecisionAutomationLogos.png"],
  ["/js/supabase-config.staging.local.js", "js/supabase-config.staging.local.js"],
  ["/js/core.js", "js/core.js"],
  ["/js/auth.js", "js/auth.js"],
  ["/js/catalog.js", "js/catalog.js"],
  ["/js/projects.js", "js/projects.js"],
  ["/js/estimates.js", "js/estimates.js"],
  ["/js/quotes.js", "js/quotes.js"],
  ["/js/shift-reports.js", "js/shift-reports.js"],
  ["/js/inventory.js", "js/inventory.js"],
  ["/js/navigation.js", "js/navigation.js"],
]);

const MIME_TYPES = new Map([
  [".css", "text/css; charset=utf-8"],
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".png", "image/png"],
]);

function configValue(source, name) {
  const match = new RegExp(`\\b${name}:\\s*"([^"]+)"`).exec(source);
  if (!match) throw new Error(`Staging Supabase config is missing ${name}.`);
  return match[1];
}

function validateStagingConfig(root) {
  const configPath = path.join(root, "js", "supabase-config.staging.local.js");
  const source = fs.readFileSync(configPath, "utf8");
  const environment = configValue(source, "environment");
  const projectRef = configValue(source, "projectRef");
  const url = configValue(source, "url");
  const publishableKey = configValue(source, "publishableKey");

  if (environment !== "staging" || projectRef !== STAGING_PROJECT_REF) {
    throw new Error(`Staging config must target project ${STAGING_PROJECT_REF}.`);
  }
  if (url !== `https://${STAGING_PROJECT_REF}.supabase.co`) {
    throw new Error("Staging Supabase URL does not match the required project.");
  }
  if (!/^sb_publishable_[A-Za-z0-9_-]+$/.test(publishableKey)) {
    throw new Error("Staging config must use a Supabase publishable key.");
  }
}

function createStagingServer(root = path.resolve(__dirname, "..")) {
  const resolvedRoot = fs.realpathSync(root);
  validateStagingConfig(resolvedRoot);

  const indexPath = path.join(resolvedRoot, "index.html");
  const index = fs.readFileSync(indexPath, "utf8");
  if (index.split(PRODUCTION_CONFIG_TAG).length - 1 !== 1) {
    throw new Error("Expected exactly one production config include in index.html.");
  }

  const stagingIndex = index.replace(PRODUCTION_CONFIG_TAG, STAGING_CONFIG_TAG);
  if (stagingIndex.includes(PRODUCTION_CONFIG_TAG)) {
    throw new Error("Production Supabase config include could not be removed.");
  }

  return http.createServer((request, response) => {
    if (request.method !== "GET" && request.method !== "HEAD") {
      response.writeHead(405, { Allow: "GET, HEAD" }).end();
      return;
    }

    let pathname;
    try {
      pathname = decodeURIComponent((request.url || "").split("?", 1)[0]);
    } catch {
      response.writeHead(404).end();
      return;
    }

    if (
      !pathname.startsWith("/") ||
      pathname.includes("\\") ||
      pathname.includes("\0") ||
      pathname.split("/").some((segment) => segment === "." || segment === "..")
    ) {
      response.writeHead(404).end();
      return;
    }
    if (pathname === "/") pathname = "/index.html";

    if (pathname === PRODUCTION_CONFIG_ROUTE) {
      response.writeHead(404).end();
      return;
    }

    const relativePath = FRONTEND_FILES.get(pathname);
    if (!relativePath) {
      response.writeHead(404).end();
      return;
    }

    let body;
    try {
      const filePath = path.join(resolvedRoot, relativePath);
      const realFilePath = fs.realpathSync(filePath);
      const relativeToRoot = path.relative(resolvedRoot, realFilePath);
      if (
        relativeToRoot === ".." ||
        relativeToRoot.startsWith(`..${path.sep}`) ||
        path.isAbsolute(relativeToRoot)
      ) {
        response.writeHead(404).end();
        return;
      }
      body = pathname === "/index.html"
        ? Buffer.from(stagingIndex)
        : fs.readFileSync(realFilePath);
    } catch (error) {
      if (error.code === "ENOENT") {
        response.writeHead(404).end();
        return;
      }
      console.error("Staging server failed to read an allowed frontend file:", error);
      response.writeHead(500).end();
      return;
    }

    response.writeHead(200, {
      "Cache-Control": "no-store",
      "Content-Type": MIME_TYPES.get(path.extname(relativePath)) || "application/octet-stream",
      "X-Content-Type-Options": "nosniff",
    });
    response.end(request.method === "HEAD" ? undefined : body);
  });
}

if (require.main === module) {
  const server = createStagingServer();
  server.once("error", (error) => {
    console.error(`Could not start Staging server at http://${HOST}:${PORT}/: ${error.message}`);
    process.exitCode = 1;
  });
  server.listen(PORT, HOST, () => {
    console.log(
      `Quote Studio Staging server connected to Supabase Staging project ${STAGING_PROJECT_REF}: http://${HOST}:${PORT}/`,
    );
  });
}

module.exports = { createStagingServer, HOST, PORT, STAGING_PROJECT_REF };
