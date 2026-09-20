"use strict";
const path = require("node:path");
const fs = require("node:fs");

function loadEnvFile(file = path.join(__dirname, "..", ".env")) {
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !(m[1] in process.env)) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
}

function config() {
  loadEnvFile();
  const allowlist = (process.env.COMMAND_ALLOWLIST || "inspect,log.read,config.read,config.write,eval_lua,reboot,agent.update,release.deploy,release.rollback,monitor.capture")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);

  return {
    operatorToken: process.env.OPERATOR_TOKEN || "",
    agentBaseUrl: process.env.AGENT_BASE_URL || "http://127.0.0.1:8080",
    bindHost: process.env.BIND_HOST || "127.0.0.1",
    port: Number(process.env.PORT || 8080),
    pairingTtlSeconds: Number(process.env.PAIRING_TTL_SECONDS || 600),
    commandTtlSeconds: Number(process.env.COMMAND_TTL_SECONDS || 3600),
    commandAllowlist: allowlist,
    dataDir: path.resolve(process.env.DATA_DIR || path.join(__dirname, "..", "data")),
    evalLuaEnabled: (process.env.EVAL_LUA_ENABLED || "0") === "1",
    healthTimeoutSeconds: Number(process.env.HEALTH_TIMEOUT_SECONDS || 60),
    rootDir: path.join(__dirname, ".."),
  };
}

module.exports = { config };