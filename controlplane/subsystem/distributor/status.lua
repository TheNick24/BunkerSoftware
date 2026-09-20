-- ============================================
-- MAMDANI OS - module: STATUS
-- Device status cache (received from bunker_status broadcasts).
-- Loaded by bunkerlib.lua (do not require directly).
-- ============================================

return function(bunkerlib)
    function bunkerlib.setStatus(statuses, id, senderId, state, cmd)
        statuses[id] = {
            state = state,
            cmd = cmd,
            senderId = senderId,
            lastSeen = os.clock(),
        }
    end

    function bunkerlib.cleanStatuses(statuses, timeout)
        for id, s in pairs(statuses) do
            if os.clock() - s.lastSeen > timeout then
                statuses[id] = nil
            end
        end
    end
end