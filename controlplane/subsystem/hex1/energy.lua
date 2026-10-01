-- ============================================
-- MAMDANI OS - module: ENERGY
-- Induction-matrix telemetry (Mekanism induction port):
--   * readInduction(side)   -> { energy, maxEnergy, filled, lastInput,
--                                lastOutput, transferCap, ... } in Joules
--                                (throttled through pcall)
--   * broadcast(side, protocol, name) -> reads, tags the table with a
--                                battery name and rednet.broadcast()s it
--   * drawMonitor(mon, batteries, opts) -> renders CARDS (gfx or text). Each
--                                battery is a raised card with a bright frame:
--                                header band (name + charge bar + percent) plus
--                                stored/max + input/output - all in FE.
--
-- Mekanism reports Joules; Forge Energy = Joules / 2.5 (1 FE = 2.5 J).
-- Multiple batteries: pass batteries = { { name=..., data=... }, ... }.
--
-- Loaded by bunkerlib.lua; use bunkerlib.energy.*
-- ============================================

local lib

local function safeNum(func)
    local ok, v = pcall(func)
    -- Reject non-finite numbers: CC:Tweaked cannot serialise NaN/Infinity
    -- over rednet, and a forming/merging Mekanism matrix can briefly report
    -- them. Treating them as "no value" keeps the client from crashing.
    if ok and type(v) == "number" and v == v and math.abs(v) ~= math.huge then
        return v
    end
    return nil
end

-- Read a Mekanism induction port into a plain, serialisable table.
-- Returns nil when the side is not an induction port. Every getter runs
-- inside pcall: a partially formed matrix or a vanished peripheral yields
-- nil-values instead of throwing.
local function readInduction(side)
    if not side then return nil end
    if not peripheral.isPresent(side) then return nil end
    if peripheral.getType(side) ~= "inductionPort" then return nil end
    local p = peripheral.wrap(side)
    if not p then return nil end

    local energy   = safeNum(function() return p.getEnergy() end)
    local maxEnergy = safeNum(function() return p.getMaxEnergy() end)
    local filled
    if energy ~= nil and maxEnergy and maxEnergy > 0 then
        filled = energy / maxEnergy
    else
        filled = safeNum(function() return p.getEnergyFilledPercentage() end)
    end

    local data = {
        energy      = energy,
        maxEnergy   = maxEnergy,
        filled      = filled,          -- 0..1
        lastInput   = safeNum(function() return p.getLastInput() end),
        lastOutput  = safeNum(function() return p.getLastOutput() end),
        transferCap = safeNum(function() return p.getTransferCap() end),
        cells       = safeNum(function() return p.getInstalledCells() end),
        providers   = safeNum(function() return p.getInstalledProviders() end),
        formed      = safeNum(function() return p.isFormed() and true or false end),
    }
    return data
end

-- Read + broadcast. Optional `name` tags the battery so the display can show
-- several batteries. Returns the read table (or nil when the port is gone).
local function broadcast(side, protocol, name)
    local data = readInduction(side)
    if data then
        data.name = name
        rednet.broadcast(data, protocol or "bunker_energy")
    end
    return data
end

-- Joules -> Forge Energy (1 FE = 2.5 J)
local function toFE(j)
    if type(j) ~= "number" then return nil end
    return j / 2.5
end

-- FE value -> short label: 1.6e12 -> "1.60 TFE", 2.5e3 -> "2.50 kFE".
-- `compact` drops the space before the unit (e.g. "2.50kFE") for tight
-- single-line displays such as the card's "stored/max" readout.
local function formatFE(n, compact)
    n = toFE(n)
    if n == nil then return "n/a" end
    local sep = compact and "" or " "
    if n <= 0 then return "0" .. sep .. "FE" end
    local UNITS = { { 1e12, "TFE" }, { 1e9, "GFE" }, { 1e6, "MFE" }, { 1e3, "kFE" }, { 1, "FE" } }
    for _, u in ipairs(UNITS) do
        if n >= u[1] then
            local v = n / u[1]
            local s
            if v >= 100 then
                s = string.format("%.0f", v)
            elseif v >= 10 then
                s = string.format("%.1f", v)
            else
                s = string.format("%.2f", v)
            end
            return s .. sep .. u[2]
        end
    end
    return string.format("%.0f", n) .. sep .. "FE"
end

-- FE per tick (input/output rates)
local function formatFERate(j)
    local s = formatFE(j)
    if s == "n/a" then return s .. "/t" end
    return s .. "/t"
end

-- Tiny flow number for the status line: compact FE with the "FE" suffix
-- stripped, e.g. 12.4kFE -> "12.4k". Keeps the little IN/OUT hint short
-- enough to fit next to the state word without crowding the card.
local function shortFE(n)
    local s = formatFE(n, true)
    if s == "n/a" then return "?" end
    return (s:gsub("FE$", ""))
end

-- A percentage for the battery (0..1) or nil (no telemetry).
local function fillPercent(data)
    if not data or data.filled == nil then return nil end
    return math.max(0, math.min(1, data.filled))
end

-- Normalise the input into a list of { name, data } cards.
-- Accepts:
--   * a single battery table (has .energy/.filled)           -> { { name, data } }
--   * an array of { name, data } or { name, energy, ... }    -> padded to cards
--   * a map  { batteryName = data, ... }                     -> sorted by name
local function batteryList(input)
    if type(input) ~= "table" then return {} end
    -- single battery table with .energy -> wrap it
    if input.energy ~= nil or input.filled ~= nil then
        return { { name = input.name or "BAT", data = input } }
    end
    -- map: named -> data table
    local firstIsMap = false
    local count = 0
    for k, v in pairs(input) do
        if type(k) == "string" and type(v) == "table" then firstIsMap = true end
        count = count + 1
    end
    if firstIsMap and #input == 0 then
        local keys = {}
        for k in pairs(input) do keys[#keys + 1] = k end
        table.sort(keys)
        local out = {}
        for _, k in ipairs(keys) do
            if type(input[k]) == "table" then
                out[#out + 1] = { name = k, data = input[k] }
            end
        end
        return out
    end
    -- array of { name, data } or { name, energy, ... } entries or {data=...}
    local out = {}
    for _, e in ipairs(input) do
        if type(e) == "table" then
            if e.data then
                out[#out + 1] = { name = e.name or "BAT", data = e.data }
            elseif e.energy ~= nil or e.filled ~= nil then
                out[#out + 1] = { name = e.name or "BAT", data = e }
            end
        end
    end
    if #out == 0 and input.data then
        return { { name = input.name or "BAT", data = input.data } }
    end
    return out
end

-- ---------- monitor drawing ----------
-- Card layout (one per battery), styled like a game HUD resource card: a
-- bright accent-coloured frame (softened corners) around a raised panel.
-- The accent colour doubles as a state indicator. Each card is 5 cells
-- tall (4 body rows + 1 gap row), so 3 batteries fit on a 19-row screen:
--   BAT1                     58%   <- header: name + percent (accent)
--   [############............]    <- charge bar, accent fill on dark track
--   363kFE/624kFE                  <- stored/max, compact (white)
--   OK                              <- state word (accent): OK / CHARGING /
--                                      DISCHARGING / LOW / CRITICAL
local function cardInterior(g, mon, x0, y0, x1, y1, bt, interior)
    local ix0, iy0 = x0 + bt, y0 + bt
    local iw, ih = (x1 - x0 + 1) - 2 * bt, (y1 - y0 + 1) - 2 * bt
    if iw > 0 and ih > 0 then
        g.fill(mon, ix0, iy0, iw, ih, interior)
    end
end

-- Border drawn LAST (on top of any text/bar bleed) so the frame stays crisp.
-- The outer corners are chamfered with `bg` to fake a soft/rounded frame.
local function cardBorder(g, mon, x0, y0, x1, y1, bt, accent, bg)
    local bw, bh = x1 - x0 + 1, y1 - y0 + 1
    g.fill(mon, x0, y0, bw, bt, accent)                -- top
    g.fill(mon, x0, y1 - bt + 1, bw, bt, accent)        -- bottom
    g.fill(mon, x0, y0, bt, bh, accent)                 -- left
    g.fill(mon, x1 - bt + 1, y0, bt, bh, accent)        -- right
    g.fill(mon, x0, y0, bt, bt, bg)                     -- corner chamfer
    g.fill(mon, x1 - bt + 1, y0, bt, bt, bg)
    g.fill(mon, x0, y1 - bt + 1, bt, bt, bg)
    g.fill(mon, x1 - bt + 1, y1 - bt + 1, bt, bt, bg)
end

-- Battery state word + accent colour, driven by charge level and net flow.
-- Uses the muted gold/amber/crimson/sage tones (not the vivid alarm colors)
-- so the cards read as calm status widgets rather than warning lights.
-- `C` is a table with .dim/.crimson/.amber/.sage/.gold fields (works with
-- both the gfx palette and a colors.* lookup table for the text fallback).
local function batteryStatus(d, pct, C)
    if pct == nil then return "NO DATA", C.dim end
    if pct < 0.10 then return "CRITICAL", C.crimson end
    if pct < 0.30 then return "LOW", C.amber end
    local inn, outt = d.lastInput or 0, d.lastOutput or 0
    if inn > outt then return "CHARGING", C.sage end
    if outt > inn then return "DISCHARGING", C.gold end
    return "OK", C.gold
end

local function drawMonitor(mon, input, opts)
    opts = opts or {}
    local g = lib.gfx
    local C = g.C

    local gfxOk = false
    if g and g.supported then
        gfxOk = g.supported(mon)
        if gfxOk then gfxOk = g.init(mon) end
        if not gfxOk and mon.setGraphicsMode then
            pcall(function() mon.setGraphicsMode(0) end)
        end
    end

    local w, h = mon.getSize()
    local bats = batteryList(input)
    local hasData = false
    for _, b in ipairs(bats) do
        if b.data and b.data.energy ~= nil then hasData = true end
    end

    if gfxOk then
        g.begin(mon)
        g.centerText(mon, 1, opts.title or "ENERGY", C.cyan, C.bg)
        g.hline(mon, 2 * g.CELL_H - 1, C.borderD)

        if #bats == 0 or not hasData then
            g.centerText(mon, math.max(3, math.floor(h / 2)), "AWAITING TELEMETRY", C.yellow, C.bg)
            g.centerText(mon, math.max(4, math.floor(h / 2) + 1), "induction port offline", C.dim, C.bg)
            g.finish(mon)
            return
        end

        -- Card box is 4 rows tall. The charge bar is a thin 3px HUD strip,
        -- rather than consuming a full text row, so name, values and status
        -- remain readable while the card stays compact.
        local bodyH = 4
        local cardH = bodyH + 1 -- + gap row between cards
        local bt = 1 -- border thickness, px
        local top = 3 -- first row available below the screen title
        local topGap = 1 -- small breathing room below the title
        local y = top + topGap

        -- Use the regular 5x7 glyphs for clarity, but keep the pixel-based
        -- positioning so the card still has padding without growing taller.
        local textW = g.CELL_W
        local function put(px0, py0, str, fg, bg)
            g.drawText(mon, px0, py0, str, fg, bg)
        end

        for _, b in ipairs(bats) do
            local d = b.data
            if y + bodyH - 1 <= h then
                local name = b.name or "BAT"
                local pct = fillPercent(d)
                local pctStr = (pct ~= nil) and string.format("%.0f%%", pct * 100) or "--"
                local status, accent = batteryStatus(d, pct, C)

                local x0, y0 = 0, (y - 1) * g.CELL_H
                local x1, y1 = w * g.CELL_W - 1, (y + bodyH) * g.CELL_H - 1

                -- raised interior panel first; the border is drawn last so
                -- it always sits crisp on top of the text/bar underneath.
                cardInterior(g, mon, x0, y0, x1, y1, bt, C.panel)

                local padPx = 3
                local contentX0 = x0 + bt + padPx
                local contentX1 = x1 - bt - padPx
                local headerPy = y0 + bt + padPx
                local barPy, barH = y0 + 12, 3
                local valuePy = y0 + 17
                -- Status + IN/OUT are intentionally lower in the card.
                local statusPy = y0 + 27

                -- header: name (left) + percent (right), in the accent colour
                put(contentX0, headerPy, name, accent, C.panel)
                if pct ~= nil then
                    put(contentX1 - #pctStr * textW + 1, headerPy, pctStr, accent, C.panel)
                end

                -- charge bar: dark inset track, accent fill by percent
                local barX0, barW = contentX0, contentX1 - contentX0 + 1
                g.fill(mon, barX0, barPy, barW, barH, C.bg)
                if pct ~= nil and pct > 0 then
                    local fw = math.max(1, math.floor(barW * pct))
                    g.fill(mon, barX0, barPy, fw, barH, accent)
                end

                -- stored/max, compact single line (e.g. "363kFE/624kFE")
                local valStr = formatFE(d.energy, true) .. "/" .. formatFE(d.maxEnergy, true)
                put(contentX0, valuePy, valStr, C.white, C.panel)

                -- state word: OK / CHARGING / DISCHARGING / LOW / CRITICAL
                put(contentX0, statusPy, status, accent, C.panel)

                -- tiny IN/OUT hint, tucked in next to the state word (dim,
                -- so it reads as a small detail rather than another alarm)
                if d.lastInput ~= nil or d.lastOutput ~= nil then
                    local flowStr = "+" .. shortFE(d.lastInput or 0) .. " -" .. shortFE(d.lastOutput or 0)
                    put(contentX1 - #flowStr * textW + 1, statusPy, flowStr, C.dim, C.panel)
                end

                cardBorder(g, mon, x0, y0, x1, y1, bt, accent, C.bg)
            end
            y = y + cardH
        end

        g.finish(mon)
        return
    end

    ---- text fallback ----
    mon.setBackgroundColor(colors.black)
    mon.clear()
    local _, th = mon.getSize()
    local STATUS_COLORS = {
        dim = colors.gray, crimson = colors.red, amber = colors.orange,
        gold = colors.yellow, sage = colors.lime,
    }

    local function wln(r, text, color)
        if r > th then return end
        mon.setCursorPos(3, r)
        mon.setTextColor(color or colors.white)
        mon.write(text)
    end

    mon.setCursorPos(math.max(1, math.floor((w - #(opts.title or "ENERGY")) / 2)), 1)
    mon.setTextColor(colors.cyan)
    mon.write(opts.title or "ENERGY")

    if #bats == 0 or not hasData then
        wln(4, "AWAITING TELEMETRY", colors.yellow)
        wln(5, "induction port offline", colors.gray)
        return
    end

    local r = 3
    for _, b in ipairs(bats) do
        local d = b.data
        if r + 2 <= th then
            local pct = fillPercent(d)
            local status, scolor = batteryStatus(d, pct, STATUS_COLORS)
            mon.setCursorPos(3, r)
            mon.setTextColor(colors.cyan)
            mon.write(b.name or "BAT")
            if pct ~= nil then
                mon.setCursorPos(w - 3, r)
                mon.setTextColor(colors.white)
                mon.write(string.format("%.0f%%", pct * 100))
            end
            wln(r + 1, formatFE(d.energy, true) .. "/" .. formatFE(d.maxEnergy, true), colors.white)
            if d.lastInput ~= nil or d.lastOutput ~= nil then
                local flowStr = "+" .. shortFE(d.lastInput or 0) .. " -" .. shortFE(d.lastOutput or 0)
                mon.setCursorPos(3, r + 2)
                mon.setTextColor(scolor)
                mon.write(status)
                mon.setCursorPos(w - #flowStr - 1, r + 2)
                mon.setTextColor(colors.gray)
                mon.write(flowStr)
            else
                wln(r + 2, status, scolor)
            end
        end
        r = r + 4
    end
end

return function(bunkerlib)
    lib = bunkerlib
    local energy = {
        readInduction = readInduction,
        broadcast = broadcast,
        toFE = toFE,
        formatFE = formatFE,
        formatFERate = formatFERate,
        fillPercent = fillPercent,
        drawMonitor = drawMonitor,
    }
    bunkerlib.energy = energy
end
