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

-- ============ CONFIG ============
local HASH_FILE = "bunker.hash"
local UPDATE_INTERVAL = 2

-- The room itself always runs (lights, monitors, status) - only the command
-- console needs the password. It starts LOCKED and re-locks after inactivity.
local LOCK_AFTER_IDLE = 300   -- seconds of idle until the console locks again
local MAX_FAILED      = 5     -- failed unlock attempts until a lockout
local LOCKOUT_SECONDS = 60    -- lockout after too many failed attempts
local AUDIT_LOG       = "bunker.audit.log"

-- Device groups. Rooms are regular rooms, special groups are NOT part of
-- a room (corridor lamps, doors, ...). Each entry needs a unique `id`.
local rooms = {
    { id = "entrance", name = "Entrance" },
    { id = "me",       name = "ME-Core" },
    { id = "control",  name = "Control-Room" },
    { id = "maschine-room", name = "Maschine Room" },
}

local aux = {
    { id = "me-corridor-1", name = "ME Corridor 1" },
    { id = "me-corridor-2", name = "ME Corridor 2" },
    { id = "maschine-corridor-1", name = "Maschine Corridor 1" },
    { id = "control-corridor-1",  name = "CR Corridor 1"}
}

-- Doors. Same pattern as the light groups.
local doors = {
    { id = "control-door", name = "Control Door" },
    { id = "server-door", name = "Server Access Door"}
}

-- Safety doors: ALARM doors that normally stand OPEN and only close in an
-- emergency. Close them all at once with the `alarm` command (red banner).
local safetyDoors = {
    { id = "me-safety-1",          name = "ME Safety Door" },
    { id = "distributor-safety-1", name = "Distributor Safety Door" },
}

-- Monitor panels: assign each monitor a device group (or `sections` to show
-- several groups on one monitor). `action` selects the device behavior
-- ("light" = on/off toggle, "door"/"safety-door" = open/close) and must
-- match the client device's `cmd`. New device types just need a list above
-- (with unique ids) + one row here.
local MONITOR_PANELS = {
    ["monitor_4"] = { title = "ROOM LIGHTS",     action = "light", header = "LIGHT", entries = rooms },
    ["monitor_7"] = { title = "CORRIDOR LIGHTS", action = "light", header = "LIGHT", entries = aux },
    ["monitor_3"] = { title = "DOORS", sections = {
        { title = "DOOR",         action = "door",        onText = "OPEN", offText = "CLOSED", entries = doors },
        { title = "SAFETY DOORS", action = "safety-door", onText = "OPEN", offText = "CLOSED", entries = safetyDoors },
    } },
}

-- Dedicated monitor that ONLY shows a big tappable ALARM button
-- (tap = start/stop the emergency, same as the `alarm` console command).
local ALARM_BUTTON_MONITOR = "monitor_14"

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

-- ============ AUDIT LOG ============
-- Appends one timestamped line per security-relevant event (login attempts,
-- lock/unlock, blocked commands, alarms). Read the log with:
--   edit bunker.audit.log        (or: type bunker.audit.log)
local function audit(entry)
    local f = fs.open(AUDIT_LOG, "a")
    if f then
        f.write(os.date("%Y-%m-%d %H:%M:%S") .. "  " .. entry .. "\n")
        f.close()
    end
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
    local h = bunkerlib.hashPassword(p1)
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
    term.setTextColor(colors.gray)
    print("Console locked - type `unlock` then the password.")
    term.setTextColor(colors.white)

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

    local buttons = {} -- buttons[monitorName][y] = { id, action }
    local statuses = {}
    local alarm = false -- true = emergency: all safety doors CLOSED

    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("=== MAMDANI OS ===")
    term.setTextColor(colors.gray)
    print("Console locked - type `unlock` to enable commands.")

    local function countEntries(panel)
        if panel.sections then
            local n = 0
            for _, s in ipairs(panel.sections) do n = n + #s.entries end
            return n
        end
        return #panel.entries
    end

    local function drawMonitors()
        buttons = {}
        for _, mon in ipairs(monitors) do
            local panel = MONITOR_PANELS[mon.name]
            if mon.name == ALARM_BUTTON_MONITOR then
                -- dedicated monitor: big tappable ALARM button
                local w, h = mon.mon.getSize()
                mon.mon.setBackgroundColor(colors.black)
                mon.mon.setCursorPos(1, 1)
                mon.mon.clear()
                local bw = math.max(3, w - 2)
                local bh = math.max(2, h - 2)
                local bx = math.max(1, math.floor((w - bw) / 2) + 1)
                local by = math.max(1, math.floor((h - bh) / 2) + 1)
                local bg = alarm and colors.red or colors.orange
                for i = 0, bh - 1 do
                    mon.mon.setCursorPos(bx, by + i)
                    mon.mon.setBackgroundColor(bg)
                    mon.mon.write(string.rep(" ", bw))
                end
                local label = alarm and "STOP ALARM" or "ALARM"
                if #label > bw then label = string.sub(label, 1, bw) end
                mon.mon.setCursorPos(bx + math.max(0, math.floor((bw - #label) / 2)), by + math.floor(bh / 2))
                mon.mon.setTextColor(colors.white)
                mon.mon.write(label)
                mon.mon.setBackgroundColor(colors.black)
                local bts = {}
                buttons[mon.name] = bts
                for i = by, by + bh - 1 do bts[i] = { id = "__ALARM__" } end
            else
                bunkerlib.drawHeader(mon.mon)
                local n, lastRow
                if panel and countEntries(panel) > 0 then
                    local btns = {}
                    buttons[mon.name] = btns
                    local total = countEntries(panel)
                    n, lastRow = bunkerlib.drawPanel(mon.mon, panel, statuses, btns, true)
                    bunkerlib.drawFooter(mon.mon, lastRow - 5, panel.title, "CLIENTS: " .. n .. "/" .. total)
                else
                    n, lastRow = 0, 3
                    bunkerlib.drawInfoPlaceholder(mon.mon)
                    bunkerlib.drawFooter(mon.mon, 3, "INFO DISPLAY")
                end
                if alarm then
                    -- red alarm banner across the footer line of every monitor
                    local w, h = mon.mon.getSize()
                    local rows = panel and countEntries(panel) > 0 and (lastRow - 5) or 3
                    local y = math.max(h - 1, 5 + rows + 2)
                    mon.mon.setBackgroundColor(colors.red)
                    mon.mon.setTextColor(colors.white)
                    mon.mon.setCursorPos(1, y)
                    mon.mon.clearLine()
                    mon.mon.setCursorPos(1, y)
                    mon.mon.write("!! ALARM !!")
                    mon.mon.setBackgroundColor(colors.black)
                end
            end
        end
    end

    drawMonitors()

    -- ---- alarm control (shared by alarm button + console) ----
    local function setAlarm(on)
        alarm = on
        audit("alarm " .. (on and "ON" or "OFF"))
        local n = bunkerlib.emergencyDoors(statuses, on)
        drawMonitors()
        if on then
            term.setTextColor(colors.red)
            print("ALARM - " .. n .. " safety door(s) CLOSED.")
        else
            term.setTextColor(colors.green)
            print("Alarm OFF - " .. n .. " safety door(s) reopened.")
        end
        term.setTextColor(colors.white)
    end

    -- ---- command console (type device commands directly) ----
    -- Starts LOCKED: the room runs (monitors stay alive) but only `unlock`
    -- plus the correct password enables commands. Auto-locks again after
    -- LOCK_AFTER_IDLE seconds. Brute force protection: MAX_FAILED wrong
    -- attempts -> LOCKOUT_SECONDS pause. Everything is written to the
    -- audit log.
    local cmdLine = ""
    local running = true

    local locked = true
    local failed = 0
    local lockedUntil = 0
    local lockTimer = os.startTimer(LOCK_AFTER_IDLE)

    local function resetLockTimer()
        if lockTimer then os.cancelTimer(lockTimer) end
        lockTimer = os.startTimer(LOCK_AFTER_IDLE)
    end

    local function drawPrompt()
        local _, th = term.getSize()
        term.setCursorPos(1, th)
        term.setBackgroundColor(colors.black)
        term.clearLine()
        term.setTextColor(locked and colors.red or colors.cyan)
        term.write((locked and "LOCKED > " or "> ") .. cmdLine)
        term.setTextColor(colors.white)
    end

    local function lockConsole(reason)
        locked = true
        audit("lock: " .. reason)
        print("Console locked" .. (reason ~= "" and (" (" .. reason .. ")") or "") .. ".")
        drawPrompt()
    end

    local function doUnlock()
        if os.time() < lockedUntil then
            print("Locked out - try again in " .. (lockedUntil - os.time()) .. "s.")
            return
        end
        local _, th = term.getSize()
        term.setCursorPos(1, th)
        term.clearLine()
        term.setTextColor(colors.white)
        term.write("Password: ")
        local input = read("*")
        if bunkerlib.verifyPassword(input, expected) then
            locked = false
            failed = 0
            audit("unlock OK")
            print("Access granted.")
            resetLockTimer()
        else
            failed = failed + 1
            audit("unlock FAILED (" .. failed .. "x)")
            if failed >= MAX_FAILED then
                lockedUntil = os.time() + LOCKOUT_SECONDS
                failed = 0
                print("Too many failed attempts - locked out for " .. LOCKOUT_SECONDS .. "s.")
            else
                print("Wrong password - " .. (MAX_FAILED - failed) .. " attempt(s) left.")
            end
        end
    end

    local function runCommand(line)
        local parts = {}
        for w in line:gmatch("%S+") do parts[#parts + 1] = w end
        if #parts == 0 then return end
        local cmd = parts[1]:lower()

        if locked then
            if cmd == "unlock" then
                doUnlock()
            else
                audit("blocked while locked: " .. cmd)
                print("Console locked - type `unlock` first.")
            end
            return
        end

        if cmd == "exit" then
            print("Bye.")
            running = false
        elseif cmd == "lock" then
            lockConsole("manual")
        elseif cmd == "list" or cmd == "status" or cmd == "s" then
            local found = false
            for id, s in pairs(statuses) do
                found = true
                print(string.format("%-20s %s", id, (s.state and "STATE ON" or "STATE OFF")))
            end
            if not found then print("(no known devices)") end
        elseif cmd == "alarm" or cmd == "panic" then
            setAlarm((parts[2] or "on"):lower() ~= "off")
        elseif cmd == "help" then
            print("Commands: unlock | lock | list | <id> on|off|toggle | alarm [on|off] | exit")
        else
            local st = statuses[cmd]
            if not st then
                print("Unknown command or device: " .. cmd)
                return
            end
            local target = (parts[2] or "toggle"):lower()
            local state
            if target == "on" then
                state = true
            elseif target == "off" then
                state = false
            else
                state = not st.state
            end
            rednet.send(st.senderId, { room = cmd, cmd = st.cmd or "light", state = state }, "bunker_cmd")
            audit("cmd " .. cmd .. " " .. target)
            print(cmd .. " -> " .. (state and "ON" or "OFF"))
        end
    end

    drawPrompt()
    local updateTimer = os.startTimer(UPDATE_INTERVAL)

    while running do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "timer" and p1 == updateTimer then
            drawMonitors()
            updateTimer = os.startTimer(UPDATE_INTERVAL)
        elseif event == "timer" and p1 == lockTimer then
            if not locked then
                lockConsole("idle " .. LOCK_AFTER_IDLE .. "s")
            end
        elseif event == "monitor_touch" then
            local btns = buttons[p1]
            if btns and btns[p3] then
                local btn = btns[p3]
                if btn.id == "__ALARM__" then
                    setAlarm(not alarm)
                else
                    local status = statuses[btn.id]
                    if status then
                        local panel = MONITOR_PANELS[p1]
                        local action = panel and bunkerlib.ACTIONS[btn.action or "light"]
                        if action then
                            local msg = action(status, btn.id)
                            rednet.send(status.senderId, msg, "bunker_cmd")
                        end
                    end
                end
            end
        elseif event == "rednet_message" then
            local senderId, message, protocol = p1, p2, p3
            if protocol == "bunker_status" and type(message) == "table" and message.id then
                bunkerlib.setStatus(statuses, message.id, senderId, message.state, message.cmd)
                drawMonitors()
            end
        elseif event == "char" then
            if not locked then resetLockTimer() end
            cmdLine = cmdLine .. p1
            drawPrompt()
        elseif event == "key" then
            if not locked then resetLockTimer() end
            if p1 == keys.enter then
                cmdLine = cmdLine:match("^%s*(.-)%s*$") or ""
                runCommand(cmdLine)
                cmdLine = ""
                drawPrompt()
            elseif p1 == keys.backspace then
                cmdLine = string.sub(cmdLine, 1, #cmdLine - 1)
                drawPrompt()
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