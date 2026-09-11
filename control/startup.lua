-- ============================================
-- BUNKER OS - CONTROL ROOM
-- Setup: control setup
-- Start: control (or control start)
-- ============================================

local args = {...}

-- ============ SHA-256 ============
local band = bit32.band
local bxor = bit32.bxor
local rrotate = bit32.rrotate
local rshift = bit32.rshift

local K = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

local function sha256(msg)
    local len = #msg * 8
    msg = msg .. "\128"
    while #msg % 64 ~= 56 do msg = msg .. "\0" end
    local h32 = math.floor(len / 4294967296)
    local l32 = len % 4294967296
    msg = msg .. string.char(
        0,0,0,0,
        math.floor(h32/16777216)%256, math.floor(h32/65536)%256, math.floor(h32/256)%256, h32%256,
        math.floor(l32/16777216)%256, math.floor(l32/65536)%256, math.floor(l32/256)%256, l32%256
    )

    local H = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}

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
            local s0 = bxor(rrotate(W[t-15],7), rrotate(W[t-15],18), rshift(W[t-15],3))
            local s1 = bxor(rrotate(W[t-2],17), rrotate(W[t-2],19), rshift(W[t-2],10))
            W[t] = band(W[t-16] + s0 + W[t-7] + s1)
        end
        local a,b,c,d,e,f,g,h = H[1],H[2],H[3],H[4],H[5],H[6],H[7],H[8]
        for t = 0, 63 do
            local S1 = bxor(rrotate(e,6), rrotate(e,11), rrotate(e,25))
            local ch = band(e,f) + band(bxor(e,0xFFFFFFFF),g)
            local t1 = band(h + S1 + ch + K[t+1] + W[t])
            local S0 = bxor(rrotate(a,2), rrotate(a,13), rrotate(a,22))
            local maj = band(a,b) + band(a,c) + band(b,c)
            local t2 = band(S0 + maj)
            h=g; g=f; f=e; e=band(d+t1); d=c; c=b; b=a; a=band(t1+t2)
        end
        H[1]=band(H[1]+a); H[2]=band(H[2]+b); H[3]=band(H[3]+c); H[4]=band(H[4]+d)
        H[5]=band(H[5]+e); H[6]=band(H[6]+f); H[7]=band(H[7]+g); H[8]=band(H[8]+h)
    end
    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",H[1],H[2],H[3],H[4],H[5],H[6],H[7],H[8])
end

-- ============ CONFIG ============
local HASH_FILE = "bunker.hash"
local UPDATE_INTERVAL = 2
local CONTROL_MONITOR = "monitor_4"

-- Content for the info monitors (later):
-- MONITOR_PANELS = { ["monitor_1"] = "clock", ["monitor_2"] = "sensor" }
local MONITOR_PANELS = {}
local rooms = {
    { id = "entrance", name = "Entrance" },
    { id = "me",       name = "ME-Core"       },
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

-- ============ MODEM ============
local function findModem()
    for _, side in ipairs(rs.getSides()) do
        local ok = pcall(rednet.open, side)
        if ok and rednet.isOpen(side) then return side end
    end
    return nil
end

-- ============ SETUP ============
local function runSetup()
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("==========================")
    print("     BUNKER OS - SETUP")
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
        print("Run: control setup")
        return
    end

    term.setTextColor(colors.cyan)
    print("=== BUNKER OS ===")
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

    local modem = findModem()
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

    local buttons = {}
    local statuses = {}

    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("=== BUNKER OS ===")
    term.setTextColor(colors.gray)
    print("Commands: s=status  exit=exit")

    local function drawHeader(mon)
        local w = mon.getSize()
        mon.setBackgroundColor(colors.black)
        mon.clear()
        local title = "BUNKER OS"
        mon.setCursorPos(math.max(1, math.floor((w - #title) / 2) + 1), 1)
        mon.setTextColor(colors.cyan)
        mon.write(title)
        mon.setCursorPos(1, 2)
        mon.setTextColor(colors.yellow)
        mon.write(string.rep("=", w))
    end

    local function drawStatusTable(mon, showButtons)
        local w = mon.getSize()
        local lightX = math.floor(w * 0.45)
        local btnX = w - 11
        local narrow = w < 24

        mon.setCursorPos(1, 4)
        mon.setTextColor(colors.yellow)
        mon.write(string.format("%-11s %s", "ROOM", "LIGHT"))
        mon.setCursorPos(1, 5)
        mon.setTextColor(colors.gray)
        mon.write(string.rep("-", w))

        local clientCount = 0
        for i, room in ipairs(rooms) do
            local y = 5 + i
            local status = statuses[room.id]
            local online = status ~= nil

            mon.setCursorPos(1, y)
            mon.setTextColor(colors.white)
            mon.write(room.name)

            mon.setCursorPos(lightX, y)
            if online then
                clientCount = clientCount + 1
                if status.light then
                    mon.setTextColor(colors.yellow)
                    mon.write(narrow and "ON " or "ON")
                else
                    mon.setTextColor(colors.gray)
                    mon.write(narrow and "OFF" or "OFF")
                end
            else
                mon.setTextColor(colors.red)
                mon.write("OFFLINE")
            end

            if showButtons then
                mon.setCursorPos(btnX, y)
                if online and status.light then
                    mon.setBackgroundColor(colors.green)
                else
                    mon.setBackgroundColor(colors.lightGray)
                end
                mon.setTextColor(colors.black)
                mon.write("[ TOGGLE ]")
                mon.setBackgroundColor(colors.black)
                buttons[y] = room.id
            end
        end

        return clientCount
    end

    local function drawInfoPlaceholder(mon)
        local w = mon.getSize()
        local inner = math.max(8, w - 6)
        mon.setCursorPos(2, 4)
        mon.setTextColor(colors.gray)
        mon.write("|" .. string.rep("=", inner) .. "|")
        mon.setCursorPos(2, 5)
        mon.write("|" .. string.rep(" ", inner) .. "|")
        mon.setCursorPos(3, 5)
        mon.setTextColor(colors.yellow)
        mon.write("INFO PANEL")
        mon.setCursorPos(2, 6)
        mon.setTextColor(colors.gray)
        mon.write("|" .. string.rep(" ", inner) .. "|")
        mon.setCursorPos(3, 6)
        mon.write("No content assigned yet.")
        mon.setCursorPos(2, 7)
        mon.write("|" .. string.rep(" ", inner) .. "|")
        mon.setCursorPos(3, 7)
        mon.write("Config: MONITOR_PANELS")
        mon.setCursorPos(2, 8)
        mon.write("|" .. string.rep("=", inner) .. "|")
    end

    local function drawFooter(mon, label, extra)
        local w = mon.getSize()
        local footerY = 5 + #rooms + 2
        mon.setCursorPos(1, footerY)
        mon.setTextColor(colors.yellow)
        mon.write(string.rep("=", w))
        mon.setCursorPos(1, footerY + 1)
        mon.setTextColor(colors.gray)
        mon.write(label)
        if extra then
            mon.setCursorPos(w - #extra, footerY + 1)
            mon.setTextColor(colors.cyan)
            mon.write(extra)
        end
    end

    local function drawMonitors()
        buttons = {}
        for _, mon in ipairs(monitors) do
            drawHeader(mon.mon)
            if mon.name == CONTROL_MONITOR then
                local clientCount = drawStatusTable(mon.mon, true)
                drawFooter(mon.mon, "CONTROL DISPLAY", "CLIENTS: " .. clientCount .. "/" .. #rooms)
            else
                drawInfoPlaceholder(mon.mon)
                drawFooter(mon.mon, "INFO DISPLAY")
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
            if p1 == CONTROL_MONITOR and buttons[p3] then
                local roomId = buttons[p3]
                local status = statuses[roomId]
                if status then
                    rednet.send(status.senderId, { room = roomId, cmd = "light", state = not status.light }, "bunker_cmd")
                end
            end

        elseif event == "rednet_message" then
            local senderId, message, protocol = p1, p2, p3
            if protocol == "bunker_status" and type(message) == "table" and message.id then
                statuses[message.id] = {
                    light = message.light,
                    senderId = senderId,
                    lastSeen = os.clock(),
                }
                drawMonitors()
            end

        elseif event == "char" then
            if p1:lower() == "s" then
                for id, s in pairs(statuses) do
                    print(id .. ": " .. (s.light and "LIGHT ON" or "LIGHT OFF"))
                end
            end
        end

        for id, s in pairs(statuses) do
            if os.clock() - s.lastSeen > 10 then
                statuses[id] = nil
            end
        end
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
    print("=== BUNKER OS ===")
    term.setTextColor(colors.white)
    print("Usage:")
    print("  setup     -> set password")
    print("  start     -> start control room")
end