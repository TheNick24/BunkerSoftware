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
--
-- LOCKABLE DOORS (driver "door"): a software lock flag that makes the door
-- ignore every open request (panel, keypad, inside button) until it is
-- unlocked again. Wiring is a redstone relay connected to a Create
-- gearshift, so signal ON = closed AND mechanically locked. Utility:
-- isLocked()/setLock() are generic, so lockable doors can be reused on any
-- screen; emergencyDoors() also locks them during an alarm and restores the
-- pre-alarm lock state afterwards.
-- Loaded by bunkerlib.lua (do not require directly).
-- ============================================

return function(bunkerlib)
    -- Driver entries (client side) - registration order builds on
    -- bunkerlib.DRIVERS from lib/drivers.lua.
    -- `describe`/`read`/`set` are the same interface as the base drivers,
    -- so runClient / direct calls (e.g. the door keypad) work unchanged.

    -- Lock flags for lockable doors, keyed by the dev config table (drivers
    -- are shared module-wide, so everything per-door lives in this table).
    local lockState = {}

    -- CONTROL-ROOM DOOR - always CLOSED, opens only via keypad code.
    -- (client/control/startup.lua implements the code-open + auto-reclose)
    -- restClosed = true = the door rests LOCKED/CLOSED without a command.
    --
    -- LOCKED means: every open attempt is refused. set() clamps - a locked
    -- door keeps (and re-asserts) the closed signal no matter what command
    -- arrives, so it can only be opened after setLock(false).
    bunkerlib.DRIVERS.door = {
        type = "door",
        name = "door",
        restClosed = true,
        describe = function(dev)
            local s = lockState[dev] and " LOCKED" or ""
            return (dev.peripheral or "?") .. " [" .. (dev.side or "?") .. "]" .. s
        end,
        read = function(dev)
            return not peripheral.call(dev.peripheral, "getOutput", dev.side)
        end,
        set = function(dev, state)
            -- a locked door cannot open: an open command is ignored and the
            -- closed signal is re-asserted instead
            local out = lockState[dev] and true or (not state)
            peripheral.call(dev.peripheral, "setOutput", dev.side, out)
        end,
        isLocked = function(dev)
            return lockState[dev] or false
        end,
        setLock = function(dev, locked)
            lockState[dev] = not not locked
            -- lock OR unlock both land on CLOSED (restClosed): unlocking
            -- never springs the door open, it just makes it openable again
            peripheral.call(dev.peripheral, "setOutput", dev.side, true)
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

    -- CREATE SEQUENCED GEARSHIFT DOOR. A door on a pulley/gantry is controlled
    -- with move(distance, modifier): opening moves it DOWN by `distance`, and
    -- closing moves it fully UP by the same distance. Unlike redstone doors it
    -- cannot report its physical position, so we retain the last command.
    local gearshiftState, gearshiftLock = {}, {}
    bunkerlib.DRIVERS["gearshift-door"] = {
        type = "door",
        name = "gearshift-door",
        restClosed = true,
        describe = function(dev)
            return "SG-" .. (dev.peripheral or "?") .. " [" .. tostring(dev.distance or 5) .. " blocks]"
        end,
        read = function(dev)
            return gearshiftState[dev] or false
        end,
        set = function(dev, state)
            if state and gearshiftLock[dev] then return false end
            local p = peripheral.wrap(dev.peripheral)
            if not p or not p.move then error("sequenced gearshift unavailable: " .. tostring(dev.peripheral)) end
            local direction = tonumber(dev.openDirection) or 1
            if not state then direction = -direction end
            p.move(tonumber(dev.distance) or 5, direction)
            gearshiftState[dev] = not not state
            return true
        end,
        -- Software position update WITHOUT sending a move. Used by the
        -- reusable gearshift controller after a (possibly multi-step)
        -- motion finished, so status broadcasts reflect the real travel.
        mark = function(dev, state)
            gearshiftState[dev] = not not state
        end,
        isLocked = function(dev)
            return gearshiftLock[dev] or false
        end,
        setLock = function(dev, locked)
            gearshiftLock[dev] = not not locked
            if locked then bunkerlib.DRIVERS["gearshift-door"].set(dev, false) end
        end,
    }

    -- Panel actions - `<cmd>` must match the client device `cmd`.
    -- NORMAL (control-room) DOOR: open/close toggle.
    bunkerlib.ACTIONS.door = function(status, id)
        return { room = id, cmd = "door", state = not status.state }
    end
    -- LOCKABLE (control-room) DOOR: locks/unlocks instead of opening.
    -- The client refuses all open requests while locked, so this is the
    -- ONLY way to make the door openable again.
    bunkerlib.ACTIONS.lock = function(status, id)
        return { room = id, cmd = "door", lock = not (status.lock or false) }
    end
    -- SAFETY/ALARM DOOR: open/close toggle.
    bunkerlib.ACTIONS["safety-door"] = function(status, id)
        return { room = id, cmd = "safety-door", state = not status.state }
    end

    -- ALARM: closes (true) / reopens (false) EVERY alarm door at once by
    -- sending to each known safety-door's client. Also LOCKS every lockable
    -- door (lockable[id] = true) while the alarm runs. `remember` (optional)
    -- must be a table that the caller keeps alive between alarm start and
    -- end: it stores each door's pre-alarm state/lock so reopening restores
    -- exactly what the door was doing before (a safety door that was already
    -- CLOSED stays closed, a control door that was UNLOCKED becomes openable
    -- again). Returns how many doors were commanded.
    function bunkerlib.emergencyDoors(statuses, close, remember, lockable)
        local count = 0
        for id, s in pairs(statuses) do
            if s.senderId then
                if s.cmd == "safety-door" then
                    local target
                    if close then
                        target = false
                        if remember then remember[id] = s.state end
                    else
                        local restore = true
                        if remember and remember[id] ~= nil then restore = remember[id] end
                        -- respect the LAST status: if the door was manually
                        -- flipped DURING the alarm (was CLOSED before, but is
                        -- OPEN now), the manual action wins over the restore
                        if restore == false and s.state == true then
                            restore = true
                        end
                        target = restore
                    end
                    rednet.send(s.senderId, { room = id, cmd = "safety-door", state = target }, "bunker_cmd")
                    count = count + 1
                elseif lockable and lockable[id] and s.cmd == "door" then
                    local targetLock
                    if close then
                        targetLock = true
                        if remember then remember[id] = s.lock or false end
                    else
                        local restore = false
                        if remember and remember[id] ~= nil then restore = remember[id] end
                        -- same rule for locks: a manual unlock during the
                        -- alarm keeps the door unlockable afterwards
                        if restore == true and (s.lock or false) == false then
                            restore = false
                        end
                        targetLock = restore
                    end
                    rednet.send(s.senderId, { room = id, cmd = "door", lock = targetLock }, "bunker_cmd")
                    count = count + 1
                end
            end
        end
        return count
    end
end
