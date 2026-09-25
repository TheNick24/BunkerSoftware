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

-- controlplane health marker (no-op without the agent)
if fs.exists("/controlplane") then
    local _hf = fs.open("/controlplane/health.marker", "w")
    if _hf then _hf.write("healthy\n") _hf.close() end
end

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

-- Second door: Create sequenced gearshift plus a PIN screen outside and an
-- OPEN screen inside. A gearshift's movement is measured in degrees; adjust
-- GEARSHIFT_OPEN_DIRECTION if the physical door moves the wrong way. The
-- configured pulley/gantry travel is exactly six blocks down, then back up.
local GEARSHIFT_DOOR_ID = "Control Door 2"
local GEARSHIFT_PERIPHERAL = "Create_SequencedGearshift_1"
local GEARSHIFT_DISTANCE = 6
local GEARSHIFT_OPEN_DIRECTION = 1 -- down; reverse only if the mechanics are inverted
-- Dwell below: 2 seconds plus 30 game ticks (a tick is 1/20 s), measured
-- from the moment the descent has fully finished.
local GEARSHIFT_OPEN_SECONDS = 2
local GEARSHIFT_OPEN_TICKS = 30
local GEARSHIFT_KEYPAD_MONITOR = "monitor_20"
local GEARSHIFT_INSIDE_MONITOR = "monitor_21"

local DEVICES = {
    { id = "control",            cmd = "light", driver = "relay",    relay = "redstone_relay_9",  side = "top" },
    { id = "control-corridor-1", cmd = "light", driver = "relay",    relay = "redstone_relay_9",  side = "right" },
    -- Mekanism Industrial Alarm (or any alarm block): powered ON with the alarm.
    -- Extra sirens: add a row here + the same id in alarmSirens (lib/alarmconfig.lua).
    { id = "alarm-siren", cmd = "alarm", driver = "relay",
      relay = "redstone_relay_9", side = "back" },
    { id = "Control Door 1",     cmd = "door",  driver = "door",  peripheral = "redstone_relay_10", side = "left" },
    { id = "server-door", cmd = "door", driver = "door", peripheral = "redstone_relay_13", side = "bottom" },
    { id = GEARSHIFT_DOOR_ID, cmd = "door", driver = "gearshift-door", peripheral = GEARSHIFT_PERIPHERAL,
      distance = GEARSHIFT_DISTANCE, openDirection = GEARSHIFT_OPEN_DIRECTION },
}

local DOOR_DEVICE = DEVICES[4]
local GEARSHIFT_DOOR = DEVICES[6]

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
-- Asks for a new PIN (with confirmation + min length) and stores the hash.
-- Returns true when the PIN was saved, false otherwise. Used by the `setup`
-- command below AND on first boot in the CHECK PIN section, so a fresh
-- deployment prompts for the door PIN right inside the running system
-- (no separate `startup setup` run required).
local function promptForPinHash()
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("==========================")
    print("   DOOR KEYPAD - SETUP")
    print("==========================")
    term.setTextColor(colors.white)
    print("New PIN (min. 4 digits):")
    term.setTextColor(colors.gray)
    local p1 = read("*")
    term.setTextColor(colors.white)
    print("Repeat PIN:")
    term.setTextColor(colors.gray)
    local p2 = read("*")
    term.setTextColor(colors.white)
    if p1 ~= p2 then
        term.setTextColor(colors.red); print("PINs do not match!"); return false
    end
    if #p1 < 4 then
        term.setTextColor(colors.red); print("PIN too short (min. 4)!"); return false
    end
    saveHash(bunkerlib.hashPassword(p1))
    term.setTextColor(colors.green)
    print("PIN saved!")
    term.setTextColor(colors.gray)
    print("Hash: " .. tostring(loadHash()))
    print("(rewritten as salted PBKDF2-HMAC-SHA256)")
    return true
end

if args[1] == "setup" then
    promptForPinHash()
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
-- First start without a PIN: do NOT exit / ask for a separate `setup` run -
-- the system booted already, so ask right here and continue into the keypad.
-- The keypad starts locked; without a stored PIN it cannot grant access, so
-- the PIN (door.hash) must be set before the first door use.
if not loadHash() then
    term.setTextColor(colors.yellow)
    print("No PIN set up yet - please set one now (keypad starts locked).")
    term.setTextColor(colors.white)
    while true do
        if promptForPinHash() then break end
        term.setTextColor(colors.yellow)
        print("A PIN is required - try again.")
        term.setTextColor(colors.white)
    end
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
local drawInsideState = nil

-- ---- gfx (cc-graphics 256-color) rendering ----
local gfxCaps = {}
local function gfxKeypadAvailable()
    if gfxCaps[keypadMonitorName] == nil then
        local ok = bunkerlib.gfx.supported(keypadMon)
        if ok then ok = bunkerlib.gfx.init(keypadMon) end
        if not ok and keypadMon.setGraphicsMode then
            pcall(function() keypadMon.setGraphicsMode(0) end)
        end
        gfxCaps[keypadMonitorName] = ok
    end
    return gfxCaps[keypadMonitorName]
end
local function gfxInsideAvailable()
    if gfxCaps[INSIDE_MONITOR] == nil then
        local ok = bunkerlib.gfx.supported(insideMon)
        if ok then ok = bunkerlib.gfx.init(insideMon) end
        if not ok and insideMon.setGraphicsMode then
            pcall(function() insideMon.setGraphicsMode(0) end)
        end
        gfxCaps[INSIDE_MONITOR] = ok
    end
    return gfxCaps[INSIDE_MONITOR]
end

-- Shared keypad renderer. Both doors use the exact same dimensions, colors,
-- frame and touch map, so one keypad cannot drift into a different layout.
local function gfxDrawKeypad(mon, codeValue, message, messageColor)
    local gg = bunkerlib.gfx
    local CC = gg.C
    local w, h = mon.getSize()

    gg.begin(mon)

    local keys, cols, rows
    if h >= 5 then
        cols, rows = 3, 4
        keys = { "1","2","3", "4","5","6", "7","8","9", "C","0","OK" }
    else
        cols, rows = 4, 3
        keys = { "1","2","3","4", "5","6","7","8", "9","C","0","OK" }
    end

    local codeRow  = (h - rows >= 1) and 1 or nil
    local fieldTop = codeRow and 2 or 1
    local gapX = (w >= 2 * cols - 1) and 1 or 0
    local availW = w
    local availH = h - fieldTop + 1

    local bw = math.max(1, math.floor((availW - (cols-1)*gapX) / cols))
    local bh = math.max(1, math.floor(availH / rows))
    local totalW = cols * bw + (cols-1) * gapX
    local startX = math.max(0, math.floor((w - totalW) / 2)) + 1
    local totalH = rows * bh
    local startY = math.max(fieldTop, h - totalH + 1)

    if codeRow then
        if message then
            local top = #message <= (w - 2) and message or (string.match(message, "%S+") or "?")
            if #top > (w - 2) then top = string.sub(top, 1, w - 2) end
            local mc = messageColor == colors.green and CC.green
                  or messageColor == colors.red and CC.red
                  or messageColor == colors.yellow and CC.yellow
                  or CC.white
            gg.centerText(mon, codeRow, top, mc, CC.bg)
        else
            local d = ""
            for i = 1, MAX_CODE_LEN do d = d .. (i <= #codeValue and "*" or "-") end
            gg.centerText(mon, codeRow, d, CC.white, CC.bg)
        end
    end

    local keyMap = {}
    for i, key in ipairs(keys) do
        local col = (i-1) % cols
        local row = math.floor((i-1) / cols)
        local x = startX + col * (bw + gapX)
        local y = startY + row * bh
        local bg = key == "OK" and CC.green
                or key == "C" and CC.red
                or CC.panel
        local accent = key == "OK" and CC.green
                or key == "C" and CC.red
                or CC.gold
        local fg = (key == "OK" or key == "C") and CC.bg or CC.white

        gg.cellFill(mon, x, y, bw, bh, bg)
        -- Fine HUD-card frame. It does not affect the logical key rectangle
        -- recorded in touchMap below.
        local x0, y0 = (x - 1) * gg.CELL_W, (y - 1) * gg.CELL_H
        local x1, y1 = (x + bw - 1) * gg.CELL_W - 1, (y + bh - 1) * gg.CELL_H - 1
        gg.fill(mon, x0, y0, x1 - x0 + 1, 1, accent)
        gg.fill(mon, x0, y1, x1 - x0 + 1, 1, CC.borderD)
        gg.fill(mon, x0, y0, 1, y1 - y0 + 1, accent)
        gg.fill(mon, x1, y0, 1, y1 - y0 + 1, accent)
        local label = key
        if bw < #label then label = string.sub(label, 1, bw) end
        gg.cellText(mon, x + math.floor((bw - #label) / 2), y + math.floor((bh - 1) / 2), label, fg, bg)

        for dy = 0, bh-1 do
            keyMap[y+dy] = keyMap[y+dy] or {}
            for dx = 0, bw-1 do keyMap[y+dy][x+dx] = key end
        end
    end

    gg.finish(mon)
    return keyMap
end

local function drawKeypad()
    if not keypadMon then return end
    if gfxKeypadAvailable() then
        touchMap = gfxDrawKeypad(keypadMon, code, msg, msgColor)
        return
    end
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
    local drv = bunkerlib.driver("door")
    if drv.isLocked and drv.isLocked(DOOR_DEVICE) then
        return false
    end
    pcall(drv.set, DOOR_DEVICE, true)
    local id = os.startTimer(DOOR_TIMEOUT)
    timers[id] = function()
        pcall(bunkerlib.driver("door").set, DOOR_DEVICE, false)
        drawInsideState()
    end
    return true
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
            if openDoor() then
                redraw("ACCESS GRANTED", colors.green, 2)
                if insideMon then drawInsideMonitor("open") end
            else
                redraw("DOOR LOCKED", colors.red, 2)
                if insideMon then drawInsideMonitor("locked") end
            end
        else
            redraw("WRONG CODE", colors.red, 2)
        end
    elseif #code < MAX_CODE_LEN then
        code = code .. key; drawKeypad()
    end
end

-- ============ INSIDE MONITOR ============
local insideBtn = nil -- { x, y, w, h }

local function gfxInside(state)
    local mon = insideMon
    local gg = bunkerlib.gfx
    local CC = gg.C
    local w, h = mon.getSize()

    gg.begin(mon)
gg.centerText(mon, 1, "CONTROL", CC.gold, CC.bg)
    gg.centerText(mon, 2, "DOOR 1", CC.gold, CC.bg)
    gg.hline(mon, 2 * gg.CELL_H - 1, CC.borderD)

    if state == "open" then
        gg.cellFill(mon, 1, 3, w, 3, CC.green)
        gg.centerText(mon, 4, "OPEN", CC.white, CC.green)
        insideBtn = nil
    elseif state == "locked" then
        gg.cellFill(mon, 1, 3, w, 3, CC.red)
        gg.centerText(mon, 4, "LOCKED", CC.white, CC.red)
        insideBtn = nil
    else
        -- Big green button with a subtle "raised key" frame: bright top/left
        -- edge, dark bottom/right edge, bright label.
        gg.cellFill(mon, 1, 3, w, 3, CC.green)
        local yTop  = (3 - 1) * gg.CELL_H
        local yBot  = (3 + 3) * gg.CELL_H - 1
        local xL    = 0
        local xR    = w * gg.CELL_W - 1
        local btnH  = 3 * gg.CELL_H
        gg.hline(mon, yTop, CC.sage)
        gg.hline(mon, yBot, CC.borderD)
        gg.fill(mon, xL, yTop, 1, btnH, CC.sage)
        gg.fill(mon, xR, yTop, 1, btnH, CC.borderD)
        gg.centerText(mon, 4, "OPEN", CC.white, CC.green)
        insideBtn = { x = 1, y = 3, w = w, h = 3 }
    end
    gg.finish(mon)
end

drawInsideMonitor = function(state)
    if not insideMon then return end
    if gfxInsideAvailable() then
        gfxInside(state)
        return
    end
    local mon = insideMon
    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()

    mon.setCursorPos(math.max(1, math.floor((w - 11) / 2)), 1)
    mon.setTextColor(colors.cyan)
    mon.write("CONTROL DOOR 1")
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

-- Re-render the inside screen from the REAL door driver state, so remote
-- lock/unlock and close-commands from the control room are reflected even
-- without a click on this computer.
drawInsideState = function()
    if not insideMon then return end
    local drv = bunkerlib.driver("door")
    if drv.isLocked and drv.isLocked(DOOR_DEVICE) then
        drawInsideMonitor("locked")
        return
    end
    local ok, st = pcall(drv.read, DOOR_DEVICE)
    if ok and st then
        drawInsideMonitor("open")
    else
        drawInsideMonitor("button")
    end
end

-- ============ GEARSHIFT DOOR MONITORS ============
-- tm_monitor peripherals expose the regular terminal methods but do not
-- necessarily identify as type "monitor" or support graphics mode. This UI
-- deliberately uses the common terminal API so both screen families work.
local gearKeypadMon, gearInsideMon = nil, nil
local gearCode, gearMsg, gearMsgColor = "", nil, colors.white
local gearTouchMap, gearTimers = {}, {}
local gearInsideBtn = nil
local gearControl = nil -- bunkerlib.gearshift controller (registered below)

local function isMonitorLike(name)
    if not peripheral.isPresent(name) then return false end
    local p = peripheral.wrap(name)
    return p and type(p.getSize) == "function" and type(p.setCursorPos) == "function"
        and type(p.write) == "function"
end

local function gfxGearAvailable(name, mon)
    if gfxCaps[name] == nil then
        local ok = bunkerlib.gfx.supported(mon)
        if ok then ok = bunkerlib.gfx.init(mon) end
        if not ok and mon.setGraphicsMode then
            pcall(function() mon.setGraphicsMode(0) end)
        end
        gfxCaps[name] = ok
    end
    return gfxCaps[name]
end

local function gfxDrawGearKeypad()
    gearTouchMap = gfxDrawKeypad(gearKeypadMon, gearCode, gearMsg, gearMsgColor)
end

local function gfxDrawGearInside(state)
    local mon = gearInsideMon
    local gg, CC = bunkerlib.gfx, bunkerlib.gfx.C
    local w, h = mon.getSize()
    gg.begin(mon)
gg.centerText(mon, 1, "CONTROL", CC.gold, CC.bg)
    gg.centerText(mon, 2, "DOOR 2", CC.gold, CC.bg)
    gg.hline(mon, 2 * gg.CELL_H - 1, CC.borderD)
if state == "open" or state == "busy" then
        gg.cellFill(mon, 1, 3, w, 3, CC.green)
        gg.centerText(mon, 4, "OPEN", CC.white, CC.green)
        gearInsideBtn = nil
    elseif state == "locked" then
        gg.cellFill(mon, 1, 3, w, 3, CC.red)
        gg.centerText(mon, 4, "LOCKED", CC.white, CC.red)
        gearInsideBtn = nil
    else
        gg.cellFill(mon, 1, 3, w, 3, CC.green)
        local yTop, yBot = (3 - 1) * gg.CELL_H, (3 + 3) * gg.CELL_H - 1
        local xL, xR, btnH = 0, w * gg.CELL_W - 1, 3 * gg.CELL_H
        gg.hline(mon, yTop, CC.white)
        gg.hline(mon, yBot, CC.borderD)
        gg.fill(mon, xL, yTop, 1, btnH, CC.white)
        gg.fill(mon, xR, yTop, 1, btnH, CC.borderD)
        gg.centerText(mon, 4, "OPEN", CC.white, CC.green)
        gearInsideBtn = { x = 1, y = 3, w = w, h = 3 }
    end
    gg.finish(mon)
end

local function drawGearKeypad()
    if not gearKeypadMon then return end
    if gfxGearAvailable(GEARSHIFT_KEYPAD_MONITOR, gearKeypadMon) then
        gfxDrawGearKeypad()
        return
    end
    local mon = gearKeypadMon
    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()

    local title = "CONTROL DOOR 2"
    mon.setCursorPos(math.max(1, math.floor((w - #title) / 2) + 1), 1)
    mon.setTextColor(colors.cyan)
    mon.write(title)
    mon.setCursorPos(1, 2)
    mon.setTextColor(colors.gray)
    mon.write(string.rep("=", w))

    local top = gearMsg or ("PIN: " .. string.rep("*", #gearCode) .. string.rep("-", MAX_CODE_LEN - #gearCode))
    if #top > w then top = string.sub(top, 1, w) end
    mon.setCursorPos(math.max(1, math.floor((w - #top) / 2) + 1), 3)
    mon.setTextColor(gearMsg and gearMsgColor or colors.white)
    mon.write(top)

    local keys = { "1","2","3", "4","5","6", "7","8","9", "C","0","OK" }
    local cols, rows = 3, 4
    local gapX = w >= 2 * cols - 1 and 1 or 0
    local fieldTop = 4
    local bw = math.max(1, math.floor((w - (cols - 1) * gapX) / cols))
    local bh = math.max(1, math.floor((h - fieldTop + 1) / rows))
    local totalW, totalH = cols * bw + (cols - 1) * gapX, rows * bh
    local startX = math.max(1, math.floor((w - totalW) / 2) + 1)
    local startY = math.max(fieldTop, h - totalH + 1)

    gearTouchMap = {}
    for i, key in ipairs(keys) do
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        local x, y = startX + col * (bw + gapX), startY + row * bh
        local bg = key == "OK" and colors.green or key == "C" and colors.red or colors.lightGray
        for dy = 0, bh - 1 do
            mon.setCursorPos(x, y + dy)
            mon.setBackgroundColor(bg)
            mon.write(string.rep(" ", bw))
        end
        local label = #key > bw and string.sub(key, 1, bw) or key
        mon.setCursorPos(x + math.floor((bw - #label) / 2), y + math.floor(bh / 2))
        mon.setTextColor(colors.black)
        mon.write(label)
        mon.setBackgroundColor(colors.black)
        for dy = 0, bh - 1 do
            gearTouchMap[y + dy] = gearTouchMap[y + dy] or {}
            for dx = 0, bw - 1 do gearTouchMap[y + dy][x + dx] = key end
        end
    end
end

local function drawGearInside(state)
    if not gearInsideMon then return end
    if gfxGearAvailable(GEARSHIFT_INSIDE_MONITOR, gearInsideMon) then
        gfxDrawGearInside(state)
        return
    end
    local mon = gearInsideMon
    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()
    local title = "CONTROL DOOR 2"
    mon.setCursorPos(math.max(1, math.floor((w - #title) / 2) + 1), 1)
    mon.setTextColor(colors.cyan)
    mon.write(title)
    mon.setCursorPos(1, 2)
    mon.setTextColor(colors.gray)
    mon.write(string.rep("=", w))

    if state == "locked" then
        mon.setCursorPos(math.max(1, math.floor((w - 11) / 2)), math.floor(h / 2))
        mon.setTextColor(colors.red)
        mon.write("DOOR LOCKED")
        gearInsideBtn = nil
elseif state == "open" or state == "busy" then
        mon.setCursorPos(math.max(1, math.floor((w - 9) / 2)), math.floor(h / 2))
        mon.setTextColor(colors.green)
        mon.write("DOOR OPEN")
        gearInsideBtn = nil
    else
        local bw, bh = math.max(8, w - 4), math.max(3, math.floor(h / 2))
        local bx, by = math.floor((w - bw) / 2) + 1, math.floor((h - bh) / 2) + 2
        for dy = 0, bh - 1 do
            mon.setCursorPos(bx, by + dy)
            mon.setBackgroundColor(colors.green)
            mon.write(string.rep(" ", bw))
        end
        mon.setCursorPos(bx + math.floor((bw - 4) / 2), by + math.floor(bh / 2))
        mon.setTextColor(colors.black)
        mon.write("OPEN")
        mon.setBackgroundColor(colors.black)
        gearInsideBtn = { x = bx, y = by, w = bw, h = bh }
    end
end

local function drawGearInsideState()
    if not gearInsideMon then return end
    local drv = bunkerlib.driver("gearshift-door")
    local state = gearControl and gearControl.getState() or "closed"
    if drv.isLocked and drv.isLocked(GEARSHIFT_DOOR) then
        drawGearInside("locked")
        return
    end
    if state == "open" then
        drawGearInside("open")
    elseif state == "opening" or state == "closing" then
        drawGearInside("busy")
    else
        drawGearInside("button")
    end
end

-- Reusable sequenced gearshift controller (lib/gearshift.lua): the whole
-- open -> wait-for-descent -> dwell -> close cycle lives in the lib now, so
-- future gearshift doors (pistons, gantries, rotating hatches, ...) in other
-- rooms only need their own motion config and a tick() call in the loop.
gearControl = bunkerlib.gearshift.create({
    devices       = GEARSHIFT_DOOR,
    motion = {
        open  = { { method = "move", distance = GEARSHIFT_DISTANCE, direction = GEARSHIFT_OPEN_DIRECTION } },
        close = { { method = "move", distance = GEARSHIFT_DISTANCE, direction = -GEARSHIFT_OPEN_DIRECTION } },
    },
    openSeconds   = GEARSHIFT_OPEN_SECONDS,
    openTicks     = GEARSHIFT_OPEN_TICKS,
    onStateChange = function()
        drawGearInsideState()
    end,
})

local function handleGearKey(key)
    if key == "C" then
        gearCode, gearMsg = "", nil
        drawGearKeypad()
elseif key == "OK" then
        if #gearCode == 0 then return end
        local verified = bunkerlib.verifyPassword(gearCode, loadHash())
        if verified and gearControl.open() then
            gearMsg, gearMsgColor = "ACCESS GRANTED", colors.green
            drawGearInside("open")
        elseif verified and gearControl.isLocked() then
            gearMsg, gearMsgColor = "DOOR LOCKED", colors.red
            drawGearInside("locked")
        elseif verified then
            gearMsg, gearMsgColor = "DOOR BUSY", colors.yellow
        else
            gearMsg, gearMsgColor = "WRONG CODE", colors.red
        end
        drawGearKeypad()
        local timer = os.startTimer(2)
        gearTimers[timer] = function() gearCode, gearMsg = "", nil; drawGearKeypad() end
    elseif #gearCode < MAX_CODE_LEN then
        gearCode = gearCode .. key
        drawGearKeypad()
    end
end

-- ============ FIND MONITORS ============
local bestArea = 0
for _, name in ipairs(peripheral.getNames()) do
    if isMonitorLike(name) and name ~= INSIDE_MONITOR
       and name ~= GEARSHIFT_KEYPAD_MONITOR and name ~= GEARSHIFT_INSIDE_MONITOR then
        local m = peripheral.wrap(name)
        local mw, mh = m.getSize()
        local area = mw * mh
        if area > bestArea then
            bestArea, keypadMonitorName, keypadMon = area, name, m
        end
    end
end

if isMonitorLike(INSIDE_MONITOR) then
    insideMon = peripheral.wrap(INSIDE_MONITOR)
end
if isMonitorLike(GEARSHIFT_KEYPAD_MONITOR) then
    gearKeypadMon = peripheral.wrap(GEARSHIFT_KEYPAD_MONITOR)
end
if isMonitorLike(GEARSHIFT_INSIDE_MONITOR) then
    gearInsideMon = peripheral.wrap(GEARSHIFT_INSIDE_MONITOR)
end

if not keypadMon and not insideMon then
    term.setTextColor(colors.yellow)
    print("No monitors found - running as client only.")
    term.setTextColor(colors.white)
end

drawKeypad()
drawInsideMonitor("button")
drawGearKeypad()
drawGearInsideState()

-- Always establish the safe, closed (fully raised) position after a reboot.
-- This also corrects the old reversed cycle before the next PIN entry. The
-- controller runs the async move itself - no extra local timer involved.
gearControl.home()

-- ============ START ============
bunkerlib.findModem(MODEM_SIDE)

bunkerlib.runClient({
    name      = NAME,
    modemSide = MODEM_SIDE,
    interval  = UPDATE_INTERVAL,
    devices   = DEVICES,
onEvent = function(event, p1, p2, p3)
        if event == "timer" then
            local action = timers[p1]
            if action then action(); timers[p1] = nil end
local gearAction = gearTimers[p1]
            if gearAction then gearAction(); gearTimers[p1] = nil end
            if not (action or gearAction) then gearControl.tick(p1) end
        elseif event == "rednet_message" then
            local message, protocol = p2, p3
            if protocol == "bunker_cmd" and type(message) == "table"
               and message.room == DOOR_DEVICE.id and message.cmd == "door" then
                drawInsideState()
            elseif protocol == "bunker_cmd" and type(message) == "table"
               and message.room == GEARSHIFT_DOOR.id and message.cmd == "door" then
                drawGearInsideState()
            end
        elseif event == "monitor_touch" then
            if p1 == keypadMonitorName then
                local g = bunkerlib.gfx
                local k = touchMap[p3] and touchMap[p3][p2]
                -- cc-graphics can report pixel coordinates (0-based) instead
                -- of cell coordinates; map them back to the cell grid.
                if not k then
                    local cx = math.floor((p2 - 1) / g.CELL_W) + 1
                    local cy = math.floor((p3 - 1) / g.CELL_H) + 1
                    k = touchMap[cy] and touchMap[cy][cx]
                end
                if k then handleKey(k) end
            elseif p1 == INSIDE_MONITOR and insideBtn then
                local b = insideBtn
                local g = bunkerlib.gfx
                local hitCell = p2 >= b.x and p2 < b.x + b.w
                            and p3 >= b.y and p3 < b.y + b.h
                local px0 = (b.x - 1) * g.CELL_W
                local py0 = (b.y - 1) * g.CELL_H
                local hitPixel = p2 >= 0 and p2 < px0 + b.w * g.CELL_W
                             and p3 >= 0 and p3 < py0 + b.h * g.CELL_H
                if hitCell or hitPixel then
                    if openDoor() then
                        drawInsideMonitor("open")
                    else
                        drawInsideMonitor("locked")
                    end
                end
            elseif p1 == GEARSHIFT_KEYPAD_MONITOR then
                local key = gearTouchMap[p3] and gearTouchMap[p3][p2]
                if not key then
                    local g = bunkerlib.gfx
                    local cx = math.floor((p2 - 1) / g.CELL_W) + 1
                    local cy = math.floor((p3 - 1) / g.CELL_H) + 1
                    key = gearTouchMap[cy] and gearTouchMap[cy][cx]
                end
                if key then handleGearKey(key) end
            elseif p1 == GEARSHIFT_INSIDE_MONITOR and gearInsideBtn then
                local b = gearInsideBtn
                local g = bunkerlib.gfx
                local hitCell = p2 >= b.x and p2 < b.x + b.w and p3 >= b.y and p3 < b.y + b.h
                local px0, py0 = (b.x - 1) * g.CELL_W, (b.y - 1) * g.CELL_H
                local hitPixel = p2 >= 0 and p2 < px0 + b.w * g.CELL_W
                             and p3 >= 0 and p3 < py0 + b.h * g.CELL_H
if hitCell or hitPixel then
                    if gearControl.open() then
                        drawGearInside("open")
                    else
                        drawGearInside("locked")
                    end
                end
            end
        end
    end,
})
