-- ============================================
-- MAMDANI OS - SHARED LIBRARY (loader)
--
-- bunkerlib.lua is now a pure loader: it loads the thematic modules and
-- combines them into one public table, so existing programs keep using
-- require("bunkerlib") unchanged.
--
-- Copy the WHOLE lib/ bundle to EVERY computer that runs a MAMDANI
-- program, FLAT into the same folder as the program:
--
--   bunkerlib.lua, network.lua, crypto.lua, status.lua, drivers.lua,
--   actions.lua, doors.lua, gearshift.lua, monitor.lua, gfx.lua, client.lua
--
-- Load with:
--   local dir = fs.getDir(shell.getRunningProgram())
--   package.path = fs.combine(dir, "?.lua") .. ";" .. package.path
--   local bunkerlib = require("bunkerlib")
-- ============================================

local dir = fs.getDir(shell.getRunningProgram())
package.path = fs.combine(dir, "?.lua") .. ";" .. package.path

local bunkerlib = {}

-- Each module is a mixin: require(name) returns a function that fills
-- the shared bunkerlib table. Order matters for cross-module links
-- (doors registers into bunkerlib's DRIVERS/ACTIONS, so drivers+actions first).
local function load(name)
    require(name)(bunkerlib)
end

load("network")   -- findModem, printOnce
load("crypto")    -- sha256, hashPassword, verifyPassword
load("status")    -- setStatus, cleanStatuses
load("drivers")   -- relayGet/Set, DRIVERS (relay, redstone), driver()
load("actions")   -- ACTIONS (light)
load("doors")     -- door controllers: DRIVERS.door + DRIVERS["safety-door"],
                  --                  ACTIONS.door + ACTIONS["safety-door"]
load("gearshift") -- sequenced gearshift doors: bunkerlib.gearshift.create()
load("monitor")   -- drawHeader, drawInfoPlaceholder, drawFooter,
                  -- drawToggleTable, drawPanel
load("gfx")       -- 256-color graphics-mode drawing (cc-graphics mod)
load("energy")    -- induction-matrix telemetry: readInduction, broadcast,
                  --                   drawMonitor (reusable energy screen)
load("alarmin")   -- redstone alarm input polling: bunkerlib.alarmin.create()
load("client")    -- runClient

return bunkerlib