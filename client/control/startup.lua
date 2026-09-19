-- ============================================
-- MAMDANI OS - DOOR KEYPAD + CLIENT
-- Runs on the control room computer.
-- Shows a PIN keypad on a monitor for door
-- access (outside) and a simple OPEN button
-- on monitor_10 (inside). Broadcasts all
-- device statuses to control.
--
-- Setup: startup setup  (set/change PIN)
-- Start: startup
-- ============================================

local args = { ... }

local dir = fs.getDir(shell.getRunningProgram())
package.path = fs.combine(dir, "?.lua") .. ";" .. package.path
local bunkerlib = require("bunkerlib")

-- ============ CONFIG ============
local NAME            = "Control"
local MODEM_SIDE      = "left"
local UPDATE_INTERVAL = 2
local DOOR_TIMEOUT    = 5   -- seconds until door auto-closes
local HASH_FILE       = "door.hash"
local MAX_CODE_LEN    = 4
local INSIDE_MONITOR  = "monitor_10" -- inside button (no PIN needed)

local DEVICES = {
    { id = "control",            cmd = "light", driver = "relay",    relay = "redstone_relay_9",  side = "top" },
    { id = "control-corridor-1", cmd = "light", driver = "relay",    relay = "redstone_relay_9",  side = "right" },
    { id = "control-door",       cmd = "door",  driver = "door",  peripheral = "redstone_relay_10", side = "left" },
    { id = "server-door", cmd = "door", driver = "door", peripheral = "redstone_relay_13", side = "front" },
}

local DOOR_DEVICE = DEVICES[3]

-- ============ HASH ============
local function loadHash()
    if fs.exists(HASH_FILE) then
        local f = fs.open(HASH_FILE, "r")
        local h = f.readAll()
        f.close()
        return h
    end
end

local function saveHash(hash)
    local f = fs.open(HASH_FILE, "w")
    f.write(hash)
    f.close()
end

-- ============ SETUP ============
if args[1] == "setup" then
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("==========================")
    print("   DOOR KEYPAD - SETUP")
    print("==========================")
    term.setTextColor(colors.white)
    print("New PIN:")
    term.setTextColor(colors.gray)
    local p1 = read("*")
    term.setTextColor(colors.white)
    print("Repeat PIN:")
    term.setTextColor(colors.gray)
    local p2 = read("*")
    if p1 ~= p2 then
        term.setTextColor(colors.red); print("PINs do not match!"); return
    end
    if #p1 < 4 then
        term.setTextColor(colors.red); print("PIN too short (min. 4)!"); return
    end
    saveHash(bunkerlib.hashPassword(p1))
    term.setTextColor(colors.green)
    print("PIN saved!")
    term.setTextColor(colors.gray)
    print("Hash: " .. tostring(loadHash()))
    print("(rewritten as salted PBKDF2-HMAC-SHA256)")
    return
end

-- ============ TEST ============
if args[1] == "test" then
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("DOOR HASH TEST")
    print("================")
    term.setTextColor(colors.white)
    print("Stored: " .. tostring(loadHash()))
    if args[2] then
        term.setTextColor(colors.yellow)
        print("Checking '" .. args[2] .. "' against stored value...")
        term.setTextColor(colors.white)
        if bunkerlib.verifyPassword(args[2], loadHash()) then
            term.setTextColor(colors.green)
            print("MATCH!")
        else
            term.setTextColor(colors.red)
            print("NO MATCH")
        end
    else
        term.setTextColor(colors.yellow)
        print("Usage: startup test <pin>")
    end
    return
end

-- ============ CHECK PIN EXISTS ============
if not loadHash() then
    term.setTextColor(colors.red)
    print("No PIN set up!")
    term.setTextColor(colors.white)
    print("Run: startup setup")
    return
end

-- ============ KEYPAD ============
local keypadMonitorName = nil
local keypadMon = nil
local touchMap = {}
local code = ""
local msg = nil
local msgColor = colors.white
local timers = {}
local insideMon = nil
local drawInsideMonitor = nil

local function drawKeypad()
    if not keypadMon then return end
    local mon = keypadMon
    local w, h = mon.getSize()

    mon.setBackgroundColor(colors.black)
    mon.clear()

    -- The keypad ALWAYS fills the whole screen. Unless the monitor is too
    -- short for 4 rows, we use 3x4 (1 2 3 / 4 5 6 / 7 8 9 / C 0 OK); on
    -- very short screens we switch to 4x3 so every key stays visible.
    local keys, cols, rows
    if h >= 5 then
        cols, rows = 3, 4
        keys = { "1","2","3", "4","5","6", "7","8","9", "C","0","OK" }
    else
        cols, rows = 4, 3
        keys = { "1","2","3","4", "5","6","7","8", "9","C","0","OK" }
    end

    -- one top row for code/message if there is still room after the keys
    local codeRow  = (h - rows >= 1) and 1 or nil
    local fieldTop = codeRow and 2 or 1

    -- only use column gaps if they actually fit without overflow
    local gapX = (w >= 2 * cols - 1) and 1 or 0
    local gapY = 0
    local availW = w
    local availH = h - fieldTop + 1

    local bw = math.max(1, math.floor((availW - (cols-1)*gapX) / cols))
    local bh = math.max(1, math.floor((availH - (rows-1)*gapY) / rows))
    local totalW = cols * bw + (cols-1) * gapX
    local startX = math.max(0, math.floor((w - totalW) / 2)) + 1
    local totalH = rows * bh + (rows-1) * gapY
    -- pinned to the BOTTOM so the last key row (with "0") is never cut off
    local startY = math.max(fieldTop, h - totalH + 1)

    -- ---- top row: message or PIN input ----
    if codeRow then
        if msg then
            local top = #msg <= (w - 2) and msg or (string.match(msg, "%S+") or "?")
            if #top > (w - 2) then top = string.sub(top, 1, w - 2) end
            mon.setCursorPos(math.max(1, math.floor((w - 2 - #top) / 2) + 1), codeRow)
            mon.setTextColor(msgColor)
            mon.write(top)
        else
            mon.setCursorPos(1, codeRow)
            mon.setTextColor(colors.gray)
            mon.write("Code: ")
            local d = ""
            for i = 1, MAX_CODE_LEN do d = d .. (i <= #code and "*" or "-") end
            mon.setTextColor(colors.white)
            mon.write(d)
        end
    end

    -- ---- keypad grid (edge to edge) ----
    touchMap = {}
    for i, key in ipairs(keys) do
        local col = (i-1) % cols
        local row = math.floor((i-1) / cols)
        local x = startX + col * (bw + gapX)
        local y = startY + row * (bh + gapY)
        local bg = key == "OK" and colors.green
                or key == "C"  and colors.red
                or colors.lightGray

        for dy = 0, bh-1 do
            mon.setCursorPos(x, y+dy)
            mon.setBackgroundColor(bg)
            mon.write(string.rep(" ", bw))
        end

        local label = key
        if bw < #label then label = string.sub(label, 1, bw) end
        mon.setCursorPos(x + math.floor((bw - #label) / 2), y + math.floor(bh / 2))
        mon.setTextColor(colors.black)
        mon.write(label)
        mon.setBackgroundColor(colors.black)

        for dy = 0, bh-1 do
            touchMap[y+dy] = touchMap[y+dy] or {}
            for dx = 0, bw-1 do touchMap[y+dy][x+dx] = key end
        end
    end
end

local function openDoor()
    pcall(bunkerlib.driver("door").set, DOOR_DEVICE, true)
    local id = os.startTimer(DOOR_TIMEOUT)
    timers[id] = function()
        pcall(bunkerlib.driver("door").set, DOOR_DEVICE, false)
        if insideMon then drawInsideMonitor("locked") end
        local id2 = os.startTimer(2)
        timers[id2] = function() if insideMon then drawInsideMonitor("button") end end
    end
end

local function redraw(newMsg, color, clearAfter)
    msg = newMsg; msgColor = color or colors.white
    drawKeypad()
    if clearAfter then
        local id = os.startTimer(clearAfter)
        timers[id] = function() msg = nil; code = ""; drawKeypad() end
    end
end

local function handleKey(key)
    if key == "C" then
        code = ""; msg = nil; drawKeypad()
    elseif key == "OK" then
        if #code == 0 then return end
        if bunkerlib.verifyPassword(code, loadHash()) then
            openDoor()
            redraw("ACCESS GRANTED", colors.green)
            if insideMon then drawInsideMonitor("open") end
        else
            redraw("WRONG CODE", colors.red, 2)
        end
    elseif #code < MAX_CODE_LEN then
        code = code .. key; drawKeypad()
    end
end

-- ============ INSIDE MONITOR ============
local insideBtn = nil -- { x, y, w, h }

drawInsideMonitor = function(state)
    if not insideMon then return end
    local mon = insideMon
    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()

    mon.setCursorPos(math.max(1, math.floor((w - 11) / 2)), 1)
    mon.setTextColor(colors.cyan)
    mon.write("DOOR ACCESS")
    mon.setCursorPos(1, 2)
    mon.setTextColor(colors.yellow)
    mon.write(string.rep("=", w))

    if state == "open" then
        mon.setCursorPos(math.max(1, math.floor((w - 9) / 2)), math.floor(h / 2))
        mon.setTextColor(colors.green)
        mon.write("DOOR OPEN")
        insideBtn = nil
    elseif state == "locked" then
        mon.setCursorPos(math.max(1, math.floor((w - 11) / 2)), math.floor(h / 2))
        mon.setTextColor(colors.gray)
        mon.write("DOOR LOCKED")
        insideBtn = nil
    else
        -- Big green button
        local btnW = math.max(8, w - 4)
        local btnH = math.max(3, math.floor(h / 2))
        local btnX = math.floor((w - btnW) / 2) + 1
        local btnY = math.floor((h - btnH) / 2) + 2

        for dy = 0, btnH-1 do
            mon.setCursorPos(btnX, btnY + dy)
            mon.setBackgroundColor(colors.green)
            mon.write(string.rep(" ", btnW))
        end
        mon.setCursorPos(btnX + math.floor((btnW - 4) / 2), btnY + math.floor(btnH / 2))
        mon.setTextColor(colors.black)
        mon.write("OPEN")
        mon.setBackgroundColor(colors.black)

        insideBtn = { x = btnX, y = btnY, w = btnW, h = btnH }
    end
end

-- ============ FIND MONITORS ============
local bestArea = 0
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" and name ~= INSIDE_MONITOR then
        local m = peripheral.wrap(name)
        local mw, mh = m.getSize()
        local area = mw * mh
        if area > bestArea then
            bestArea, keypadMonitorName, keypadMon = area, name, m
        end
    end
end

if peripheral.isPresent(INSIDE_MONITOR) and peripheral.getType(INSIDE_MONITOR) == "monitor" then
    insideMon = peripheral.wrap(INSIDE_MONITOR)
end

if not keypadMon and not insideMon then
    term.setTextColor(colors.yellow)
    print("No monitors found - running as client only.")
    term.setTextColor(colors.white)
end

drawKeypad()
drawInsideMonitor("button")

-- ============ START ============
bunkerlib.runClient({
    name      = NAME,
    modemSide = MODEM_SIDE,
    interval  = UPDATE_INTERVAL,
    devices   = DEVICES,
    onEvent = function(event, p1, p2, p3)
        if event == "timer" then
            local action = timers[p1]
            if action then action(); timers[p1] = nil end
        elseif event == "monitor_touch" then
            if p1 == keypadMonitorName
               and touchMap[p3] and touchMap[p3][p2] then
                handleKey(touchMap[p3][p2])
            elseif p1 == INSIDE_MONITOR and insideBtn then
                local b = insideBtn
                if p2 >= b.x and p2 < b.x + b.w
                   and p3 >= b.y and p3 < b.y + b.h then
                    openDoor()
                    drawInsideMonitor("open")
                end
            end
        end
    end,
})
