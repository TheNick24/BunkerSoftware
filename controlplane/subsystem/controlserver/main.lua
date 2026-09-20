-- ============================================
-- MAMDANI OS - CONTROL SERVER
-- Setup: setup            (set password)
-- Start: start            (auto-run on normal boot)
-- ============================================

local args = { ... }

-- controlplane health marker (no-op without the agent)
if fs.exists("/controlplane") then
    local _hf = fs.open("/controlplane/health.marker", "w")
    if _hf then _hf.write("healthy\n") _hf.close() end
end

-- ============ LIB ============
local dir = fs.getDir(shell.getRunningProgram())
package.path = fs.combine(dir, "?.lua") .. ";" .. package.path
local bunkerlib = require("bunkerlib")

-- ============ CONFIG ============
local HASH_FILE = "bunker.hash"
local UPDATE_INTERVAL = 20

-- The room itself always runs (lights, monitors, status) - only the command
-- console needs the password. It starts LOCKED and re-locks after inactivity.
local LOCK_AFTER_IDLE = 300   -- seconds of idle until the console locks again
local MAX_FAILED      = 5     -- failed unlock attempts until a lockout
local LOCKOUT_SECONDS = 60    -- lockout after too many failed attempts
local AUDIT_LOG       = "bunker.audit.log"
local HISTORY_FILE    = "bunker.history"
local MAX_HISTORY     = 20

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

-- ============ SHELL HISTORY (loading) ============
local function loadHistory()
    if not fs.exists(HISTORY_FILE) then return {} end
    local f = fs.open(HISTORY_FILE, "r")
    if not f then return {} end
    local h = {}
    while true do
        local line = f.readLine()
        if not line then break end
        if line ~= "" then h[#h + 1] = line end
    end
    f.close()
    return h
end

-- ============ SETUP ============
-- Asks for a new password (with confirmation + min length) and returns the
-- PBKDF2 hash string. Returns nil when the input was invalid. Used by the
-- `setup` command AND on first boot in runControl(), so a fresh deployment
-- prompts for the password right inside the running system.
local function promptForPasswordHash()
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("==========================")
    print("     MAMDANI OS - SETUP")
    print("==========================")
    term.setTextColor(colors.white)
    print("New password (min. 6 characters):")
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
        term.setTextColor(colors.white)
        return nil
    end
    if #p1 < 6 then
        term.setTextColor(colors.red)
        print("Password too short (min. 6 characters)!")
        term.setTextColor(colors.white)
        return nil
    end
    return bunkerlib.hashPassword(p1)
end

local function runSetup()
    local hash = promptForPasswordHash()
    if hash then
        saveHash(hash)
        term.setTextColor(colors.green)
        print("Password saved!")
        term.setTextColor(colors.white)
    end
end

-- ============ CONTROL ROOM ============
local function runControl()
    local expected = loadHash()
    if not expected then
        -- First start without a password: do NOT exit / ask for a separate
        -- `setup` run - the booted client is main.lua without that hint.
        -- Ask right here so the room keeps running and the console gets a
        -- password to unlock against.
        term.setTextColor(colors.yellow)
        print("No password set up yet - please set one now (console starts locked).")
        term.setTextColor(colors.white)
        while true do
            local hash = promptForPasswordHash()
            if hash then
                saveHash(hash)
                expected = hash
                term.setTextColor(colors.green)
                print("Password saved!")
                term.setTextColor(colors.white)
                break
            end
            term.setTextColor(colors.yellow)
            print("A password is required - try again.")
            term.setTextColor(colors.white)
        end
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

    -- ---- output scrollback ----
    -- All console output goes into a bounded buffer that is rendered into the
    -- area ABOVE the input line, so new lines never push the input away.
    -- PGUP/PGDN scroll back through the history.
    local outState = {} -- { t = text, c = color }
    local OUT_MAX  = 200
    local scroll   = 0
    local outColor = colors.white

    local function renderOut()
        local w, th = term.getSize()
        local view = th - 1
        local total = #outState
        local start = math.max(1, total - view - scroll + 1)
        term.setBackgroundColor(colors.black)
        for y = 1, view do
            term.setCursorPos(1, y)
            term.clearLine()
            local idx = start + (y - 1)
            if idx <= total then
                local e = outState[idx]
                term.setTextColor(e.c or colors.white)
                term.write(e.t:sub(1, w))
            end
        end
        term.setTextColor(colors.white)
    end

    local function outWrite(text, color)
        color = color or outColor
        local w = term.getSize()
        for chunk in (text .. "\n"):gmatch("(.-)\n") do
            while #chunk > w do
                outState[#outState + 1] = { t = chunk:sub(1, w), c = color }
                if #outState > OUT_MAX then table.remove(outState, 1) end
                chunk = chunk:sub(w + 1)
            end
            outState[#outState + 1] = { t = chunk, c = color }
            if #outState > OUT_MAX then table.remove(outState, 1) end
        end
        scroll = 0
        renderOut()
    end

    local function out(...)
        local n = select("#", ...)
        local parts = {}
        for i = 1, n do parts[i] = tostring(select(i, ...)) end
        outWrite(table.concat(parts, "\t"))
    end

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

    -- ---- gfx (cc-graphics 256-color) rendering ----
    local g = bunkerlib.gfx
    local C = g.C
    local gfxCaps = {}
    local function monGfx(mon)
        local key = mon.name
        if gfxCaps[key] == nil then
            local ok = g.supported(mon.mon)
            if ok then ok = g.init(mon.mon) end
            if not ok and mon.mon.setGraphicsMode then
                pcall(function() mon.mon.setGraphicsMode(0) end)
            end
            gfxCaps[key] = ok
        end
        return gfxCaps[key]
    end

    local function gfxHeader(mon)
        g.centerText(mon.mon, 1, "MAMDANI OS", C.cyan, C.bg)
        g.hline(mon.mon, 2 * g.CELL_H - 1, C.borderD)
    end

    local function gfxFooter(mon, label, extra)
        local w, h = mon.mon.getSize()
        local fy = h - 1
        g.hline(mon.mon, fy * g.CELL_H - 1, C.borderD)
        g.cellText(mon.mon, 2, h, label, C.dim, C.bg)
        if extra then
            g.cellText(mon.mon, w - #extra + 1, h, extra, C.cyan, C.bg)
        end
    end

    local function gfxAlarmBar(mon)
        local h = mon.mon.getSize()
        g.bar(mon.mon, h, C.red)
        g.centerText(mon.mon, h, "!! ALARM !!", C.white, C.red)
    end

    -- one toggle table (same cell layout as drawToggleTable so touch rows match)
    local function gfxToggleTable(mon, src, startRow, btns)
        local w = mon.mon.getSize()
        local action = src.action or "light"
        local label = src.button or "[CLICK]"
        local btnW = #label
        local btnX = w - btnW + 1
        local header = src.header or "STATE"
        local onText = src.onText or "ON"
        local offText = src.offText or "OFF"
        local stateW = math.max(#header, #onText, #offText, #"OFFLINE")
        local zoneRight = btnX - 1
        local zoneLeft = zoneRight - stateW + 1
        local maxName = math.max(3, zoneLeft - 2)

        g.cellText(mon.mon, 2, startRow, "NAME", C.yellow, C.bg)
        local hx = zoneLeft + math.floor((stateW - #header) / 2)
        g.cellText(mon.mon, hx, startRow, header, C.yellow, C.bg)
        g.hline(mon.mon, startRow * g.CELL_H - 1, C.borderD)

        local clientCount = 0
        for i, entry in ipairs(src.entries) do
            local y = startRow + 1 + i
            local status = statuses[entry.id]
            local online = status ~= nil
            local rowBg = (i % 2 == 1) and C.panel or C.panel2
            g.cellFill(mon.mon, 1, y, w, 1, rowBg)
            local name = entry.name
            if #name > maxName then name = string.sub(name, 1, maxName) end
            g.cellText(mon.mon, 2, y, name, C.text, rowBg)
            if online then
                clientCount = clientCount + 1
                local txt = status.state and onText or offText
                local sx = zoneLeft + math.floor((stateW - #txt) / 2)
                local sc = status.state and C.yellow or C.dim
                g.cellText(mon.mon, sx, y, txt, sc, rowBg)
            else
                g.cellText(mon.mon, zoneLeft, y, "OFFLINE", C.red, rowBg)
            end
            local bc = (online and status.state) and C.green or C.dim
            g.cellFill(mon.mon, btnX, y, btnW, 1, bc)
            g.cellText(mon.mon, btnX, y, label, C.bg, bc)
            g.hline(mon.mon, y * g.CELL_H - 1, C.borderD)
            btns[y] = { id = entry.id, action = action }
        end
        return clientCount
    end

    local function gfxPanel(mon, panel)
        g.begin(mon.mon)
        gfxHeader(mon)
        local btns = {}
        buttons[mon.name] = btns
        local total = countEntries(panel)
        local n
        if panel.sections then
            n = 0
            local y = 4
            for _, sec in ipairs(panel.sections) do
                g.cellText(mon.mon, 2, y, sec.title or panel.title or "GROUP", C.cyan, C.bg)
                n = n + gfxToggleTable(mon, sec, y + 1, btns)
                y = y + 4 + #sec.entries
            end
        else
            n = gfxToggleTable(mon, panel, 4, btns)
        end
        gfxFooter(mon, panel.title, "CLIENTS: " .. n .. "/" .. total)
        if alarm then gfxAlarmBar(mon) end
        g.finish(mon.mon)
    end

    local function gfxInfo(mon)
        local w, h = mon.mon.getSize()
        g.begin(mon.mon)
        gfxHeader(mon)
        local bx1, by1 = 2, 3
        local bx2, by2 = w - 1, math.max(by1, math.min(h - 2, 8))
        local bw = bx2 - bx1 + 1
        local bh = by2 - by1 + 1
        if bh > 2 then
            g.cellFill(mon.mon, bx1 + 1, by1 + 1, bw - 2, bh - 2, C.panel)
        end
        if bh > 0 then
            g.cellFill(mon.mon, bx1, by1, bw, 1, C.borderD)
            g.cellFill(mon.mon, bx1, by2, bw, 1, C.borderD)
            if bh > 2 then
                g.cellFill(mon.mon, bx1, by1 + 1, 1, bh - 2, C.borderD)
                g.cellFill(mon.mon, bx2, by1 + 1, 1, bh - 2, C.borderD)
            end
        end
        local lines = {
            { "INFO PANEL", C.yellow },
            { "No content assigned yet.", C.dim },
            { "Config: MONITOR_PANELS", C.dim },
        }
        for li, line in ipairs(lines) do
            local ry = by1 + li
            if ry <= by2 then
                g.cellText(mon.mon, bx1 + 1, ry, line[1], line[2], C.panel)
            end
        end
        gfxFooter(mon, "INFO DISPLAY")
        g.finish(mon.mon)
    end

    local function gfxAlarmButton(mon)
        local h = mon.mon.getSize()
        local pw, ph = g.pxSize(mon.mon)
        g.begin(mon.mon)
        local bg = alarm and C.red or C.orange
        g.fill(mon.mon, 0, 0, pw, ph, bg)
        if alarm then g.centerText(mon.mon, 2, "STOP", C.white, bg) end
        g.centerText(mon.mon, 3, "ALARM", alarm and C.white or C.bg, bg)
        local bts = {}
        buttons[mon.name] = bts
        for i = 1, h do bts[i] = { id = "__ALARM__" } end
        g.finish(mon.mon)
    end

    local function drawMonitors()
        buttons = {}
        for _, mon in ipairs(monitors) do
            local panel = MONITOR_PANELS[mon.name]
            if monGfx(mon) then
                if mon.name == ALARM_BUTTON_MONITOR then
                    gfxAlarmButton(mon)
                elseif panel and countEntries(panel) > 0 then
                    gfxPanel(mon, panel)
                else
                    gfxInfo(mon)
                end
            elseif mon.name == ALARM_BUTTON_MONITOR then
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

    local function statusKey()
        local parts = {}
        for id, s in pairs(statuses) do
            parts[#parts + 1] = id .. "=" .. tostring(s.state) .. "@" .. tostring(s.senderId)
        end
        table.sort(parts)
        return table.concat(parts, "|") .. "|alarm=" .. tostring(alarm)
    end

    local lastKey = ""
    local function drawMonitorsIfChanged(force)
        if force then
            drawMonitors()
            lastKey = statusKey()
            return
        end
        local k = statusKey()
        if k ~= lastKey then
            lastKey = k
            drawMonitors()
        end
    end

    drawMonitorsIfChanged(true)

    -- ---- alarm control (shared by alarm button + console) ----
    local function setAlarm(on)
        alarm = on
        audit("alarm " .. (on and "ON" or "OFF"))
        local n = bunkerlib.emergencyDoors(statuses, on)
        drawMonitorsIfChanged(true)
        if on then
            outWrite("ALARM - " .. n .. " safety door(s) CLOSED.", colors.red)
        else
            outWrite("Alarm OFF - " .. n .. " safety door(s) reopened.", colors.green)
        end
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

    -- shell niceties: history (up/down), TAB completion, clean prompt line
    local history = loadHistory()
    local histIdx = nil
    local COMMANDS = { "unlock", "lock", "list", "status", "s", "clear", "cls", "help", "alarm", "panic", "exit" }
    local STATES   = { "on", "off", "toggle" }
    local compToken  = nil -- the (partial) token being completed
    local compField  = nil -- which token slot we were completing on
    local compIndex  = 0
    local PROMPT     = "MAMDANI > "
    local PROMPT_LOCKED = "MAMDANI LOCKED > "

    local function pushHistory(line)
        if line ~= "" and line ~= history[#history] then
            history[#history + 1] = line
            if #history > MAX_HISTORY then table.remove(history, 1) end
            local f = fs.open(HISTORY_FILE, "w")
            if f then
                for _, l in ipairs(history) do f.writeLine(l) end
                f.close()
            end
        end
    end

    -- candidates for the token slot being edited (1 = command/device id,
    -- 2 = state word, >=3 = no completion)
    local function completeFor(field)
        if locked then return { "unlock" } end -- locked: only autocomplete unlock
        if field <= 1 then
            local res = {}
            for _, c in ipairs(COMMANDS) do res[#res + 1] = c end
            for id in pairs(statuses) do res[#res + 1] = id end
            return res
        elseif field == 2 then
            return STATES
        end
        return {}
    end

    local function drawPrompt()
        local w, th = term.getSize()
        local prefix = locked and PROMPT_LOCKED or PROMPT
        term.setCursorPos(1, th)
        term.setBackgroundColor(colors.black)
        term.setTextColor(locked and colors.red or colors.cyan)
        term.write(prefix)
        term.setTextColor(colors.white)
        term.write(cmdLine)
        -- clear any leftover from a longer previous line so nothing "sticks"
        local rest = w - #prefix - #cmdLine
        if rest > 0 then term.write(string.rep(" ", rest)) end
        term.setCursorPos(1 + #prefix + #cmdLine, th)
    end

    local function doComplete()
        local words = {}
        for w in cmdLine:gmatch("%S+") do words[#words + 1] = w end
        local endsWithSpace = cmdLine:sub(-1) == " "
        local field = #words + (endsWithSpace and 1 or 0)
        if field < 1 then field = 1 end
        local pref = (not endsWithSpace and words[#words]) or ""

        if compToken ~= pref or compField ~= field then
            compToken, compField, compIndex = pref, field, 0
        end

        local matches = {}
        for _, c in ipairs(completeFor(field)) do
            if c:sub(1, #pref) == pref then matches[#matches + 1] = c end
        end
        if #matches == 0 then return end

        compIndex = (compIndex % #matches) + 1
        local done = matches[compIndex]

        if endsWithSpace or pref == "" then
            cmdLine = cmdLine .. done
        else
            local lastStart = cmdLine:match(".*%s")
            lastStart = lastStart and #lastStart + 1 or 1
            cmdLine = cmdLine:sub(1, lastStart - 1) .. done
        end
        -- auto-space on a unique match (only outside the locked prompt)
        if not locked and #matches == 1 then
            cmdLine = cmdLine .. " "
        end
        drawPrompt()
    end

    local function resetComp()
        compToken, compField, compIndex = nil, nil, 0
    end

    local function resetLockTimer()
        if lockTimer then os.cancelTimer(lockTimer) end
        lockTimer = os.startTimer(LOCK_AFTER_IDLE)
    end

    local function lockConsole(reason)
        locked = true
        audit("lock: " .. reason)
        outWrite("Console locked" .. (reason ~= "" and (" (" .. reason .. ")") or "") .. ".", colors.red)
        drawPrompt()
    end

    local function doUnlock()
        if os.time() < lockedUntil then
            outWrite("Locked out - try again in " .. (lockedUntil - os.time()) .. "s.", colors.yellow)
            return
        end
        local _, th = term.getSize()
        term.setCursorPos(1, th)
        term.setBackgroundColor(colors.black)
        term.clearLine()
        term.setTextColor(colors.white)
        term.write("Password: ")
        local input = read("*")
        term.setBackgroundColor(colors.black)
        if bunkerlib.verifyPassword(input, expected) then
            locked = false
            failed = 0
            audit("unlock OK")
            outWrite("Access granted.", colors.green)
            resetLockTimer()
        else
            failed = failed + 1
            audit("unlock FAILED (" .. failed .. "x)")
            if failed >= MAX_FAILED then
                lockedUntil = os.time() + LOCKOUT_SECONDS
                failed = 0
                outWrite("Too many failed attempts - locked out for " .. LOCKOUT_SECONDS .. "s.", colors.red)
            else
                outWrite("Wrong password - " .. (MAX_FAILED - failed) .. " attempt(s) left.", colors.red)
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
                outWrite("Console locked - type `unlock` first.", colors.red)
            end
            return
        end

        if cmd == "exit" then
            outWrite("Bye.")
            running = false
        elseif cmd == "lock" then
            lockConsole("manual")
        elseif cmd == "clear" or cmd == "cls" then
            outState = {}
            scroll = 0
            outWrite("=== MAMDANI OS ===", colors.cyan)
            outWrite("Screen cleared - `help` shows the commands.", colors.gray)
        elseif cmd == "list" or cmd == "status" or cmd == "s" then
            local found = false
            for id, s in pairs(statuses) do
                found = true
                outWrite(string.format("%-20s %s", id, (s.state and "STATE ON" or "STATE OFF")))
            end
            if not found then outWrite("(no known devices)", colors.gray) end
        elseif cmd == "alarm" or cmd == "panic" then
            setAlarm((parts[2] or "on"):lower() ~= "off")
        elseif cmd == "help" then
            outWrite("Commands: unlock | lock | list | <id> on|off|toggle | alarm [on|off] | clear | exit", colors.yellow)
        else
            local st = statuses[cmd]
            if not st then
                outWrite("Unknown command or device: " .. cmd, colors.red)
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
            outWrite(cmd .. " -> " .. (state and "ON" or "OFF"), colors.green)
        end
    end

    -- initial console screen (header comes from the buffer, not prints)
    outWrite("=== MAMDANI OS ===", colors.cyan)
    outWrite("Console locked - type `unlock` to enable commands.", colors.gray)
    renderOut()
    drawPrompt()
    local updateTimer = os.startTimer(UPDATE_INTERVAL)
    local tick = 0

    while running do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "timer" and p1 == updateTimer then
            -- redraw only when something changed; repaint fully on every
            -- second tick in case the world unloaded and wiped the screens
            local force = (tick % 2 == 1)
            drawMonitorsIfChanged(force)
            tick = tick + 1
            updateTimer = os.startTimer(UPDATE_INTERVAL)
        elseif event == "timer" and p1 == lockTimer then
            if not locked then
                lockConsole("idle " .. LOCK_AFTER_IDLE .. "s")
            end
        elseif event == "monitor_touch" then
            local monName = p1
            if monName == ALARM_BUTTON_MONITOR then
                setAlarm(not alarm)
            else
                local btns = buttons[monName]
                if btns then
                    local y = p3
                    if gfxCaps[monName] then
                        -- graphics mode reports pixel co-ordinates on touch
                        y = math.floor(p3 / g.CELL_H) + 1
                    end
                    local btn = btns[y]
                    if btn then
                        if btn.id == "__ALARM__" then
                            setAlarm(not alarm)
                        else
                            local status = statuses[btn.id]
                            if status then
                                local panel = MONITOR_PANELS[monName]
                                local action = panel and bunkerlib.ACTIONS[btn.action or "light"]
                                if action then
                                    local msg = action(status, btn.id)
                                    rednet.send(status.senderId, msg, "bunker_cmd")
                                end
                            end
                        end
                    end
                end
            end
        elseif event == "rednet_message" then
            local senderId, message, protocol = p1, p2, p3
            if protocol == "bunker_status" and type(message) == "table" and message.id then
                bunkerlib.setStatus(statuses, message.id, senderId, message.state, message.cmd)
                drawMonitorsIfChanged()
            end
        elseif event == "char" then
            if not locked then resetLockTimer() end
            resetComp()
            cmdLine = cmdLine .. p1
            drawPrompt()
        elseif event == "key" then
            if not locked then resetLockTimer() end
            if p1 == keys.enter then
                local line = cmdLine:match("^%s*(.-)%s*$") or ""
                resetComp()
                pushHistory(line)
                -- echo the executed line with the prefix (terminal style)
                if line ~= "" then
                    outWrite((locked and PROMPT_LOCKED or PROMPT) .. line, locked and colors.red or colors.cyan)
                end
                runCommand(line)
                cmdLine = ""
                histIdx = nil
                drawPrompt()
            elseif p1 == keys.tab then
                doComplete()
            elseif p1 == keys.up then
                if #history > 0 then
                    histIdx = (histIdx == nil) and #history or math.max(1, histIdx - 1)
                    cmdLine = history[histIdx] or ""
                    resetComp()
                    drawPrompt()
                end
            elseif p1 == keys.down then
                if histIdx then
                    histIdx = histIdx + 1
                    if histIdx > #history then
                        histIdx = nil
                        cmdLine = ""
                    else
                        cmdLine = history[histIdx]
                    end
                    resetComp()
                    drawPrompt()
                end
            elseif p1 == keys.pageup then
                local th = term.getSize()
                local view = th - 1
                scroll = math.min(scroll + math.ceil(view / 2), math.max(0, #outState - view))
                renderOut()
            elseif p1 == keys.pagedown then
                local th = term.getSize()
                local view = th - 1
                scroll = math.max(0, scroll - math.ceil(view / 2))
                renderOut()
            elseif p1 == keys.backspace then
                cmdLine = string.sub(cmdLine, 1, #cmdLine - 1)
                resetComp()
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