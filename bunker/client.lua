local args = {...}
local config = require("config")
local protocol = "bunker_monitor"

local roomId = args[1]
if not roomId then
    term.setTextColor(colors.red)
    print("Benutzung: bunker/client <raum_id>")
    term.setTextColor(colors.white)
    print("Verfuegbare Raeume:")
    for _, room in ipairs(config.rooms) do
        print("  - " .. room.id)
    end
    return
end

local roomConfig = nil
for _, room in ipairs(config.rooms) do
    if room.id == roomId then
        roomConfig = room
        break
    end
end

if not roomConfig then
    term.setTextColor(colors.red)
    print("FEHLER: Raum '" .. tostring(roomId) .. "' nicht in config.lua gefunden!")
    term.setTextColor(colors.white)
    return
end

local commandProtocol = "bunker_" .. roomConfig.id

if rednet.open("back") then
    print("Rednet geoeffnet (back)")
else
    term.setTextColor(colors.red)
    print("FEHLER: Konnte rednet nicht oeffnen!")
    term.setTextColor(colors.white)
    return
end
local function readDoor()
    return rs.getInput(roomConfig.door_side)
end

local function readLight()
    return rs.getInput(roomConfig.light_side)
end

local function setDoor(state)
    rs.setOutput(roomConfig.door_side, state)
end

local function setLight(state)
    rs.setOutput(roomConfig.light_side, state)
end

local function sendStatus()
    rednet.broadcast({
        id = roomConfig.id,
        door = readDoor(),
        light = readLight(),
        time = os.time(),
    }, protocol)
end

term.setTextColor(colors.cyan)
print("CLIENT: " .. roomConfig.id)
term.setTextColor(colors.white)

local statusTimer = os.startTimer(config.update_interval or 2)

while true do
    local event, param1, param2, param3 = os.pullEvent()
    if event == "timer" and param1 == statusTimer then
        sendStatus()
        statusTimer = os.startTimer(config.update_interval or 2)
    elseif event == "rednet_message" then
        local senderId, message, msgProtocol = param1, param2, param3
        if msgProtocol == commandProtocol and message then
            if message.cmd == "toggle" then
                setDoor(not readDoor())
                setLight(not readLight())
            elseif message.cmd == "door" then
                setDoor(message.state)
            elseif message.cmd == "light" then
                setLight(message.state)
            else
                print("Unbekannter Befehl: " .. tostring(message.cmd))
            end
            sendStatus()
        end
    end
end
