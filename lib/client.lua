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
--   interval  = status broadcast interval (seconds)
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

return function(bunkerlib)
    lib = bunkerlib
    bunkerlib.runClient = runClient
end