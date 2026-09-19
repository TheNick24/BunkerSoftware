-- ============================================
-- MAMDANI OS - CLIENT
-- Adjust config below, then copy as startup.lua
-- to the room computer. Also copy bunkerlib.lua
-- into the same folder.
-- ============================================

local dir             = fs.getDir(shell.getRunningProgram())
package.path          = fs.combine(dir, "?.lua") .. ";" .. package.path
local bunkerlib       = require("bunkerlib")

-- ============ CONFIG (edit here!) ============
local NAME            = "ME-Core"
local MODEM_SIDE      = "left" -- e.g. "left"; nil = auto-detect
local UPDATE_INTERVAL = 5 -- status heartbeat (plain on/off goes out instantly)

-- Every device this computer controls.
-- `driver` selects HOW it is controlled:
--   "relay"    -> through a redstone relay peripheral (`relay` + `side`)
--   "redstone" -> directly on a computer redstone output (only `side`)
--   "door"     -> door contact/link bridge (`peripheral` + `side`, inverted)
-- `cmd` is the command it reacts to - must match the panel's `action`
--   in the control room. `id` must match the control panel's entry.
local DEVICES         = {
    { id = "me",            cmd = "light",       driver = "relay",    relay = "redstone_relay_7", side = "top" },
    { id = "me-corridor-1", cmd = "light",       driver = "relay",    relay = "redstone_relay_7", side = "right" },
    { id = "me-safety-1",   cmd = "safety-door", driver = "door",     peripheral = "redstone_relay_11", side = "front" },
}

-- ============ START ============
bunkerlib.runClient({
    name      = NAME,
    modemSide = MODEM_SIDE,
    interval  = UPDATE_INTERVAL,
    devices   = DEVICES,
})
