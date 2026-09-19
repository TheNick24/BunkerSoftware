-- ============================================
-- MAMDANI OS - DEPLOY RECEIVER
--
-- One-time install on every computer that should receive updates
-- wirelessly. After the FIRST deploy the generated startup.lua launcher
-- runs this together with the main program on every boot, so this manual
-- run is only needed once per computer.
--
-- Copy this file once to each computer (floppy, Pastebin, or manually)
-- and run:  receiver
--
-- Protocol (with deploy/startup.lua):
--   admin -> receiver:  { action="file", file, index, total, chunk }  "bunker_deploy"
--   receiver -> admin:  { action="ack",  file }                       "bunker_deploy"
--   admin -> receiver:  { action="reboot" }                           "bunker_deploy"
--   admin -> receiver:  { action="update" }                           "bunker_deploy"
--                         -> receiver runs update.lua: pulls the newest
--                            files over HTTP from GitHub, then reboots
--                            (the actual data never travels over rednet).
-- ============================================

local function openModem()
    for _, side in ipairs({ "back", "left", "right", "top", "bottom", "front" }) do
        if (rednet.isOpen(side) or pcall(rednet.open, side)) and rednet.isOpen(side) then
            return side
        end
    end
    for _, side in ipairs(rs.getSides()) do
        if not rednet.isOpen(side) then
            if pcall(rednet.open, side) and rednet.isOpen(side) then
                return side
            end
        end
    end
    return nil
end

local modem = openModem()
if not modem then
    term.setTextColor(colors.red)
    print("No modem found - receiver cannot start.")
    term.setTextColor(colors.white)
    return
end

term.setTextColor(colors.cyan)
print("=== MAMDANI DEPLOY RECEIVER ===")
term.setTextColor(colors.white)
print("Computer ID: " .. os.getComputerID())
print("Modem: " .. modem)
print("Waiting for deploy...")

local buffers = {}

while true do
    local e, senderId, p2, p3 = os.pullEvent()
    if e == "rednet_message" and p3 == "bunker_deploy" and type(p2) == "table" then
        local m = p2
        if m.action == "file" and m.file and m.chunk and m.index then
            local b = buffers[m.file]
            if not b or b.total ~= m.total then
                b = { data = {}, received = 0, total = m.total or 1 }
                buffers[m.file] = b
            end
            if not b.data[m.index] then
                b.data[m.index] = m.chunk
                b.received = b.received + 1
            end
            if b.received >= b.total then
                local parts = {}
                for i = 1, b.total do
                    parts[i] = b.data[i] or ""
                end
                local f = fs.open(m.file, "w")
                f.write(table.concat(parts, ""))
                f.close()
                buffers[m.file] = nil
                term.setTextColor(colors.green)
                print("saved " .. m.file .. " (" .. b.total .. " chunk(s))")
                term.setTextColor(colors.white)
                if type(senderId) == "number" then
                    rednet.send(senderId, { action = "ack", file = m.file }, "bunker_deploy")
                    term.setTextColor(colors.yellow)
                    print("ack " .. m.file)
                    term.setTextColor(colors.white)
                end
            end
        elseif m.action == "reboot" then
            term.setTextColor(colors.yellow)
            print("REBOOT")
            term.setTextColor(colors.white)
            os.sleep(0.5)
            os.reboot()
        elseif m.action == "update" then
            -- manual update trigger: the DATA goes over HTTP from GitHub,
            -- rednet only says "please update now".
            term.setTextColor(colors.yellow)
            print("UPDATE triggered - pulling from GitHub ...")
            term.setTextColor(colors.white)
            if type(senderId) == "number" then
                rednet.send(senderId, { action = "ack", file = "update" }, "bunker_deploy")
            end
            if fs.exists("update.lua") then
                shell.run("update.lua")
            else
                os.reboot()
            end
        end
    end
end