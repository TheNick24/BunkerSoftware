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
--   remote watch           -> live view of all incoming messages
--   remote shell           -> interactive console (type commands)
--   remote help            -> this text
--
-- Works with any device type (light, door,
-- safety-door, ...): the tool reads `cmd` from
-- the client status message. Known devices are
-- cached in remote.cache, so commands also work
-- briefly when out of range.
-- ============================================

local dir = fs.getDir(shell.getRunningProgram())
package.path = fs.combine(dir, "?.lua") .. ";" .. package.path
local bunkerlib = require("bunkerlib")

local args = { ... }

local LISTEN_SECONDS = 5
local CACHE_FILE = "remote.cache"

-- ============ DEVICE MAP ============
-- known[id] = { cmd, state, senderId, lastSeen }
local known = {}

local function stateText(cmd, state)
    if cmd == "door" or cmd == "safety-door" then
        return (state and "OPEN" or "CLOSED")
    end
    return (state and "ON" or "OFF")
end

-- ============ CACHE ============
local function loadCache()
    if fs.exists(CACHE_FILE) then
        local ok, data = pcall(function()
            local f = fs.open(CACHE_FILE, "r")
            local s = f.readAll()
            f.close()
            return textutils.unserialize(s)
        end)
        if ok and type(data) == "table" then return data end
    end
    return {}
end

local function saveCache()
    local f = fs.open(CACHE_FILE, "w")
    f.write(textutils.serialize(known))
    f.close()
end

-- ============ MODEM ============
-- Try every side (pocket computers attach their built-in modem to
-- different sides depending on version). Reuses already open modems.
local function openModem()
    local sides = { "back", "left", "right", "top", "bottom", "front" }
    for _, side in ipairs(sides) do
        local ok = rednet.isOpen(side) or pcall(rednet.open, side)
        if ok and rednet.isOpen(side) then return side end
    end
    for _, side in ipairs(rs.getSides()) do
        if not rednet.isOpen(side) then
            local ok = pcall(rednet.open, side)
            if ok and rednet.isOpen(side) then return side end
        end
    end
    return nil
end

-- ============ SCAN ============
-- Listens for `seconds` seconds. Returns the number of rednet messages
-- received and how many of them were bunker_status broadcasts.
local function scan(seconds)
    local deadline = os.clock() + seconds
    local received = 0
    local statuses = 0
    while true do
        local remaining = deadline - os.clock()
        if remaining <= 0 then break end
        local event, p1, p2, p3 = os.pullEvent(remaining)
        if event == "rednet_message" then
            received = received + 1
            if p3 == "bunker_status" and type(p2) == "table" and p2.id then
                statuses = statuses + 1
                known[p2.id] = {
                    cmd = p2.cmd or "light",
                    state = p2.state,
                    senderId = p1,
                    lastSeen = os.clock(),
                }
            end
        end
    end
    return received, statuses
end

-- ============ OUTPUT ============
local function list()
    local ids = {}
    for id in pairs(known) do ids[#ids + 1] = id end
    table.sort(ids)

    if #ids == 0 then
        term.setTextColor(colors.yellow)
        print("No clients heard.")
        term.setTextColor(colors.gray)
        print(" - Are the clients running? (check control room monitors)")
        print(" - Is the pocket computer in wireless range of a client?")
        print(" - Is the pocket wireless modem enabled in the pocket GUI?")
        print(" - Run 'remote watch' to see if ANY message arrives.")
        term.setTextColor(colors.white)
        return
    end

    term.setTextColor(colors.cyan)
    print(string.format("%-22s %-12s %-8s %s", "ID", "TYPE", "STATE", "CLIENT"))
    print(string.rep("-", 50))
    term.setTextColor(colors.white)
    for _, id in ipairs(ids) do
        local d = known[id]
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

-- Continuous listen: prints every incoming message so you can see
-- whether any traffic at all arrives at this computer.
local function watch()
    term.setTextColor(colors.yellow)
    print("WATCH - listening. Press any key to stop.")
    print("-----------------------------------------")
    term.setTextColor(colors.white)
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "rednet_message" then
            term.setTextColor(colors.yellow)
            print("[" .. tostring(p1) .. " <" .. tostring(p3) .. ">] " .. textutils.serialize(p2))
            term.setTextColor(colors.white)
            if p3 == "bunker_status" and type(p2) == "table" and p2.id then
                known[p2.id] = {
                    cmd = p2.cmd or "light",
                    state = p2.state,
                    senderId = p1,
                    lastSeen = os.clock(),
                }
                saveCache()
            end
        elseif event == "char" or event == "key" or event == "terminate" then
            break
        end
    end
    list()
end

-- Interactive console: type commands without restarting the program.
local function shell()
    local running = true
    local cmdLine = ""

    local function prompt()
        local _, th = term.getSize()
        term.setCursorPos(1, th)
        term.setBackgroundColor(colors.black)
        term.clearLine()
        term.setTextColor(colors.cyan)
        term.write("remote> " .. cmdLine)
        term.setTextColor(colors.white)
    end

    local function run(line)
        local parts = {}
        for w in line:gmatch("%S+") do parts[#parts + 1] = w end
        if #parts == 0 then return end
        local c = parts[1]:lower()

        if c == "exit" or c == "quit" then
            running = false
        elseif c == "list" or c == "status" then
            list()
        elseif c == "watch" then
            watch()
        elseif c == "help" then
            help()
        else
            local d = known[c]
            if not d then
                term.setTextColor(colors.red)
                print("Unknown device: " .. c)
                term.setTextColor(colors.white)
                print("Run 'list' to see available devices.")
                return
            end
            local target = (parts[2] or "toggle"):lower()
            local state
            if target == "on" then
                state = true
            elseif target == "off" then
                state = false
            else
                state = not d.state
            end

            if send(c, state) then saveCache() end

            local deadline = os.clock() + 2
            while os.clock() < deadline do
                local e, e1, e2, e3 = os.pullEvent(deadline - os.clock())
                if e == "rednet_message" and e3 == "bunker_status"
                   and type(e2) == "table" and e2.id == c then
                    known[c] = {
                        cmd = e2.cmd or d.cmd,
                        state = e2.state,
                        senderId = e1,
                        lastSeen = os.clock(),
                    }
                    if e2.state == state then
                        term.setTextColor(colors.green)
                        print("Confirmed: " .. c .. " is now " .. stateText(d.cmd, state))
                        term.setTextColor(colors.white)
                    end
                    break
                end
            end
        end
    end

    term.setTextColor(colors.yellow)
    print("MAMDANI remote shell - 'help' for commands, 'exit' to quit.")
    term.setTextColor(colors.white)
    term.setTextColor(colors.gray)
    print("Refreshing devices (" .. LISTEN_SECONDS .. "s)...")
    term.setTextColor(colors.white)
    scan(LISTEN_SECONDS)
    prompt()
    while running do
        local event, p1 = os.pullEvent()
        if event == "char" then
            cmdLine = cmdLine .. p1
            prompt()
        elseif event == "key" then
            if p1 == keys.enter then
                cmdLine = cmdLine:match("^%s*(.-)%s*$") or ""
                run(cmdLine)
                cmdLine = ""
                prompt()
            elseif p1 == keys.backspace then
                cmdLine = string.sub(cmdLine, 1, #cmdLine - 1)
                prompt()
            end
        end
    end
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
    print("  remote watch             live view of incoming messages")
    print("  remote shell             interactive console")
    print("  remote help              this text")
    print("Devices are discovered live from the clients' status broadcasts.")
end

-- ============ MAIN ============
term.clear()
term.setCursorPos(1, 1)

known = loadCache() or known

local modem = openModem()
if not modem then
    term.setTextColor(colors.red)
    print("No wireless modem found!")
    return
end
term.setTextColor(colors.gray)
print("Modem: " .. modem)
term.setTextColor(colors.white)

local arg1 = args[1]

if arg1 == "watch" then
    watch()
elseif arg1 == "shell" then
    shell()
elseif arg1 == "help" or arg1 == "-h" then
    help()
elseif arg1 == nil or arg1 == "list" or arg1 == "status" then
    term.setTextColor(colors.yellow)
    print("Listening for clients (" .. LISTEN_SECONDS .. "s)...")
    term.setTextColor(colors.white)
    local received, statuses = scan(LISTEN_SECONDS)
    term.setTextColor(colors.gray)
    print("Received " .. received .. " message(s), " .. statuses .. " status(es).")
    term.setTextColor(colors.white)
    list()
else
    local id = arg1
    local target = (args[2] or "toggle"):lower()

    term.setTextColor(colors.yellow)
    print("Listening for clients (" .. LISTEN_SECONDS .. "s)...")
    term.setTextColor(colors.white)
    scan(LISTEN_SECONDS)

    local d = known[id]
    if not d then
        term.setTextColor(colors.red)
        print("Unknown device: " .. id)
        term.setTextColor(colors.white)
        print("Run 'remote' to list available devices.")
        return
    end

    local state
    if target == "on" then
        state = true
    elseif target == "off" then
        state = false
    else
        state = not d.state
    end

    if not send(id, state) then return end
    saveCache()

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