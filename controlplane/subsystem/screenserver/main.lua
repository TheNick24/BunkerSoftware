-- ============================================
-- MAMDANI OS - SCREEN SERVER
-- Draws the monitor panels, forwards touch presses, keeps the alarm
-- banner in sync. NO console - the command console lives on the
-- control server (controlserver/startup.lua).
--
-- Multi-instance: run this on as many computers as you want (one per
-- control room). Every instance:
--   * listens to bunker_status / bunker_energy / bunker_alarm
--   * sends bunker_status_request + bunker_alarm (alarm stays in sync)
--   * may hold a SUBSET of the monitors -> own panels via override file
--
-- Panels override (optional, per instance): file /screenserver_panels.lua
-- on the computer (survives deploys). Must return a table:
--
--   return {
--     panels = {              -- full MONITOR_PANELS replacement, OR
--       ["monitor_4"] = { title = "...", action = "light", header = "LIGHT",
--                         entries = { { id = "entrance", name = "Entrance" } } },
--     },
--     only = { "monitor_4" }, -- OR: subset of the DEFAULT panels by name
--     alarmButton = "monitor_14",  -- or false to disable
--     energyMonitor = "monitor_18",-- or false to disable
--   }
--
-- Without an override the defaults below are used (same as the old
-- all-in-one control server).
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
local INSTANCE = "screenserver#" .. os.getComputerID()

-- Draw only when something changed; repaint fully on every second tick in
-- case the world unloaded and wiped the screens.
local UPDATE_INTERVAL = 20
-- Periodically re-ask all clients for their full state (see controlserver).
local STATUS_RESYNC_INTERVAL = 15
local AUDIT_LOG = "bunker.audit.log"

local rooms        = bunkerlib.rooms
local aux          = bunkerlib.aux
local doors        = bunkerlib.doors
local alarmSirens  = bunkerlib.alarmSirens
local safetyDoors  = bunkerlib.safetyDoors
local lockableDoors = bunkerlib.lockableDoors

-- Default monitor panels (identical to the old all-in-one control server).
-- `action` selects the device behavior ("light" = on/off, "door"/"safety-door"
-- = open/close) and must match the client device's `cmd`.
local DEFAULT_PANELS = {
    ["monitor_4"] = { title = "ROOM LIGHTS",     action = "light", header = "LIGHT", entries = rooms },
    ["monitor_7"] = { title = "CORRIDOR LIGHTS", action = "light", header = "LIGHT", entries = aux },
    ["monitor_3"] = { title = "DOORS", sections = {
        { title = "DOOR",         action = "door",        onText = "OPEN", offText = "CLOSED", entries = {
            { id = "Control Door 1", name = "Control Door 1",    action = "lock", lock = true },
            { id = "Control Door 2", name = "Control Door 2", action = "lock", lock = true },
            { id = "server-door",  name = "Server Access Door" },
        } },
        { title = "SAFETY DOORS", action = "safety-door", onText = "OPEN", offText = "CLOSED", entries = safetyDoors },
        { title = "ALARM",        action = "alarm",       onText = "ON",   offText = "OFF",   entries = alarmSirens },
    } },
}

-- Dedicated monitor that ONLY shows a big tappable ALARM button.
local DEFAULT_ALARM_BUTTON_MONITOR = "monitor_14"
-- Dedicated monitor with the reusable ENERGY screen.
local DEFAULT_ENERGY_MONITOR = "monitor_18"

-- ---- per-instance override (/screenserver_panels.lua) ----
local function loadPanelsOverride()
    local path = "/screenserver_panels.lua"
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local src = f.readAll()
    f.close()
    local chunk, err = load(src, "@" .. path)
    if not chunk then
        term.setTextColor(colors.red)
        print("screenserver_panels.lua: " .. tostring(err))
        term.setTextColor(colors.white)
        return nil
    end
    local ok, cfg = pcall(chunk)
    if not ok or type(cfg) ~= "table" then
        term.setTextColor(colors.red)
        print("screenserver_panels.lua: must return a table")
        term.setTextColor(colors.white)
        return nil
    end
    return cfg
end

local override = loadPanelsOverride() or {}

local MONITOR_PANELS = DEFAULT_PANELS
if type(override.panels) == "table" then
    MONITOR_PANELS = override.panels
elseif type(override.only) == "table" then
    MONITOR_PANELS = {}
    for _, name in ipairs(override.only) do
        if DEFAULT_PANELS[name] then
            MONITOR_PANELS[name] = DEFAULT_PANELS[name]
        else
            term.setTextColor(colors.yellow)
            print("screenserver_panels: unknown panel '" .. tostring(name) .. "' skipped")
            term.setTextColor(colors.white)
        end
    end
end

local ALARM_BUTTON_MONITOR = override.alarmButton
if ALARM_BUTTON_MONITOR == nil then ALARM_BUTTON_MONITOR = DEFAULT_ALARM_BUTTON_MONITOR end
local ENERGY_MONITOR = override.energyMonitor
if ENERGY_MONITOR == nil then ENERGY_MONITOR = DEFAULT_ENERGY_MONITOR end
-- false disables the dedicated monitor (both end up nil -> never matched)

-- ============ AUDIT LOG ============
local function audit(entry)
    local f = fs.open(AUDIT_LOG, "a")
    if f then
        f.write(os.date("%Y-%m-%d %H:%M:%S") .. "  " .. entry .. "\n")
        f.close()
    end
end

-- ============ SCREEN SERVER ============
local function runScreenserver()
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
    local energyData = {} -- battery name -> latest bunker_energy telemetry
    local energyRx = 0 -- energy messages received since last flush
    local lastEnergyDraw = 0 -- epoch ms of last energy-triggered redraw
    local alarm = false -- true = emergency: all safety doors CLOSED

    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("=== MAMDANI OS ===")
    term.setTextColor(colors.gray)
    print("  Screen Server: " .. INSTANCE)
    print("  Modem: " .. tostring(modem))
    print("  Monitors: " .. #monitors)
    print("  Panels: " .. tostring(next(MONITOR_PANELS) and "configured" or "(none)"))
    term.setTextColor(colors.white)

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
        g.centerText(mon.mon, 1, "MAMDANI OS", C.gold, C.bg)
        g.hline(mon.mon, 2 * g.CELL_H - 1, C.borderD)
    end

    local function gfxFooter(mon, label, extra)
        local w, h = mon.mon.getSize()
        local fy = h - 1
        g.hline(mon.mon, fy * g.CELL_H - 1, C.borderD)
        g.cellText(mon.mon, 2, h, label, C.dim, C.bg)
        if extra then
            g.cellText(mon.mon, w - #extra + 1, h, extra, C.gold, C.bg)
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
        local stateW = math.max(#header, #onText, #offText, #"OFFLINE", #"LOCKED")
        local zoneRight = btnX - 1
        local zoneLeft = zoneRight - stateW + 1
        local maxName = math.max(3, zoneLeft - 2)

        g.cellText(mon.mon, 2, startRow, "NAME", C.gold, C.bg)
        local hx = zoneLeft + math.floor((stateW - #header) / 2)
        g.cellText(mon.mon, hx, startRow, header, C.gold, C.bg)
        g.hline(mon.mon, startRow * g.CELL_H - 1, C.borderD)

        local clientCount = 0
        for i, entry in ipairs(src.entries) do
            local y = startRow + 1 + i
            local status = statuses[entry.id]
            local online = status ~= nil
            local rowBg = C.panel
            g.cellFill(mon.mon, 1, y, w, 1, rowBg)
            local accent = not online and C.crimson
                or (entry.lock and status.lock) and C.amber
                or status.state and C.sage or C.gold
            local rowTop = (y - 1) * g.CELL_H
            -- Thin card accent: it gives each touch row a HUD-card edge
            -- without changing the logical row size used for hit testing.
            g.fill(mon.mon, 0, rowTop + 1, 2, g.CELL_H - 2, accent)
            local name = entry.name
            if #name > maxName then name = string.sub(name, 1, maxName) end
            g.cellText(mon.mon, 2, y, name, C.text, rowBg)
            if online then
                clientCount = clientCount + 1
                local locked = entry.lock and status.lock
                local txt = locked and "LOCKED" or (status.state and onText or offText)
                local sx = zoneLeft + math.floor((stateW - #txt) / 2)
                local sc = locked and C.red or (status.state and C.sage or C.dim)
                g.cellText(mon.mon, sx, y, txt, sc, rowBg)
            else
                g.cellText(mon.mon, zoneLeft, y, "OFFLINE", C.crimson, rowBg)
            end
            local bc = (online and locked) and C.red or ((online and status.state) and C.sage or C.panel2)
            g.cellFill(mon.mon, btnX, y, btnW, 1, bc)
            g.cellText(mon.mon, btnX, y, label, online and C.bg or C.dim, bc)
            g.hline(mon.mon, y * g.CELL_H - 1, C.borderD)
            btns[y] = { id = entry.id, action = entry.action or action }
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
                g.cellText(mon.mon, 2, y, sec.title or panel.title or "GROUP", C.gold, C.bg)
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
        local x0, y0 = (bx1 - 1) * g.CELL_W, (by1 - 1) * g.CELL_H
        local x1, y1 = bx2 * g.CELL_W - 1, by2 * g.CELL_H - 1
        g.fill(mon.mon, x0, y0, x1 - x0 + 1, y1 - y0 + 1, C.panel)
        g.fill(mon.mon, x0, y0, x1 - x0 + 1, 1, C.gold)
        g.fill(mon.mon, x0, y1, x1 - x0 + 1, 1, C.borderD)
        g.fill(mon.mon, x0, y0, 1, y1 - y0 + 1, C.gold)
        g.fill(mon.mon, x1, y0, 1, y1 - y0 + 1, C.gold)
        local lines = {
            { "INFO PANEL", C.gold },
            { "No content assigned yet.", C.dim },
            { "Config: screenserver_panels.lua", C.dim },
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
            if mon.name == ENERGY_MONITOR and bunkerlib.energy then
                -- reusable energy screen (self-contained gfx/text fallback)
                bunkerlib.energy.drawMonitor(mon.mon, energyData, { title = "ENERGY MANAGEMENT" })
            elseif monGfx(mon) then
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
                local label = alarm and "STOP ALARM" or "ACTIVATE ALARM"
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
            parts[#parts + 1] = id .. "=" .. tostring(s.state) .. "|" .. tostring(s.lock or false) .. "@" .. tostring(s.senderId)
        end
        table.sort(parts)
        local ek = ""
        local names = {}
        for n in pairs(energyData) do names[#names + 1] = n end
        table.sort(names)
        for _, n in ipairs(names) do
            local d = energyData[n]
            ek = ek .. "|" .. n .. "="
                .. tostring(d.energy) .. "/" .. tostring(d.maxEnergy)
                .. "+" .. tostring(d.lastInput) .. "-" .. tostring(d.lastOutput)
        end
        return table.concat(parts, "|") .. "|alarm=" .. tostring(alarm) .. ek
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

    -- ---- alarm control (shared by alarm button + remote bunker_alarm) ----
    local preAlarm = {}
    -- Power every alarm siren in the group (Mekanism Industrial Alarm, ...).
    local function setAlarmSirens(on)
        for _, s in ipairs(alarmSirens) do
            local st = statuses[s.id]
            if st and st.senderId then
                rednet.send(st.senderId, { room = s.id, cmd = "alarm", state = on }, "bunker_cmd")
            end
        end
    end
    -- Apply an alarm state WITHOUT re-broadcasting (used by both the local
    -- button and the receive path of other servers' bunker_alarm messages).
    local function applyAlarm(on, origin)
        alarm = on
        audit("alarm " .. (on and "ON" or "OFF") .. (origin and (" via " .. origin) or ""))
        setAlarmSirens(on)
        bunkerlib.emergencyDoors(statuses, on, preAlarm, lockableDoors)
        drawMonitorsIfChanged(true)
        term.setTextColor(on and colors.red or colors.green)
        print("ALARM " .. (on and "ON" or "OFF") .. (origin and (" (" .. origin .. ")") or ""))
        term.setTextColor(colors.white)
    end
    -- Local trigger (touch): apply + tell every other server instance.
    local function setAlarm(on)
        if alarm == on then return end
        applyAlarm(on, INSTANCE)
        rednet.broadcast({ on = on, source = INSTANCE }, "bunker_alarm")
    end

    -- Diagnostics log beside this program; read back via log.read path=main.
    -- BUFFERED on purpose (see controlserver) - flushed on each status tick.
    local markBuf = {}
    local function flushMarks()
        if #markBuf == 0 then return end
        local lines = table.concat(markBuf, "\n")
        markBuf = {}
        pcall(function()
            local d = fs.getDir(shell.getRunningProgram())
            if not d or d == "" then d = "/" end
            local fp = fs.combine(d, "client-error.log")
            if fs.exists(fp) then
                local sz = fs.getSize(fp)
                if sz and sz > 16384 then fs.delete(fp) end
            end
            local f = fs.open(fp, "a")
            if f then
                f.write(lines .. "\n")
                f.close()
            end
        end)
    end
    local function serverMark(msg)
        if #markBuf >= 64 then flushMarks() end
        markBuf[#markBuf + 1] = "@" .. tostring(os.epoch("utc")) .. ": " .. msg
    end

    -- Ask all running clients for an immediate full state after this server
    -- restarts. Clients still send their normal heartbeats afterwards.
    rednet.broadcast({ request = "status" }, "bunker_status_request")
    serverMark("boot request sent monitors=" .. #monitors)
    local updateTimer = os.startTimer(UPDATE_INTERVAL)
    local syncTimer = os.startTimer(STATUS_RESYNC_INTERVAL)
    local tick = 0

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "timer" and p1 == updateTimer then
            -- redraw only when something changed; repaint fully on every
            -- second tick in case the world unloaded and wiped the screens
            local force = (tick % 2 == 1)
            drawMonitorsIfChanged(force)
            tick = tick + 1
            serverMark("flush tick=" .. tostring(tick) .. " energyRx=" .. tostring(energyRx))
            energyRx = 0
            flushMarks()
            updateTimer = os.startTimer(UPDATE_INTERVAL)
        elseif event == "timer" and p1 == syncTimer then
            rednet.broadcast({ request = "status" }, "bunker_status_request")
            serverMark("sync request sent")
            syncTimer = os.startTimer(STATUS_RESYNC_INTERVAL)
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
                        if btn.id == "__ALARM__" or btn.action == "alarm" then
                            -- Alarm group row / big ALARM button: same toggle.
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
                bunkerlib.setStatus(statuses, message.id, senderId, message.state, message.cmd, message.lock)
                serverMark("status id=" .. tostring(message.id) .. " state=" .. tostring(message.state and 1 or 0) .. " from=" .. tostring(senderId))
                drawMonitorsIfChanged()
            elseif protocol == "bunker_energy" and type(message) == "table" then
                energyRx = energyRx + 1
                energyData[tostring(message.name or "Battery - 1")] = message
                -- A fast energy flood must not repaint all monitors each time.
                -- Redraw at most every 2 s (statusKey includes energy, so the
                -- energy change alone would otherwise trigger a full repaint).
                local now = os.epoch("utc")
                if now - lastEnergyDraw >= 2000 then
                    lastEnergyDraw = now
                    drawMonitorsIfChanged()
                end
            elseif protocol == "bunker_alarm" and type(message) == "table" and type(message.on) == "boolean" then
                -- Alarm state from another server instance (control server or
                -- another screen server). Apply WITHOUT re-broadcasting.
                if alarm ~= message.on then
                    local src = tostring(message.source or senderId)
                    serverMark("alarm sync " .. (message.on and "ON" or "OFF") .. " from " .. src)
                    applyAlarm(message.on, src)
                    flushMarks()
                end
            end
        end

        -- A deploy = fetch + reboot + boot, which can keep a client silent for
        -- well over ten seconds (see controlserver comment).
        bunkerlib.cleanStatuses(statuses, 25)
    end
end

-- ============ MAIN ============
local cmd = args[1]

if cmd == nil or cmd == "start" then
    runScreenserver()
else
    term.setTextColor(colors.cyan)
    print("=== MAMDANI OS ===")
    term.setTextColor(colors.white)
    print("Usage:")
    print("  start     -> start screen server (auto-run)")
end
