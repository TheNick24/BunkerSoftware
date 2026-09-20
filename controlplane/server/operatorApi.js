"use strict";
const { randomToken } = require("./crypto");
const { buildRelease, persistRelease } = require("./releaseService");
const { replyJson } = require("./deviceRoutes");

function operatorApi(ctx) {
  const { store, cfg, wake, releaseServiceCtx } = ctx;

  const ALLOWED = new Set(cfg.commandAllowlist);

  function enqueue(deviceId, type, payload, opts = {}) {
    if (!ALLOWED.has(type)) {
      const e = new Error(`command type not allowed: ${type}`);
      e.status = 403;
      throw e;
    }
    if (type === "eval_lua" && !cfg.evalLuaEnabled) {
      const e = new Error("eval_lua is disabled on this server");
      e.status = 403;
      throw e;
    }
    if (!store.devices[deviceId]) {
      const e = new Error("unknown device");
      e.status = 404;
      throw e;
    }
    const cid = randomToken(16);
    const ttl = opts.ttl || cfg.commandTtlSeconds;
    if (!store.commands[deviceId]) store.commands[deviceId] = {};
    store.commands[deviceId][cid] = {
      id: cid,
      type,
      payload: payload || {},
      createdAt: Date.now(),
      ttl,
      status: "pending",
    };
    store.persistCommands();
    wake(deviceId);
    return cid;
  }

  // ---- fleet ---------------------------------------------------------------
  function fleet() {
    return Object.entries(store.devices).map(([id, d]) => ({
      id,
      label: d.label || null,
      lastSeen: d.lastSeen || null,
      seq: d.seq,
      releases: d.releases || {},
    }));
  }

  function deviceDetail(id) {
    const d = store.devices[id];
    if (!d) return null;
    const cmds = Object.values(store.commands[id] || {}).sort((a, b) => a.createdAt - b.createdAt);
    return {
      id,
      label: d.label || null,
      agentVersion: d.agentVersion || null,
      lastSeen: d.lastSeen || null,
      seq: d.seq,
      releases: d.releases || {},
      recentCommands: cmds.slice(-20),
    };
  }

  // ---- routing --------------------------------------------------------------
  const routes = {
    // GET /api/fleet
    fleet: { auth: true, run: async (req, res, m) => replyJson(req, res, 200, fleet()) },

    // GET /api/devices/:id
    "devices/:id": {
      auth: true,
      run: async (req, res, m) => {
        const d = deviceDetail(m.params.id);
        if (!d) return replyJson(req, res, 404, { error: "no such device" });
        replyJson(req, res, 200, d);
      },
    },

    // GET /api/devices/:id/commands
    "devices/:id/commands": {
      auth: true,
      run: async (req, res, m) => {
        const all = Object.values(store.commands[m.params.id] || {});
        replyJson(req, res, 200, all);
      },
    },

    // GET /api/commands/:cid  (also used by MCP bounded wait)
    "commands/:cid": {
      auth: true,
      run: async (req, res, m) => {
        for (const dev of Object.values(store.commands)) {
          if (dev[m.params.cid]) return replyJson(req, res, 200, dev[m.params.cid]);
        }
        replyJson(req, res, 404, { error: "no such command" });
      },
    },

    // POST /api/devices/:id/command  body: {type, payload}
    "devices/:id/command": {
      auth: true,
      run: async (req, res, m) => {
        const body = req.body || {};
        if (!body.type || typeof body.type !== "string") return replyJson(req, res, 400, { error: "type required" });
        try {
          const cid = enqueue(m.params.id, body.type, body.payload || {});
          replyJson(req, res, 200, { cid, id: cid });
        } catch (e) {
          replyJson(req, res, e.status || 400, { error: e.message });
        }
      },
    },

    // POST /api/pairing  body: {deviceId, label?}
    pairing: {
      auth: true,
      run: async (req, res) => {
        const body = req.body || {};
        const deviceId = String(body.deviceId || "");
        if (!/^[0-9]+$/.test(deviceId)) return replyJson(req, res, 400, { error: "deviceId must be a number" });
        if (!store.devices[deviceId]) {
          store.devices[deviceId] = {
            id: deviceId,
            label: typeof body.label === "string" ? body.label.slice(0, 120) : `cc${deviceId}`,
            labelSource: typeof body.label === "string" && body.label ? "operator" : "agent",
            secret: randomToken(32),
            seq: 0,
            lastSeen: null,
            releases: {},
          };
          store.persistDevices();
        }
        const token = randomToken(24);
        store.pairing[token] = { deviceId, createdAt: Date.now(), expiresAt: Date.now() + cfg.pairingTtlSeconds * 1000 };
        store.persistPairing();
        const base = cfg.agentBaseUrl.replace(/\/$/, "");
        replyJson(req, res, 200, {
          token,
          expiresAt: store.pairing[token].expiresAt,
          bootstrapCommand: `wget run ${base}/agentd.lua ${deviceId} ${token}`,
          deviceId,
        });
      },
    },

    // POST /api/devices/:id/rename  body: {label}
    "devices/:id/rename": {
      auth: true,
      run: async (req, res, m) => {
        const dev = store.devices[m.params.id];
        if (!dev) return replyJson(req, res, 404, { error: "no such device" });
        const label = String(((req.body || {}).label) || "").trim().slice(0, 120);
        if (!label) return replyJson(req, res, 400, { error: "label required" });
        dev.label = label;
        dev.labelSource = "operator";
        store.persistDevices();
        replyJson(req, res, 200, { ok: true, label });
      },
    },

    // POST /api/devices/:id/change-id  body: {newId}
    // Creates the computer under a new id (label/secret history kept) and
    // issues a fresh pairing token, because the resident agent must be
    // re-bootstrapped to use the new id.
    "devices/:id/change-id": {
      auth: true,
      run: async (req, res, m) => {
        const old = store.devices[m.params.id];
        if (!old) return replyJson(req, res, 404, { error: "no such device" });
        const newId = String(((req.body || {}).newId) || "").trim();
        if (!/^[0-9]+$/.test(newId)) return replyJson(req, res, 400, { error: "newId must be a number" });
        if (newId === m.params.id) return replyJson(req, res, 200, { deviceId: newId, note: "id unchanged" });
        if (store.devices[newId]) return replyJson(req, res, 409, { error: "a device with that id already exists" });
        store.devices[newId] = Object.assign({}, old, { id: newId });
        delete store.devices[m.params.id];
        store.persistDevices();
        if (store.commands[m.params.id]) {
          store.commands[newId] = store.commands[m.params.id];
          delete store.commands[m.params.id];
          store.persistCommands();
        }
        const token = randomToken(24);
        store.pairing[token] = { deviceId: newId, createdAt: Date.now(), expiresAt: Date.now() + cfg.pairingTtlSeconds * 1000 };
        store.persistPairing();
        const base = cfg.agentBaseUrl.replace(/\/$/, "");
        replyJson(req, res, 200, {
          deviceId: newId,
          token,
          expiresAt: store.pairing[token].expiresAt,
          note: "re-run the bootstrap on the computer with its new id",
          bootstrapCommand: `wget run ${base}/agentd.lua ${newId} ${token}`,
        });
      },
    },

    // POST /api/devices/:id/delete
    "devices/:id/delete": {
      auth: true,
      run: async (req, res, m) => {
        const id = m.params.id;
        if (!store.devices[id]) return replyJson(req, res, 404, { error: "no such device" });
        delete store.devices[id];
        if (store.commands[id]) { delete store.commands[id]; store.persistCommands(); }
        for (const t of Object.keys(store.pairing)) {
          if (store.pairing[t].deviceId === id) delete store.pairing[t];
        }
        store.persistDevices();
        store.persistPairing();
        replyJson(req, res, 200, { ok: true, deleted: id });
      },
    },

    // GET /api/releases
    releases: {
      auth: true,
      run: async (req, res) => {
        replyJson(req, res, 200, { releases: store.releases || {} });
      },
    },

    // POST /api/deploy  body: {deviceId, role, installation}
    deploy: {
      auth: true,
      run: async (req, res) => {
        const body = req.body || {};
        const { deviceId, role, installation } = body;
        if (!store.devices[deviceId]) return replyJson(req, res, 404, { error: "unknown device" });
        try {
          const manifest = buildRelease({ rootDir: cfg.rootDir, role, installation });
          persistRelease({ rootDir: cfg.rootDir, manifest });
          if (!store.releases[manifest.releaseId]) {
            store.releases[manifest.releaseId] = {
              role,
              installation,
              created: manifest.created,
              files: manifest.files,
            };
            store.persistReleases();
          }
          const cid = enqueue(deviceId, "release.deploy", {
            releaseId: manifest.releaseId,
            manifestUrl: `${cfg.agentBaseUrl.replace(/\/$/, "")}/releases/${manifest.releaseId}/manifest.json`,
            healthTimeoutSeconds: cfg.healthTimeoutSeconds,
          });
          replyJson(req, res, 200, { cid, releaseId: manifest.releaseId, files: manifest.files.length });
        } catch (e) {
          replyJson(req, res, 400, { error: e.message });
        }
      },
    },

    // POST /api/devices/:id/reboot | :id/agent-update | :id/rollback (convenience)
    "devices/:id/reboot": { auth: true, run: cmd("reboot") },
    "devices/:id/agent-update": { auth: true, run: cmd("agent.update") },
    "devices/:id/rollback": { auth: true, run: cmd("release.rollback") },

    // GET /api/config, PUT /api/config
    config: {
      auth: true,
      run: async (req, res) => {
        if (req.method === "GET") return replyJson(req, res, 200, store.loadDesiredState());
        const body = req.body || {};
        const cfgOk = validateDesiredState(body, cfg.rootDir);
        if (!cfgOk.ok) return replyJson(req, res, 400, { error: cfgOk.error });
        store.persistConfig(body);
        replyJson(req, res, 200, { ok: true });
      },
    },
  };

  function cmd(type) {
    return async (req, res, m) => {
      try {
        const cid = enqueue(m.params.id, type, {});
        replyJson(req, res, 200, { cid, id: cid });
      } catch (e) {
        replyJson(req, res, e.status || 400, { error: e.message });
      }
    };
  }

  return { routes, enqueue };
}

function validateDesiredState(cfg, rootDir) {
  const { existsSync } = require("node:fs");
  const path = require("node:path");
  if (typeof cfg !== "object" || !cfg) return { ok: false, error: "config must be an object" };
  if (cfg.devices && typeof cfg.devices !== "object") return { ok: false, error: "devices must be an object" };
  for (const [id, v] of Object.entries(cfg.devices || {})) {
    if (!/^[0-9]+$/.test(id)) return { ok: false, error: `bad device id ${id}` };
    if (!v || typeof v.role !== "string" || typeof v.installation !== "string") {
      return { ok: false, error: `device ${id}: role+installation required` };
    }
    if (!existsSync(path.join(rootDir, "subsystem", v.role)) && v.role !== "none") {
      return { ok: false, error: `device ${id}: unknown role ${v.role}` };
    }
    if (!existsSync(path.join(rootDir, "installation", v.installation))) {
      return { ok: false, error: `device ${id}: unknown installation ${v.installation}` };
    }
  }
  return { ok: true };
}

module.exports = { operatorApi, validateDesiredState };