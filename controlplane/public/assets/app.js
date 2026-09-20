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

  function boot() {
    $("#tokenGate").classList.add("hidden");
    $("#tokenInput").value = token;
    bindNav();
    bindPairing();
    bindReleases();
    bindConfig();
    $("#permClose").addEventListener("click", function () { $("#permModal").classList.add("hidden"); });
    pollStatus();
    loadFleet();
    loadReleases();
    loadConfig();
    setInterval(loadFleet, 5000);
    setInterval(loadReleases, 15000);
  }

  function bindNav() {
    var buttons = document.querySelectorAll("nav button");
    buttons.forEach(function (b) {
      b.addEventListener("click", function () {
        buttons.forEach(function (x) { x.classList.remove("active"); });
        document.querySelectorAll("main section").forEach(function (x) { x.classList.remove("active"); });
        b.classList.add("active");
        $("#panel-" + b.dataset.panel).classList.add("active");
      });
    });
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
      var rel = Object.entries(d.releases || {});
      relWrap.innerHTML = rel.map(function (pair) {
        var rid = pair[0], st = pair[1];
        return '<span class="badge release" title="' + esc(st.state || "") + '">' +
          esc(rid.slice(0, 8)) + (st.state ? ":" + esc(st.state) : "") + "</span>";
      }).join(" ");
    }
  }

  function deviceCard(d) {
    var el = document.createElement("div");
    el.className = "card";
    el.dataset.id = String(d.id);
    renderCard(el, d);
    el.querySelector('[data-a="reboot"]').addEventListener("click", function () { quickCmd(d.id, "reboot", {}); });
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
    return '<div class="cmd-row">' +
      '<span class="type">' + esc(c.type) + "</span>" +
      ' <span class="t">' + esc(c.id) + " · " + esc(c.status) + " · " + relTime(c.createdAt) + "</span>" +
      (c.payload && Object.keys(c.payload).length ? "<pre>" + esc(JSON.stringify(c.payload, null, 2)) + "</pre>" : "") +
      (c.result != null ? "<pre>" + esc(typeof c.result === "string" ? c.result : JSON.stringify(c.result, null, 2)) + "</pre>" : "") +
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

  function bindReleases() {
    $("#deployBtn").addEventListener("click", function () {
      var deviceId = $("#depDevice").value;
      var role = $("#depRole").value.trim();
      var installation = $("#depInstall").value.trim();
      if (!deviceId || !role || !installation) { toast("device, role and installation are required", "err"); return; }
      $("#deployBtn").disabled = true;
      api("/api/deploy", { method: "POST", body: { deviceId: deviceId, role: role, installation: installation } })
        .then(function (r) {
          toast("deployed " + role + "/" + installation + " -> #" + deviceId + " (" + r.releaseId + ")", "ok");
          loadReleases();
          pollCommand(r.cid, 90);
        })
        .catch(function (e) { toast(e.message, "err"); })
        .finally(function () { $("#deployBtn").disabled = false; });
    });
  }

  function loadReleases() {
    api("/api/releases").then(function (data) {
      var rel = data.releases || {};
      var tbody = $("#releaseRows");
      var entries = Object.entries(rel);
      tbody.innerHTML = "";
      $("#releaseEmpty").style.display = entries.length ? "none" : "";
      entries.forEach(function (pair) {
        var rid = pair[0], m = pair[1];
        var tr = document.createElement("tr");
        var targets = Object.entries(m.targets || {}).map(function (t) {
          return '<span class="badge release" title="">#' + esc(t[0]) + ":" + esc(t[1].state || "") + "</span>";
        }).join(" ");
        tr.innerHTML =
          "<td>" + esc(rid.slice(0, 10)) + "</td>" +
          "<td>" + esc(m.role || "") + "</td>" +
          "<td>" + esc(m.installation || "") + "</td>" +
          "<td class='muted'>" + relTime(m.created) + "</td>" +
          "<td>" + esc(String((m.files || []).length)) + "</td>" +
          "<td>" + targets + "</td>";
        tbody.appendChild(tr);
      });
    }).catch(function () {});
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