-- ============================================
-- MAMDANI OS - module: NETWORK
-- Loaded by bunkerlib.lua (do not require directly).
-- ============================================

-- Opens the first working modem. Tries `preferredSide` first
-- (nil = auto), then all other sides.
local function findModem(preferredSide)
    local order = {}
    if preferredSide and preferredSide ~= "" then table.insert(order, preferredSide) end
    for _, side in ipairs(rs.getSides()) do
        if side ~= preferredSide then table.insert(order, side) end
    end
    for _, side in ipairs(order) do
        local ok = pcall(rednet.open, side)
        if ok and rednet.isOpen(side) then return side end
    end
    return nil
end

-- Prints a message only when it changes (dedupe per key).
local function printOnce(cache, key, txt)
    if cache[key] ~= txt then
        cache[key] = txt
        term.setTextColor(colors.red)
        print(txt)
        term.setTextColor(colors.white)
    end
end

return function(bunkerlib)
    bunkerlib.findModem = findModem
    bunkerlib.printOnce = printOnce
end