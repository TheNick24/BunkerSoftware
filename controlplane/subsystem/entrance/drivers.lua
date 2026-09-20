-- ============================================
-- MAMDANI OS - module: DRIVERS
-- Base transport drivers + protected relay accesses.
-- A driver defines HOW a device is read/set on the client.
-- Loaded by bunkerlib.lua (do not require directly).
-- ============================================

-- Protected read/write on a redstone relay peripheral.
local function relayGet(relay, side, onError)
    local ok, res = pcall(peripheral.call, relay, "getOutput", side)
    if ok then return res end
    if onError then onError(tostring(res)) end
    return false
end

local function relaySet(relay, side, state, onError)
    local ok, res = pcall(peripheral.call, relay, "setOutput", side, state)
    if not ok and onError then onError(tostring(res)) end
end

return function(bunkerlib)
    bunkerlib.relayGet = relayGet
    bunkerlib.relaySet = relaySet

    -- Base transports. Door controllers (lib/doors.lua) add their own
    -- drivers on top of these (door, safety-door).
    bunkerlib.DRIVERS = {
        -- Controlled through a redstone relay peripheral.
        relay = {
            name = "relay",
            describe = function(dev)
                return (dev.relay or "?") .. " [" .. (dev.side or "?") .. "]"
            end,
            read = function(dev)
                return peripheral.call(dev.relay, "getOutput", dev.side)
            end,
            set = function(dev, state)
                peripheral.call(dev.relay, "setOutput", dev.side, state)
            end,
        },

        -- Controlled DIRECTLY on a computer redstone output (no relay).
        redstone = {
            name = "redstone",
            describe = function(dev)
                return "redstone [" .. (dev.side or "?") .. "]"
            end,
            read = function(dev)
                return rs.getOutput(dev.side)
            end,
            set = function(dev, state)
                rs.setOutput(dev.side, state)
            end,
        },
    }

    function bunkerlib.driver(name)
        return bunkerlib.DRIVERS[name] or bunkerlib.DRIVERS.relay
    end
end