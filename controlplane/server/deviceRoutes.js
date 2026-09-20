"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { safeRelPath } = require("./validate");

// Wire the device-facing HTTP surface. Every POST here is HMAC-signed and
// sequence-checked by `deviceAuth`. The only unauthenticated reads are:
//   GET /agentd.lua            (generic bootstrap helper, public)
//   GET /bootstrap/:token      (token bearer - one-time, TTL-limited)
//   GET /releases/<id>/<file>  (content-derived id, unguessable)
// Nothing else on this surface is worth talking to.

function deviceRoutes(ctx) {
  const { store, cfg, wake } = ctx;

  function waiters() {
    if (!ctx._waiters) ctx._waiters = new Set();
    return ctx._waiters;
  }

  // Called by the operator layer when a new command is enqueued for `deviceId`.
  function wakeDevice(deviceId) {
    for (const w of waiters()) {
      if (!deviceId || w.id === deviceId) {
        waiters().delete(w);
        clearTimeout(w.t);
        w.fn();
      }
    }
  }

  function hasPending(agentId) {
    return Object.values(store.commands[agentId] || {}).some(
      (c) => c.status === "pending" && (c.createdAt + (c.ttl || cfg.commandTtlSeconds) * 1000) > Date.now()
    );
  }

  function pendingFor(agentId) {
    return Object.entries(store.commands[agentId] || {})
      .filter(([, c]) => c.status === "pending")
      .filter(([, c]) => (c.createdAt + (c.ttl || cfg.commandTtlSeconds) * 1000) > Date.now())
      .map(([cid, c]) => ({ cid, type: c.type, payload: c.payload }));
  }

  async function poll(req, res, params) {
    // Long-poll up to ~25 s so agents get commands near-instantly.
    await new Promise((done) => {
      if (hasPending(req.agentId)) return done();
      const w = { id: req.agentId, fn: done, t: setTimeout(done, 25000) };
      waiters().add(w);
    });
    replyJson(req, res, 200, { commands: pendingFor(req.agentId) });
  }

  // POST /agent/register - agent confirms/updates its label+version once known.
  async function register(req, res) {
    const body = JSON.parse(req.rawBody || "{}");
    const dev = store.devices[req.agentId];
    // Never overwrite a name the operator set via the dashboard.
    if (dev.labelSource !== "operator") {
      dev.label = typeof body.label === "string" ? body.label.slice(0, 120) : undefined;
      dev.labelSource = "agent";
    }
    dev.agentVersion = typeof body.version === "string" ? body.version.slice(0, 40) : undefined;
    store.persistDevices();
    replyJson(req, res, 200, { ok: true });
  }

  // POST /agent/commands/:id/result
  async function commandResult(req, res, params) {
    const cid = params.id;
    const body = safeJSON(req.rawBody || "{}");
    const cmds = store.commands[req.agentId] || {};
    const c = cmds[cid];
    if (!c) return replyJson(req, res, 404, { error: "unknown command id" });
    if (c.status === "pending") {
      c.status = body.status === "error" ? "error" : "done";
      c.result = body.result;
      c.completedAt = Date.now();
      store.persistCommands();
    }
    replyJson(req, res, 200, { ok: true });
  }

  // POST /agent/commands/:id/result-shortcut is omitted; keep surface minimal.

  // POST /agent/release-status
  async function releaseStatus(req, res, params) {
    const body = safeJSON(req.rawBody || "{}");
    const dev = store.devices[req.agentId];
    const releaseId = typeof body.releaseId === "string" ? body.releaseId : "";
    const state = String(body.state || "");
    if (!/^(pending|healthy|failed|rolled_back)$/.test(state)) return replyJson(req, res, 400, { error: "bad state" });
    if (!dev.releases) dev.releases = {};
    dev.releases[releaseId] = { state, at: Date.now() };
    store.persistDevices();
    replyJson(req, res, 200, { ok: true });
  }

  // GET /bootstrap/:token - bearer one-time token, TTL-bounded
  async function bootstrap(req, res, params) {
    const token = params.token;
    const rec = store.pairing[token];
    if (!rec || rec.expiresAt < Date.now()) return replyJson(req, res, 401, { error: "invalid or expired token" });
    const dev = store.devices[rec.deviceId];
    if (!dev) return replyJson(req, res, 404, { error: "no device" });
    delete store.pairing[token];
    store.persistPairing();
    replyJson(req, res, 200, {
      deviceId: rec.deviceId,
      secret: dev.secret,
      seq: dev.seq + 1,
      agentBaseUrl: cfg.agentBaseUrl,
      pollSeconds: 25,
      evalLuaEnabled: cfg.evalLuaEnabled,
    });
  }

  // GET /agentd.lua
  function agentd(req, res) {
    const p = path.join(cfg.rootDir, "agent", "agentd.lua");
    const body = (fs.existsSync(p) ? fs.readFileSync(p, "utf8") : "-- agentd missing\n")
      .split("__AGENT_BASE_URL__").join(cfg.agentBaseUrl.replace(/\/+$/, ""));
    res.statusCode = 200;
    res.setHeader("content-type", "text/plain; charset=utf-8");
    res.setHeader("cache-control", "no-store");
    res.end(body);
  }

  // GET /releases/:releaseId/:file...
  function releaseFile(req, res, params) {
    try {
      const target = ctx.releasePaths.resolve(cfg, params.id, params.file);
      res.statusCode = 200;
      res.setHeader("content-type", "text/plain; charset=utf-8");
      res.end(fs.readFileSync(target));
    } catch (e) {
      res.statusCode = e.status || 404;
      res.end(JSON.stringify({ error: e.message }));
    }
  }

  return { poll, register, commandResult, releaseStatus, bootstrap, agentd, releaseFile, waiters, wakeDevice, hasPending, pendingFor };
}

function replyJson(req, res, status, body) {
  res.statusCode = status;
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify(body));
}

function safeJSON(raw) {
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

// Resolver for release file paths (traversal-guarded).
const releasePaths = {
  resolve(cfg, releaseId, rawPath) {
    const rel = safeRelPath(rawPath || "manifest.json");
    const root = path.join(cfg.rootDir, "releases");
    const base = path.resolve(root, releaseId);
    const target = path.resolve(base, rel);
    if (!target.startsWith(base + path.sep) && target !== base) {
      const e = new Error("forbidden");
      e.status = 403;
      throw e;
    }
    if (!fs.existsSync(target) || !fs.statSync(target).isFile()) {
      const e = new Error("not found");
      e.status = 404;
      throw e;
    }
    return target;
  },
};

module.exports = { deviceRoutes, releasePaths, replyJson, safeJSON };