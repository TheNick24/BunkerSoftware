-- ============================================
-- MAMDANI OS - SHARED LIBRARY
-- Copy this file (bunkerlib.lua) to EVERY computer
-- that runs a MAMDANI program, into the SAME
-- folder as the program.
-- Load with:
--   local dir = fs.getDir(shell.getRunningProgram())
--   package.path = fs.combine(dir, "?.lua") .. ";" .. package.path
--   local bunkerlib = require("bunkerlib")
-- ============================================

local bunkerlib = {}

-- ============ NETWORK ============

-- Opens the first working modem. Tries `preferredSide` first
-- (nil = auto), then all other sides.
function bunkerlib.findModem(preferredSide)
    local order = {}
    if preferredSide and preferredSide ~= "" then table.insert(order, preferredSide) end
    for _, side in ipairs(rs.getSides()) do
        if side ~= preferredSide then table.insert(order, side) end
    end
    for _, side in ipairs(order) do
        local ok = pcall(rednet.open, side)
        if ok and rednet.isOpen(side) then return side end
    end
    return nil
end

-- Prints a message only when it changes (dedupe per key).
function bunkerlib.printOnce(cache, key, txt)
    if cache[key] ~= txt then
        cache[key] = txt
        term.setTextColor(colors.red)
        print(txt)
        term.setTextColor(colors.white)
    end
end

-- ============ SHA-256 ============
local band    = bit32.band
local bxor    = bit32.bxor
local rrotate = bit32.rrotate
local rshift  = bit32.rshift

local SHA256_K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

function bunkerlib.sha256(msg)
    local len = #msg * 8
    msg = msg .. "\128"
    while #msg % 64 ~= 56 do msg = msg .. "\0" end
    local h32 = math.floor(len / 4294967296)
    local l32 = len % 4294967296
    msg = msg .. string.char(
        0, 0, 0, 0,
        math.floor(h32 / 16777216) % 256, math.floor(h32 / 65536) % 256,
        math.floor(h32 / 256) % 256, h32 % 256,
        math.floor(l32 / 16777216) % 256, math.floor(l32 / 65536) % 256,
        math.floor(l32 / 256) % 256, l32 % 256
    )
    local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    for chunk = 0, #msg - 1, 64 do
        local W = {}
        for t = 0, 15 do
            local o = chunk + t * 4
            W[t] = (string.byte(msg,o+1) or 0) * 16777216
                 + (string.byte(msg,o+2) or 0) * 65536
                 + (string.byte(msg,o+3) or 0) * 256
                 + (string.byte(msg,o+4) or 0)
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
            local t1 = band(h + S1 + ch + SHA256_K[t+1] + W[t])
            local S0 = bxor(rrotate(a,2), rrotate(a,13), rrotate(a,22))
            local maj = band(a,b) + band(a,c) + band(b,c)
            local t2 = band(S0 + maj)
            h=g; g=f; f=e; e=band(d+t1); d=c; c=b; b=a; a=band(t1+t2)
        end
        H[1]=band(H[1]+a); H[2]=band(H[2]+b); H[3]=band(H[3]+c); H[4]=band(H[4]+d)
        H[5]=band(H[5]+e); H[6]=band(H[6]+f); H[7]=band(H[7]+g); H[8]=band(H[8]+h)
    end
    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
        H[1],H[2],H[3],H[4],H[5],H[6],H[7],H[8])
end

-- ============ RELAY (protected accesses) ============
function bunkerlib.relayGet(relay, side, onError)
    local ok, res = pcall(peripheral.call, relay, "getOutput", side)
    if ok then return res end
    if onError then onError(tostring(res)) end
    return false
end

function bunkerlib.relaySet(relay, side, state, onError)
    local ok, res = pcall(peripheral.call, relay, "setOutput", side, state)
    if not ok and onError then onError(tostring(res)) end
end

-- ============ STATUS CACHE ============
function bunkerlib.setStatus(statuses, id, senderId, state)
    statuses[id] = {
        state = state,
        senderId = senderId,
        lastSeen = os.clock(),
    }
end

function bunkerlib.cleanStatuses(statuses, timeout)
    for id, s in pairs(statuses) do
        if os.clock() - s.lastSeen > timeout then
            statuses[id] = nil
        end
    end
end

-- ============ MONITORS ============
function bunkerlib.drawHeader(mon)
    local w = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()
    local title = "MAMDANI OS"
    mon.setCursorPos(math.max(1, math.floor((w - #title) / 2) + 1), 1)
    mon.setTextColor(colors.cyan)
    mon.write(title)
    mon.setCursorPos(1, 2)
    mon.setTextColor(colors.yellow)
    mon.write(string.rep("=", w))
end

function bunkerlib.drawInfoPlaceholder(mon)
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

function bunkerlib.drawFooter(mon, rows, label, extra)
    local w, h = mon.getSize()
    -- pinned to the bottom of the monitor, but below the table if it is long
    local footerY = math.max(h - 1, 5 + rows + 2)
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

-- ============ DEVICE DRIVERS ============

-- A driver defines HOW a device is read/set on the client.
-- A device is only a configured instance of a driver (e.g. lights via
-- a relay, doors directly on a redstone output, ...). Add new transports
-- (other peripherals) here - the rest of the system stays unchanged.
bunkerlib.DRIVERS = {
    -- Controlled through a redstone relay peripheral.
    relay = {
        name = "relay",
        describe = function(dev)
            return (dev.relay or "?") .. " [" .. (dev.side or "?") .. "]"
        end,
        read = function(dev)
            return peripheral.call(dev.relay, "getOutput", dev.side)
        end,
        set = function(dev, state)
            peripheral.call(dev.relay, "setOutput", dev.side, state)
        end,
    },

    -- Controlled DIRECTLY on a computer redstone output (no relay).
    redstone = {
        name = "redstone",
        describe = function(dev)
            return "redstone [" .. (dev.side or "?") .. "]"
        end,
        read = function(dev)
            return rs.getOutput(dev.side)
        end,
        set = function(dev, state)
            rs.setOutput(dev.side, state)
        end,
    },

    -- Door controlled through a redstone link bridge / contact peripheral
    -- (e.g. redstone_link_bridge_1) on the given side.
    -- A redstone signal ON means the door is CLOSED, so the state is
    -- inverted: state true = OPEN, false = CLOSED.
    door = {
        name = "door",
        describe = function(dev)
            return (dev.peripheral or "?") .. " [" .. (dev.side or "?") .. "]"
        end,
        read = function(dev)
            return not peripheral.call(dev.peripheral, "getOutput", dev.side)
        end,
        set = function(dev, state)
            peripheral.call(dev.peripheral, "setOutput", dev.side, not state)
        end,
    },
}

function bunkerlib.driver(name)
    return bunkerlib.DRIVERS[name] or bunkerlib.DRIVERS.relay
end

-- ============ ACTIONS ============

-- An action defines what a monitor button press sends. Device types with
-- a different behavior (e.g. doors with open/close) get a new entry here.
-- The `cmd` of the action must match the `cmd` of the client device.
bunkerlib.ACTIONS = {
    light = function(status, id)
        return { room = id, cmd = "light", state = not status.state }
    end,
    -- Door: open/close toggle (controllable).
    door = function(status, id)
        return { room = id, cmd = "door", state = not status.state }
    end,
    -- Safety door: binary open/closed door (can only be ON or OFF).
    -- Same toggle behavior as "door", but a separate type/group.
    ["safety-door"] = function(status, id)
        return { room = id, cmd = "safety-door", state = not status.state }
    end,
}

-- ============ MONITOR PANELS ============

-- Draws a device group with ON/OFF state + click buttons.
-- `btns[y]` gets { id = device id, action = action name } for every drawn row.
-- The state column is pushed right, sitting flush left of the button, so
-- the names get the whole remaining width. Header and state texts are
-- centered within that column.
-- opts: { action = action name for the row buttons (default "light"),
--         button = label shown in each row (default "[CLICK]"),
--         header = state column title (default "STATE"),
--         onText / offText = texts for state true/false
--                           (default "ON" / "OFF") }
-- startRow: row where the header is drawn (default 4).
-- Returns the number of online devices.
function bunkerlib.drawToggleTable(mon, entries, statuses, btns, showButtons, opts, startRow)
    opts = opts or {}
    startRow = startRow or 4
    local w = mon.getSize()
    local action = opts.action or "light"
    local label = opts.button or "[CLICK]"
    local btnW = #label
    local btnX = w - btnW + 1         -- button at the far right edge
    local header = opts.header or "STATE"
    local onText = opts.onText or "ON"
    local offText = opts.offText or "OFF"
    -- column width fits header + both state texts + "OFFLINE"
    local stateW = math.max(#header, #onText, #offText, #"OFFLINE")
    local zoneRight = btnX - 1
    local zoneLeft = zoneRight - stateW + 1
    local centerX = function(len)
        return zoneLeft + math.floor((stateW - len) / 2)
    end
    local maxName = math.max(3, zoneLeft - 2)

    mon.setCursorPos(1, startRow)
    mon.setTextColor(colors.yellow)
    mon.write("NAME")
    mon.setCursorPos(centerX(#header), startRow)
    mon.write(header)
    mon.setCursorPos(1, startRow + 1)
    mon.setTextColor(colors.gray)
    mon.write(string.rep("-", w))

    local clientCount = 0
    for i, entry in ipairs(entries) do
        local y = startRow + 1 + i
        local status = statuses[entry.id]
        local online = status ~= nil

        local name = entry.name
        if #name > maxName then
            name = string.sub(name, 1, maxName)
        end
        mon.setCursorPos(1, y)
        mon.setTextColor(colors.white)
        mon.write(name)

        if online then
            clientCount = clientCount + 1
            local txt = status.state and onText or offText
            mon.setCursorPos(centerX(#txt), y)
            if status.state then
                mon.setTextColor(colors.yellow)
            else
                mon.setTextColor(colors.gray)
            end
            mon.write(txt)
        else
            mon.setCursorPos(zoneRight - 7 + 1, y)
            mon.setTextColor(colors.red)
            mon.write("OFFLINE")
        end

        if showButtons then
            mon.setCursorPos(btnX, y)
            if online and status.state then
                mon.setBackgroundColor(colors.green)
            else
                mon.setBackgroundColor(colors.lightGray)
            end
            mon.setTextColor(colors.black)
            mon.write(label)
            mon.setBackgroundColor(colors.black)
            btns[y] = { id = entry.id, action = action }
        end
    end

    return clientCount
end

-- Draws a monitor panel. A panel can be either a single device group
-- (as before) or multiple groups/sections, so one monitor can show
-- several device types (e.g. doors + safety doors):
--   panel: { title, action = "light", entries = { {id,name}, ... },
--            button = optional button label, header = optional column title,
--            onText / offText = optional state texts }
--   OR
--   panel: { title, sections = {
--            { title, action, button?, header?, onText?, offText?, entries },
--            ... } }
-- Returns the number of online devices and the last used row.
function bunkerlib.drawPanel(mon, panel, statuses, btns, showButtons)
    if panel.sections then
        local y = 3
        local clientCount = 0
        for _, sec in ipairs(panel.sections) do
            y = y + 1
            mon.setCursorPos(1, y)
            mon.setTextColor(colors.cyan)
            mon.write(sec.title or panel.title or "GROUP")
            clientCount = clientCount + bunkerlib.drawToggleTable(mon, sec.entries, statuses,
                btns, showButtons, {
                    action  = sec.action or panel.action,
                    button  = sec.button or panel.button,
                    header  = sec.header,
                    onText  = sec.onText,
                    offText = sec.offText,
                }, y + 1)
            y = y + 2 + #sec.entries
        end
        return clientCount, y
    end
    local n = bunkerlib.drawToggleTable(mon, panel.entries, statuses, btns, showButtons, {
        action  = panel.action,
        button  = panel.button,
        header  = panel.header,
        onText  = panel.onText,
        offText = panel.offText,
    })
    return n, 5 + #panel.entries
end

-- ============ CLIENT ============

-- Runs a full client: opens the modem, prints the banner, broadcasts
-- the state of every device and reacts to bunker_cmd commands.
-- conf:
--   name      = client display name (header line)
--   modemSide = preferred modem side (nil = auto)
--   interval  = status broadcast interval (seconds)
--   devices   = { { id, cmd = "light", driver = "relay"|"redstone",
--                   relay?, side }, ... }
function bunkerlib.runClient(conf)
    local modem = bunkerlib.findModem(conf.modemSide)
    if not modem then
        term.setTextColor(colors.red)
        print("No modem found!")
        return
    end

    local devices = {}
    for _, d in ipairs(conf.devices or {}) do
        devices[#devices + 1] = {
            id = d.id,
            cmd = d.cmd or "light",
            driver = bunkerlib.driver(d.driver),
            conf = d,
        }
    end

    local errs = {}
    local function read(dev)
        local ok, res = pcall(dev.driver.read, dev.conf)
        if ok then
            errs[dev.id] = nil
            return res
        end
        bunkerlib.printOnce(errs, dev.id, dev.driver.name .. " error (" .. dev.id .. "): " .. tostring(res))
        return false
    end
    local function set(dev, state)
        local ok, res = pcall(dev.driver.set, dev.conf, state)
        if not ok then
            bunkerlib.printOnce(errs, dev.id, dev.driver.name .. " error (" .. dev.id .. "): " .. tostring(res))
        end
    end

    local function sendStatus()
        for _, dev in ipairs(devices) do
            rednet.broadcast({ id = dev.id, cmd = dev.cmd, state = read(dev) }, "bunker_status")
        end
    end

    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("==========================")
    print("       MAMDANI OS")
    term.setTextColor(colors.white)
    print("    Client: " .. (conf.name or "BUNKER"))
    term.setTextColor(colors.cyan)
    print("==========================")
    term.setTextColor(colors.gray)
    print("Modem: " .. modem)
    for _, dev in ipairs(devices) do
        term.setTextColor(colors.cyan)
        print("  " .. dev.id .. " -> " .. dev.driver.describe(dev.conf))
    end
    term.setTextColor(colors.white)
    print("---")

    sendStatus()
    local statusTimer = os.startTimer(conf.interval)

    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "timer" and p1 == statusTimer then
            sendStatus()
            statusTimer = os.startTimer(conf.interval)
        elseif event == "rednet_message" then
            local senderId, message, protocol = p1, p2, p3
            if protocol == "bunker_cmd" and type(message) == "table" and message.cmd then
                for _, dev in ipairs(devices) do
                    if dev.id == message.room and dev.cmd == message.cmd then
                        set(dev, message.state)
                        sendStatus()
                        term.setTextColor(colors.yellow)
                        print(dev.id .. ": " .. (message.state and "ON" or "OFF"))
                        term.setTextColor(colors.white)
                        break
                    end
                end
            end
        end
        -- optional custom event handler (e.g. for keypad monitors)
        if conf.onEvent then
            pcall(conf.onEvent, event, p1, p2, p3)
        end
    end
end

return bunkerlib