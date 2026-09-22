"use strict";
(function () {
  var $ = function (sel) { return document.querySelector(sel); };
  var TOKEN_KEY = "cp.operatorToken";
  var token = localStorage.getItem(TOKEN_KEY) || "";

  function getToken() { return token; }
  function setToken(t) { token = t || ""; localStorage.setItem(TOKEN_KEY, token); }

  function api(path, opts) {
    opts = opts || {};
    var o = { headers: {} };
    for (var k in opts) { if (k !== "headers") o[k] = opts[k]; }
    if (opts.headers) { for (var h in opts.headers) o.headers[h] = opts.headers[h]; }
    o.headers["x-operator-token"] = getToken();
    if (o.body && typeof o.body !== "string") {
      o.body = JSON.stringify(o.body);
      o.headers["content-type"] = "application/json";
    }
    return fetch(path, o).then(function (r) {
      return r.json().catch(function () { return null; }).then(function (data) {
        if (!r.ok) {
          var err = new Error((data && data.error) || ("HTTP " + r.status));
          err.status = r.status;
          throw err;
        }
        return data;
      });
    });
  }

  function toast(msg, kind) {
    var d = document.createElement("div");
    if (kind) d.className = kind;
    d.textContent = msg;
    $("#toasts").appendChild(d);
    setTimeout(function () { d.remove(); }, 6000);
  }

  function relTime(ts) {
    if (!ts) return "never";
    var s = Math.floor((Date.now() - ts) / 1000);
    if (s < 5) return "just now";
    if (s < 60) return s + "s ago";
    if (s < 3600) return Math.floor(s / 60) + "m ago";
    if (s < 86400) return Math.floor(s / 3600) + "h ago";
    return Math.floor(s / 86400) + "d ago";
  }

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function showGate() { $("#tokenGate").classList.remove("hidden"); }

  var activeDeviceId = null;
  var deviceRefreshTimer = null;
  var deviceFileMap = {};
  var deviceReleasePage = 1;
  var deviceReleasePageSize = 10;
  var deviceReleaseHistory = [];
  var deviceCmdPage = 1;
  var deviceCmdPageSize = 5;
  var deviceCommands = [];

  function boot() {
    $("#tokenGate").classList.add("hidden");
    $("#tokenInput").value = token;
    bindNav();
    bindPairing();
    bindDeploy();
    bindConfig();
    bindUpdate();
    bindDevicePanel();
    $("#permClose").addEventListener("click", function () { $("#permModal").classList.add("hidden"); });
    pollStatus();
    loadFleet();
    loadConfig();
    setInterval(loadFleet, 5000);
  }

  function bindNav() {
    var buttons = document.querySelectorAll("nav button");
    buttons.forEach(function (b) {
      b.addEventListener("click", function () {
        activatePanel(b.dataset.panel);
        buttons.forEach(function (x) { x.classList.toggle("active", x === b); });
      });
    });
  }

  function activatePanel(name) {
    document.querySelectorAll("main section").forEach(function (x) { x.classList.remove("active"); });
    var panel = $("#panel-" + name);
    if (panel) panel.classList.add("active");
    if (name !== "device") {
      activeDeviceId = null;
      stopDeviceRefresh();
    } else if (activeDeviceId) {
      loadDevice(activeDeviceId, true);
    }
  }

  function pollStatus() {
    setInterval(function () {
      api("/api/fleet").then(function () {
        $("#serverStatus").textContent = "online";
      }).catch(function (e) {
        $("#serverStatus").textContent = e.status === 401 ? "auth required" : "offline";
      });
    }, 15000);
  }

  function loadFleet() {
    api("/api/fleet").then(function (devices) {
      var grid = $("#fleetGrid");
      if (!devices || !devices.length) {
        $("#fleetEmpty").style.display = "";
        return;
      }
      $("#fleetEmpty").style.display = "none";
      var byId = {};
      devices.forEach(function (d) { byId[d.id] = d; });
      grid.querySelectorAll(".card[data-id]").forEach(function (card) {
        var fresh = byId[card.dataset.id];
        if (!fresh) { card.remove(); return; }
        updateCardDom(card, fresh);
      });
      devices.forEach(function (d) {
        if (!grid.querySelector('.card[data-id="' + d.id + '"]')) {
          grid.appendChild(deviceCard(d));
        }
      });
      fillDeviceSelect(devices);
    }).catch(function (e) {
      if (e.status === 401) { showGate(); return; }
      $("#serverStatus").textContent = "offline";
    });
  }

  function updateCardDom(el, d) {
    var nameEl = el.querySelector(".name");
    if (nameEl && nameEl.dataset.v !== String(d.label)) nameEl.textContent = d.label || ("device " + d.id);
    var seen = el.querySelector(".muted.seen");
    if (seen) seen.innerHTML = "last seen " + relTime(d.lastSeen) + " &middot; seq " + esc(String(d.seq));
    var onlineBadge = el.querySelector(".badge.state");
    var online = d.lastSeen && Date.now() - d.lastSeen < 70000;
    if (onlineBadge) {
      onlineBadge.textContent = online ? "online" : "offline";
      onlineBadge.className = "badge state " + (online ? "online" : "offline");
    }
    var relWrap = el.querySelector(".rel-wrap");
    if (relWrap) {
      var latest = latestRelease(d.releases);
      var chips = "";
      if (latest) {
        chips = '<span class="badge release" title="' + esc(latest.releaseId) + '">' +
          esc(latest.releaseId.slice(0, 8)) + (latest.state ? ":" + esc(latest.state) : "") + "</span>";
      }
      if (d.target && d.target.role) {
        chips += ' <span class="badge" title="update target (' + esc(d.target.source || "") + ')">' +
          esc(d.target.role) + "/" + esc(d.target.installation) + "</span>";
      }
      relWrap.innerHTML = chips;
    }
    var upd = el.querySelector('[data-a="update"]');
    if (upd) upd.disabled = !!el.dataset.updating;
  }

  function latestRelease(releases) {
    var best = null;
    Object.keys(releases || {}).forEach(function (rid) {
      var st = releases[rid] || {};
      if (!best || (st.at || 0) >= (best.at || 0)) {
        best = { releaseId: rid, state: st.state, at: st.at };
      }
    });
    return best;
  }

  function deviceCard(d) {
    var el = document.createElement("div");
    el.className = "card";
    el.dataset.id = String(d.id);
    renderCard(el, d);
    el.querySelector('[data-a="reboot"]').addEventListener("click", function () { quickCmd(d.id, "reboot", {}); });
    el.querySelector('[data-a="details"]').addEventListener("click", function () { openDevice(d.id); });
    el.querySelector('[data-a="update"]').addEventListener("click", function () { updateDevice(d.id); });
    el.querySelector('[data-a="agent-update"]').addEventListener("click", function () { quickCmd(d.id, "agent.update", {}); });
    el.querySelector('[data-a="rollback"]').addEventListener("click", function () { quickCmd(d.id, "release.rollback", {}); });
    el.querySelector('[data-a="cmd"]').addEventListener("click", function () { customCmd(d.id); });
    el.querySelector('[data-a="perms"]').addEventListener("click", function () { openPeripherals(d.id); });
    el.querySelector('[data-a="cmds"]').addEventListener("click", function () { toggleCommands(el, d.id); });
    el.querySelector('[data-a="rename"]').addEventListener("click", function () { renameDevice(d.id, el.querySelector('[data-i="name"]').value); });
    el.querySelector('[data-a="change-id"]').addEventListener("click", function () { changeId(d.id, el.querySelector('[data-i="newid"]').value); });
    el.querySelector('[data-a="delete"]').addEventListener("click", function () { deleteDevice(d.id); });
    return el;
  }

  function renderCard(el, d) {
    var online = d.lastSeen && Date.now() - d.lastSeen < 70000;
    el.innerHTML =
      '<div class="top">' +
        '<span class="name" data-v="">' + esc(d.label || ("device " + d.id)) + '</span>' +
        '<span class="id">#' + esc(String(d.id)) + "</span>" +
        '<span class="badge state ' + (online ? "online" : "offline") + '">' + (online ? "online" : "offline") + "</span>" +
      "</div>" +
      '<div class="row muted seen">last seen ' + relTime(d.lastSeen) + " &middot; seq " + esc(String(d.seq)) + "</div>" +
      '<div class="row rel-wrap"></div>' +
      '<div class="row">' +
        '<button data-a="details" class="primary">details</button>' +
        '<button data-a="update" title="Rebuild sources and deploy to this device">update</button>' +
        '<button data-a="reboot">reboot</button>' +
        '<button data-a="agent-update">update agent</button>' +
        '<button data-a="rollback">rollback</button>' +
        '<button data-a="cmd">command…</button>' +
        '<button data-a="perms">peripherals</button>' +
        '<button data-a="cmds">commands</button>' +
      "</div>" +
      '<div class="row manage">' +
        '<input data-i="name" class="manage" value="' + esc(d.label || "") + '" placeholder="name">' +
        '<button data-a="rename" class="small">rename</button>' +
        '<input data-i="newid" class="manage" value="" placeholder="new id">' +
        '<button data-a="change-id" class="small">change id</button>' +
        '<button data-a="delete" class="small danger">delete</button>' +
      "</div>" +
      '<div class="hidden" data-log></div>';
    updateCardDom(el, d);
  }

  function renameDevice(deviceId, label) {
    label = (label || "").trim();
    if (!label) { toast("name required", "err"); return; }
    api("/api/devices/" + deviceId + "/rename", { method: "POST", body: { label: label } })
      .then(function () { toast("renamed #" + deviceId, "ok"); loadFleet(); })
      .catch(function (e) { toast(e.message, "err"); });
  }

  function changeId(deviceId, newId) {
    newId = (newId || "").trim();
    if (!/^[0-9]+$/.test(newId)) { toast("new id must be a number", "err"); return; }
    api("/api/devices/" + deviceId + "/change-id", { method: "POST", body: { newId: newId } })
      .then(function (r) {
        toast("id changed -> #" + newId + "; re-run the bootstrap on the computer", "ok");
        loadFleet();
      })
      .catch(function (e) { toast(e.message, "err"); });
  }

  function deleteDevice(deviceId) {
    if (!confirm("Delete computer #" + deviceId + "? This removes its record and commands.")) return;
    api("/api/devices/" + deviceId + "/delete", { method: "POST", body: {} })
      .then(function () { toast("device #" + deviceId + " deleted", "ok"); loadFleet(); })
      .catch(function (e) { toast(e.message, "err"); });
  }

  function quickCmd(deviceId, type, payload) {
    api("/api/devices/" + deviceId + "/command", { method: "POST", body: { type: type, payload: payload } })
      .then(function (r) {
        toast(type + " -> #" + deviceId + " enqueued (" + r.cid + ")", "ok");
        pollCommand(r.cid, 40);
      })
      .catch(function (e) { toast(e.message, "err"); });
  }

  function pollCommand(cid, seconds) {
    var end = Date.now() + seconds * 1000;
    var tick = function () {
      if (Date.now() > end) { toast("command " + cid + " still pending", "warn"); return; }
      api("/api/commands/" + cid).then(function (c) {
        if (!c) return;
        if (c.status === "done") { toast("command " + cid + " done: " + JSON.stringify(c.result), "ok"); return; }
        if (c.status === "error") { toast("command " + cid + " error: " + JSON.stringify(c.result), "err"); return; }
        setTimeout(tick, 2000);
      }).catch(function () { setTimeout(tick, 2000); });
    };
    setTimeout(tick, 1500);
  }

  function customCmd(deviceId) {
    var type = prompt("Command type for #" + deviceId + ":", "inspect");
    if (!type) return;
    var raw = prompt("Payload as JSON (empty = {}):", "{}");
    var payload = {};
    if (raw) {
      try { payload = JSON.parse(raw); }
      catch (e) { toast("invalid payload JSON", "err"); return; }
    }
    quickCmd(deviceId, type, payload);
  }

  function openPeripherals(deviceId) {
    var box = $("#permModal");
    box.classList.remove("hidden");
    var body = $("#permBody");
    $("#permTitle").textContent = "Peripherals - #" + deviceId;
    body.innerHTML = '<div class="muted">Requesting peripherals from #' + deviceId + "…</div>";
    api("/api/devices/" + deviceId + "/command", { method: "POST", body: { type: "peripherals", payload: {} } })
      .then(function (r) { return waitCommand(r.cid, 60); })
      .then(function (c) { renderPeripherals(body, c); })
      .catch(function (e) {
        body.innerHTML = '<div class="banner err">' + esc(e.message || "request failed") + "</div>";
      });
  }

  function waitCommand(cid, seconds) {
    var end = Date.now() + seconds * 1000;
    return new Promise(function (resolve, reject) {
      var tick = function () {
        api("/api/commands/" + cid).then(function (c) {
          if (!c) return setTimeout(tick, 1500);
          if (c.status === "done") return resolve(c);
          if (c.status === "error") return reject(new Error("command " + cid + " error: " + (typeof c.result === "string" ? c.result : JSON.stringify(c.result || ""))));
          if (Date.now() > end) return reject(new Error("command " + cid + " still pending"));
          setTimeout(tick, 1500);
        }).catch(function () {
          if (Date.now() > end) return reject(new Error("command " + cid + " still pending"));
          setTimeout(tick, 1500);
        });
      };
      setTimeout(tick, 1200);
    });
  }

  function renderPeripherals(body, c) {
    var res = (c && c.result) || {};
    var perms = res.peripherals || {};
    var sides = Object.keys(perms).sort(function (a, b) { return String(a).localeCompare(String(b), "en", { numeric: true }); });
    if (!sides.length) {
      body.innerHTML = '<div class="muted">No peripherals found on this computer.</div>';
      return;
    }
    var head = '<div class="row muted">computer ' + esc(res.label || res.computerId) +
      " &middot; agent " + esc(res.agentVersion || "?") + "</div>";
    body.innerHTML = head + sides.map(function (side) {
      var p = perms[side];
      var info = esc(side) + " <span class='muted'> / " + esc(p.type || "?") + "</span>";
      if (p.size) {
        info += " <span class='muted'>[" + esc(String(p.size[0])) + "x" + esc(String(p.size[1])) +
          (p.textScale ? " @x" + esc(String(p.textScale)) : "") + "]</span>";
      }
      var chips = (p.methods || []).map(function (m) {
        return '<span class="chip">' + esc(String(m)) + "</span>";
      }).join("");
      return '<div class="perm-side"><div class="perm-head">' + info + "</div>" +
        '<div class="perm-methods">' + (chips || '<span class="muted">(no methods)</span>') + "</div></div>";
    }).join("");
  }

  function toggleCommands(el, deviceId) {
    var log = el.querySelector("[data-log]");
    if (log.classList.contains("hidden")) {
      log.classList.remove("hidden");
      log.innerHTML = '<div class="log">loading…</div>';
      api("/api/devices/" + deviceId + "/commands").then(function (cmds) {
        if (!cmds || !cmds.length) { log.innerHTML = '<div class="log muted">no commands recorded</div>'; return; }
        log.innerHTML = cmds.map(cmdRow).join("");
      }).catch(function (e) {
        log.innerHTML = '<div class="log"><span class="err">' + esc(e.message) + "</span></div>";
      });
    } else {
      log.classList.add("hidden");
    }
  }

  function cmdRow(c) {
    var hasPayload = c.payload && Object.keys(c.payload).length;
    var hasResult = c.result != null;
    var head =
      '<button class="linkish cmd-toggle" data-cmd-toggle>▸</button> ' +
      '<span class="type">' + esc(c.type) + "</span>" +
      ' <span class="t">' + esc(c.id) + " · " + esc(c.status) + " · " + relTime(c.createdAt) + "</span>";
    var body = "";
    if (hasPayload) body += '<pre>' + esc(JSON.stringify(c.payload, null, 2)) + "</pre>";
    if (hasResult) body += '<pre>' + esc(typeof c.result === "string" ? c.result : JSON.stringify(c.result, null, 2)) + "</pre>";
    if (!body) body = '<span class="muted">no payload / result</span>';
    return '<div class="cmd-row collapsed">' +
      '<div class="cmd-head">' + head + "</div>" +
      '<div class="cmd-body hidden">' + body + "</div>" +
      "</div>";
  }

  function fillDeviceSelect(devices) {
    var sel = $("#depDevice");
    var current = sel.value;
    sel.innerHTML = "";
    devices.forEach(function (d) {
      var o = document.createElement("option");
      o.value = d.id;
      o.textContent = (d.label || ("device " + d.id)) + " (#" + d.id + ")";
      if (String(d.id) === current) o.selected = true;
      sel.appendChild(o);
    });
  }

  function bindPairing() {
    $("#pairBtn").addEventListener("click", function () {
      $("#pairResult").classList.add("hidden");
      var deviceId = $("#pairId").value.trim();
      if (!/^[0-9]+$/.test(deviceId)) { toast("computer ID must be a number", "err"); return; }
      api("/api/pairing", { method: "POST", body: { deviceId: deviceId, label: $("#pairName").value.trim() || undefined } })
        .then(function (r) {
          var box = $("#pairResult");
          box.classList.remove("hidden");
          box.innerHTML =
            '<div class="pair-box"></div>';
          var inner = box.querySelector(".pair-box");
          inner.innerHTML =
            "<div class='muted'>pairing token expires " + relTime(r.expiresAt) + "</div>" +
            "<div class='cmd'>" + esc(r.bootstrapCommand) + "</div>" +
            '<div class="row"><button class="primary" id="copyBootstrap">copy command</button></div>';
          $("#copyBootstrap").addEventListener("click", function () {
            navigator.clipboard.writeText(r.bootstrapCommand).then(function () {
              toast("bootstrap command copied", "ok");
            });
          });
          $("#depDevice").innerHTML =
            '<option value="' + esc(deviceId) + '" selected="selected">' + esc($("#pairName").value.trim() || ("device " + deviceId)) + " (#" + deviceId + ")</option>";
          toast("pairing token created for #" + deviceId, "ok");
        })
        .catch(function (e) { toast(e.message, "err"); });
    });
  }

  function bindDeploy() {
    $("#deployBtn").addEventListener("click", function () {
      var deviceId = $("#depDevice").value;
      var role = $("#depRole").value.trim();
      var installation = $("#depInstall").value.trim();
      if (!deviceId || !role || !installation) { toast("device, role and installation are required", "err"); return; }
      $("#deployBtn").disabled = true;
      api("/api/deploy", { method: "POST", body: { deviceId: deviceId, role: role, installation: installation } })
        .then(function (r) {
          toast("deployed " + role + "/" + installation + " -> #" + deviceId + " (" + r.releaseId + ")", "ok");
          if (activeDeviceId === deviceId) loadDevice(deviceId, true);
          pollCommand(r.cid, 90);
        })
        .catch(function (e) { toast(e.message, "err"); })
        .finally(function () { $("#deployBtn").disabled = false; });
    });
  }

  function bindUpdate() {
    $("#updateFleetBtn").addEventListener("click", function () {
      if (!confirm("Rebuild from current sources and deploy to every paired device?")) return;
      runUpdate(null, $("#updateFleetBtn"));
    });
  }

  function updateDevice(deviceId) {
    var card = document.querySelector('.card[data-id="' + deviceId + '"]');
    runUpdate(String(deviceId), card && card.querySelector('[data-a="update"]'), card);
  }

  function runUpdate(deviceId, btn, card) {
    if (btn) btn.disabled = true;
    if (card) card.dataset.updating = "1";
    var label = deviceId ? "#" + deviceId : "fleet";
    toast("rebuilding sources and updating " + label + "…", "ok");
    var url = deviceId ? "/api/devices/" + deviceId + "/update" : "/api/update";
    api(url, { method: "POST", body: deviceId ? {} : {} })
      .then(function (r) {
        var results = r.results || [{
          deviceId: deviceId,
          cid: r.cid,
          releaseId: r.releaseId,
          role: r.role,
          installation: r.installation,
        }];
        var okRows = results.filter(function (x) { return !x.error && x.cid; });
        var badRows = results.filter(function (x) { return x.error; });
        badRows.forEach(function (x) {
          toast("update #" + x.deviceId + " skipped: " + x.error, "err");
        });
        if (!okRows.length) {
          toast("nothing deployed", "err");
          return Promise.reject(new Error("nothing deployed"));
        }
        toast("deploying " + okRows.length + " release(s)…", "ok");
        if (activeDeviceId) loadDevice(activeDeviceId, true);
        return Promise.all(okRows.map(function (row) {
          return waitCommand(row.cid, 120).then(function () { return row; });
        })).then(function (rows) {
          return waitForHealth(rows.map(function (row) { return row.releaseId; }), 90);
        }).then(function (states) {
          var failed = states.filter(function (s) { return s.state !== "healthy"; });
          if (failed.length) {
            failed.forEach(function (s) {
              toast("release " + s.releaseId.slice(0, 8) + " -> " + s.state, "err");
            });
          } else {
            toast("update complete: " + okRows.length + " device(s) healthy", "ok");
          }
          loadFleet();
        });
      })
      .catch(function (e) {
        if (e && e.message !== "nothing deployed") toast(e.message, "err");
      })
      .finally(function () {
        if (btn) btn.disabled = false;
        if (card) delete card.dataset.updating;
        loadFleet();
      });
  }

  function waitForHealth(releaseIds, seconds) {
    var end = Date.now() + seconds * 1000;
    var unique = Array.from(new Set(releaseIds));
    return new Promise(function (resolve, reject) {
      var tick = function () {
        api("/api/fleet").then(function (devices) {
          var states = [];
          var pending = false;
          unique.forEach(function (rid) {
            var found = null;
            devices.forEach(function (d) {
              if (d.releases && d.releases[rid]) found = d.releases[rid].state || "pending";
            });
            if (!found) found = "pending";
            if (found === "pending") pending = true;
            states.push({ releaseId: rid, state: found });
          });
          if (!pending) return resolve(states);
          if (Date.now() > end) return resolve(states);
          setTimeout(tick, 2500);
        }).catch(function () {
          if (Date.now() > end) return reject(new Error("health wait timed out"));
          setTimeout(tick, 2500);
        });
      };
      setTimeout(tick, 2000);
    });
  }

  function openDevice(deviceId) {
    activeDeviceId = deviceId;
    deviceReleasePage = 1;
    deviceCmdPage = 1;
    document.querySelectorAll("nav button").forEach(function (x) { x.classList.remove("active"); });
    activatePanel("device");
    loadDevice(deviceId, true);
  }

  function bindDevicePanel() {
    $("#deviceBack").addEventListener("click", function () {
      activeDeviceId = null;
      stopDeviceRefresh();
      var fleetBtn = document.querySelector('nav button[data-panel="fleet"]');
      if (fleetBtn) fleetBtn.click();
      else activatePanel("fleet");
    });
    $("#deviceActions").addEventListener("click", function (e) {
      var btn = e.target.closest("button[data-a]");
      if (!btn || !activeDeviceId) return;
      var id = activeDeviceId;
      if (btn.dataset.a === "update") {
        runUpdate(String(id), btn);
      } else if (btn.dataset.a === "reboot") {
        quickCmd(id, "reboot", {});
      } else if (btn.dataset.a === "agent-update") {
        quickCmd(id, "agent.update", {});
      } else if (btn.dataset.a === "rollback") {
        quickCmd(id, "release.rollback", {});
      } else if (btn.dataset.a === "cmd") {
        customCmd(id);
      } else if (btn.dataset.a === "perms") {
        openPeripherals(id);
      }
    });
    $("#deviceReleaseRows").addEventListener("click", function (e) {
      var btn = e.target.closest("[data-files]");
      if (!btn) return;
      toggleReleaseFiles(btn.dataset.files);
    });
    $("#deviceReleasePager").addEventListener("click", function (e) {
      var btn = e.target.closest("button[data-page]");
      if (!btn || btn.disabled) return;
      gotoReleasePage(Number(btn.dataset.page));
    });
    $("#deviceCmdPager").addEventListener("click", function (e) {
      var btn = e.target.closest("button[data-cmd-page]");
      if (!btn || btn.disabled) return;
      gotoCmdPage(Number(btn.dataset.cmdPage));
    });
    document.addEventListener("click", function (e) {
      var t = e.target.closest("[data-cmd-toggle]");
      if (!t) return;
      var row = t.closest(".cmd-row");
      if (!row) return;
      var body = row.querySelector(".cmd-body");
      if (!body) return;
      var open = !row.classList.contains("collapsed");
      row.classList.toggle("collapsed", open);
      body.classList.toggle("hidden", open);
      t.textContent = open ? "▸" : "▾";
    });
  }

  function toggleReleaseFiles(rid) {
    var box = $("#deviceReleaseFiles");
    if (box.dataset.rid === rid) {
      box.classList.add("hidden");
      box.dataset.rid = "";
      box.innerHTML = "";
      return;
    }
    var list = deviceFileMap[rid] || [];
    box.dataset.rid = rid;
    box.classList.remove("hidden");
    box.innerHTML = list.length
      ? '<div class="rel-files">' + list.map(function (f) {
          return '<div><span class="path">' + esc(f.path) + '</span> <span class="hash">' + esc(String(f.hash || "").slice(0, 12)) + "</span></div>";
        }).join("") + "</div>"
      : '<div class="rel-files muted">No file manifest for this release.</div>';
  }

  function gotoReleasePage(page) {
    var total = deviceReleaseHistory.length;
    var pages = Math.max(1, Math.ceil(total / deviceReleasePageSize));
    if (!total) return;
    if (page < 1) page = 1;
    if (page > pages) page = pages;
    deviceReleasePage = page;
    hideReleaseFiles();
    renderReleaseHistory();
  }

  function hideReleaseFiles() {
    var box = $("#deviceReleaseFiles");
    box.classList.add("hidden");
    box.dataset.rid = "";
    box.innerHTML = "";
  }

  function pageWindow(page, pages) {
    if (pages <= 7) {
      var all = [];
      for (var i = 1; i <= pages; i++) all.push(i);
      return all;
    }
    var nums = [1];
    var start = Math.max(2, page - 1);
    var end = Math.min(pages - 1, page + 1);
    if (start > 2) nums.push("…");
    for (var n = start; n <= end; n++) nums.push(n);
    if (end < pages - 1) nums.push("…");
    nums.push(pages);
    return nums;
  }

  function renderReleasePager(history) {
    var pager = $("#deviceReleasePager");
    var total = history.length;
    if (!total) { pager.innerHTML = ""; return; }
    var pages = Math.max(1, Math.ceil(total / deviceReleasePageSize));
    if (deviceReleasePage > pages) deviceReleasePage = pages;
    var page = deviceReleasePage;
    var from = (page - 1) * deviceReleasePageSize + 1;
    var to = Math.min(total, page * deviceReleasePageSize);
    var html = "";
    html += '<button data-page="' + (page - 1) + '"' + (page <= 1 ? " disabled" : "") + ">&larr;</button>";
    pageWindow(page, pages).forEach(function (p) {
      if (p === "…") {
        html += '<span class="dots">&hellip;</span>';
        return;
      }
      html += '<button data-page="' + p + '"' + (p === page ? ' class="on"' : "") + ">" + p + "</button>";
    });
    html += '<button data-page="' + (page + 1) + '"' + (page >= pages ? " disabled" : "") + ">&rarr;</button>";
    html += '<span class="meta">Seite ' + page + " / " + pages + " &middot; " + from + "&ndash;" + to + " von " + total + " Releases</span>";
    pager.innerHTML = html;
  }

  function renderReleaseHistory() {
    var history = deviceReleaseHistory;
    var tbody = $("#deviceReleaseRows");
    renderReleasePager(history);
    if (!history.length) {
      tbody.innerHTML = "";
      $("#deviceReleaseEmpty").style.display = "";
      hideReleaseFiles();
      return;
    }
    $("#deviceReleaseEmpty").style.display = "none";
    var pages = Math.max(1, Math.ceil(history.length / deviceReleasePageSize));
    if (deviceReleasePage > pages) deviceReleasePage = pages;
    var start = (deviceReleasePage - 1) * deviceReleasePageSize;
    var slice = history.slice(start, start + deviceReleasePageSize);
    tbody.innerHTML = slice.map(function (h) {
      var state = h.state || "unknown";
      var stateCls = state === "healthy" ? "online" : (state === "failed" ? "offline" : "");
      return '<tr' + (h.current ? ' class="rel-current"' : "") + ">" +
        "<td><code>" + esc(h.releaseId.slice(0, 10)) + "</code>" +
          (h.current ? ' <span class="chip">current</span>' : "") + "</td>" +
        "<td>" + esc(h.role || "—") + "</td>" +
        "<td>" + esc(h.installation || "—") + "</td>" +
        '<td><span class="badge ' + stateCls + '">' + esc(state) + "</span></td>" +
        '<td class="muted" title="' + esc(String(h.at || "")) + '">' + relTime(h.at) + "</td>" +
        '<td class="muted" title="' + esc(String(h.created || "")) + '">' + relTime(h.created) + "</td>" +
        "<td>" + esc(String(h.fileCount || 0)) +
          ' <button class="linkish" data-files="' + esc(h.releaseId) + '">show</button></td>' +
        "</tr>";
    }).join("");
  }

  function stopDeviceRefresh() {
    if (deviceRefreshTimer) {
      clearInterval(deviceRefreshTimer);
      deviceRefreshTimer = null;
    }
  }

  function loadDevice(deviceId, restartTimer) {
    activeDeviceId = deviceId;
    api("/api/devices/" + deviceId).then(function (dev) {
      if (activeDeviceId !== String(deviceId) && activeDeviceId !== deviceId) return;
      renderDeviceDetail(dev);
      if (restartTimer) {
        stopDeviceRefresh();
        deviceRefreshTimer = setInterval(function () {
          if (!activeDeviceId) return stopDeviceRefresh();
          loadDevice(activeDeviceId, false);
        }, 15000);
      }
    }).catch(function (e) {
      if (e.status === 401) { showGate(); return; }
      $("#deviceHead").innerHTML = '<div class="banner err">' + esc(e.message || "load failed") + "</div>";
    });
  }

  function renderDeviceDetail(dev) {
    var online = dev.lastSeen && Date.now() - dev.lastSeen < 70000;
    var history = dev.releaseHistory || [];
    var current = history[0] || null;
    $("#deviceHead").innerHTML =
      '<span class="name">' + esc(dev.label || ("device " + dev.id)) + "</span>" +
      '<span class="id">#' + esc(String(dev.id)) + "</span>" +
      '<span class="badge state ' + (online ? "online" : "offline") + '">' + (online ? "online" : "offline") + "</span>";

    var tiles = [
      { k: "Agent", v: dev.agentVersion || "unknown" },
      { k: "Last seen", v: relTime(dev.lastSeen) },
      { k: "Seq", v: String(dev.seq) },
      { k: "Target role", v: dev.target && dev.target.role ? dev.target.role + "/" + dev.target.installation : "—" , mono: true },
      { k: "Target source", v: (dev.target && dev.target.source) || "—" },
      { k: "Current release", v: current ? current.releaseId.slice(0, 12) + (current.state ? " · " + current.state : "") : "—", mono: true },
      { k: "Releases deployed", v: String(history.length) },
      { k: "Label source", v: dev.labelSource || "manual" },
    ];
    $("#deviceInfo").innerHTML = tiles.map(function (t) {
      return '<div class="info-tile"><div class="k">' + esc(t.k) + '</div><div class="v' +
        (t.mono ? " mono" : "") + '">' + esc(t.v) + "</div></div>";
    }).join("");

    $("#deviceActions").innerHTML =
      '<button data-a="update" class="primary" title="Rebuild sources and deploy">update</button>' +
      '<button data-a="reboot">reboot</button>' +
      '<button data-a="agent-update">update agent</button>' +
      '<button data-a="rollback">rollback</button>' +
      '<button data-a="cmd">command…</button>' +
      '<button data-a="perms">peripherals</button>';

    deviceReleaseHistory = history;
    var payload = {};
    history.forEach(function (h) { payload[h.releaseId] = h.files || []; });
    deviceFileMap = payload;
    renderReleaseHistory();

    deviceCommands = dev.recentCommands || [];
    renderCommands();
  }

  function gotoCmdPage(page) {
    var total = deviceCommands.length;
    var pages = Math.max(1, Math.ceil(total / deviceCmdPageSize));
    if (!total) return;
    if (page < 1) page = 1;
    if (page > pages) page = pages;
    deviceCmdPage = page;
    renderCommands();
  }

  function renderCmdPager() {
    var pager = $("#deviceCmdPager");
    var total = deviceCommands.length;
    if (!total) { pager.innerHTML = ""; return; }
    var pages = Math.max(1, Math.ceil(total / deviceCmdPageSize));
    if (deviceCmdPage > pages) deviceCmdPage = pages;
    var page = deviceCmdPage;
    var from = (page - 1) * deviceCmdPageSize + 1;
    var to = Math.min(total, page * deviceCmdPageSize);
    var html = "";
    html += '<button data-cmd-page="' + (page - 1) + '"' + (page <= 1 ? " disabled" : "") + ">&larr;</button>";
    pageWindow(page, pages).forEach(function (p) {
      if (p === "…") {
        html += '<span class="dots">&hellip;</span>';
        return;
      }
      html += '<button data-cmd-page="' + p + '"' + (p === page ? ' class="on"' : "") + ">" + p + "</button>";
    });
    html += '<button data-cmd-page="' + (page + 1) + '"' + (page >= pages ? " disabled" : "") + ">&rarr;</button>";
    html += '<span class="meta">Seite ' + page + " / " + pages + " &middot; " + from + "&ndash;" + to + " von " + total + " Commands</span>";
    pager.innerHTML = html;
  }

  function renderCommands() {
    var box = $("#deviceCommands");
    renderCmdPager();
    if (!deviceCommands.length) {
      box.innerHTML = '<div class="muted">No commands recorded.</div>';
      return;
    }
    var pages = Math.max(1, Math.ceil(deviceCommands.length / deviceCmdPageSize));
    if (deviceCmdPage > pages) deviceCmdPage = pages;
    var start = (deviceCmdPage - 1) * deviceCmdPageSize;
    var slice = deviceCommands.slice(start, start + deviceCmdPageSize);
    box.innerHTML = slice.map(cmdRow).join("");
  }

  function loadConfig() {
    api("/api/config").then(function (cfg) {
      $("#configText").value = JSON.stringify(cfg, null, 2);
    }).catch(function (e) {
      if (e.status !== 401) toast("config load failed: " + e.message, "err");
    });
  }

  function bindConfig() {
    $("#configLoad").addEventListener("click", loadConfig);
    $("#configSave").addEventListener("click", function () {
      var raw = $("#configText").value;
      var cfg;
      try { cfg = JSON.parse(raw); }
      catch (e) { toast("invalid JSON: " + e.message, "err"); return; }
      $("#configSave").disabled = true;
      api("/api/config", { method: "PUT", body: cfg })
        .then(function () {
          toast("desired state saved", "ok");
          loadConfig();
        })
        .catch(function (e) { toast(e.message, "err"); })
        .finally(function () { $("#configSave").disabled = false; });
    });
  }

  $("#tokenInput").addEventListener("change", function (e) {
    setToken(e.target.value.trim());
    toast("token updated", "ok");
  });
  $("#gateToken").addEventListener("keydown", function (e) { if (e.key === "Enter") unlockGate(); });
  $("#gateBtn").addEventListener("click", unlockGate);
  function unlockGate() {
    var t = $("#gateToken").value.trim();
    if (!t) { $("#gateToken").classList.add("bad"); return; }
    $("#gateToken").classList.remove("bad");
    setToken(t);
    boot();
  }

  if (token) {
    boot();
  } else {
    showGate();
  }
})();