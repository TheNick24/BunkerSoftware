-- ============================================
-- MAMDANI OS - module: DOORS
-- Door controllers with their OWN driver + action per door type.
--
-- Each controller is a small unit: it knows how the physical signal maps to
-- the door state (driver: read/set/describe) AND what a panel button sends
-- (action). Add a new door type here instead of touching the renderer or
-- the client runtime.
--
-- Shared principle: a redstone signal ON on the bridge/contact means the
-- door is CLOSED/engaged. The driver inverts, so state true = OPEN/SEALED,
-- false = CLOSED.
-- Loaded by bunkerlib.lua (do not require directly).
-- ============================================

return function(bunkerlib)
    -- Driver entries (client side) - registration order builds on
    -- bunkerlib.DRIVERS from lib/drivers.lua.
    -- `describe`/`read`/`set` are the same interface as the base drivers,
    -- so runClient / direct calls (e.g. the door keypad) work unchanged.

    -- CONTROL-ROOM DOOR - always CLOSED, opens only via keypad code.
    -- (client/control/startup.lua implements the code-open + auto-reclose)
    -- restClosed = true = the door rests LOCKED/CLOSED without a command.
    bunkerlib.DRIVERS.door = {
        type = "door",
        name = "door",
        restClosed = true,
        describe = function(dev)
            return (dev.peripheral or "?") .. " [" .. (dev.side or "?") .. "]"
        end,
        read = function(dev)
            return not peripheral.call(dev.peripheral, "getOutput", dev.side)
        end,
        set = function(dev, state)
            peripheral.call(dev.peripheral, "setOutput", dev.side, not state)
        end,
    }

    -- ALARM DOOR / SAFETY DOOR - normally OPEN, closes ONLY in an emergency.
    -- Close them all at once with bunkerlib.emergencyDoors(statuses, true)
    -- (or the control room `alarm` command); reopen with ...(statuses, false).
    -- alarm = true and safeWhenClosed = true mark the desired emergency
    -- semantics: on error the door counts as CLOSED (the safe state).
    bunkerlib.DRIVERS["safety-door"] = {
        type = "alarm-door",
        name = "safety-door",
        alarm = true,
        safeWhenClosed = true,
        describe = function(dev)
            return "SD-" .. (dev.peripheral or "?") .. " [" .. (dev.side or "?") .. "]"
        end,
        read = function(dev)
            return not peripheral.call(dev.peripheral, "getOutput", dev.side)
        end,
        set = function(dev, state)
            peripheral.call(dev.peripheral, "setOutput", dev.side, not state)
        end,
    }

    -- Panel actions - `<cmd>` must match the client device `cmd`.
    -- NORMAL (control-room) DOOR: open/close toggle.
    bunkerlib.ACTIONS.door = function(status, id)
        return { room = id, cmd = "door", state = not status.state }
    end
    -- SAFETY/ALARM DOOR: open/close toggle.
    bunkerlib.ACTIONS["safety-door"] = function(status, id)
        return { room = id, cmd = "safety-door", state = not status.state }
    end

    -- ALARM: closes (true) / reopens (false) EVERY alarm door at once by
    -- sending to each known safety-door's client. Returns how many were
    -- commanded. This is the intended "emergency" way to use alarm doors.
    function bunkerlib.emergencyDoors(statuses, close)
        local count = 0
        for id, s in pairs(statuses) do
            if s.cmd == "safety-door" and s.senderId then
                rednet.send(s.senderId, { room = id, cmd = "safety-door", state = not close }, "bunker_cmd")
                count = count + 1
            end
        end
        return count
    end
end