"use strict";
const path = require("node:path");
const fs = require("node:fs");

// --- request size limits -----------------------------------------------------
const MAX_BODY = 256 * 1024; // 256 KiB, includes agent logs/inspect payloads

function readBody(req, limit = MAX_BODY) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) {
        reject(Object.assign(new Error("payload too large"), { status: 413 }));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", (e) => reject(e));
  });
}

function parseJSON(raw, what) {
  if (raw == null || raw === "") return {};
  try {
    return JSON.parse(raw);
  } catch {
    const err = new Error(`invalid JSON in ${what}`);
    err.status = 400;
    throw err;
  }
}

// --- secret-safe settings loader --------------------------------------------
function boolish(v) {
  return v === true || v === "1" || v === "true" || v === "yes";
}

// --- filesystem safety --------------------------------------------------------
function safeRelPath(input) {
  if (typeof input !== "string" || input.length === 0) {
    const e = new Error("empty path");
    e.status = 400;
    throw e;
  }
  if (input.includes("\0") || input.includes("\\") || input.split("/").includes("..") || input.startsWith("/")) {
    const e = new Error("invalid path");
    e.status = 400;
    throw e;
  }
  return input;
}

function resolveInside(baseDir, rel) {
  const target = path.resolve(baseDir, rel);
  const base = path.resolve(baseDir);
  if (target !== base && !target.startsWith(base + path.sep)) {
    const e = new Error("path escapes its root");
    e.status = 403;
    throw e;
  }
  return target;
}

// Bounded JSON read/write with atomic replacement (tmp + rename).
function readJSON(file, fallback) {
  try {
    const raw = fs.readFileSync(file, "utf8");
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
}

function writeJSON(file, data) {
  const tmp = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
  fs.renameSync(tmp, file);
}

module.exports = {
  MAX_BODY,
  readBody,
  parseJSON,
  safeRelPath,
  resolveInside,
  readJSON,
  writeJSON,
  boolish,
};