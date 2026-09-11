-- ============================================
-- MAMDANI OS - CLIENT
-- Adjust config below, then copy as startup.lua
-- to the room computer.
-- ============================================

-- ============ CONFIG (edit here!) ============
local ROOM_ID     = "entrance"
local ROOM_NAME   = "Entrance"
local RELAY       = "redstone_relay_6"
local RELAY_SIDE  = "right"
-- Modem side of the computer (which side the wireless modem is on),
-- e.g. "left"; nil = auto-detect all sides
local MODEM_SIDE  = nil
-- Optional extra lights on this computer (e.g. corridor lamps).
-- One entry per group; `id` must match the control room's `aux` table.
-- These are NOT part of a room. Leave empty if not used.
local AUX_GROUPS = {
    -- { id = "flur1", relay = "redstone_relay_X", side = "right" },
}
local UPDATE_INTERVAL = 2

-- ============ MODEM ============
local function findModem()
    local order = {}
    if MODEM_SIDE and MODEM_SIDE ~= "" then table.insert(order, MODEM_SIDE) end
    for _, side in ipairs(rs.getSides()) do
        if not (MODEM_SIDE and MODEM_SIDE ~= "" and side == MODEM_SIDE) then
            table.insert(order, side)
        end
    end
    for _, side in ipairs(order) do
        local ok = pcall(rednet.open, side)
        if ok and rednet.isOpen(side) then return side end
    end
    return nil
end

-- ============ START ============
local modem = findModem()
if not modem then
    term.setTextColor(colors.red)
    print("No modem found!")
    return
end

local function readLight()
    return peripheral.call(RELAY, "getOutput", RELAY_SIDE)
end

local function setLight(state)
    peripheral.call(RELAY, "setOutput", RELAY_SIDE, state)
end

local function auxById(id)
    for _, g in ipairs(AUX_GROUPS) do
        if g.id == id then return g end
    end
    return nil
end

local function readAux(g)
    return peripheral.call(g.relay, "getOutput", g.side)
end

local function setAux(g, state)
    peripheral.call(g.relay, "setOutput", g.side, state)
end

local function sendStatus()
    rednet.broadcast({ id = ROOM_ID, light = readLight() }, "bunker_status")
    for _, g in ipairs(AUX_GROUPS) do
        rednet.broadcast({ id = g.id, light = readAux(g) }, "bunker_status")
    end
end

term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.cyan)
print("==========================")
print("       MAMDANI OS")
term.setTextColor(colors.white)
print("    Client: " .. ROOM_NAME)
term.setTextColor(colors.cyan)
print("==========================")
term.setTextColor(colors.gray)
print("Modem: " .. modem)
print("Relay: " .. RELAY .. " [" .. RELAY_SIDE .. "]")
if #AUX_GROUPS > 0 then
    term.setTextColor(colors.cyan)
    for _, g in ipairs(AUX_GROUPS) do
        print("Aux: " .. g.id .. " -> " .. g.relay .. " [" .. g.side .. "]")
    end
end
term.setTextColor(colors.white)
print("---")

sendStatus()
local statusTimer = os.startTimer(UPDATE_INTERVAL)

while true do
    local event, p1, p2, p3 = os.pullEvent()
    if event == "timer" and p1 == statusTimer then
        sendStatus()
        statusTimer = os.startTimer(UPDATE_INTERVAL)
    elseif event == "rednet_message" then
        local senderId, message, protocol = p1, p2, p3
        if protocol == "bunker_cmd" and type(message) == "table" and message.cmd == "light" then
            if message.room == ROOM_ID then
                setLight(message.state)
                sendStatus()
                term.setTextColor(colors.yellow)
                print("Light: " .. (message.state and "ON" or "OFF"))
                term.setTextColor(colors.white)
            else
                local g = auxById(message.room)
                if g then
                    setAux(g, message.state)
                    sendStatus()
                    term.setTextColor(colors.yellow)
                    print("Aux " .. g.id .. ": " .. (message.state and "ON" or "OFF"))
                    term.setTextColor(colors.white)
                end
            end
        end
    end
end