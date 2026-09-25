-- ============================================
-- MAMDANI OS - module: ALARMCONFIG
-- Shared static device lists for the control server AND every screen
-- server instance. One source of truth so multiple servers stay in sync.
-- Loaded by bunkerlib.lua (do not require directly).
-- ============================================

return function(bunkerlib)
    -- Device groups. Rooms are regular rooms, special groups are NOT part of
    -- a room (corridor lamps, doors, ...). Each entry needs a unique `id`.
    bunkerlib.rooms = {
        { id = "entrance", name = "Entrance" },
        { id = "me",       name = "ME-Core" },
        { id = "control",  name = "Control-Room" },
        { id = "maschine-room", name = "Maschine Room" },
    }

    bunkerlib.aux = {
        { id = "me-corridor-1", name = "ME Corridor 1" },
        { id = "me-corridor-2", name = "ME Corridor 2" },
        { id = "maschine-corridor-1", name = "Maschine Corridor 1" },
        { id = "control-corridor-1",  name = "CR Corridor 1"}
    }

    -- Doors. Same pattern as the light groups.
    bunkerlib.doors = {
        { id = "Control Door 1", name = "Control Door 1" },
        { id = "Control Door 2", name = "Control Door 2" },
        { id = "server-door", name = "Server Access Door"},
    }

    -- Alarm sirens (Mekanism Industrial Alarm etc.): OUTPUTS powered while the
    -- alarm is ON. One row per redstone relay/side on a client. To add another
    -- block: entry here (unique id) + matching device row in the client's
    -- DEVICES list.
    bunkerlib.alarmSirens = {
        { id = "alarm-siren", name = "Mekanism Alarm" },
    }

    -- Safety doors: ALARM doors that normally stand OPEN and only close in an
    -- emergency. emergencyDoors() finds them via the status table (cmd =
    -- "safety-door"), this list is for the panels.
    bunkerlib.safetyDoors = {
        { id = "me-safety-1",          name = "ME Safety Door 1" },
        { id = "me-safety-2",          name = "ME Safety Door 2" },
        { id = "distributor-safety-1", name = "Distributor Safety Door" },
    }

    -- Doors the alarm LOCKS (set = true). Previously scanned from the monitor
    -- panels' `lock = true` entries; explicit here because screen servers may
    -- show only a subset of the panels.
    bunkerlib.lockableDoors = {
        ["Control Door 1"] = true,
        ["Control Door 2"] = true,
    }
end
