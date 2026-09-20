-- ============================================================
-- CONTROLPLANE AGENT (agentd)
-- Resident HTTP agent for CC:Tweaked computers managed by the
-- BunkerSoftware controlplane.
--
-- Run once (bootstrap):
--   wget run <agentBaseUrl>/agentd.lua <deviceId> <pairingToken>
--
-- On every later boot the generated /startup.lua runs this agent
-- (no args -> loads saved settings) together with the installed
-- release's main program.
--
-- Talk: HMAC-SHA256 signed, sequence-numbered JSON over HTTP.
--   signature = hmac(secret, "METHOD\nPATH\nSEQ\nRAW_BODY")
--   headers   : x-agent-id, x-agent-seq, x-agent-sig
-- ============================================================

local AGENT_VERSION = "0.1.0"
local BASE_DIR = "/controlplane"
local SETTINGS_FILE = BASE_DIR .. "/settings.json"
local SELF_FILE = BASE_DIR .. "/agentd.lua"
local LOG_FILE = BASE_DIR .. "/agent.log"
local RELEASES_DIR = BASE_DIR .. "/releases"
local HEALTH_FILE = "/controlplane/health.marker"
local CONFIG_FILE = BASE_DIR .. "/config.lua"
local LAUNCHER_FILE = "/startup.lua"

-- Placeholder replaced by the controlplane server at serve time with the
-- configured AGENT_BASE_URL. Bootstrap can therefore find the server even
-- without an explicit URL argument or saved settings.
local AGENT_BASE_URL_SERVE = "__AGENT_BASE_URL__"

local okHttp, http = pcall(function() return http end)
if not okHttp or not http then
    term.setTextColor(colors.red)
    print("agentd: HTTP API is disabled (https is required).")
    term.setTextColor(colors.white)
    return
end

-- ------------------------------------------------------------
-- logging
-- ------------------------------------------------------------
local function log(msg)
    local line = "[" .. os.epoch("utc") .. "] " .. tostring(msg)
    local f = fs.open(LOG_FILE, "a")
    if f then
        if f.getSize and f.getSize() > (200 * 1024) then
            f.close()
            fs.delete(LOG_FILE)
            f = fs.open(LOG_FILE, "a")
        end
        if f then
            f.write(line .. "\n")
            f.close()
        end
    end
    print(line)
end

local function readFile(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local data = f.readAll()
    f.close()
    return data
end

local function writeFile(path, data)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(data)
    f.close()
    return true
end

-- ------------------------------------------------------------
-- sha256 + hmac (pure Lua, bit32)
-- ------------------------------------------------------------
local band, bxor, rrotate, rshift = bit32.band, bit32.bxor, bit32.rrotate, bit32.rshift
local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function sha256(msg, raw)
    local band, bxor, rrotate, rshift = bit32.band, bit32.bxor, bit32.rrotate, bit32.rshift
    local K = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    }
    local len = #msg * 8
    msg = msg .. "\128"
    while #msg % 64 ~= 56 do msg = msg .. "\0" end
    local h32 = math.floor(len / 4294967296)
    local l32 = len % 4294967296
    msg = msg .. string.char(
        math.floor(h32 / 16777216) % 256, math.floor(h32 / 65536) % 256,
        math.floor(h32 / 256) % 256, h32 % 256,
        math.floor(l32 / 16777216) % 256, math.floor(l32 / 65536) % 256,
        math.floor(l32 / 256) % 256, l32 % 256)
    local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    for chunk = 0, #msg - 1, 64 do
        local W = {}
        for t = 0, 15 do
            local o = chunk + t * 4
            W[t] = (string.byte(msg, o + 1) or 0) * 16777216
                + (string.byte(msg, o + 2) or 0) * 65536
                + (string.byte(msg, o + 3) or 0) * 256
                + (string.byte(msg, o + 4) or 0)
        end
        for t = 16, 63 do
            local s0 = bxor(rrotate(W[t - 15], 7), rrotate(W[t - 15], 18), rshift(W[t - 15], 3))
            local s1 = bxor(rrotate(W[t - 2], 17), rrotate(W[t - 2], 19), rshift(W[t - 2], 10))
            W[t] = band(W[t - 16] + s0 + W[t - 7] + s1)
        end
        local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
        for t = 0, 63 do
            local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
            local ch = band(e, f) + band(bxor(e, 0xFFFFFFFF), g)
            local t1 = band(h + S1 + ch + K[t + 1] + W[t])
            local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local t2 = band(S0 + maj)
            h, g, f, e = g, f, e, band(d + t1)
            d, c, b, a = c, b, a, band(t1 + t2)
        end
        H[1] = band(H[1] + a); H[2] = band(H[2] + b); H[3] = band(H[3] + c); H[4] = band(H[4] + d)
        H[5] = band(H[5] + e); H[6] = band(H[6] + f); H[7] = band(H[7] + g); H[8] = band(H[8] + h)
    end
    if raw then
        local bin = {}
        for i = 1, 8 do
            local v = H[i]
            bin[i] = string.char(
                math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256,
                math.floor(v / 256) % 256, v % 256)
        end
        return table.concat(bin)
    end
    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
        H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8])
end

local HEX = "0123456789abcdef"
local function toHex(bs)
    local out = {}
    for i = 1, #bs do
        local b = string.byte(bs, i)
        out[#out + 1] = HEX:sub(math.floor(b / 16) + 1, math.floor(b / 16) + 1)
            .. HEX:sub(b % 16 + 1, b % 16 + 1)
    end
    return table.concat(out)
end

local function hmacSha256(key, msg)
    local bxor = bit32.bxor
    local block = 64
    if #key > block then key = sha256(key, true) end
    local kp = key .. string.rep("\0", block - #key)
    local ipad, opad = {}, {}
    for i = 1, block do
        local b = string.byte(kp, i)
        ipad[i] = string.char(bxor(b, 0x36))
        opad[i] = string.char(bxor(b, 0x5c))
    end
    return sha256(table.concat(opad) .. sha256(table.concat(ipad) .. msg, true), true)
end

-- ------------------------------------------------------------
-- settings
-- ------------------------------------------------------------
local s = {
    deviceId = nil,
    secret = nil,
    seq = 1,
    agentBaseUrl = "",
    pollSeconds = 25,
    evalLuaEnabled = false,
    currentRelease = nil,
    previousRelease = nil,
    releaseRole = nil,
    releaseMain = nil,
    installStatus = "live", -- live | pending | healthy | failed | rolled_back
    registered = false,
}

function loadSettings()
    local raw = readFile(SETTINGS_FILE)
    if not raw then return false end
    local ok, data = pcall(textutils.unserialiseJSON, raw)
    if not ok or type(data) ~= "table" then return false end
    for k, v in pairs(data) do s[k] = v end
    return type(s.deviceId) == "string" and type(s.secret) == "string"
end

function saveSettings()
  if not fs.exists(BASE_DIR) then fs.makeDir(BASE_DIR) end
  writeFile(SETTINGS_FILE, textutils.serializeJSON(s))
end

-- ------------------------------------------------------------
-- low level http, pullEvent-driven with timeout
-- ------------------------------------------------------------
local function httpCall(method, url, body, headers, timeoutSeconds)
    local timer = os.startTimer(timeoutSeconds or 40)
    -- CC http has no arbitrary-method API: body present -> POST, else GET.
    -- binary=true so readAll() returns the exact bytes (hash fidelity).
    local request = http.request(url, body or nil, headers, true)
    if not request then
        os.cancelTimer(timer)
        return nil, "request rejected"
    end
    while true do
        local ev, p1, p2, p3 = os.pullEventRaw()
        if ev == "http_success" and p1 == url then
            os.cancelTimer(timer)
            local code = p2.getResponseCode()
            local text = p2.readAll()
            p2.close()
            return code, text
        elseif ev == "http_failure" and p1 == url then
            os.cancelTimer(timer)
            return nil, tostring(p2)
        elseif ev == "timer" and p1 == timer then
            return nil, "timeout"
        elseif ev == "terminate" then
            os.cancelTimer(timer)
            return nil, "terminated"
        end
    end
end

local function get(url, timeoutSeconds)
    local code, body = httpCall("GET", url, nil, {}, timeoutSeconds or 40)
    if not code then return nil, body end
    if code ~= 200 then return nil, "HTTP " .. code end
    return body
end

-- ------------------------------------------------------------
-- signed device API
-- ------------------------------------------------------------
local function signedCall(method, path, bodyTable)
    local body = ""
    if bodyTable ~= nil then body = textutils.serializeJSON(bodyTable) end
    local url = s.agentBaseUrl .. path
    local sig = toHex(hmacSha256(s.secret, method .. "\n" .. path .. "\n" .. s.seq .. "\n" .. body))
    local headers = {
        ["x-agent-id"] = tostring(s.deviceId),
        ["x-agent-seq"] = tostring(s.seq),
        ["x-agent-sig"] = sig,
        ["content-type"] = "application/json",
    }
    local code, respBody, err = httpCall(method, url, method ~= "GET" and body or nil, headers, 45)
    if not code then
        return nil, tostring(err or "no response")
    end
    if code == 401 or code == 409 then
        log("signed call rejected (" .. code .. "): " .. tostring(respBody))
        log("seq out of sync - re-bootstrap: generate a new pairing token and run agentd.lua <id> <token>")
        return nil, "auth " .. code
    end
    if code < 200 or code >= 300 then
        return nil, "HTTP " .. code .. " " .. tostring(respBody)
    end
    s.seq = s.seq + 1
    saveSettings()
    local ok, parsed = pcall(textutils.unserialiseJSON, respBody or "")
    if not ok then return code, nil end
    return code, parsed
end

local function reportCommand(cid, status, result)
    local code, _ = signedCall("POST", "/agent/commands/" .. cid .. "/result", {
        status = status,
        result = result,
    })
    return code ~= nil
end

local function reportReleaseState(releaseId, state)
    local code, _ = signedCall("POST", "/agent/release-status", {
        releaseId = releaseId,
        state = state,
    })
    return code ~= nil
end

-- ------------------------------------------------------------
-- bootstrap launcher
-- ------------------------------------------------------------
local function writeLauncher()
    local launcher = [[
-- controlplane agent launcher (generated)
local function readActive()
  local f = fs.open("/controlplane/active.txt", "r")
  if not f then return nil end
  local p = f.readAll()
  f.close()
  return p ~= "" and p or nil
end
parallel.waitForAll(
  function()
    while true do
      local ok, err = pcall(shell.run, "/controlplane/agentd.lua")
      if not ok then io.stderr.write("agentd error: " .. tostring(err) .. "\n") end
      os.sleep(2)
    end
  end,
  function()
    local main = readActive()
    if main and fs.exists(main) then
      -- Run the release main from ITS folder so require("bunkerlib") etc.
      -- resolve against the flat lib bundle that ships with the release
      -- (same principle as the legacy deploy toolchain).
      local dir = fs.getDir(main) or "/"
      if pcall(shell.setDir, dir) then
        local name = fs.getName(main)
        while true do
          local ok, err = pcall(shell.run, name)
          if not ok then io.stderr.write("main error: " .. tostring(err) .. "\n") end
          os.sleep(3)
        end
      end
    end
  end
)
]]
    writeFile(LAUNCHER_FILE, launcher)
end

-- ------------------------------------------------------------
-- bootstrap
-- ------------------------------------------------------------
local function isAgentContent(s)
    return type(s) == "string" and s:find("CONTROLPLANE AGENT", 1, true) ~= nil
end

local function bootstrap(deviceId, token)
    log("bootstrap " .. deviceId)
    -- heal a possible stray file where /controlplane should be
    if fs.exists(BASE_DIR) and not fs.isDir(BASE_DIR) then
        fs.delete(BASE_DIR)
    end
    if not fs.exists(BASE_DIR) then fs.makeDir(BASE_DIR) end
    -- make THIS agent stable at SELF_FILE so startup.lua can always run it.
    -- wget run executes the script from inside CC's http program, so
    -- getRunningProgram() can be http.lua itself; never copy unverified bytes.
    local candidates = {}
    if _G.arg and type(_G.arg[0]) == "string" and _G.arg[0] ~= "" then
        candidates[#candidates + 1] = _G.arg[0]
    end
    local rp = shell.getRunningProgram()
    if rp and rp ~= "" and rp ~= SELF_FILE then
        candidates[#candidates + 1] = rp
    end
    candidates[#candidates + 1] = "agentd.lua"
    local copied = false
    for _, cand in ipairs(candidates) do
        if cand ~= SELF_FILE and fs.exists(cand) then
            local f = fs.open(cand, "r")
            local content = f and f.readAll()
            if f then f.close() end
            if isAgentContent(content) then
                fs.copy(cand, SELF_FILE)
                copied = true
                break
            end
        end
    end
    if not copied then
        local body, ferr = get(s.agentBaseUrl .. "/agentd.lua", 20)
        if body and isAgentContent(body) then
            writeFile(SELF_FILE, body)
            log("self-copy via http")
        else
            log("self-copy unavailable: " .. tostring(ferr or "no marker"))
        end
    end

    print(s.agentBaseUrl .. "/bootstrap/" .. token)
    local body, err = get(s.agentBaseUrl .. "/bootstrap/" .. token, 15)
    if not body then
        log("bootstrap failed: " .. tostring(err))
        term.setTextColor(colors.red)
        print("bootstrap failed: " .. tostring(err))
        print("check AGENT_BASE_URL + tunnel, and that the token is fresh.")
        term.setTextColor(colors.white)
        return false
    end
    local ok, data = pcall(textutils.unserialiseJSON, body)
    if not ok or type(data) ~= "table" then
        log("bootstrap: bad response")
        return false
    end
    s.deviceId = tostring(data.deviceId)
    s.secret = tostring(data.secret)
    s.seq = tonumber(data.seq) or 1
    s.agentBaseUrl = (tostring(data.agentBaseUrl or "")):gsub("/+$", "")
    s.pollSeconds = tonumber(data.pollSeconds) or 25
    s.evalLuaEnabled = data.evalLuaEnabled == true
    s.installStatus = "live"
    saveSettings()
    writeLauncher()
    log("bootstrap ok, device " .. s.deviceId)
    return true
end

-- ------------------------------------------------------------
-- command: generic device info
-- ------------------------------------------------------------
local function listPeripherals()
    local out = {}
    if peripheral then
        for _, side in ipairs(peripheral.getNames() or {}) do
            out[side] = peripheral.getType(side)
        end
    end
    return out
end

local function listMonitors(payload)
    local out = {}
    local wanted = payload and payload.side
    for side, typ in pairs(listPeripherals()) do
        if typ and typ:find("monitor") and (not wanted or side == wanted) then
            local ok, m = pcall(peripheral.wrap, side)
            local rec = { side = side, type = typ }
            if ok and m then
                local ok2, scale = pcall(function() return m.getTextScale() end)
                local ok3, size = pcall(function() return m.getSize() end)
                rec.textScale, rec.size = ok2 and scale or nil, ok3 and size or nil
            end
            out[side] = rec
        end
    end
    return out
end

local function readConfig()
    local raw = readFile(CONFIG_FILE)
    if not raw then return {} end
    local chunk, lerr = load(raw, "config")
    if not chunk then return { error = tostring(lerr) } end
    local ok, cfg = pcall(chunk)
    if not ok or type(cfg) ~= "table" then return { error = "config is not a table" } end
    return cfg
end

local function computeMain(releaseId, role)
    if not releaseId or not role then return nil end
    local base = RELEASES_DIR .. "/" .. releaseId
    for _, c in ipairs({ "subsystem/" .. role .. "/src/main.lua", "subsystem/" .. role .. "/main.lua", "main.lua" }) do
        local p = base .. "/" .. c
        if fs.exists(p) then return p end
    end
    return nil
end

local function setActiveMain(path)
    writeFile(BASE_DIR .. "/active.txt", path or "")
end

-- ------------------------------------------------------------
-- command: release deploy
-- ------------------------------------------------------------
local function installRelease(payload)
    local releaseId = payload and payload.releaseId
    local manifestUrl = payload and payload.manifestUrl
    local healthTimeout = tonumber((payload and payload.healthTimeoutSeconds) or 60)
    if not releaseId or not manifestUrl then
        return { ok = false, error = "release.deploy: releaseId + manifestUrl required" }
    end

    local manifestRaw, err = get(manifestUrl, 30)
    if not manifestRaw then
        reportReleaseState(releaseId, "failed")
        return { ok = false, error = "manifest fetch: " .. tostring(err) }
    end
    local okM, manifest = pcall(textutils.unserialiseJSON, manifestRaw)
    if not okM or type(manifest) ~= "table" or type(manifest.files) ~= "table" then
        reportReleaseState(releaseId, "failed")
        return { ok = false, error = "bad manifest" }
    end

    local relBase = manifestUrl:gsub("/manifest%.json$", "")
    local destDir = RELEASES_DIR .. "/" .. releaseId
    if fs.exists(destDir) then fs.delete(destDir) end
    fs.makeDir(destDir)

    reportReleaseState(releaseId, "pending")

    for _, file in ipairs(manifest.files) do
        local relPath = file.path
        local url = relBase .. "/" .. relPath
        log("fetch " .. relPath)
        local data, ferr = get(url, 45)
        if not data then
            reportReleaseState(releaseId, "failed")
            return { ok = false, error = "fetch " .. relPath .. ": " .. tostring(ferr) }
        end
        if sha256(data) ~= file.hash then
            reportReleaseState(releaseId, "failed")
            return { ok = false, error = "hash mismatch on " .. relPath }
        end
        if not writeFile(destDir .. "/" .. relPath, data) then
            reportReleaseState(releaseId, "failed")
            return { ok = false, error = "cannot write " .. relPath }
        end
    end

    -- compute the role main program path
    local mainPath = computeMain(releaseId, manifest.role)

    s.previousRelease = s.currentRelease
    s.currentRelease = releaseId
    s.releaseRole = manifest.role
    s.releaseMain = mainPath
    s.installStatus = "pending"
    setActiveMain(mainPath)
    saveSettings()

    log("release " .. releaseId .. " installed; health check after reboot")
    return { ok = true, reboot = true }
end

-- ------------------------------------------------------------
-- command: health check after reboot
-- ------------------------------------------------------------
local function verifyHealth()
    local releaseId = s.currentRelease
    if not releaseId or s.installStatus ~= "pending" then return end
    local healthy = false
    for _ = 1, 60 do
        if fs.exists(HEALTH_FILE) then
            local content = readFile(HEALTH_FILE) or ""
            if content:find("healthy") then
                healthy = true
                break
            end
        end
        os.sleep(1)
    end
    if healthy then
        s.installStatus = "healthy"
        saveSettings()
        reportReleaseState(releaseId, "healthy")
        log("release " .. releaseId .. " is healthy")
    else
        s.installStatus = "failed"
        saveSettings()
        reportReleaseState(releaseId, "failed")
        log("release " .. releaseId .. " HEALTH CHECK FAILED")
    end
end

-- ------------------------------------------------------------
-- command handlers
-- ------------------------------------------------------------
local function handleCommand(cmd)
    local cid, ctype, payload = cmd.cid, cmd.type, cmd.payload or {}
    log("cmd " .. tostring(cid) .. " " .. tostring(ctype))

    if ctype == "inspect" then
        return reportCommand(cid, "done", {
            computerId = os.getComputerID(),
            label = os.getComputerLabel() or ("cc" .. os.getComputerID()),
            agentVersion = AGENT_VERSION,
            uptime = math.floor(os.uptime()),
            epochMs = os.epoch("utc"),
            peripherals = listPeripherals(),
            currentRelease = s.currentRelease,
            installStatus = s.installStatus,
            monitors = listMonitors(nil),
        })
    elseif ctype == "log.read" then
        local n = tonumber((payload and payload.lines) or 100)
        local raw = readFile(LOG_FILE) or ""
        local lines = {}
        for line in raw:gmatch("[^\r\n]+") do lines[#lines + 1] = line end
        local tail = {}
        for i = math.max(1, #lines - n + 1), #lines do tail[#tail + 1] = lines[i] end
        return reportCommand(cid, "done", { lines = tail })
    elseif ctype == "config.read" then
        return reportCommand(cid, "done", { config = readConfig() })
    elseif ctype == "config.write" then
        local cfg = payload.config
        if type(cfg) ~= "table" then
            return reportCommand(cid, "error", "config.write: config must be an object")
        end
        writeFile(CONFIG_FILE, "return " .. textutils.serialize(cfg))
        return reportCommand(cid, "done", { ok = true })
    elseif ctype == "eval_lua" then
        if not s.evalLuaEnabled then
            return reportCommand(cid, "error", "eval_lua is disabled on this agent")
        end
        local code = payload.code
        if type(code) ~= "string" then
            return reportCommand(cid, "error", "eval_lua: code string required")
        end
        local chunk, cerr = load(code, "=eval", "t", _G)
        if not chunk then
            return reportCommand(cid, "error", "eval_lua compile: " .. tostring(cerr))
        end
        local co = coroutine.create(chunk)
        local timer = os.startTimer(5)
        local timeout = false
        local res
        while coroutine.status(co) ~= "dead" and not timeout do
            local oks, r = coroutine.resume(co)
            res = r
            if not oks then
                return reportCommand(cid, "error", "eval_lua: " .. tostring(r))
            end
            if coroutine.status(co) ~= "dead" then
                local ev, p1 = os.pullEvent()
                if ev == "timer" and p1 == timer then timeout = true end
                if ev == "terminate" then
                    return reportCommand(cid, "error", "eval_lua: terminated")
                end
            end
        end
        if timeout then
            return reportCommand(cid, "error", "eval_lua: timed out")
        end
        return reportCommand(cid, "done", { result = tostring(res) })
    elseif ctype == "reboot" then
        reportCommand(cid, "done", { reboot = true })
        log("reboot requested, rebooting")
        os.sleep(0.5)
        os.reboot()
    elseif ctype == "agent.update" then
        local newCode, err = get(s.agentBaseUrl .. "/agentd.lua", 45)
        if not newCode then
            return reportCommand(cid, "error", "agent.update: " .. tostring(err))
        end
        writeFile(SELF_FILE, newCode)
        writeFile("/agentd.lua", newCode)
        reportCommand(cid, "done", { updated = AGENT_VERSION, to = "latest" })
        os.reboot()
    elseif ctype == "release.deploy" then
        local res = installRelease(payload)
        if not res.ok then
            return reportCommand(cid, "error", res.error or "deploy failed")
        end
        reportCommand(cid, "done", { installed = true, releaseId = s.currentRelease })
        if res.reboot then
            os.sleep(0.5)
            os.reboot()
        end
        return true
    elseif ctype == "release.rollback" then
        if not s.previousRelease then
            return reportCommand(cid, "error", "release.rollback: no previous release")
        end
        reportReleaseState(s.currentRelease, "rolled_back")
        local old = s.previousRelease
        s.previousRelease = nil
        s.currentRelease = old
        s.installStatus = "live"
        s.releaseMain = computeMain(old, s.releaseRole)
        setActiveMain(s.releaseMain)
        saveSettings()
        reportCommand(cid, "done", { rolledBack = true, releaseId = old })
        os.reboot()
    elseif ctype == "monitor.capture" then
        return reportCommand(cid, "done", { monitors = listMonitors(payload) })
    else
        return reportCommand(cid, "error", "unknown command type: " .. tostring(ctype))
    end
end

-- ------------------------------------------------------------
-- main loop
-- ------------------------------------------------------------
local function register()
    if s.registered then return end
    local code, _ = signedCall("POST", "/agent/register", {
        label = os.getComputerLabel() or ("cc" .. os.getComputerID()),
        version = AGENT_VERSION,
    })
    if code then
        s.registered = true
        saveSettings()
    end
end

local function agentLoop()
    while true do
        -- release health handshake first if we are mid-deploy
        if s.installStatus == "pending" then
            verifyHealth()
        end
        -- Continuous long-polling: the server holds the connection and
        -- responds as soon as a new command is enqueued, so commands land
        -- near-instantly instead of on a misaligned 25 s cadence.
        local code, resp = signedCall("POST", "/agent/poll", {})
        if not code then
            os.sleep(math.min(s.pollSeconds or 25, 10))
        else
            local commands = resp and resp.commands
            if type(commands) == "table" and #commands > 0 then
                for _, cmd in ipairs(commands) do
                    handleCommand(cmd)
                end
            end
            os.sleep(1)
        end
    end
end

-- ------------------------------------------------------------
-- entry
-- ------------------------------------------------------------
local args = { ... }

local scriptUrl = _G.arg and _G.arg[0] or ""
local derivedBase = scriptUrl:match("^https?://[^/]+") or ""
if #args >= 3 and args[3] ~= "" then
    s.agentBaseUrl = args[3]
elseif derivedBase ~= "" then
    s.agentBaseUrl = derivedBase
else
    loadSettings()
end
s.agentBaseUrl = AGENT_BASE_URL_SERVE
s.agentBaseUrl = s.agentBaseUrl:gsub("/+$", "")

if #args >= 2 then
    if not bootstrap(args[1], args[2]) then return end
end

if not loadSettings() then
    term.setTextColor(colors.red)
    print("agentd: no settings. Run:  wget run <agentBaseUrl>/agentd.lua <deviceId> <token>")
    term.setTextColor(colors.white)
    return
end

log("agentd " .. AGENT_VERSION .. " start (device " .. s.deviceId .. ")")
if not s.registered then register() end
agentLoop()
