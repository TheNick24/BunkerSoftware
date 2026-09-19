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
        bunkerlib.printOnce(errs, dev.id, dev.driver.name .. " error (" .. dev.id .. "): " .. tostring(res))
        return false
    end
    local function set(dev, state)
        local ok, res = pcall(dev.driver.set, dev.conf, state)
        if not ok then
lib.printOnce(errs, dev.id, dev.driver.name .. " error (" .. dev.id .. "): " .. tostring(res))
        end
    end

    local lastStatus = {}
    local lastSet = {} -- last COMMANDED state per device (persisted)
    local stateFile = conf.stateFile or "room.state"

    -- On boot the client restores the last commanded state of LIGHT devices,
    -- so a reboot leaves the room lit exactly as before - no input needed.
    -- Doors are NEVER auto-restored (they must stay closed unless opened).
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
        end
    end

    local function saveState()
        local f = fs.open(stateFile, "w")
        if not f then return end
        f.write(textutils.serialise({ lastSet = lastSet }))
        f.close()
    end
    -- `force` = heartbeat: broadcast EVERY device (keeps the control room's
    -- online detection working). Without force: only broadcast what CHANGED,
    -- so quick on/off commands do not re-flood rednet with all devices.
    local function sendStatus(force)
        for _, dev in ipairs(devices) do
            local state = read(dev)
            if force or lastStatus[dev.id] ~= state then
                rednet.broadcast({ id = dev.id, cmd = dev.cmd, state = state }, "bunker_status")
            end
            lastStatus[dev.id] = state
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

    applySavedState()
    sendStatus(true)
    local statusTimer = os.startTimer(conf.interval)

    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "timer" and p1 == statusTimer then
            sendStatus(true)
            statusTimer = os.startTimer(conf.interval)
        elseif event == "rednet_message" then
            local senderId, message, protocol = p1, p2, p3
            if protocol == "bunker_cmd" and type(message) == "table" and message.cmd then
                for _, dev in ipairs(devices) do
                    if dev.id == message.room and dev.cmd == message.cmd then
                        set(dev, message.state)
                        if dev.cmd == "light" then lastSet[dev.id] = message.state end
                        saveState()
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

return function(bunkerlib)
    lib = bunkerlib
    bunkerlib.runClient = runClient
end