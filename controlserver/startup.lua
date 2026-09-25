-- ============================================
-- MAMDANI OS - CONTROL SERVER
-- Command console + alarm + status cache. NO monitors - the monitor
-- panels live on the screen server(s) (screenserver/startup.lua).
-- Multiple control server instances may run in parallel (backup
-- consoles): all stay in sync via bunker_status (device states) and
-- bunker_alarm (alarm on/off).
--
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
local INSTANCE = "controlserver#" .. os.getComputerID()
local HASH_FILE = "bunker.hash"
local UPDATE_INTERVAL = 20
-- Periodically re-ask all clients for their full state, so a room that was
-- rebooting (update wave) or that missed a heartbeat comes back online
-- within at most this many seconds instead of showing OFFLINE.
-- Must stay well below the 25s cleanStatuses expiry (see below) or rooms
-- flap OFFLINE between resyncs when their regular heartbeats are delayed.
local STATUS_RESYNC_INTERVAL = 15

-- The room itself always runs (lights, status) - only the command console
-- needs the password. It starts LOCKED and re-locks after inactivity.
local LOCK_AFTER_IDLE = 300   -- seconds of idle until the console locks again
local MAX_FAILED      = 5     -- failed unlock attempts until a lockout
local LOCKOUT_SECONDS = 60    -- lockout after too many failed attempts
local AUDIT_LOG       = "bunker.audit.log"
local HISTORY_FILE    = "bunker.history"
local MAX_HISTORY     = 20

-- Shared static device lists (same source as every screen server).
local alarmSirens   = bunkerlib.alarmSirens
local lockableDoors = bunkerlib.lockableDoors

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

-- ============ CONTROL SERVER ============
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
    print("Control Server: " .. INSTANCE)
    print("Console locked - type `unlock` then the password.")
    term.setTextColor(colors.white)

    local modem = bunkerlib.findModem()
    if not modem then
        term.setTextColor(colors.red)
        print("No modem found!")
        return
    end

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

    -- ---- alarm control (console `alarm on|off`; mirrors of the screen
    -- server's touch buttons - both instances may trigger, bunker_alarm
    -- keeps every instance in sync without loops) ----
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
    -- Apply an alarm state WITHOUT re-broadcasting (receive path).
    local function applyAlarm(on, origin)
        alarm = on
        audit("alarm " .. (on and "ON" or "OFF") .. (origin and (" via " .. origin) or ""))
        setAlarmSirens(on)
        local n = bunkerlib.emergencyDoors(statuses, on, preAlarm, lockableDoors)
        if on then
            outWrite("ALARM" .. (origin and (" [" .. origin .. "]") or "") .. " - " .. n .. " safety door(s) CLOSED.", colors.red)
        else
            outWrite("Alarm OFF" .. (origin and (" [" .. origin .. "]") or "") .. " - " .. n .. " safety door(s) reopened.", colors.green)
        end
    end
    -- Local trigger (console): apply + tell every other server instance.
    local function setAlarm(on)
        if alarm == on then return end
        applyAlarm(on, INSTANCE)
        rednet.broadcast({ on = on, source = INSTANCE }, "bunker_alarm")
    end

    -- ---- command console (type device commands directly) ----
    -- Starts LOCKED: the room runs (status stays alive) but only `unlock`
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
    outWrite("Control Server: " .. INSTANCE, colors.gray)
    outWrite("Console locked - type `unlock` to enable commands.", colors.gray)
    renderOut()
    drawPrompt()
    -- Diagnostic log, written beside this program, read back via
    -- `log.read path=main`. BUFFERED on purpose: rednet traffic previously
    -- caused one disk open/write/close per message - exactly the CPU load
    -- that makes CC computers tick slower (timers fire late -> rooms drop
    -- OFFLINE). Lines are flushed together on each status tick instead.
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
    serverMark("boot request sent")
    local updateTimer = os.startTimer(UPDATE_INTERVAL)
    -- Also re-ask periodically: a room that was itself rebooting (e.g. after
    -- an update wave) or that missed a heartbeat resumes instantly instead of
    -- sitting on OFFLINE until its next regular broadcast.
    local syncTimer = os.startTimer(STATUS_RESYNC_INTERVAL)
    local tick = 0

    while running do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "timer" and p1 == updateTimer then
            tick = tick + 1
            serverMark("flush tick=" .. tostring(tick))
            flushMarks()
            updateTimer = os.startTimer(UPDATE_INTERVAL)
        elseif event == "timer" and p1 == syncTimer then
            rednet.broadcast({ request = "status" }, "bunker_status_request")
            serverMark("sync request sent")
            syncTimer = os.startTimer(STATUS_RESYNC_INTERVAL)
        elseif event == "timer" and p1 == lockTimer then
            if not locked then
                lockConsole("idle " .. LOCK_AFTER_IDLE .. "s")
            end
        elseif event == "rednet_message" then
            local senderId, message, protocol = p1, p2, p3
            if protocol == "bunker_status" and type(message) == "table" and message.id then
                bunkerlib.setStatus(statuses, message.id, senderId, message.state, message.cmd, message.lock)
                serverMark("status id=" .. tostring(message.id) .. " state=" .. tostring(message.state and 1 or 0) .. " from=" .. tostring(senderId))
            elseif protocol == "bunker_alarm" and type(message) == "table" and type(message.on) == "boolean" then
                -- Alarm state from another server instance (screen server or
                -- another control server). Apply WITHOUT re-broadcasting.
                if alarm ~= message.on then
                    local src = tostring(message.source or senderId)
                    serverMark("alarm sync " .. (message.on and "ON" or "OFF") .. " from " .. src)
                    applyAlarm(message.on, src)
                    flushMarks()
                end
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

        -- A deploy = fetch + reboot + boot, which can keep a client silent for
        -- well over ten seconds. Using only 10s would briefly flash every
        -- component OFFLINE during update waves; 25s absorbs those reboots
        -- while still detecting a truly dead computer within half a minute.
        -- STATUS_RESYNC_INTERVAL (15s) re-asks every client before this
        -- window closes, so a missed regular heartbeat does not flap OFFLINE.
        bunkerlib.cleanStatuses(statuses, 25)
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
    print("  start     -> start control server")
end
