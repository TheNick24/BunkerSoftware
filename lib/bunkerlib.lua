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
}

-- ============ MONITOR PANELS ============

-- Draws a device group with ON/OFF state + click buttons.
-- `btns[y]` gets the device id for every drawn row.
-- State is right-aligned (ends right before the button), so long room
-- names do not collide with it.
-- opts: { button = label shown in each row (default "[CLICK]"),
--         header = state column title (default "STATE") }
-- Returns the number of online devices.
function bunkerlib.drawToggleTable(mon, entries, statuses, btns, showButtons, opts)
    opts = opts or {}
    local w = mon.getSize()
    local label = opts.button or "[CLICK]"
    local btnW = #label
    local btnX = w - btnW + 1         -- button at the far right edge
    local header = opts.header or "STATE"
    -- the state column is pushed right, sitting flush left of the button,
    -- so the names get the whole remaining width
    local headerX = btnX - #header -- header starts directly left of the button
    local stateRight = headerX + #header - 1
    local maxName = math.max(3, headerX - 2)

    mon.setCursorPos(1, 4)
    mon.setTextColor(colors.yellow)
    mon.write("NAME")
    mon.setCursorPos(headerX, 4)
    mon.write(header)
    mon.setCursorPos(1, 5)
    mon.setTextColor(colors.gray)
    mon.write(string.rep("-", w))

    local clientCount = 0
    for i, entry in ipairs(entries) do
        local y = 5 + i
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
            local txt = status.state and "ON" or "OFF"
            -- centered under the state column header (e.g. "LIGHT")
            mon.setCursorPos(headerX + math.floor((#header - #txt) / 2), y)
            if status.state then
                mon.setTextColor(colors.yellow)
            else
                mon.setTextColor(colors.gray)
            end
            mon.write(txt)
        else
            mon.setCursorPos(stateRight - 7 + 1, y)
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
            btns[y] = entry.id
        end
    end

    return clientCount
end

-- Draws a monitor panel (its configured device group).
-- panel: { title, action = "light", entries = { {id,name}, ... },
--          button = optional button label, header = optional column title }
function bunkerlib.drawPanel(mon, panel, statuses, btns, showButtons)
    return bunkerlib.drawToggleTable(mon, panel.entries, statuses, btns, showButtons, {
        button = panel.button,
        header = panel.header,
    })
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
            rednet.broadcast({ id = dev.id, state = read(dev) }, "bunker_status")
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
    end
end

return bunkerlib