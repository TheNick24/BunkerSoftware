"use strict";
const crypto = require("node:crypto");

// Canonical string that device and server both sign:
//   METHOD \n PATH \n SEQUENCE \n RAW_BODY
// PATH is the decoded path (no query string). RAW_BODY is the exact raw
// bytes of the request payload (for the Lua agent: the exact JSON string it
// sends, so both sides agree byte-for-byte).
function canonical(method, path, seq, rawBody) {
  return [method.toUpperCase(), path, String(seq), rawBody || ""].join("\n");
}

function hmacHex(secret, message) {
  return crypto.createHmac("sha256", secret).update(message).digest("hex");
}

function constantTimeEqualHex(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  if (a.length !== b.length || !/^[0-9a-f]+$/i.test(a) || !/^[0-9a-f]+$/i.test(b)) {
    return false;
  }
  const bufA = Buffer.from(a, "hex");
  const bufB = Buffer.from(b, "hex");
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

// Constant-time equality for arbitrary strings (operator tokens etc.).
function constantTimeEq(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const ha = crypto.createHash("sha256").update(a, "utf8").digest();
  const hb = crypto.createHash("sha256").update(b, "utf8").digest();
  return crypto.timingSafeEqual(ha, hb);
}

function randomToken(bytes = 32) {
  return crypto.randomBytes(bytes).toString("hex");
}

// Content-derived release ID: a stable, unguessable digest of the manifest
// entries (path + hash pairs, sorted byte-wise).
function releaseIdFromEntries(entries) {
  const h = crypto.createHash("sha256");
  for (const e of entries.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0))) {
    h.update(`${e.path}\0${e.hash}\0`);
  }
  return h.digest("hex");
}

module.exports = {
  canonical,
  hmacHex,
  constantTimeEqualHex,
  constantTimeEq,
  randomToken,
  releaseIdFromEntries,
};