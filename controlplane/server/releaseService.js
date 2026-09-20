"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { releaseIdFromEntries } = require("./crypto");
const { safeRelPath } = require("./validate");

function sha256File(file) {
  const h = crypto.createHash("sha256");
  h.update(fs.readFileSync(file));
  return h.digest("hex");
}

// Build a deterministic release for one (role, installation) pair:
//   core/  -> shared code
//   subsystem/<role>/  -> role code        (added second: may override core)
//   installation/<installation>/ -> config (added last: highest precedence)
// The manifest maps every relative path (POSIX) to its SHA-256, the release
// ID is content-derived, and `files` ordering is stable for reproducibility.
function buildRelease({ rootDir, role, installation }) {
  const layers = [
    path.join(rootDir, "core"),
    path.join(rootDir, "subsystem", role),
    path.join(rootDir, "installation", installation),
  ];
  const files = new Map(); // rel -> sha256
  for (const layer of layers) {
    if (!fs.existsSync(layer)) continue;
    const walk = (dir) => {
      for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
        const abs = path.join(dir, ent.name);
        const rel = path.relative(rootDir, abs).replace(/\\/g, "/");
        if (ent.isDirectory()) walk(abs);
        else files.set(rel, sha256File(abs));
      }
    };
    walk(layer);
  }
  const entries = [...files.entries()]
    .map(([p, h]) => ({ path: p, hash: h }))
    .sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  return {
    releaseId: releaseIdFromEntries(entries),
    role,
    installation,
    created: Date.now(),
    files: entries,
  };
}

// Serve one release file. `releaseId` must be content-derived (unguessable)
// and exist in `known`; the relative path is validated against traversal.
function pathForRelease(root, releaseId, known, rawPath) {
  if (!known[releaseId]) {
    const e = new Error("unknown release");
    e.status = 404;
    throw e;
  }
  const rel = safeRelPath(rawPath);
  const base = path.join(root, "releases", releaseId);
  const target = path.resolve(base, rel);
  if (!target.startsWith(path.resolve(base) + path.sep)) {
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
}

// Materialize a built manifest to disk (for serving) and verify each file
// against its recorded hash. Returns { ok, failures }.
function persistRelease({ rootDir, manifest }) {
  const relAbs = path.join(rootDir, "releases", manifest.releaseId);
  let failures = 0;
  for (const f of manifest.files) {
    const src = path.resolve(rootDir, f.path);
    const dst = path.join(relAbs, f.path);
    if (!fs.existsSync(src)) {
      failures++;
      continue;
    }
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.copyFileSync(src, dst);
    if (sha256File(dst) !== f.hash) failures++;
  }
  // manifest.json is part of the release download surface, not of the hash set.
  fs.mkdirSync(relAbs, { recursive: true });
  fs.writeFileSync(path.join(relAbs, "manifest.json"), JSON.stringify(manifest, null, 2));
  return { ok: failures === 0, failures };
}

module.exports = { buildRelease, pathForRelease, persistRelease, sha256File };