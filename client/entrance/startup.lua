-- ============================================
-- MAMDANI OS - CLIENT
-- Adjust config below, then copy as startup.lua
-- to the room computer. Also copy bunkerlib.lua
-- into the same folder.
-- ============================================

local dir = fs.getDir(shell.getRunningProgram())
package.path = fs.combine(dir, "?.lua") .. ";" .. package.path
local bunkerlib = require("bunkerlib")

-- ============ CONFIG (edit here!) ============
local NAME           = "Entrance"
local MODEM_SIDE     = "back"   -- e.g. "left"; nil = auto-detect
local UPDATE_INTERVAL = 5 -- status heartbeat (plain on/off goes out instantly)

-- Every device this computer controls.
-- `driver` selects HOW it is controlled:
--   "relay"    -> through a redstone relay peripheral (`relay` + `side`)
--   "redstone" -> directly on a computer redstone output (only `side`)
-- `cmd` is the command it reacts to - must match the panel's `action`
--   in the control room. `id` must match the control panel's entry.
local DEVICES = {
    { id = "entrance", cmd = "light", driver = "relay", relay = "redstone_relay_6", side = "right" },
    -- { id = "door1", cmd = "light", driver = "redstone", side = "front" },
}

-- ============ START ============
bunkerlib.runClient({
    name      = NAME,
    modemSide = MODEM_SIDE,
    interval  = UPDATE_INTERVAL,
    devices   = DEVICES,
})