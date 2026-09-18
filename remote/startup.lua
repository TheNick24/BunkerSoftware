-- ============================================
-- MAMDANI OS - REMOTE CLI
-- Controls devices from the command line, e.g.
-- on a pocket computer. Listens for the clients'
-- status broadcasts, then sends on/off commands.
--
-- Copy as remote.lua (next to bunkerlib.lua):
--   remote                 -> list known devices
--   remote <id> on|off     -> set a device
--   remote <id> toggle     -> flip a device
--   remote <id>            -> shorthand for toggle
--   remote help            -> this text
--
-- Works with any device type (light, door,
-- safety-door, ...): the tool reads `cmd` from
-- the client status message.
-- ============================================

local dir = fs.getDir(shell.getRunningProgram())
package.path = fs.combine(dir, "?.lua") .. ";" .. package.path
local bunkerlib = require("bunkerlib")

local args = { ... }

local LISTEN_SECONDS = 4

-- ============ DEVICE MAP ============
-- known[id] = { cmd, state, senderId, lastSeen }
local known = {}

local function stateText(cmd, state)
    if cmd == "door" or cmd == "safety-door" then
        return (state and "OPEN" or "CLOSED")
    end
    return (state and "ON" or "OFF")
end

-- Collect status broadcasts for `seconds` seconds.
local function scan(seconds)
    local deadline = os.clock() + seconds
    while true do
        local remaining = deadline - os.clock()
        if remaining <= 0 then break end
        local event, p1, p2, p3 = os.pullEvent(remaining)
        if event == "rednet_message" then
            if p3 == "bunker_status" and type(p2) == "table" and p2.id then
                known[p2.id] = {
                    cmd = p2.cmd or "light",
                    state = p2.state,
                    senderId = p1,
                    lastSeen = os.clock(),
                }
            elseif p3 == "bunker_cmd" and type(p2) == "table" and p2.room then
                -- echo of our own command (same machine); ignore
            end
        end
    end
end

local function list()
    if next(known) == nil then
        term.setTextColor(colors.yellow)
        print("No clients heard - are the clients running and in range?")
        term.setTextColor(colors.white)
        return
    end
    term.setTextColor(colors.cyan)
    print("=== KNOWN DEVICES ===")
    term.setTextColor(colors.white)
    print(string.format("%-22s %-12s %-8s %s", "ID", "TYPE", "STATE", "CLIENT"))
    for id, d in pairs(known) do
        print(string.format("%-22s %-12s %-8s %d", id, d.cmd, stateText(d.cmd, d.state), d.senderId))
    end
end

local function send(id, state)
    local d = known[id]
    if not d then
        term.setTextColor(colors.red)
        print("Unknown device: " .. id)
        term.setTextColor(colors.white)
        print("Run 'remote' to list available devices.")
        return false
    end
    rednet.send(d.senderId, { room = id, cmd = d.cmd, state = state }, "bunker_cmd")
    term.setTextColor(colors.green)
    print(id .. " -> " .. stateText(d.cmd, state) .. " (sent to client " .. d.senderId .. ")")
    term.setTextColor(colors.white)
    return true
end

local function help()
    term.setTextColor(colors.cyan)
    print("=== MAMDANI OS - REMOTE CLI ===")
    term.setTextColor(colors.white)
    print("Usage:")
    print("  remote                   list known devices")
    print("  remote <id> on|off       set a device")
    print("  remote <id> toggle       flip a device")
    print("  remote <id>              shorthand for toggle")
    print("  remote help              this text")
    print("Devices are discovered live from the clients' status broadcasts.")
end

-- ============ MAIN ============
term.clear()
term.setCursorPos(1, 1)

--- Open the first working modem. Pocket computers expose their built-in
--- modem as a normal side too, so try "back" first (common on pocket),
--- then all redstone sides via the library.
local modem = bunkerlib.findModem("back")
if not modem then
    term.setTextColor(colors.red)
    print("No wireless modem found!")
    return
end
term.setTextColor(colors.gray)
print("Modem: " .. modem)
term.setTextColor(colors.white)

local arg1 = args[1]

if arg1 == nil or arg1 == "list" or arg1 == "status" then
    term.setTextColor(colors.yellow)
    print("Listening for clients (" .. LISTEN_SECONDS .. "s)...")
    term.setTextColor(colors.white)
    scan(LISTEN_SECONDS)
    list()
elseif arg1 == "help" or arg1 == "-h" then
    help()
else
    local id = arg1
    local target = ((args[2] or "toggle"):lower())

    term.setTextColor(colors.yellow)
    print("Listening for clients (" .. LISTEN_SECONDS .. "s)...")
    term.setTextColor(colors.white)
    scan(LISTEN_SECONDS)

    if not known[id] then
        term.setTextColor(colors.red)
        print("Unknown device: " .. id)
        term.setTextColor(colors.white)
        print("Run 'remote' to list available devices.")
        return
    end

    local d = known[id]
    local state
    if target == "on" then
        state = true
    elseif target == "off" then
        state = false
    else
        state = not d.state
    end

    if not send(id, state) then return end

    -- wait for the client's next status broadcast to confirm
    local deadline = os.clock() + 3
    local confirmed = false
    while os.clock() < deadline do
        local e, e1, e2, e3 = os.pullEvent(deadline - os.clock())
        if e == "rednet_message" and e3 == "bunker_status"
           and type(e2) == "table" and e2.id == id then
            known[id] = {
                cmd = e2.cmd or d.cmd,
                state = e2.state,
                senderId = e1,
                lastSeen = os.clock(),
            }
            confirmed = (e2.state == state)
            break
        end
    end

    if confirmed then
        term.setTextColor(colors.green)
        print("Confirmed: " .. id .. " is now " .. stateText(d.cmd, state))
        term.setTextColor(colors.white)
    else
        term.setTextColor(colors.yellow)
        print("No confirmation yet - device offline or out of range?")
        term.setTextColor(colors.white)
    end
end