local config = require("config")

local protocol = "bunker_monitor"
local auth_protocol = "bunker_auth"

local statuses = {}
local authenticated = false
local startTime = os.clock()

local function findMonitors()
    local monitors = {}
    local names = {peripheral.find("monitor")}
    for _, name in ipairs(names) do
        table.insert(monitors, peripheral.wrap(name))
    end
    if #monitors == 0 then
        for _, side in ipairs(rs.getSides()) do
            if peripheral.getType(side) == "monitor" then
                table.insert(monitors, peripheral.wrap(side))
            end
        end
    end
    return monitors
end

local function clearMonitor(monitor)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()
    monitor.setCursorPos(1, 1)
end

local function drawHeader(monitor, width)
    local timeStr = textutils.formatTime(os.time(), true)
    local dateStr = os.date("%d.%m.%Y")
    monitor.setTextColor(colors.cyan)
    monitor.setCursorPos(1, 1)
    monitor.write("BUNKER MONITORING")
    monitor.setCursorPos(width - #dateStr - #timeStr, 1)
    monitor.setTextColor(colors.gray)
    monitor.write(dateStr .. " " .. timeStr)
    monitor.setTextColor(colors.white)
    monitor.setCursorPos(1, 2)
    monitor.write(string.rep("=", width))
end

local function drawTableHeader(monitor, width)
    monitor.setTextColor(colors.yellow)
    monitor.setCursorPos(1, 3)
    monitor.write(string.format("%-10s | %-8s | %-8s | %-12s", "RAUM", "TUR", "LAMPE", "STATUS"))
    monitor.setTextColor(colors.white)
    monitor.setCursorPos(1, 4)
    monitor.write(string.rep("-", width))
end

local function drawRoom(monitor, room, y, width)
    local status = statuses[room.id]
    local doorStr = "---"
    local lightStr = "---"
    local statusStr = "OFFLINE"
    local statusColor = colors.red

    if status then
        if status.door then
            doorStr = status.door and "OFFEN" or "ZU"
        end
        if status.light ~= nil then
            lightStr = status.light and "AN" or "AUS"
        end
        statusStr = "ONLINE"
        statusColor = colors.green
    end

    monitor.setCursorPos(1, y)
    monitor.setTextColor(colors.white)
    monitor.write(string.format("%-10s", room.name))
    monitor.write(" | ")

    monitor.setTextColor(status.door and colors.red or colors.green)
    monitor.write(string.format("%-8s", doorStr))
    monitor.setTextColor(colors.white)
    monitor.write(" | ")

    monitor.setTextColor(status.light and colors.yellow or colors.gray)
    monitor.write(string.format("%-8s", lightStr))
    monitor.setTextColor(colors.white)
    monitor.write(" | ")

    monitor.setTextColor(statusColor)
    monitor.write(statusStr)
    monitor.setTextColor(colors.white)
end

local function drawFooter(monitor, y, width)
    monitor.setCursorPos(1, y)
    monitor.write(string.rep("=", width))

    local clientCount = 0
    for _, s in pairs(statuses) do
        if s then clientCount = clientCount + 1 end
    end
    local totalRooms = #config.rooms

    local uptimeSec = os.clock() - startTime
    local hours = math.floor(uptimeSec / 3600)
    local mins = math.floor((uptimeSec % 3600) / 60)
    local secs = math.floor(uptimeSec % 60)
    local uptimeStr = string.format("%d:%02d:%02d", hours, mins, secs)

    monitor.setCursorPos(1, y + 1)
    monitor.setTextColor(colors.gray)
    monitor.write(string.format("CLIENTS: %d/%d", clientCount, totalRooms))
    monitor.setCursorPos(width - #uptimeStr - 7, y + 1)
    monitor.write("UPTIME: " .. uptimeStr)
    monitor.setTextColor(colors.white)
end

local function updateMonitors(monitors)
    for _, monitor in ipairs(monitors) do
        local width, height = monitor.getSize()
        clearMonitor(monitor)
        drawHeader(monitor, width)
        drawTableHeader(monitor, width)

        for i, room in ipairs(config.rooms) do
            drawRoom(monitor, room, 4 + i, width)
        end

        drawFooter(monitor, 4 + #config.rooms + 2, width)
    end
end

local function handleAuth()
    term.setTextColor(colors.cyan)
    print("=== BUNKER CONTROL SYSTEM ===")
    term.setTextColor(colors.white)
    print("Passwort eingeben:")
    term.setTextColor(colors.gray)
    local input = read("*")
    term.setTextColor(colors.white)

    if input == config.password then
        authenticated = true
        term.setTextColor(colors.green)
        print("Zugang gewahrt!")
        term.setTextColor(colors.white)
        return true
    else
        term.setTextColor(colors.red)
        print("Falsches Passwort!")
        term.setTextColor(colors.white)
        return false
    end
end

local function handleCommand(input)
    if not authenticated then
        term.setTextColor(colors.red)
        print("Nicht authentifiziert!")
        term.setTextColor(colors.white)
        return
    end

    local parts = {}
    for word in input:gmatch("%S+") do
        table.insert(parts, word)
    end

    if #parts < 2 then
        print("Benutzung: <raum_id> <toggle/tuer/licht> [an/aus]")
        return
    end

    local roomId = parts[1]
    local action = parts[2]
    local value = parts[3]

    local status = statuses[roomId]
    if not status then
        term.setTextColor(colors.red)
        print("Raum '" .. roomId .. "' ist offline oder unbekannt!")
        term.setTextColor(colors.white)
        return
    end
    local clientId = status.senderId
    local sendProtocol = "bunker_" .. roomId

    if action == "toggle" then
        rednet.send(clientId, {cmd = "toggle"}, sendProtocol)
        print("Toggle gesendet an: " .. roomId)
    elseif action == "tuer" then
        local state = value == "an"
        rednet.send(clientId, {cmd = "door", state = state}, sendProtocol)
        print("Tür " .. roomId .. ": " .. (state and "OFFEN" or "ZU"))
    elseif action == "licht" then
        local state = value == "an"
        rednet.send(clientId, {cmd = "light", state = state}, sendProtocol)
        print("Licht " .. roomId .. ": " .. (state and "AN" or "AUS"))
    else
        print("Unbekannter Befehl: " .. action)
    end
end

local function main()
    if not handleAuth() then
        return
    end

    local monitors = findMonitors()
    print("Monitore gefunden: " .. #monitors)

    for _, room in ipairs(config.rooms) do
        statuses[room.id] = nil
    end

    rednet.open("back")

    parallel.waitForAny(
        function()
            while true do
                local senderId, message, msgProtocol = rednet.receive(protocol)
                if senderId and message and message.id then
                    statuses[message.id] = {
                        door = message.door,
                        light = message.light,
                        lastSeen = os.clock(),
                        senderId = senderId,
                    }
                end
            end
        end,
        function()
            while true do
                updateMonitors(monitors)
                sleep(config.update_interval)
            end
        end,
        function()
            while true do
                term.setTextColor(colors.cyan)
                write("> ")
                term.setTextColor(colors.white)
                local input = read()
                if input == "exit" then
                    print("Beende...")
                    return
                elseif input == "clear" then
                    statuses = {}
                    print("Status zurueckgesetzt.")
                else
                    handleCommand(input)
                end
            end
        end,
        function()
            while true do
                for id, status in pairs(statuses) do
                    if os.clock() - status.lastSeen > 10 then
                        statuses[id] = nil
                    end
                end
                sleep(5)
            end
        end
    )
end

main()
