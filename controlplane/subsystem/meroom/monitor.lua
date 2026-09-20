-- ============================================
-- MAMDANI OS - module: MONITOR
-- Monitor rendering (headers, panels, state tables, footer).
-- Loaded by bunkerlib.lua (do not require directly).
-- ============================================

-- Draws the classic MAMDANI OS top header on a monitor.
local function drawHeader(mon)
    local w = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()
    local title = "MAMDANI OS"
    mon.setCursorPos(math.max(1, math.floor((w - #title) / 2) + 1), 1)
    mon.setTextColor(colors.cyan)
    mon.write(title)
    mon.setCursorPos(1, 2)
    mon.setTextColor(colors.yellow)
    mon.write(string.rep("=", w))
end

local function drawInfoPlaceholder(mon)
    local w = mon.getSize()
    local inner = math.max(8, w - 6)
    mon.setCursorPos(2, 4)
    mon.setTextColor(colors.gray)
    mon.write("|" .. string.rep("=", inner) .. "|")
    mon.setCursorPos(2, 5)
    mon.write("|" .. string.rep(" ", inner) .. "|")
    mon.setCursorPos(3, 5)
    mon.setTextColor(colors.yellow)
    mon.write("INFO PANEL")
    mon.setCursorPos(2, 6)
    mon.setTextColor(colors.gray)
    mon.write("|" .. string.rep(" ", inner) .. "|")
    mon.setCursorPos(3, 6)
    mon.write("No content assigned yet.")
    mon.setCursorPos(2, 7)
    mon.write("|" .. string.rep(" ", inner) .. "|")
    mon.setCursorPos(3, 7)
    mon.write("Config: MONITOR_PANELS")
    mon.setCursorPos(2, 8)
    mon.write("|" .. string.rep("=", inner) .. "|")
end

local function drawFooter(mon, rows, label, extra)
    local w, h = mon.getSize()
    -- pinned to the bottom of the monitor, but below the table if it is long
    local footerY = math.max(h - 1, 5 + rows + 2)
    mon.setCursorPos(1, footerY)
    mon.setTextColor(colors.yellow)
    mon.write(string.rep("=", w))
    mon.setCursorPos(1, footerY + 1)
    mon.setTextColor(colors.gray)
    mon.write(label)
    if extra then
        mon.setCursorPos(w - #extra, footerY + 1)
        mon.setTextColor(colors.cyan)
        mon.write(extra)
    end
end

-- Draws a device group with ON/OFF state + click buttons.
-- `btns[y]` gets { id = device id, action = action name } for every drawn row.
-- The state column is pushed right, sitting flush left of the button, so
-- the names get the whole remaining width. Header and state texts are
-- centered within that column.
-- opts: { action = action name for the row buttons (default "light"),
--         button = label shown in each row (default "[CLICK]"),
--         header = state column title (default "STATE"),
--         onText / offText = texts for state true/false
--                           (default "ON" / "OFF") }
-- startRow: row where the header is drawn (default 4).
-- Returns the number of online devices.
local function drawToggleTable(mon, entries, statuses, btns, showButtons, opts, startRow)
    opts = opts or {}
    startRow = startRow or 4
    local w = mon.getSize()
    local action = opts.action or "light"
    local label = opts.button or "[CLICK]"
    local btnW = #label
    local btnX = w - btnW + 1         -- button at the far right edge
    local header = opts.header or "STATE"
    local onText = opts.onText or "ON"
    local offText = opts.offText or "OFF"
    -- column width fits header + both state texts + "OFFLINE"
    local stateW = math.max(#header, #onText, #offText, #"OFFLINE")
    local zoneRight = btnX - 1
    local zoneLeft = zoneRight - stateW + 1
    local centerX = function(len)
        return zoneLeft + math.floor((stateW - len) / 2)
    end
    local maxName = math.max(3, zoneLeft - 2)

    mon.setCursorPos(1, startRow)
    mon.setTextColor(colors.yellow)
    mon.write("NAME")
    mon.setCursorPos(centerX(#header), startRow)
    mon.write(header)
    mon.setCursorPos(1, startRow + 1)
    mon.setTextColor(colors.gray)
    mon.write(string.rep("-", w))

    local clientCount = 0
    for i, entry in ipairs(entries) do
        local y = startRow + 1 + i
        local status = statuses[entry.id]
        local online = status ~= nil

        local name = entry.name
        if #name > maxName then
            name = string.sub(name, 1, maxName)
        end
        mon.setCursorPos(1, y)
        mon.setTextColor(colors.white)
        mon.write(name)

        if online then
            clientCount = clientCount + 1
            local txt = status.state and onText or offText
            mon.setCursorPos(centerX(#txt), y)
            if status.state then
                mon.setTextColor(colors.yellow)
            else
                mon.setTextColor(colors.gray)
            end
            mon.write(txt)
        else
            mon.setCursorPos(zoneRight - 7 + 1, y)
            mon.setTextColor(colors.red)
            mon.write("OFFLINE")
        end

        if showButtons then
            mon.setCursorPos(btnX, y)
            if online and status.state then
                mon.setBackgroundColor(colors.green)
            else
                mon.setBackgroundColor(colors.lightGray)
            end
            mon.setTextColor(colors.black)
            mon.write(label)
            mon.setBackgroundColor(colors.black)
            btns[y] = { id = entry.id, action = action }
        end
    end

    return clientCount
end

-- Draws a monitor panel. A panel can be either a single device group
-- (as before) or multiple groups/sections, so one monitor can show
-- several device types (e.g. doors + safety doors):
--   panel: { title, action = "light", entries = { {id,name}, ... },
--            button = optional button label, header = optional column title,
--            onText / offText = optional state texts }
--   OR
--   panel: { title, sections = {
--            { title, action, button?, header?, onText?, offText?, entries },
--            ... } }
-- Returns the number of online devices and the last used row.
local function drawPanel(mon, panel, statuses, btns, showButtons)
    if panel.sections then
        local y = 3
        local clientCount = 0
        for _, sec in ipairs(panel.sections) do
            y = y + 1
            mon.setCursorPos(1, y)
            mon.setTextColor(colors.cyan)
            mon.write(sec.title or panel.title or "GROUP")
            local n, lastRow = drawToggleTable(mon, sec.entries, statuses,
                btns, showButtons, {
                    action  = sec.action or panel.action,
                    button  = sec.button or panel.button,
                    header  = sec.header,
                    onText  = sec.onText,
                    offText = sec.offText,
                }, y + 1)
            clientCount = clientCount + n
            y = y + 2 + #sec.entries
        end
        return clientCount, y
    end
    local n = drawToggleTable(mon, panel.entries, statuses, btns, showButtons, {
        action  = panel.action,
        button  = panel.button,
        header  = panel.header,
        onText  = panel.onText,
        offText = panel.offText,
    })
    return n, 5 + #panel.entries
end

return function(bunkerlib)
    bunkerlib.drawHeader = drawHeader
    bunkerlib.drawInfoPlaceholder = drawInfoPlaceholder
    bunkerlib.drawFooter = drawFooter
    bunkerlib.drawToggleTable = drawToggleTable
    bunkerlib.drawPanel = drawPanel
end