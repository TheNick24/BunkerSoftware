"use strict";
// BunkerSoftware controlplane - MCP server (stdio).
//
// Minimal Model Context Protocol server (JSON-RPC 2.0 over stdin/stdout,
// newline-delimited) that fronts the controlplane operator API. It talks to
// the running controlplane HTTP server on loopback, so it must be launched
// on the same machine (or pointed elsewhere via CONTROLPLANE_BASE_URL).
//
//   OPERATOR_TOKEN   from controlplane/.env (auto-loaded)
//   CONTROLPLANE_BASE_URL  override, default http://127.0.0.1:8080
//
// Run via:  npm run mcp
// Client config (e.g. ~/.config/<client>/mcp.json):
//   { "mcpServers": { "bunker": { "command": "node",
//       "args": ["G:/Everbuild/0_Kotlin/BunkerSoftware/controlplane/mcp/index.js"] } } }
const path = require("node:path");
const fs = require("node:fs");
const readline = require("node:readline");

function loadEnvFile(file = path.join(__dirname, "..", ".env")) {
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !(m[1] in process.env)) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
}
loadEnvFile();

const TOKEN = process.env.OPERATOR_TOKEN || "";
const BASE_URL = (process.env.CONTROLPLANE_BASE_URL || `http://${process.env.BIND_HOST || "127.0.0.1"}:${process.env.PORT || 8080}`).replace(/\/+$/, "");

const SERVER = { name: "controlplane-mcp", version: "0.1.0" };
const PROTOCOL_VERSION = "2025-03-26";

if (!TOKEN) {
  console.error("[controlplane-mcp] OPERATOR_TOKEN missing (set it in controlplane/.env)");
  process.exit(1);
}

// ---------------------------------------------------------------- HTTP API --
async function api(method, urlPath, body) {
  const opts = {
    method,
    headers: { "x-operator-token": TOKEN },
  };
  if (body !== undefined) {
    opts.headers["content-type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  const r = await fetch(BASE_URL + urlPath, opts);
  const text = await r.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!r.ok) {
    const e = new Error((data && data.error) || `HTTP ${r.status}`);
    e.status = r.status;
    throw e;
  }
  return data;
}

async function waitForCommand(cid, seconds) {
  const end = Date.now() + seconds * 1000;
  for (;;) {
    const c = await api("GET", `/api/commands/${cid}`);
    if (!c) throw new Error(`command ${cid} not found`);
    if (c.status === "done") return c;
    if (c.status === "error") throw new Error(`command ${cid} error: ${c.result != null ? JSON.stringify(c.result) : "unknown"}`);
    if (Date.now() >= end) throw new Error(`command ${cid} still pending after ${seconds}s`);
    await new Promise((res) => setTimeout(res, 1500));
  }
}

async function sendCommandTool(args, waitFor) {
  const deviceId = String((args && args.id) ?? (args && args.deviceId) ?? "");
  if (!/^[0-9]+$/.test(deviceId)) throw new Error("id must be a number");
  if (!args.type) throw new Error("type required");
  const payload = args.payload || {};
  const r = await api("POST", `/api/devices/${deviceId}/command`, { type: args.type, payload });
  const seconds = waitFor == null ? 0 : Number(waitFor);
  if (seconds > 0) {
    const c = await waitForCommand(r.cid, seconds);
    return { cid: r.cid, status: c.status, result: c.result };
  }
  return { cid: r.cid, status: "pending" };
}

// ------------------------------------------------------------------- tools --
const TOOLS = [
  {
    name: "list_fleet",
    description: "List all paired computers with label, last-seen, sequence and their installed releases.",
    inputSchema: { type: "object", properties: {} },
    run: async () => api("GET", "/api/fleet"),
  },
  {
    name: "get_device",
    description: "Details for one computer (label, agent version, releases, recent commands).",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string", description: "computer id, e.g. 10" } },
      required: ["id"],
    },
    run: async (args) => {
      if (!/^[0-9]+$/.test(String(args.id || ""))) throw new Error("id must be a number");
      const d = await api("GET", `/api/devices/${args.id}`);
      return d;
    },
  },
  {
    name: "list_commands",
    description: "All recorded commands for one computer (id, type, status, result).",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string", description: "computer id, e.g. 10" } },
      required: ["id"],
    },
    run: async (args) => {
      if (!/^[0-9]+$/.test(String(args.id || ""))) throw new Error("id must be a number");
      return api("GET", `/api/devices/${args.id}/commands`);
    },
  },
  {
    name: "get_command",
    description: "Look up a single command by id (cid) and its current status/result.",
    inputSchema: {
      type: "object",
      properties: { cid: { type: "string", description: "command id" } },
      required: ["cid"],
    },
    run: async (args) => {
      if (!args.cid) throw new Error("cid required");
      return api("GET", `/api/commands/${args.cid}`);
    },
  },
  {
    name: "send_command",
    description: "Enqueue an arbitrary command on a computer (inspect, reboot, config.read, eval_lua, etc.).",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "computer id, e.g. 10" },
        type: { type: "string", description: "command type (must be on the allowlist)" },
        payload: { type: "object", description: "command payload as object" },
        wait_seconds: { type: "number", description: "poll until done/error for up to this many seconds (0 = fire and forget)" },
      },
      required: ["id", "type"],
    },
    run: async (args) => sendCommandTool(args, args.wait_seconds),
  },
  {
    name: "peripherals",
    description: "List all peripherals of one computer with their type and available methods (monitors also get size/text scale).",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "computer id, e.g. 10" },
        side: { type: "string", description: "optional: restrict to one side (e.g. left, monitor_4)" },
        wait_seconds: { type: "number", description: "timeout in seconds (default 60)" },
      },
      required: ["id"],
    },
    run: async (args) => {
      if (!/^[0-9]+$/.test(String(args.id || ""))) throw new Error("id must be a number");
      const side = args.side ? String(args.side) : "";
      const r = await sendCommandTool({ id: args.id, type: "peripherals", payload: side ? { side } : {} }, args.wait_seconds == null ? 60 : args.wait_seconds);
      return { computerId: r.result && r.result.computerId, label: r.result && r.result.label, peripherals: r.result && r.result.peripherals };
    },
  },
  {
    name: "deploy_release",
    description: "Build a release for a role+installation and deploy it to a computer (waits for install result).",
    inputSchema: {
      type: "object",
      properties: {
        deviceId: { type: "string", description: "computer id" },
        role: { type: "string", description: "release role (subsystem folder), e.g. controlserver" },
        installation: { type: "string", description: "installation (installation folder), e.g. base" },
        wait_seconds: { type: "number", description: "default 60" },
      },
      required: ["deviceId", "role", "installation"],
    },
    run: async (args) => {
      const r = await api("POST", "/api/deploy", {
        deviceId: String(args.deviceId),
        role: String(args.role),
        installation: String(args.installation),
      });
      const seconds = args.wait_seconds == null ? 60 : Number(args.wait_seconds);
      const c = await waitForCommand(r.cid, seconds);
      return { cid: r.cid, releaseId: r.releaseId, files: r.files, status: c.status, result: c.result };
    },
  },
];

const TOOLS_BY_NAME = new Map(TOOLS.map((t) => [t.name, t]));

// ---------------------------------------------------------------- MCP core --
function respond(id, result, isError) {
  const msg = { jsonrpc: "2.0", id };
  if (isError) msg.error = { code: -32000, message: typeof result === "string" ? result : JSON.stringify(result) };
  else msg.result = result;
  process.stdout.write(JSON.stringify(msg) + "\n");
}

async function handleRequest(req) {
  if (!req || typeof req !== "object") return;
  const { id, method, params } = req;
  const isNotif = id === undefined || id === null;

  try {
    switch (method) {
      case "initialize": {
        const res = {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: { listChanged: false } },
          serverInfo: SERVER,
          instructions: "Controlplane operator tools. Use peripherals to inspect a computer's attached peripherals and their methods.",
        };
        if (!isNotif) respond(id, res);
        return;
      }
      case "notifications/initialized":
      case "notifications/cancelled":
        return;
      case "ping":
        if (!isNotif) respond(id, {});
        return;
      case "tools/list": {
        const res = { tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) };
        if (!isNotif) respond(id, res);
        return;
      }
      case "tools/call": {
        const p = params || {};
        const tool = TOOLS_BY_NAME.get(p.name);
        if (!tool) return respond(id, `unknown tool: ${p.name}`, true);
        try {
          const out = await tool.run(p.arguments || {});
          const text = typeof out === "string" ? out : JSON.stringify(out, null, 2);
          respond(id, {
            content: [{ type: "text", text }],
            structuredContent: out,
            isError: false,
          }, false);
        } catch (e) {
          respond(id, { content: [{ type: "text", text: e.message }], isError: true }, false);
        }
        return;
      }
      case "shutdown":
        if (!isNotif) respond(id, null);
        process.exit(0);
        return;
      default:
        if (!isNotif) respond(id, { code: -32601, message: `method not found: ${method}` }, true);
    }
  } catch (e) {
    if (!isNotif) respond(id, e.message || String(e), true);
  }
}

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", (line) => {
  const t = line.trim();
  if (!t) return;
  let req;
  try { req = JSON.parse(t); } catch { return; }
  handleRequest(req).catch((e) => respond(req.id, e.message || String(e), true));
});
rl.on("close", () => setTimeout(() => process.exit(0), 5000));
process.on("SIGINT", () => process.exit(0));
process.on("SIGTERM", () => process.exit(0));

console.error(`[controlplane-mcp] ${SERVER.name} ${SERVER.version} -> ${BASE_URL}`);