-- ============================================
-- MAMDANI OS - module: CLIENT
-- Full room-client runtime (bunkerlib.runClient).
-- Loaded by bunkerlib.lua (do not require directly).
-- ============================================

-- Runs a full client: opens the modem, prints the banner, broadcasts
-- the state of every device and reacts to bunker_cmd commands.
-- conf:
--   name      = client display name (header line)
--   modemSide = preferred modem side (nil = auto)
--   interval  = status heartbeat interval (seconds); the full state of all
--               devices is re-broadcast this often, changes go out instantly
--   devices   = { { id, cmd = "light", driver = "relay"|"redstone"|"door"|"safety-door",
--                   relay?, peripheral?, side }, ... }
local lib

local function runClient(conf)
    local modem = lib.findModem(conf.modemSide)
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
            driver = lib.driver(d.driver),
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
        lib.printOnce(errs, dev.id, dev.driver.name .. " error (" .. dev.id .. "): " .. tostring(res))
        return false
    end
    local function set(dev, state)
        local ok, res = pcall(dev.driver.set, dev.conf, state)
        if not ok then
lib.printOnce(errs, dev.id, dev.driver.name .. " error (" .. dev.id .. "): " .. tostring(res))
        end
    end

    local lastStatus = {}
    local lastLockOut = {} -- last BROADCAST lock flag per device
    local lastSet = {} -- last COMMANDED state per device (persisted)
    local lastLock = {} -- last LOCK state per lockable door (persisted)
    local stateFile = conf.stateFile or "room.state"

    -- On boot the client restores the last commanded state of LIGHT devices,
    -- so a reboot leaves the room lit exactly as before - no input needed.
    -- Doors are NEVER auto-open (they must stay closed), but a LOCKED door
    -- must stay locked across a reboot, so its lock flag IS restored.
    local function applySavedState()
        if not fs.exists(stateFile) then return end
        local f = fs.open(stateFile, "r")
        if not f then return end
        local data
        local ok = pcall(function() data = textutils.unserialise(f.readAll()) end)
        f.close()
        if not ok or type(data) ~= "table" or type(data.lastSet) ~= "table" then return end
        for _, dev in ipairs(devices) do
            if dev.cmd == "light" and data.lastSet[dev.id] ~= nil then
                local saved = data.lastSet[dev.id]
                if saved ~= read(dev) then
                    local ok2 = pcall(dev.driver.set, dev.conf, saved)
                    if ok2 then
                        lastSet[dev.id] = saved
                        term.setTextColor(colors.gray)
                        print("restored " .. dev.id .. " -> " .. (saved and "ON" or "OFF"))
                        term.setTextColor(colors.white)
                    end
                end
            end
            if dev.driver.setLock and data.lastLock and data.lastLock[dev.id] ~= nil then
                local saved = data.lastLock[dev.id]
                local ok3 = pcall(dev.driver.setLock, dev.conf, saved)
                if ok3 then
                    lastLock[dev.id] = saved
                    term.setTextColor(colors.yellow)
                    print("restored " .. dev.id .. " -> " .. (saved and "LOCKED" or "unlocked"))
                    term.setTextColor(colors.white)
                end
            end
        end
    end

    local function saveState()
        local f = fs.open(stateFile, "w")
        if not f then return end
        f.write(textutils.serialise({ lastSet = lastSet, lastLock = lastLock }))
        f.close()
    end
    -- Boot/heartbeat audit: BUFFERED on purpose - one disk open/write/close
    -- per status request is exactly the CPU load that makes CC timers fire
    -- late (same rationale as controlserver's serverMark). Flushed on each
    -- heartbeat and when the buffer fills. Defined BEFORE sendStatus so the
    -- references inside sendStatus bind to this local.
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
    local function clientMark(msg)
        if #markBuf >= 64 then flushMarks() end
        markBuf[#markBuf + 1] = "@" .. tostring(os.epoch("utc")) .. ": " .. msg
    end

    -- `force` = heartbeat: broadcast EVERY device (keeps the control room's
    -- online detection working). Without force: only broadcast what CHANGED,
    -- so quick on/off commands do not re-flood rednet with all devices.
    -- Lockable doors broadcast their lock flag alongside the door state.
    local function sendStatus(force)
        for _, dev in ipairs(devices) do
            local state = read(dev)
            local lock
            if dev.driver.isLocked then
                local okL, locked = pcall(dev.driver.isLocked, dev.conf)
                if okL then lock = locked or false end
            end
            if force or lastStatus[dev.id] ~= state or lastLockOut[dev.id] ~= lock then
                local msg = { id = dev.id, cmd = dev.cmd, state = state }
                if lock ~= nil then msg.lock = lock end
                pcall(rednet.broadcast, msg, "bunker_status")
            end
            lastStatus[dev.id] = state
            lastLockOut[dev.id] = lock
        end
    end

    -- Boot/heartbeat audit comment retained; definition moved above.
    local function clientLoop()
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

    applySavedState()
    sendStatus(true)
    local statusTimer = os.startTimer(conf.interval)

    clientMark("boot: modem=" .. tostring(modem) .. " devices=" .. #devices)
    clientMark("boot prog=" .. tostring(shell.getRunningProgram()) .. " dir=" .. tostring(fs.getDir(shell.getRunningProgram())))
    clientMark("modem open left=" .. tostring(rednet.isOpen("left")) .. " back=" .. tostring(rednet.isOpen("back")) .. " top=" .. tostring(rednet.isOpen("top")))
    flushMarks()
    pcall(rednet.broadcast, { test = true, at = os.epoch("utc") }, "bunker_test")

    -- Optional telemetry: periodically read one or more induction matrices and
    -- broadcast the values under "bunker_energy" so any room can display the
    -- energy screen. Batteries are keyed by NAME so several can run at once:
    --   conf.telemetry = { BAT1 = { side = "inductionPort_0", interval = 5 } }
    -- Each entry: side, protocol (default "bunker_energy"), interval (default
    -- conf.interval or 10).
    local telemTimers = {} -- timerId -> battery name
    local batteryTimerIds = {} -- battery name -> currently armed timerId
    -- Exactly one timer per battery: arming cancels any pending timer first.
    -- Without this, every bunker_status_request spawned a parallel chain and
    -- the bunker_energy flood starved the event loop (late heartbeats).
    local function telemTimerArm(name, interval)
        local prev = batteryTimerIds[name]
        if prev then
            pcall(os.cancelTimer, prev)
            telemTimers[prev] = nil
        end
        local timerId = os.startTimer(interval or conf.interval or 10)
        telemTimers[timerId] = name
        batteryTimerIds[name] = timerId
        return timerId
    end
    local function broadcastBattery(name)
        local t = conf.telemetry and conf.telemetry[name]
        if not t or not t.side then return end
        -- Fully isolated: a vanished/forming induction port or a rednet
        -- serialisation error must never kill the client loop.
        local okR, data = pcall(function()
            return lib.energy and lib.energy.readInduction(t.side)
        end)
        if okR and data then
            local sent
            local okB, resB = pcall(function()
                data.name = name
                rednet.broadcast(data, t.protocol or "bunker_energy")
                sent = true
            end)
            if not okB or not sent then
                lib.printOnce(errs, "telem." .. name, "telemetry broadcast failed: " .. tostring(resB))
            end
        end
        telemTimerArm(name, t.interval)
    end
    if conf.telemetry and lib.energy then
        for name in pairs(conf.telemetry) do
            broadcastBattery(name)
        end
    end

    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "timer" and p1 == statusTimer then
            -- Re-arm BEFORE the (potentially slow) send so the next due time
            -- is measured from now, not from after sendStatus returns.
            statusTimer = os.startTimer(conf.interval)
            sendStatus(true)
            clientMark("hb ok")
            flushMarks()
        elseif event == "timer" then
            local name = telemTimers[p1]
            if name then
                telemTimers[p1] = nil
                batteryTimerIds[name] = nil
                broadcastBattery(name)
                -- Belt and suspenders: if the dedicated status timer ever
                -- gets lost (parallel agent/HTTP quirks), telemetry ticks
                -- still keep the room heartbeats alive.
                sendStatus(true)
            end
        elseif event == "rednet_message" then
            local senderId, message, protocol = p1, p2, p3
            if protocol == "bunker_status_request" then
                -- A control-server restart loses its in-memory status table.
                -- Reply immediately instead of making the monitors wait for
                -- the next ordinary room heartbeat. broadcastBattery cancels
                -- and re-arms the existing per-battery timer (no chain leak).
                sendStatus(true)
                if conf.telemetry and lib.energy then
                    for name in pairs(conf.telemetry) do broadcastBattery(name) end
                end
                clientMark("request from " .. tostring(senderId) .. " -> replayed")
                flushMarks()
            elseif protocol == "bunker_cmd" and type(message) == "table" and message.cmd then
                for _, dev in ipairs(devices) do
                    if dev.id == message.room and dev.cmd == message.cmd then
                        if message.lock ~= nil and dev.driver.setLock then
                            pcall(dev.driver.setLock, dev.conf, message.lock)
                            lastLock[dev.id] = not not message.lock
                        else
                            set(dev, message.state)
                            if dev.cmd == "light" then lastSet[dev.id] = message.state end
                        end
                        saveState()
                        sendStatus()
                        term.setTextColor(colors.yellow)
                        if message.lock ~= nil and dev.driver.setLock then
                            print(dev.id .. ": " .. (message.lock and "LOCKED" or "unlocked"))
                        else
                            print(dev.id .. ": " .. (message.state and "ON" or "OFF"))
                        end
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

    -- Supervisor loop: one bad frame must never take the whole client down.
    -- The room computer re-arms itself (fresh timers, fresh telemetry) instead
    -- of going silent on rednet until somebody reboots it. Errors are also
    -- appended beside main.lua so the operator can read them via the agent's
    -- `log.read` command (payload.path = "main").
    while true do
        local ok, err = xpcall(clientLoop, debug.traceback)
        if ok then break end
        local okDir, errFile = pcall(function()
            local d = fs.getDir(shell.getRunningProgram())
            if not d or d == "" then d = "/" end
            local fp = fs.combine(d, "client-error.log")
            if fs.exists(fp) then
                local sz = fs.getSize(fp)
                if sz and sz > 16384 then fs.delete(fp) end
            end
            local f = fs.open(fp, "a")
            if f then
                f.write("@" .. tostring(os.epoch("utc")) .. ": " .. tostring(err) .. "\n")
                f.close()
            end
        end)
        term.setTextColor(colors.red)
        term.setCursorPos(1, 1)
        term.clear()
        print("Client error; restarting in 5s: " .. tostring(err))
        term.setTextColor(colors.white)
        sleep(5)
    end
end

return function(bunkerlib)
    lib = bunkerlib
    bunkerlib.runClient = runClient
end
