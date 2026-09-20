"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { readJSON, writeJSON } = require("./validate");

// Tiny JSON-file store. Persistence is atomic (tmp + rename) so sequences,
// commands and config survive crashes without corruption. All writes are
// synchronous and debounced where irrelevant - small local single-writer.
class Store {
  constructor(dataDir) {
    this.dir = dataDir;
    fs.mkdirSync(this.dir, { recursive: true });
    this.devicesPath = path.join(this.dir, "devices.json");
    this.commandsPath = path.join(this.dir, "commands.json");
    this.pairingPath = path.join(this.dir, "pairing.json");
    this.configPath = path.join(this.dir, "desired_state.json");
    this.releasesPath = path.join(this.dir, "releases.json");

    this.devices = readJSON(this.devicesPath, {}); // id -> {secret,label,seq,lastSeen,releases,role}
    this.commands = readJSON(this.commandsPath, {}); // deviceId -> { cid -> {type,payload,createdAt,ttl,status,result,claimedBy}}
    this.pairing = readJSON(this.pairingPath, {}); // token -> {deviceId,createdAt,expiresAt}
    this.releases = readJSON(this.releasesPath, {}); // releaseId -> manifest
  }

  persistDevices() {
    writeJSON(this.devicesPath, this.devices);
  }
  persistCommands() {
    writeJSON(this.commandsPath, this.commands);
  }
  persistPairing() {
    writeJSON(this.pairingPath, this.pairing);
  }
  persistReleases() {
    writeJSON(this.releasesPath, this.releases);
  }
  persistConfig(cfg) {
    writeJSON(this.configPath, cfg);
  }

  loadDesiredState() {
    const def = { devices: {}, installations: {} };
    if (!fs.existsSync(this.configPath)) {
      this.persistConfig(def);
    }
    return readJSON(this.configPath, def);
  }
}

module.exports = { Store };