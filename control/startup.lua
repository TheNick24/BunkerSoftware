-- ============================================
-- MAMDANI OS - CONTROL ROOM
-- Setup: control setup
-- Start: control (or control start)
-- ============================================

local args = { ... }

-- ============ LIB ============
local dir = fs.getDir(shell.getRunningProgram())
package.path = fs.combine(dir, "?.lua") .. ";" .. package.path
local bunkerlib = require("bunkerlib")

-- ============ SHA-256 ============
local band = bit32.band
local bxor = bit32.bxor
local rrotate = bit32.rrotate
local rshift = bit32.rshift

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

local function sha256(msg)
    local len = #msg * 8
    msg = msg .. "\128"
    while #msg % 64 ~= 56 do msg = msg .. "\0" end
    local h32 = math.floor(len / 4294967296)
    local l32 = len % 4294967296
    msg = msg .. string.char(
        0, 0, 0, 0,
        math.floor(h32 / 16777216) % 256, math.floor(h32 / 65536) % 256, math.floor(h32 / 256) % 256, h32 % 256,
        math.floor(l32 / 16777216) % 256, math.floor(l32 / 65536) % 256, math.floor(l32 / 256) % 256, l32 % 256
    )

    local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }

    for chunk = 0, #msg - 1, 64 do
        local W = {}
        for t = 0, 15 do
            local o = chunk + t * 4
            local a = string.byte(msg, o + 1) or 0
            local b = string.byte(msg, o + 2) or 0
            local c = string.byte(msg, o + 3) or 0
            local d = string.byte(msg, o + 4) or 0
            W[t] = a * 16777216 + b * 65536 + c * 256 + d
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
            local maj = band(a, b) + band(a, c) + band(b, c)
            local t2 = band(S0 + maj)
            h = g; g = f; f = e; e = band(d + t1); d = c; c = b; b = a; a = band(t1 + t2)
        end
        H[1] = band(H[1] + a); H[2] = band(H[2] + b); H[3] = band(H[3] + c); H[4] = band(H[4] + d)
        H[5] = band(H[5] + e); H[6] = band(H[6] + f); H[7] = band(H[7] + g); H[8] = band(H[8] + h)
    end
    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8])
end

-- ============ CONFIG ============
local HASH_FILE = "bunker.hash"
local UPDATE_INTERVAL = 2

-- Device groups. Rooms are regular rooms, special groups are NOT part of
-- a room (corridor lamps, doors, ...). Each entry needs a unique `id`.
local rooms = {
    { id = "entrance", name = "Entrance" },
    { id = "me",       name = "ME-Core" },
    { id = "control",  name = "Control-Room" },
}

local aux = {
    { id = "me-corridor-1", name = "ME Corridor 1" },
    { id = "control-corridor-1",  name = "CR Corridor 1"}
}

-- Doors. Same pattern as the light groups.
local doors = {
    { id = "control-door", name = "Control Door" },
}

-- Monitor panels: assign each monitor a device group.
-- `action` selects the device behavior ("light" = on/off toggle) and must
-- match the client device's `cmd`. New device types just need a list above
-- (with unique ids) + one row here.
local MONITOR_PANELS = {
    ["monitor_4"] = { title = "ROOM LIGHTS",     action = "light", header = "LIGHT", entries = rooms },
    ["monitor_7"] = { title = "CORRIDOR LIGHTS", action = "light", header = "LIGHT", entries = aux },
    ["monitor_3"] = { title = "DOOR",            action = "door", header = "DOOR",
                      onText = "OPEN", offText = "CLOSED", entries = doors },
}

-- ============ HASH ============
local function loadHash()
    if fs.exists(HASH_FILE) then
        local f = fs.open(HASH_FILE, "r")
        local h = f.readAll()
        f.close()
        return h
    end
    return nil
end

local function saveHash(hash)
    local f = fs.open(HASH_FILE, "w")
    f.write(hash)
    f.close()
end

-- ============ SETUP ============
local function runSetup()
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("==========================")
    print("     MAMDANI OS - SETUP")
    print("==========================")
    term.setTextColor(colors.white)
    print("New password:")
    term.setTextColor(colors.gray)
    local p1 = read("*")
    term.setTextColor(colors.white)
    print("Repeat password:")
    term.setTextColor(colors.gray)
    local p2 = read("*")
    term.setTextColor(colors.white)
    if p1 ~= p2 then
        term.setTextColor(colors.red)
        print("Passwords do not match!")
        return
    end
    if #p1 < 6 then
        term.setTextColor(colors.red)
        print("Password too short (min. 6 characters)!")
        return
    end
    local h = sha256(p1)
    saveHash(h)
    term.setTextColor(colors.green)
    print("Password saved!")
    term.setTextColor(colors.white)
end

-- ============ CONTROL ROOM ============
local function runControl()
    local expected = loadHash()
    if not expected then
        term.setTextColor(colors.red)
        print("No password set up!")
        term.setTextColor(colors.white)
        print("Run: startup setup")
        return
    end

    term.setTextColor(colors.cyan)
    print("=== MAMDANI OS ===")
    term.setTextColor(colors.white)
    print("Password:")
    term.setTextColor(colors.gray)
    local input = read("*")
    if sha256(input) ~= expected then
        term.setTextColor(colors.red)
        print("Wrong password!")
        return
    end
    term.setTextColor(colors.green)
    print("Access granted!")

    local modem = bunkerlib.findModem()
    if not modem then
        term.setTextColor(colors.red)
        print("No modem found!")
        return
    end

    local monitors = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            table.insert(monitors, { name = name, mon = peripheral.wrap(name) })
        end
    end

    local buttons = {} -- buttons[monitorName][y] = device id
    local statuses = {}

    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("=== MAMDANI OS ===")
    term.setTextColor(colors.gray)
    print("Commands: s=status  exit=exit")

    local function drawMonitors()
        buttons = {}
        for _, mon in ipairs(monitors) do
            local panel = MONITOR_PANELS[mon.name]
            bunkerlib.drawHeader(mon.mon)
            if panel and #panel.entries > 0 then
                local btns = {}
                buttons[mon.name] = btns
                local n = bunkerlib.drawPanel(mon.mon, panel, statuses, btns, true)
                bunkerlib.drawFooter(mon.mon, #panel.entries, panel.title, "CLIENTS: " .. n .. "/" .. #panel.entries)
            else
                bunkerlib.drawInfoPlaceholder(mon.mon)
                bunkerlib.drawFooter(mon.mon, 3, "INFO DISPLAY")
            end
        end
    end

    drawMonitors()
    local updateTimer = os.startTimer(UPDATE_INTERVAL)

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "timer" and p1 == updateTimer then
            drawMonitors()
            updateTimer = os.startTimer(UPDATE_INTERVAL)
        elseif event == "monitor_touch" then
            local btns = buttons[p1]
            if btns and btns[p3] then
                local id = btns[p3]
                local status = statuses[id]
                local panel = MONITOR_PANELS[p1]
                if status and panel then
                    local action = bunkerlib.ACTIONS[panel.action or "light"]
                    if action then
                        local msg = action(status, id)
                        rednet.send(status.senderId, msg, "bunker_cmd")
                    end
                end
            end
        elseif event == "rednet_message" then
            local senderId, message, protocol = p1, p2, p3
            if protocol == "bunker_status" and type(message) == "table" and message.id then
                bunkerlib.setStatus(statuses, message.id, senderId, message.state)
                drawMonitors()
            end
        elseif event == "char" then
            if p1:lower() == "s" then
                for id, s in pairs(statuses) do
                    print(id .. ": " .. (s.state and "STATE ON" or "STATE OFF"))
                end
            end
        end

        bunkerlib.cleanStatuses(statuses, 10)
    end
end

-- ============ MAIN ============
local cmd = args[1]

if cmd == "setup" then
    runSetup()
elseif cmd == "start" or cmd == nil then
    runControl()
else
    term.setTextColor(colors.cyan)
    print("=== MAMDANI OS ===")
    term.setTextColor(colors.white)
    print("Usage:")
    print("  setup     -> set password")
    print("  start     -> start control room")
end