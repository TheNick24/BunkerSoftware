-- ============================================
-- MAMDANI OS - CLIENT
-- Adjust config below, then copy as startup.lua
-- to the room computer. Also copy bunkerlib.lua
-- into the same folder.
-- ============================================

-- controlplane health marker (no-op without the agent)
if fs.exists("/controlplane") then
    local _hf = fs.open("/controlplane/health.marker", "w")
    if _hf then _hf.write("healthy\n") _hf.close() end
end

local dir = fs.getDir(shell.getRunningProgram())
package.path = fs.combine(dir, "?.lua") .. ";" .. package.path
local bunkerlib = require("bunkerlib")

-- ============ CONFIG (edit here!) ============
local NAME           = "Maschine Room"
local MODEM_SIDE     = "left"   -- e.g. "left"; nil = auto-detect
local UPDATE_INTERVAL = 5 -- status heartbeat (plain on/off goes out instantly)

-- Every device this computer controls.
-- `driver` selects HOW it is controlled:
--   "relay"    -> through a redstone relay peripheral (`relay` + `side`)
--   "redstone" -> directly on a computer redstone output (only `side`)
-- `cmd` is the command it reacts to - must match the panel's `action`
--   in the control room. `id` must match the control panel's entry.
local DEVICES = {
    { id = "maschine-room", cmd = "light", driver = "relay", relay = "redstone_relay_14", side = "top" },
    { id = "maschine-corridor-1", cmd = "light", driver = "relay", relay = "redstone_relay_14", side = "left" },
    { id = "me-corridor-2", cmd = "light", driver = "relay", relay = "redstone_relay_14", side = "right" }
}

-- Induction-matrix telemetry: read these peripherals and broadcast the values
-- so the control room (and any future local screen) can display energy.
-- Map = battery name -> { side, protocol, interval }. Add more batteries here
-- (e.g. "Battery - 2") as further induction cells come online.
local ENERGY_TELEMETRY = {
    ["Battery - 1"] = {
        side = "inductionPort_0",
        protocol = "bunker_energy",
        interval = 5,
    },
}

-- ============ START ============
bunkerlib.runClient({
    name      = NAME,
    modemSide = MODEM_SIDE,
    interval  = UPDATE_INTERVAL,
    devices   = DEVICES,
    telemetry = ENERGY_TELEMETRY,
})