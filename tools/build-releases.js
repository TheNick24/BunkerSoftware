// Auto-build the controlplane release folders from the current MAMDANI sources.
//
//   core/          <- reserved shared layer (anything you drop in is overlaid
//                     over every role; empty by default - each role folder is
//                     a complete, self-contained runnable bundle)
//   subsystem/<role>/ <- compile the role program + the whole lib/ bundle flat
//   installation/    <- left untouched (per-installation config is user-managed)
//
// The agent runs a release main with cwd set to its release folder (see the
// generated launcher in agentd.lua), so require("bunkerlib") resolves exactly
// like the legacy toolchain (lib flat next to main.lua).
//
//   node tools/build-releases.js          one-shot build
//   node tools/build-releases.js --watch  rebuild whenever a source changes
"use strict";
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const CP = path.join(ROOT, "controlplane");
const LIB = path.join(ROOT, "lib");
const ROLES_PATH = path.join(__dirname, "roles.json");

const { roles } = JSON.parse(fs.readFileSync(ROLES_PATH, "utf8"));

function listLua(dir) {
  return fs.readdirSync(dir).filter((f) => f.toLowerCase().endsWith(".lua")).sort();
}

function freshDir(dir) {
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
}

function copyFile(src, dst) {
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(src, dst);
}

let errors = 0;
function fail(msg) {
  errors++;
  console.error("  ! " + msg);
}

function build() {
  errors = 0;
  console.log("[build-releases] " + new Date().toISOString());
  const libs = listLua(LIB);

  // core layer: shared overlay (kept intentionally empty; role bundles are flat & runnable)
  freshDir(path.join(CP, "core"));
  console.log("  core/            (empty, shared overlay)");

  // prune stale role folders
  const subRoot = path.join(CP, "subsystem");
  fs.mkdirSync(subRoot, { recursive: true });
  for (const ent of fs.readdirSync(subRoot, { withFileTypes: true })) {
    if (!(roles[ent.name] && roles[ent.name].main)) {
      fs.rmSync(path.join(subRoot, ent.name), { recursive: true, force: true });
    }
  }

  const roleNames = Object.keys(roles).sort();
  for (const role of roleNames) {
    const spec = roles[role];
    const src = path.join(ROOT, spec.src);
    const dir = path.join(subRoot, role);
    freshDir(dir);
    if (!fs.existsSync(src)) {
      fail(`${role}: source missing (${spec.src})`);
      continue;
    }
    copyFile(src, path.join(dir, spec.dest));
    for (const f of libs) copyFile(path.join(LIB, f), path.join(dir, f));
    console.log(`  subsystem/${role}/   ${spec.src} -> ${spec.dest}  (+ ${libs.length} lib files)`);
  }

  // installation layer: untouched, only listed
  const instRoot = path.join(CP, "installation");
  fs.mkdirSync(instRoot, { recursive: true });
  const instDirs = fs.readdirSync(instRoot, { withFileTypes: true })
    .filter((e) => e.isDirectory()).map((e) => e.name);
  if (instDirs.length) console.log("  installation/      " + instDirs.join(", ") + " (untouched)");

  console.log(errors ? `  FAILED with ${errors} error(s)` : "  ok");
  return errors === 0;
}

module.exports = { build };

if (require.main === module) {
  const ok = build();
  if (!ok) process.exitCode = 1;

  if (process.argv.includes("--watch")) {
    const watched = [LIB, path.join(ROOT, "controlserver"), path.join(ROOT, "client"), path.join(ROOT, "remote"), ROLES_PATH];
    console.log("[build-releases] watching sources for changes (Ctrl+C to stop)...");
    const onEvent = (p) => {
      try { build(); } catch (e) { errors++; console.error("  ! rebuild failed: " + e.message); }
    };
    for (const w of watched) {
      fs.watch(w, { persistent: true }, onEvent);
    }
    setInterval(() => {}, 60000);
  }
}