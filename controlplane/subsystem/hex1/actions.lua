-- ============================================
-- MAMDANI OS - module: ACTIONS
-- Generic control-panel actions (what a button press sends).
-- Loaded by bunkerlib.lua (do not require directly).
-- Door actions live in lib/doors.lua (they belong to their controllers).
-- ============================================

return function(bunkerlib)
    -- An action defines what a monitor button press sends. The `cmd` of the
    -- action must match the `cmd` of the client device.
    bunkerlib.ACTIONS = {
        light = function(status, id)
            return { room = id, cmd = "light", state = not status.state }
        end,
    }
end