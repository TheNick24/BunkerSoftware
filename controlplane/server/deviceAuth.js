"use strict";
const { canonical, hmacHex, constantTimeEqualHex } = require("./crypto");

const DEVICE_SIG_HEADERS = { id: "x-agent-id", seq: "x-agent-seq", sig: "x-agent-sig" };

// Verifies every device request: real device, strictly-newer sequence number
// (replay rejection), HMAC over METHOD\nPATH\nSEQ\nRAW_BODY with the device
// secret, constant-time comparison. On success the new sequence is persisted
// BEFORE the handler runs, so a crash cannot re-open the old window.
function deviceAuth(store) {
  return async function (req, res, next) {
    const rawBody = req.rawBody || "";
    const id = req.headers[DEVICE_SIG_HEADERS.id];
    const seq = Number(req.headers[DEVICE_SIG_HEADERS.seq]);
    const sig = req.headers[DEVICE_SIG_HEADERS.sig];

    if (!id || typeof id !== "string" || !/^[A-Za-z0-9_-]+$/.test(id)) return fail(res, 401, "bad agent id"), false;
    if (!Number.isInteger(seq) || seq < 1) return fail(res, 401, "bad sequence"), false;
    if (!sig || typeof sig !== "string" || !/^[0-9a-f]{64}$/i.test(sig)) return fail(res, 401, "bad signature"), false;

    const dev = store.devices[id];
    if (!dev || !dev.secret) return fail(res, 401, "unknown device"), false;

    if (seq < dev.seq) return fail(res, 409, "sequence replay rejected"), false;
    if (seq > dev.seq + 100000) return fail(res, 400, "sequence too far ahead"), false;

    const expect = hmacHex(dev.secret, canonical(req.method, req.urlNoQuery, seq, rawBody));
    if (!constantTimeEqualHex(expect, sig)) return fail(res, 401, "bad signature"), false;

    if (seq === dev.seq) {
      // Lost-response retry: a request of this exact seq was already verified
      // and processed, but the response never reached the agent (e.g. the
      // server crashed mid long-poll). Accept it idempotently - refresh
      // lastSeen but do NOT advance the sequence - so the agent can resume.
      req.replayed = true;
      dev.lastSeen = Date.now();
    } else {
      req.replayed = false;
      dev.seq = seq;
      dev.lastSeen = Date.now();
    }
    store.persistDevices();

    req.agentId = id;
    req.rawBody = rawBody;
    next();
    return true;
  };
}

function signBody(secret, path, seq, bodyText) {
  return hmacHex(secret, canonical("RESPONSE", path, seq, bodyText));
}

function reply(req, res, status, body) {
  const text = JSON.stringify(body);
  res.statusCode = status;
  res.setHeader("content-type", "application/json");
  res.setHeader(
    "x-agent-sig",
    signBody(req.agentSecret, req.urlNoQuery, req.agentSeq, text)
  );
  res.end(text);
}

function fail(res, status, msg) {
  res.statusCode = status;
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify({ error: msg }));
}

// Attach the signing secret + seq onto `req` after auth, so routes can use reply().
async function signedDeviceHandler(handler) {
  return async function (req, res) {
    const dev = this.store.devices[req.agentId];
    req.agentSecret = dev.secret;
    req.agentSeq = Number(req.headers["x-agent-seq"]);
    await handler(req, res);
  };
}

module.exports = {
  DEVICE_SIG_HEADERS,
  deviceAuth,
  signedDeviceHandler,
  signBody,
  reply,
  fail,
};