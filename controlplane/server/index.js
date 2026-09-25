"use strict";
const http = require("node:http");
const path = require("node:path");
const fs = require("node:fs");
const { config } = require("./config");
const { Store } = require("./store");
const { deviceAuth } = require("./deviceAuth");
const { readBody, parseJSON } = require("./validate");
const { deviceRoutes } = require("./deviceRoutes");
const { operatorApi } = require("./operatorApi");
const { constantTimeEq } = require("./crypto");

async function main() {
  const cfg = config();
  if (!cfg.operatorToken) {
    console.error("[controlplane] OPERATOR_TOKEN is empty. Set it in .env (copy .env.example).");
    process.exit(1);
  }
  const store = new Store(cfg.dataDir);
  const releaseCtx = { releasePaths: require("./deviceRoutes").releasePaths };

  const dr = deviceRoutes({ store, cfg, wake: undefined, releasePaths: releaseCtx.releasePaths });
  const api = operatorApi({
    store, cfg,
    wake: (id) => id && dr.wakeDevice(id),
    releaseServiceCtx: releaseCtx,
  });

  // wire the deviceAuth middleware onto the raw-body-holding server
  const authDev = deviceAuth(store);

  const server = http.createServer(async (req, res) => {
    const u = new URL(req.url, `http://${req.headers.host || "localhost"}`);
    const p = u.pathname;
    const method = req.method || "GET";

    // read raw body once; devices need the exact bytes for HMAC, operators need JSON
    let rawBody = "";
    if (method === "POST" || method === "PUT") {
      try {
        rawBody = await readBody(req);
      } catch (e) {
        res.statusCode = e.status || 400;
        res.end(JSON.stringify({ error: e.message }));
        return;
      }
    }
    req.rawBody = rawBody;
    req.body = parseJSON(rawBody, "request body");
    req.urlNoQuery = p;
    // route matching helpers
    const route = matchRoute(method, p);
    if (!route) {
      return json(res, 404, { error: "not found" });
    }

    // --- public surface -----------------------------------------------------
    if (route.kind === "static" && route.arg === "index") {
      return sendFile(res, path.join(cfg.rootDir, "public", "index.html"), "text/html");
    }
    if (route.kind === "static" && route.arg === "agentd") {
      const p = path.join(cfg.rootDir, "agent", "agentd.lua");
      const body = fs.existsSync(p)
        ? fs.readFileSync(p, "utf8").split("__AGENT_BASE_URL__").join(cfg.agentBaseUrl.replace(/\/+$/, ""))
        : "-- agentd missing\n";
      return sendText(res, 200, body, "text/plain; charset=utf-8");
    }
    if (route.kind === "asset") {
      return sendFile(res, path.join(cfg.rootDir, "public", "assets", route.arg), mimeFor(route.arg));
    }
    if (route.kind === "bootstrap") {
      req.params = { token: route.arg };
      return dr.bootstrap(req, res, req.params);
    }
    if (route.kind === "release") {
      req.params = { id: route.arg[0], file: route.arg[1] };
      return dr.releaseFile(req, res, req.params);
    }

    // --- device surface (HMAC-signed) ----------------------------------------
    if (route.kind === "device") {
      try {
        if (!(await authDev(req, res, () => {}))) return;
        req.params = route.params || {};
        switch (route.arg) {
          case "poll": return dr.poll(req, res, req.params);
          case "register": return dr.register(req, res, req.params);
          case "commands/result": return dr.commandResult(req, res, req.params);
          case "release-status": return dr.releaseStatus(req, res, req.params);
          default: return json(res, 404, { error: "unknown device route" });
        }
      } catch (e) {
        return json(res, e.status || 500, { error: e.message });
      }
    }

    // --- operator surface (loopback + token) ----------------------------------
    if (route.kind === "operator") {
      if (!constantTimeEq(cfg.operatorToken, req.headers["x-operator-token"])) {
        return json(res, 401, { error: "operator token required" });
      }
      req.params = route.params || {};
      try {
        return await api.routes[route.arg].run(req, res, { params: req.params });
      } catch (e) {
        return json(res, e.status || 500, { error: e.message });
      }
    }

    json(res, 404, { error: "not found" });
  });

  server.on("listening", () => {
    console.log(`[controlplane] listening on ${cfg.bindHost}:${cfg.port}`);
    console.log(`[controlplane] AGENT_BASE_URL=${cfg.agentBaseUrl}`);
    console.log(`[controlplane] device ingress + releases served (HMAC), operator API + dashboard on bind host (token)`);
  });
  server.listen(cfg.port, cfg.bindHost);
}

function matchRoute(method, p) {
  if (method === "GET") {
    if (p === "/" || p === "/index.html") return { kind: "static", arg: "index" };
    if (p === "/agentd.lua") return { kind: "static", arg: "agentd" };
    const a = p.match(/^\/assets\/([^/]+)$/);
    if (a) return { kind: "asset", arg: decodeURIComponent(a[1]) };
    const b = p.match(/^\/bootstrap\/([0-9a-f]+)\/?$/i);
    if (b) return { kind: "bootstrap", arg: b[1] };
    const r = p.match(/^\/releases\/([0-9a-f]+)\/(.+)$/i);
    if (r) return { kind: "release", arg: [r[1], r[2]] };
  }
  if (method === "POST") {
    if (p === "/agent/poll") return { kind: "device", arg: "poll" };
    if (p === "/agent/register") return { kind: "device", arg: "register" };
    if (p === "/agent/release-status") return { kind: "device", arg: "release-status" };
    const c = p.match(/^\/agent\/commands\/([0-9a-f]+)\/result$/i);
    if (c) return { kind: "device", arg: "commands/result", params: { id: c[1] } };
  }
  // operator
  const opMatch = p.match(/^\/api\/(fleet|pairing|config|releases|deploy)$/);
  if (method === "GET" && opMatch) return { kind: "operator", arg: opMatch[1] };
  if ((method === "POST" || method === "PUT") && opMatch) return { kind: "operator", arg: opMatch[1] };
  if (method === "POST" && p === "/api/update") return { kind: "operator", arg: "update" };
  const opDev = p.match(/^\/api\/devices\/([0-9]+)\/?$/);
  if (method === "GET" && opDev) return { kind: "operator", arg: "devices/:id", params: { id: opDev[1] } };
  const opId = p.match(/^\/api\/devices\/([0-9]+)\/([a-z-]+)(?:\/([a-z-]+))?$/);
  if (opId && ["command", "commands", "reboot", "agent-update", "rollback", "rename", "delete", "change-id", "update"].includes(opId[2])) {
    return { kind: "operator", arg: `devices/:id/${opId[2]}`, params: { id: opId[1] } };
  }
  const opCmd = p.match(/^\/api\/commands\/([0-9a-f]+)$/i);
  if (method === "GET" && opCmd) return { kind: "operator", arg: "commands/:cid", params: { cid: opCmd[1] } };
  return null;
}

function json(res, status, body) {
  res.statusCode = status;
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify(body));
}

function sendFile(res, file, type) {
  if (!fs.existsSync(file)) {
    res.statusCode = 404;
    return res.end("not found");
  }
  res.statusCode = 200;
  res.setHeader("content-type", type);
  res.setHeader("cache-control", "no-store");
  res.end(fs.readFileSync(file));
}

function sendText(res, status, body, type) {
  res.statusCode = status;
  res.setHeader("content-type", type);
  res.setHeader("cache-control", "no-store");
  res.end(body);
}

function mimeFor(name) {
  const ext = path.extname(name).toLowerCase();
  if (ext === ".js") return "application/javascript; charset=utf-8";
  if (ext === ".css") return "text/css; charset=utf-8";
  if (ext === ".html") return "text/html; charset=utf-8";
  if (ext === ".json") return "application/json";
  if (ext === ".png") return "image/png";
  if (ext === ".svg") return "image/svg+xml";
  return "application/octet-stream";
}

module.exports = { main, matchRoute };

if (require.main === module) {
  main();
}