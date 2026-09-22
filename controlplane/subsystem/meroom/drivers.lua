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

-- Protected read of a redstone relay INPUT (getInput / getAnalogInput).
local function relayGetInput(relay, side, onError)
    local ok, res = pcall(peripheral.call, relay, "getInput", side)
    if ok then return res end
    if onError then onError(tostring(res)) end
    return false
end

local function relayGetAnalogInput(relay, side, onError)
    local ok, res = pcall(peripheral.call, relay, "getAnalogInput", side)
    if ok then return res end
    if onError then onError(tostring(res)) end
    return 0
end

return function(bunkerlib)
    bunkerlib.relayGet = relayGet
    bunkerlib.relaySet = relaySet
    bunkerlib.relayGetInput = relayGetInput
    bunkerlib.relayGetAnalogInput = relayGetAnalogInput

    -- Base transports. Door controllers (lib/doors.lua) add their own
    -- drivers on top of these (door, safety-door).
    bunkerlib.DRIVERS = {
        -- Controlled through a redstone relay peripheral.
        relay = {
            name = "relay",
            describe = function(dev)
                local side = dev.side
                if type(side) == "table" then side = table.concat(side, ",") end
                return (dev.relay or "?") .. " [" .. (side or "?") .. "]"
            end,
            read = function(dev)
                -- input devices: OR over all listed sides (alarm contacts etc.)
                if dev.input then
                    local sides = dev.side
                    if type(sides) ~= "table" then sides = { sides } end
                    for _, s in ipairs(sides) do
                        if peripheral.call(dev.relay, "getInput", s) then return true end
                    end
                    return false
                end
                return peripheral.call(dev.relay, "getOutput", dev.side)
            end,
            set = function(dev, state)
                if dev.input then return end
                peripheral.call(dev.relay, "setOutput", dev.side, state)
            end,
            -- INPUT side (for alarm contacts / panic buttons):
            readInput = function(dev)
                return peripheral.call(dev.relay, "getInput", dev.side)
            end,
            readAnalogInput = function(dev)
                return peripheral.call(dev.relay, "getAnalogInput", dev.side)
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
            readInput = function(dev)
                return rs.getInput(dev.side)
            end,
            readAnalogInput = function(dev)
                return rs.getAnalogInput(dev.side)
            end,
        },
    }

    function bunkerlib.driver(name)
        return bunkerlib.DRIVERS[name] or bunkerlib.DRIVERS.relay
    end
end