-- ============================================
-- MAMDANI OS - module: GEARSHIFT
-- Reusable controller for Create Sequenced Gearshift machines.
--
-- community is a state machine around Create's ASYNC movement: every move
-- is ordered and then "runs" for a while. This controller turns raw moves
-- into a full door/gate cycle:
--
--   closed -> opening (run OPEN motion) -> open (dwell) -> closing
--            (run CLOSE motion) -> closed
--
-- The motion is fully configurable, so the same controller drives all of:
--   * a piston/pulley door   - move down + reverse up
--   * a gantry gate          - move alongside + reverse (sideways travel)
--   * a rotating hatch       - rotate + rotate back
--   * multi-step machines    - a list of steps executed one after another
--
-- Between any two steps the controller waits until Create reports the
-- movement as finished (isRunning() == false), so quick steps can never
-- overwrite each other. Machines that do not report isRunning() fall back
-- to chaining the steps directly.
--
-- The controller owns all timing and only needs a single `tick()` call per
-- timer event from YOUR event loop, so it works in any client (runClient
-- via onEvent, or a custom loop). It refuses a second cycle while one is
-- running and sticks to the lock semantics of the shared "gearshift-door"
-- driver (a LOCKED machine never starts).
--
-- Motion steps:
--   { method = "move",  distance = 6, direction = -1 }   -- blocks along an axis
--   { method = "rotate", angle = 90 }                    -- degrees
--   { call = function(peripheral) ... end }              -- anything custom
-- `method = "piston"` is an alias for "move" (a piston travels linearly).
--
-- Usage:
--   local door = bunkerlib.gearshift.create({
--       devices     = { id = "Control Door 2", driver = "gearshift-door",
--                        peripheral = "Create_SequencedGearshift_1" },
--       motion = {
--           open  = { { method = "move", distance = 6, direction = 1 } },
--           close = { { method = "move", distance = 6, direction = -1 } },
--       },
--       openSeconds = 2,   -- dwell: whole seconds
--       openTicks   = 30,  -- dwell: additional game ticks (20/s)
--       onStateChange = function(state) ... end,
--   })
--   if door.open() then end      -- start the cycle; false = locked/busy
--   door.home()                  -- run the close motion once (boot/restore)
--
--   -- in the event loop:
--   if event == "timer" then door.tick(p1) end
--
-- States passed to onStateChange: "closed", "opening", "open", "closing".
--
-- Backwards compatibility: without `motion` the controller falls back to the
-- classic behaviour (open = move conf.distance along conf.openDirection,
-- close = the same distance in the opposite direction).
-- Loaded by bunkerlib.lua (do not require directly).
-- ============================================

return function(bunkerlib)
    local lib = bunkerlib

    local function pcallWrap(fn)
        local ok, res = pcall(fn)
        return ok, res
    end

    local function isRunning(peripheralName)
        local p = peripheral.wrap(peripheralName)
        if not p or type(p.isRunning) ~= "function" then return false end
        local ok, running = pcallWrap(function() return p.isRunning() end)
        return ok and running
    end

    -- Normalize a motion (single step table or list of steps) into a list.
    local function normalizeMotion(motion, fallback)
        if motion then
            if motion[1] and type(motion[1]) == "table" then
                return motion
            end
            return { motion }
        end
        return fallback
    end

    -- conf as documented above. `devices` (optional) is the driver config
    -- entry for lock/status handling (id, peripheral, distance, openDirection).
    bunkerlib.gearshift = bunkerlib.gearshift or {}
    function bunkerlib.gearshift.create(conf)
        local c = {
            timers = {},
            busy   = false,
            state  = "closed",
            conf   = conf,
        }

        local peripheralName = (conf.devices and conf.devices.peripheral)
            or conf.peripheral

        local function driver()
            return lib.driver("gearshift-door")
        end

        local function drvHas(fn)
            local drv = driver()
            return drv and drv[fn] ~= nil
        end

        local function onPhase(newState)
            c.state = newState
            if conf.onStateChange then pcallWrap(function() conf.onStateChange(newState) end) end
        end

        local function schedule(cb, seconds)
            local timer = os.startTimer(seconds)
            c.timers[timer] = cb
            return timer
        end

        -- Execute exactly one motion step against the machine.
        local function runStep(step, onDone, onError)
            local p = peripheral.wrap(peripheralName)
            if not p then onError("machine unavailable: " .. tostring(peripheralName)) return end
            local ok, err = pcallWrap(function()
                if step.call then
                    step.call(p)
                elseif step.method == "rotate" then
                    p.rotate(step.angle or 0, step.modifier)
                else
                    -- "move" (and its alias "piston"): linear travel along an
                    -- axis. Gantries just use a different direction here.
                    p.move(step.distance or 0, step.direction or 1, step.modifier)
                end
            end)
            if not ok then onError(err) return end

            -- chain the next step as soon as Create reports the machine idle
            local function waitIdle()
                if isRunning(peripheralName) then
                    schedule(waitIdle, 0.1)
                else
                    onDone()
                end
            end
            if p and type(p.isRunning) == "function" then
                schedule(waitIdle, 0.05)
            else
                onDone()
            end
        end

        -- Run a whole motion step-by-step, waiting for the machine between
        -- each step. `first`/`last` mark the software open/closed flag on
        -- the shared driver (used for status broadcasts and lock semantics).
        local function runMotion(kind, onFinished)
            local baseDir = tonumber(conf.openDirection)
                or tonumber(conf.devices and conf.devices.openDirection) or 1
            local dist = tonumber(conf.distance)
                or tonumber(conf.devices and conf.devices.distance) or 5
            local fallback = { { method = "move", distance = dist,
                                 direction = kind == "open" and baseDir or -baseDir } }
            local steps = normalizeMotion(conf.motion and conf.motion[kind], fallback)

            local idx = 1
            local function nextStep()
                if idx > #steps then
                    if drvHas("mark") and conf.devices then
                        pcallWrap(function() driver().mark(conf.devices, kind == "open") end)
                    end
                    onFinished()
                    return
                end
                local step = steps[idx]
                idx = idx + 1
                runStep(step, nextStep, function(err)
                    print("gearshift step error: " .. tostring(err))
                    c.busy = false
                    onPhase("closed")
                end)
            end
            nextStep()
        end

        -- Start a full open cycle. Returns true when the first move was
        -- ordered; false when the machine is locked or already cycling.
        function c.open()
            if c.busy then return false end
            if conf.devices and drvHas("isLocked") and driver().isLocked(conf.devices) then
                return false
            end
            c.busy = true
            onPhase("opening")
            runMotion("open", function()
                onPhase("open")
                schedule(function() c.busy = true; onPhase("closing"); runMotion("close", function() c.busy = false; onPhase("closed") end) end,
                    conf.openSeconds + (conf.openTicks or 0) / 20)
            end)
            return true
        end

        -- Run the close motion now (if the machine is not already cycling).
        -- Used at boot to establish the safe closed position.
        function c.close()
            if c.busy then return false end
            c.busy = true
            onPhase("closing")
            runMotion("close", function()
                c.busy = false
                onPhase("closed")
            end)
            return true
        end

        -- Alias for boot/restore.
        function c.home()
            return c.close()
        end

        function c.isBusy()
            return c.busy
        end

        function c.getState()
            return c.state
        end

        function c.isLocked()
            if not conf.devices or not drvHas("isLocked") then return false end
            return driver().isLocked(conf.devices) or false
        end

        function c.tick(timerId)
            local cb = c.timers[timerId]
            if not cb then return false end
            c.timers[timerId] = nil
            local ok, err = pcallWrap(cb)
            if not ok then
                -- One corrupted frame must never wedge the machine; drop back
                -- to a clean closed state and keep the client running.
                c.busy = false
                onPhase("closed")
                print("gearshift sequence error: " .. tostring(err))
            end
            return true
        end

        return c
    end
end