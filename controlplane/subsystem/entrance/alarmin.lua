-- ============================================
-- MAMDANI OS - module: ALARMIN
-- Redstone alarm input polling utility.
-- Loaded by bunkerlib.lua (do not require directly).
--
-- Reads alarm trigger inputs from redstone relays (or the computer's own
-- redstone sides) and fires an edge-triggered callback when an input turns
-- ON. Useful for wired panic buttons / door contacts / smoke detectors that
-- should activate the bunker alarm.
--
-- Config format (list of inputs):
--   {
--     { relay = "redstone_relay_9", side = "front", invert = false, label = "Panic" },
--     { side = "left", analog = true, threshold = 8 },  -- computer's own redstone
--   }
--
-- `relay` + `side`  = redstone relay peripheral (getInput). `side` may be a
--                     single name or a list of names (OR: any side ON = ON).
-- `side` only       = computer's own redstone input (rs.getInput / rs.getAnalogInput).
-- `invert`          = true when the signal is active-LOW (OFF = triggered).
-- `analog`          = true to use getAnalogInput / getAnalogRedstone.
-- `threshold`       = minimum analog level to count as ON (default 1).
-- `label`           = human-readable name for logs / messages.
--
-- Public API added to bunkerlib:
--   bunkerlib.alarmin.create(conf)
--     conf = { inputs = <list>, onTrigger = function(input, state) end,
--              pollInterval = <seconds, default 0.5> }
--     Returns a controller with:
--       poll()              - read all inputs once, fire callbacks on edges
--       tick(timerId)       - call from your event loop when pollTimer fires
--       start() / stop()    - arm / disarm the poll timer
--       isTriggered(id)     - current (latched until next edge) state
--
-- The controller keeps a latched "triggered" state per input until the input
-- returns to its idle level, so a short pulse is not lost between polls.
-- ============================================

return function(bunkerlib)
    -- Protected read of one input (relay or local computer redstone).
    local function readSide(inp, side)
        local ok, val
        if inp.relay then
            if inp.analog then
                ok, val = pcall(peripheral.call, inp.relay, "getAnalogInput", side)
            else
                ok, val = pcall(peripheral.call, inp.relay, "getInput", side)
            end
        else
            if inp.analog then
                ok, val = pcall(rs.getAnalogInput, side)
            else
                ok, val = pcall(rs.getInput, side)
            end
        end
        if not ok or val == nil then return nil end

        if inp.analog then
            local thr = tonumber(inp.threshold) or 1
            local on = (tonumber(val) or 0) >= thr
            if inp.invert then on = not on end
            return on
        else
            local on = not not val
            if inp.invert then on = not on end
            return on
        end
    end

    local function readInput(inp)
        local sides = inp.side
        if sides == nil then return nil end
        if type(sides) ~= "table" then sides = { sides } end
        if #sides == 0 then return nil end

        -- OR across all listed sides: any powered side counts as ON.
        local saw = false
        local anyOn = false
        for _, side in ipairs(sides) do
            local on = readSide(inp, side)
            if on ~= nil then
                saw = true
                if on then anyOn = true end
            end
        end
        if not saw then return nil end
        return anyOn
    end

    -- Create a polling controller for a set of alarm inputs.
    -- conf.inputs     = list of input configs (see header).
    -- conf.onTrigger  = function(input, state) called on every edge
    --                   (state = true = just armed/ON, false = released/OFF).
    -- conf.pollInterval = seconds between polls (default 0.5).
    function bunkerlib.alarmin_create(conf)
        conf = conf or {}
        local inputs = conf.inputs or {}
        local onTrigger = conf.onTrigger
        local interval = tonumber(conf.pollInterval) or 0.5

        local lastState = {}   -- id -> last observed ON/OFF (nil = never read)
        local latched   = {}   -- id -> latched triggered state (edge buffer)
        local pollTimer = nil
        local running   = false

        -- stable id per input (label or index-based)
        local function inputId(inp, idx)
            return inp.id or inp.label or (idx .. ":" .. tostring(inp.relay or "local") .. "/" .. tostring(inp.side or "?"))
        end

        local function fire(inp, state)
            if onTrigger then
                local ok, err = pcall(onTrigger, inp, state)
                if not ok then
                    -- never let a bad callback kill the poller
                    if bunkerlib.printOnce then
                        bunkerlib.printOnce({}, "alarmin.cb", "alarmin callback error: " .. tostring(err))
                    end
                end
            end
        end

        -- Read all inputs once; detect rising/falling edges and fire callbacks.
        local function poll()
            for idx, inp in ipairs(inputs) do
                local id = inputId(inp, idx)
                local cur = readInput(inp)
                if cur ~= nil then
                    local prev = lastState[id]
                    if prev == nil then
                        -- First read: establish baseline. If the input is
                        -- already powered at boot, still fire once - a stuck
                        -- panic/smoke line must not be silent after a restart.
                        lastState[id] = cur
                        latched[id] = cur
                        if cur then fire(inp, true) end
                    elseif cur ~= prev then
                        lastState[id] = cur
                        if cur then
                            -- rising edge: input just went ON (triggered)
                            latched[id] = true
                            fire(inp, true)
                        else
                            -- falling edge: input released
                            latched[id] = false
                            fire(inp, false)
                        end
                    end
                    -- no change: keep latched state as-is
                end
            end
        end

        local function armTimer()
            if pollTimer then pcall(os.cancelTimer, pollTimer) end
            if running then
                pollTimer = os.startTimer(interval)
            else
                pollTimer = nil
            end
        end

        local ctrl = {}

        function ctrl.poll()
            poll()
        end

        -- Call this from your event loop when `pollTimer` fires:
        --   elseif event == "timer" and alarmIn.tick(p1) then ... end
        -- Returns true when the timerId belonged to this controller.
        function ctrl.tick(timerId)
            if pollTimer and timerId == pollTimer then
                pollTimer = nil
                if running then
                    poll()
                    armTimer()
                end
                return true
            end
            return false
        end

        function ctrl.start()
            if running then return end
            running = true
            poll()          -- baseline read on start (no edge fires for first state)
            armTimer()
        end

        function ctrl.stop()
            running = false
            if pollTimer then pcall(os.cancelTimer, pollTimer) end
            pollTimer = nil
        end

        function ctrl.isTriggered(id)
            return latched[id] or false
        end

        function ctrl.isRunning()
            return running
        end

        return ctrl
    end

    -- Convenience alias matching the planned public name.
    bunkerlib.alarmin = { create = bunkerlib.alarmin_create }
end
