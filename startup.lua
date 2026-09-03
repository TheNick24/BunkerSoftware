-- BUNKER CONTROL (Server only)
-- Steuert das Atrium-Relay direkt (kein Client, kein Rednet noetig).

local PASSWORD = "bunker123"
local RELAY = "redstone_relay_4"
local RELAY_SIDE = "right"
local UPDATE_INTERVAL = 1

local function readLight()
    return peripheral.call(RELAY, "getOutput", RELAY_SIDE)
end

local function setLight(state)
    peripheral.call(RELAY, "setOutput", RELAY_SIDE, state)
end

local function updateMonitors()
    local light = readLight()
    local names = peripheral.getNames()
    for _, name in ipairs(names) do
        if peripheral.getType(name) == "monitor" then
            local mon = peripheral.wrap(name)
            mon.setBackgroundColor(colors.black)
            mon.clear()

            mon.setCursorPos(1, 1)
            mon.setTextColor(colors.cyan)
            mon.write("BUNKER CONTROL")

            mon.setCursorPos(1, 3)
            mon.setTextColor(colors.white)
            mon.write("Atrium:")

            mon.setCursorPos(1, 4)
            if light then
                mon.setTextColor(colors.yellow)
                mon.write("* LICHT AN *")
            else
                mon.setTextColor(colors.gray)
                mon.write("LICHT AUS")
            end

            mon.setCursorPos(3, 7)
            mon.setTextColor(colors.white)
            mon.setBackgroundColor(colors.gray)
            mon.write("[ LICHT ]")
            mon.setBackgroundColor(colors.black)
        end
    end
end

local function main()
    term.setTextColor(colors.cyan)
    print("=== BUNKER CONTROL ===")
    term.setTextColor(colors.white)
    print("Passwort:")
    term.setTextColor(colors.gray)
    local input = read("*")
    term.setTextColor(colors.white)
    if input ~= PASSWORD then
        term.setTextColor(colors.red)
        print("Falsches Passwort!")
        term.setTextColor(colors.white)
        return
    end
    print("Zugang gewahrt!")

    local updateTimer = os.startTimer(UPDATE_INTERVAL)

    while true do
        local event, param1, param2, param3 = os.pullEvent()

        if event == "timer" and param1 == updateTimer then
            updateMonitors()
            updateTimer = os.startTimer(UPDATE_INTERVAL)

        elseif event == "monitor_touch" then
            print("TOUCH: " .. tostring(param1) .. " x=" .. tostring(param2) .. " y=" .. tostring(param3))
            local x, y = param2, param3
            if y == 7 then
                local newState = not readLight()
                setLight(newState)
                term.setTextColor(colors.yellow)
                print("Licht: " .. (newState and "AN" or "AUS"))
                term.setTextColor(colors.white)
                updateMonitors()
            end

        elseif event == "char" then
            local ch = param1
            if ch == "l" or ch == "L" or ch == " " then
                local newState = not readLight()
                setLight(newState)
                term.setTextColor(colors.yellow)
                print("Licht: " .. (newState and "AN" or "AUS"))
                term.setTextColor(colors.white)
                updateMonitors()
            elseif ch == "s" or ch == "S" then
                print("Atrium: " .. (readLight() and "LICHT AN" or "LICHT AUS"))
            end
        end
    end
end

main()