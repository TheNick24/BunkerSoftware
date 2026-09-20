-- ============================================
-- MAMDANI OS - module: GFX
-- 256-color graphics-mode rendering for
-- cc-graphics (CraftOS-PC compatible gfxmode) -
-- https://modrinth.com/mod/cc-graphics
--
-- Uses term/monitor graphics mode 2 (256 colors)
-- with a per-monitor palette and a 5x7 bitmap
-- font. All drawing is pixel based: one
-- character cell = 6x9 px. Frames are drawn
-- with setFrozen() so the update appears in one
-- step (no flicker).
--
-- Loaded by bunkerlib.lua (do not require directly).
-- ============================================

local CELL_W, CELL_H = 6, 9

-- Named palette slots (256-color indices 1-16).
-- Index 0 is reserved as the "null" color: it is used ONLY via the solid
-- drawPixels(x,y,color,w,h) / setPixel fill form. It must never appear in a
-- packed-string drawPixels row, because byte 0x00 can break string-based
-- drawing on the cc-graphics transport.
local C = {
    bg      = 1,   -- screen background
    panel   = 2,   -- panel surface
    panel2  = 3,   -- row / alt surface
    border  = 4,   -- bright frame
    borderD = 5,   -- dark frame / separators
    dim     = 6,   -- muted text
    text    = 7,   -- normal text
    white   = 8,
    cyan    = 9,
    green   = 10,
    yellow  = 11,
    orange  = 12,
    red     = 13,
    purple  = 14,
    pink    = 15,
    blue    = 16,
}

-- RGB per palette slot (0-255 each). Slot 0 is set to bg in init() so the
-- default canvas color matches the screen background.
local PALETTE = {
    [1]  = { 5, 9, 20 },    -- bg: near-black navy
    [2]  = { 12, 22, 44 },  -- panel
    [3]  = { 22, 36, 66 },  -- panel2 / row
    [4]  = { 52, 82, 128 }, -- border
    [5]  = { 30, 48, 84 },  -- borderD / separators
    [6]  = { 122, 145, 178 }, -- dim text
    [7]  = { 208, 220, 238 }, -- text
    [8]  = { 246, 250, 255 }, -- white
    [9]  = { 64, 210, 235 },  -- cyan
    [10] = { 74, 228, 118 },  -- green (ON / good)
    [11] = { 252, 214, 74 },  -- yellow (warn)
    [12] = { 255, 156, 40 },  -- orange (alarm arm)
    [13] = { 255, 74, 74 },   -- red (alarm / error)
    [14] = { 180, 132, 255 }, -- purple
    [15] = { 255, 112, 200 }, -- pink
    [16] = { 78, 126, 255 },  -- blue
}

-- 5x7 bitmap font (ASCII 0x20-0x7E). Each glyph is 7 rows of 5 chars,
-- '#' = ink, '.' = background. Fits the 6x9 cell with 1px right + 2px
-- bottom padding.
local FONT = {}

FONT[" "] = { ".....",
               ".....",
               ".....",
               ".....",
               ".....",
               ".....",
               "....." }
FONT["!"] = { "..#..",
               "..#..",
               "..#..",
               "..#..",
               "..#..",
               ".....",
               "..#.." }
FONT['"'] = { ".#.#.",
               ".#.#.",
               ".....",
               ".....",
               ".....",
               ".....",
               "....." }
FONT["#"] = { ".#.#.",
               ".#.#.",
               "#####",
               ".#.#.",
               "#####",
               ".#.#.",
               ".#.#." }
FONT["$"] = { "..#..",
               ".####",
               "#.#..",
               ".###.",
               "..#.#",
               "####.",
               "..#.." }
FONT["%"] = { "##..#",
               "##.#.",
               "..#..",
               "..#..",
               ".#.##",
               "#..##",
               "....." }
FONT["&"] = { ".##..",
               "#..#.",
               "#.#..",
               ".##..",
               "#.#.#",
               "#..#.",
               ".##.#" }
FONT["'"] = { "..#..",
               "..#..",
               ".....",
               ".....",
               ".....",
               ".....",
               "....." }
FONT["("] = { "...#.",
               "..#..",
               ".#...",
               ".#...",
               ".#...",
               "..#..",
               "...#." }
FONT[")"] = { ".#...",
               "..#..",
               "...#.",
               "...#.",
               "...#.",
               "..#..",
               ".#..." }
FONT["*"] = { ".....",
               "#.#.#",
               ".###.",
               ".###.",
               ".###.",
               "#.#.#",
               "....." }
FONT["+"] = { ".....",
               "..#..",
               "..#..",
               "#####",
               "..#..",
               "..#..",
               "....." }
FONT[","] = { ".....",
               ".....",
               ".....",
               ".....",
               ".....",
               "...#.",
               ".##.." }
FONT["-"] = { ".....",
               ".....",
               ".....",
               "#####",
               ".....",
               ".....",
               "....." }
FONT["."] = { ".....",
               ".....",
               ".....",
               ".....",
               ".....",
               "..##.",
               "..##." }
FONT["/"] = { "....#",
               "...#.",
               "..#..",
               ".#...",
               "#....",
               "#....",
               "....." }
FONT["0"] = { ".###.",
               "#...#",
               "#..##",
               "#.#.#",
               "##..#",
               "#...#",
               ".###." }
FONT["1"] = { "..#..",
               ".##..",
               ".#.#.",
               "..#..",
               "..#..",
               "..#..",
               "#####" }
FONT["2"] = { ".###.",
               "#...#",
               "....#",
               "...#.",
               "..##.",
               ".#...",
               "#####" }
FONT["3"] = { ".###.",
               "#...#",
               "....#",
               "..##.",
               "....#",
               "#...#",
               ".###." }
FONT["4"] = { "...#.",
               "..##.",
               ".#.#.",
               "#..#.",
               "#####",
               "...#.",
               "...#." }
FONT["5"] = { "#####",
               "#....",
               "####.",
               "....#",
               "....#",
               "#...#",
               ".###." }
FONT["6"] = { ".###.",
               "#....",
               "#....",
               "####.",
               "#...#",
               "#...#",
               ".###." }
FONT["7"] = { "#####",
               "....#",
               "...#.",
               "..#..",
               ".#...",
               ".#...",
               ".#..." }
FONT["8"] = { ".###.",
               "#...#",
               "#...#",
               ".###.",
               "#...#",
               "#...#",
               ".###." }
FONT["9"] = { ".###.",
               "#...#",
               "#...#",
               ".####",
               "....#",
               "....#",
               ".###." }
FONT[":"] = { ".....",
               "..##.",
               "..##.",
               ".....",
               "..##.",
               "..##.",
               "....." }
FONT[";"] = { ".....",
               "..##.",
               "..##.",
               ".....",
               "..##.",
               ".#...",
               ".#..." }
FONT["<"] = { "...#.",
               "..#..",
               ".#...",
               "#....",
               ".#...",
               "..#..",
               "...#." }
FONT["="] = { ".....",
               ".....",
               "#####",
               ".....",
               "#####",
               ".....",
               "....." }
FONT[">"] = { "#....",
               ".#...",
               "..#..",
               "...#.",
               "..#..",
               ".#...",
               "#...." }
FONT["?"] = { ".###.",
               "#...#",
               "....#",
               "...#.",
               "..#..",
               ".....",
               "..#.." }
FONT["@"] = { ".###.",
               "#...#",
               "#.###",
               "#.###",
               "#...#",
               ".###.",
               "....." }
FONT["A"] = { "..#..",
               ".#.#.",
               "#...#",
               "#####",
               "#...#",
               "#...#",
               "#...#" }
FONT["B"] = { "####.",
               "#...#",
               "#...#",
               "####.",
               "#...#",
               "#...#",
               "####." }
FONT["C"] = { ".###.",
               "#...#",
               "#....",
               "#....",
               "#....",
               "#...#",
               ".###." }
FONT["D"] = { "####.",
               "#...#",
               "#...#",
               "#...#",
               "#...#",
               "#...#",
               "####." }
FONT["E"] = { "#####",
               "#....",
               "#....",
               "####.",
               "#....",
               "#....",
               "#####" }
FONT["F"] = { "#####",
               "#....",
               "#....",
               "####.",
               "#....",
               "#....",
               "#...." }
FONT["G"] = { ".###.",
               "#...#",
               "#....",
               "#.###",
               "#...#",
               "#...#",
               ".####" }
FONT["H"] = { "#...#",
               "#...#",
               "#...#",
               "#####",
               "#...#",
               "#...#",
               "#...#" }
FONT["I"] = { "#####",
               "..#..",
               "..#..",
               "..#..",
               "..#..",
               "..#..",
               "#####" }
FONT["J"] = { "..###",
               "...#.",
               "...#.",
               "...#.",
               "#..#.",
               "#..#.",
               ".##.." }
FONT["K"] = { "#...#",
               "#..#.",
               "#.#..",
               "##...",
               "#.#..",
               "#..#.",
               "#...#" }
FONT["L"] = { "#....",
               "#....",
               "#....",
               "#....",
               "#....",
               "#....",
               "#####" }
FONT["M"] = { "#...#",
               "##.##",
               "#.#.#",
               "#.#.#",
               "#...#",
               "#...#",
               "#...#" }
FONT["N"] = { "#...#",
               "##..#",
               "#.#.#",
               "#..##",
               "#...#",
               "#...#",
               "#...#" }
FONT["O"] = { ".###.",
               "#...#",
               "#...#",
               "#...#",
               "#...#",
               "#...#",
               ".###." }
FONT["P"] = { "####.",
               "#...#",
               "#...#",
               "####.",
               "#....",
               "#....",
               "#...." }
FONT["Q"] = { ".###.",
               "#...#",
               "#...#",
               "#...#",
               "#.#.#",
               "#..#.",
               ".##.#" }
FONT["R"] = { "####.",
               "#...#",
               "#...#",
               "####.",
               "#.#..",
               "#..#.",
               "#...#" }
FONT["S"] = { ".####",
               "#....",
               "#....",
               ".###.",
               "....#",
               "....#",
               "####." }
FONT["T"] = { "#####",
               "..#..",
               "..#..",
               "..#..",
               "..#..",
               "..#..",
               "..#.." }
FONT["U"] = { "#...#",
               "#...#",
               "#...#",
               "#...#",
               "#...#",
               "#...#",
               ".###." }
FONT["V"] = { "#...#",
               "#...#",
               "#...#",
               "#...#",
               "#...#",
               ".#.#.",
               "..#.." }
FONT["W"] = { "#...#",
               "#...#",
               "#...#",
               "#.#.#",
               "#.#.#",
               "##.##",
               "#...#" }
FONT["X"] = { "#...#",
               "#...#",
               ".#.#.",
               "..#..",
               ".#.#.",
               "#...#",
               "#...#" }
FONT["Y"] = { "#...#",
               "#...#",
               ".#.#.",
               "..#..",
               "..#..",
               "..#..",
               "..#.." }
FONT["Z"] = { "#####",
               "....#",
               "...#.",
               "..#..",
               ".#...",
               "#....",
               "#####" }
FONT["["] = { "..##.",
               "..#..",
               "..#..",
               "..#..",
               "..#..",
               "..#..",
               "..##." }
FONT["\\"] = { "#....",
               "#....",
               ".#...",
               "..#..",
               "...#.",
               "....#",
               "....#" }
FONT["]"] = { ".##..",
               "..#..",
               "..#..",
               "..#..",
               "..#..",
               "..#..",
               ".##.." }
FONT["^"] = { "..#..",
               ".#.#.",
               "#...#",
               ".....",
               ".....",
               ".....",
               "....." }
FONT["_"] = { ".....",
               ".....",
               ".....",
               ".....",
               ".....",
               ".....",
               "#####" }
FONT["`"] = { ".#...",
               "..#..",
               ".....",
               ".....",
               ".....",
               ".....",
               "....." }
FONT["a"] = { ".....",
               ".....",
               ".###.",
               "#...#",
               "#.###",
               "#...#",
               ".####" }
FONT["b"] = { "#....",
               "#....",
               ".###.",
               "#...#",
               "#...#",
               "#...#",
               ".###." }
FONT["c"] = { ".....",
               ".....",
               ".###.",
               "#....",
               "#....",
               "#...#",
               ".###." }
FONT["d"] = { "...#.",
               "...#.",
               ".###.",
               "#.#.#",
               "#...#",
               "#...#",
               ".####" }
FONT["e"] = { ".....",
               ".....",
               ".###.",
               "#...#",
               "#####",
               "#....",
               ".###." }
FONT["f"] = { "..##.",
               ".#...",
               "####.",
               ".#...",
               ".#...",
               ".#...",
               ".#..." }
FONT["g"] = { ".....",
               ".####",
               "#...#",
               "#...#",
               ".####",
               "...#.",
               ".##.." }
FONT["h"] = { "#....",
               "#....",
               ".###.",
               "#...#",
               "#...#",
               "#...#",
               "#...#" }
FONT["i"] = { "..#..",
               ".....",
               ".##..",
               "..#..",
               "..#..",
               "..#..",
               ".###." }
FONT["j"] = { "...#.",
               ".....",
               "..##.",
               "...#.",
               "...#.",
               "...#.",
               ".##.." }
FONT["k"] = { "#....",
               "#....",
               "#..#.",
               "#.#..",
               "##...",
               "#.#..",
               "#..#." }
FONT["l"] = { ".##..",
               "..#..",
               "..#..",
               "..#..",
               "..#..",
               "..#..",
               ".###." }
FONT["m"] = { ".....",
               ".....",
               "##.##",
               "#.#.#",
               "#.#.#",
               "#...#",
               "#...#" }
FONT["n"] = { ".....",
               ".....",
               ".###.",
               "#...#",
               "#...#",
               "#...#",
               "#...#" }
FONT["o"] = { ".....",
               ".....",
               ".###.",
               "#...#",
               "#...#",
               "#...#",
               ".###." }
FONT["p"] = { ".....",
               ".###.",
               "#...#",
               "#...#",
               "####.",
               "#....",
               "#...." }
FONT["q"] = { ".....",
               ".###.",
               "#.#.#",
               "#...#",
               ".####",
               "...#.",
               "...#." }
FONT["r"] = { ".....",
               ".....",
               "#.##.",
               "##..#",
               "#....",
               "#....",
               "#...." }
FONT["s"] = { ".....",
               ".....",
               ".####",
               "#....",
               ".###.",
               "....#",
               "####." }
FONT["t"] = { ".#...",
               ".#...",
               "####.",
               ".#...",
               ".#...",
               ".#...",
               "..##." }
FONT["u"] = { ".....",
               ".....",
               "#...#",
               "#...#",
               "#...#",
               "#...#",
               ".####" }
FONT["v"] = { ".....",
               ".....",
               "#...#",
               "#...#",
               "#...#",
               ".#.#.",
               "..#.." }
FONT["w"] = { ".....",
               ".....",
               "#...#",
               "#...#",
               "#.#.#",
               "#.#.#",
               ".#.#." }
FONT["x"] = { ".....",
               ".....",
               "#...#",
               ".#.#.",
               "..#..",
               ".#.#.",
               "#...#" }
FONT["y"] = { ".....",
               "#...#",
               "#...#",
               "#...#",
               ".####",
               "...#.",
               ".##.." }
FONT["z"] = { ".....",
               ".....",
               "#####",
               "...#.",
               "..#..",
               ".#...",
               "#####" }
FONT["{"] = { "...#.",
               "..#..",
               "..#..",
               ".#...",
               "..#..",
               "..#..",
               "...#." }
FONT["|"] = { "..#..",
               "..#..",
               "..#..",
               "..#..",
               "..#..",
               "..#..",
               "..#.." }
FONT["}"] = { ".#...",
               "..#..",
               "..#..",
               "...#.",
               "..#..",
               "..#..",
               ".#..." }
FONT["~"] = { ".....",
               ".....",
               ".##..",
               "#.#.#",
               "..##.",
               ".....",
               "....." }

-- Fallback for unknown characters (blank cell).
setmetatable(FONT, { __index = function() return FONT[" "] end })

-- ------------------------------------------------------------
-- pixel helpers
-- ------------------------------------------------------------
local fmt = string.char

local function pxSize(mon)
    local ok, pw, ph = pcall(function() return mon.getSize(2) end)
    if ok and pw and ph then return pw, ph end
    local w, h = mon.getSize()
    return w * CELL_W, h * CELL_H
end

local function supported(mon)
    local ok, a, b, c = pcall(function()
        local gm = mon.getGraphicsMode
        local sm = mon.setGraphicsMode
        if not gm or not sm or not mon.drawPixels or not mon.setPixel then return false end
        return sm(2), gm()
    end)
    if not ok then return false end
    return b == 2
end

-- Switch a monitor to 256-color graphics mode and install the palette.
-- Returns true when the monitor is now in graphics mode 2.
local function init(mon)
    if not mon.setGraphicsMode then return false end
    local ok = pcall(function() mon.setGraphicsMode(2) end)
    if not ok then return false end
    local ok2, gm = pcall(function() return mon.getGraphicsMode() end)
    if not ok2 or gm ~= 2 then return false end
    local bg = PALETTE[C.bg]
    pcall(function() mon.setPaletteColor(0, bg[1] / 255, bg[2] / 255, bg[3] / 255) end)
    for idx, rgb in pairs(PALETTE) do
        pcall(function() mon.setPaletteColor(idx, rgb[1] / 255, rgb[2] / 255, rgb[3] / 255) end)
    end
    return true
end

local function begin(mon)
    pcall(function() mon.setFrozen(true) end)
    local pw, ph = pxSize(mon)
    pcall(function() mon.drawPixels(0, 0, 0, pw, ph) end)
end

local function finish(mon)
    pcall(function() mon.setFrozen(false) end)
end

-- solid pixel rect
local function fill(mon, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    pcall(function() mon.drawPixels(x, y, color, w, h) end)
end

-- solid rect in cell units (cx, cy = 1-based top-left cell, cw x ch cells)
local function cellFill(mon, cx, cy, cw, ch, color)
    fill(mon, (cx - 1) * CELL_W, (cy - 1) * CELL_H, cw * CELL_W, ch * CELL_H, color)
end

-- Draw one packed pixel row (byte-per-pixel string) as consecutive solid
-- fills. The packed-string drawPixels(x,y,string) variant is unreliable on
-- the cc-graphics transport, so we only rely on the proven solid fill form
-- drawPixels(x,y,color,w,h).
local function drawRowSolid(mon, x, y, rowstr)
    if rowstr == "" then return end
    local runStart = 1
    local first = rowstr:byte(runStart)
    for i = 2, #rowstr + 1 do
        local c = (i <= #rowstr) and rowstr:byte(i) or -1
        if c ~= first then
            pcall(function() mon.drawPixels(x + runStart - 1, y, first, i - runStart, 1) end)
            runStart = i
            first = c
        end
    end
end

-- one glyph drawn at pixel origin (px0, py0); cell 6x9, glyph 5x7
local function glyph(mon, px0, py0, ch, fg, bg)
    fill(mon, px0, py0, CELL_W, CELL_H, bg)
    local rows = FONT[ch]
    if not rows then return end
    local fa, ba = fmt(fg), fmt(bg)
    for r = 1, 7 do
        local rowstr = rows[r]:gsub("[#.]", function(c)
            return c == "#" and fa or ba
        end)
        drawRowSolid(mon, px0, py0 + r - 1, rowstr)
    end
end

-- text at a pixel origin (glyphs are placed in 6px cells from px0)
local function drawText(mon, px0, py0, s, fg, bg)
    for i = 1, #s do
        glyph(mon, px0 + (i - 1) * CELL_W, py0, s:sub(i, i), fg, bg)
    end
end

-- text at a cell position (1-based)
local function cellText(mon, cx, cy, s, fg, bg)
    drawText(mon, (cx - 1) * CELL_W, (cy - 1) * CELL_H, s, fg, bg)
end

-- text centered horizontally on the screen, on cell row cy
local function centerText(mon, cy, s, fg, bg)
    local w = mon.getSize()
    local cx = math.floor((w - #s) / 2) + 1
    cellText(mon, cx, cy, s, fg, bg)
end

-- text centered horizontally in pixels (whole screen width) at pixel row py0
local function pxCenterText(mon, py0, s, fg, bg)
    local pw = pxSize(mon)
    local x = math.floor((pw - #s * CELL_W) / 2)
    drawText(mon, math.max(0, x), py0, s, fg, bg)
end

-- full-width bar on cell row cy
local function bar(mon, cy, color)
    local pw = pxSize(mon)
    fill(mon, 0, (cy - 1) * CELL_H, pw, CELL_H, color)
end

-- full-width horizontal 1px line on pixel row y
local function hline(mon, y, color)
    local pw = pxSize(mon)
    if y < 0 then return end
    fill(mon, 0, y, pw, 1, color)
end

return function(bunkerlib)
    local gfx = {
        C = C,
        palette = PALETTE,
        CELL_W = CELL_W,
        CELL_H = CELL_H,
        pxSize = pxSize,
        supported = supported,
        init = init,
        begin = begin,
        finish = finish,
        fill = fill,
        cellFill = cellFill,
        glyph = glyph,
        drawText = drawText,
        cellText = cellText,
        centerText = centerText,
        pxCenterText = pxCenterText,
        bar = bar,
        hline = hline,
    }
    bunkerlib.gfx = gfx
end