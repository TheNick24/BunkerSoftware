-- Bunker Installer (runs on a fresh computer via diskette startup)
-- Copies bunker scripts into the computer's internal storage and sets up autostart.
-- Usage: install <server|client> [raum_id]

local args = {...}
local choice = args[1]

local function yes(prompt)
    io.write(prompt .. " [j/n] ")
    local a = io.read()
    return a:lower():sub(1, 1) == "j"
end

print("=== BUNKER NETZWERK INSTALLER ===")
local label = os.getComputerLabel()
if label then
    print("Dieser Computer: " .. label .. " (ID " .. os.getComputerID() .. ")")
else
    print("Dieser Computer: ID " .. os.getComputerID())
end

if not choice then
    print("Soll dieser Computer werden:")
    print("  [s] Server (Control-Raum)")
    print("  [c] Client (Raum)")
    io.write("Wahl (s/c): ")
    choice = io.read():lower()
    if choice == "s" then choice = "server" elseif choice == "c" then choice = "client" end
end

choice = choice:lower()

if choice == "server" or choice == "s" then
    if not fs.exists("bunker") then fs.makeDir("bunker") end
    for _, f in ipairs({"config.lua", "server.lua", "client.lua"}) do
        if fs.exists("disk/" .. f) then
            local src = fs.open("disk/" .. f, "r")
            local dst = fs.open("bunker/" .. f, "w")
            dst.write(src.readAll())
            dst.close(); src.close()
            print("  -> bunker/" .. f)
        else
            print("  (fehlt: " .. f .. ")")
        end
    end
    -- Autostart
    local st = fs.open("bunker/startup.lua", "w")
    st.write('shell.run("bunker/server")\n')
    st.close()
    print("Server eingerichtet. Autostart aktiviert (bunker/server).")
    print("Vergiss nicht: config.lua anpassen und Modem an back anschließen!")

elseif choice == "client" or choice == "c" then
    local roomId = args[2]
    if not roomId then
        print("Bitte Raum-ID angeben, z.B.:")
        print("  install client atrium")
        print("Verfügbare Räume (aus config.lua):")
        -- print rooms from config if available
        print("  (siehe config.lua)")
        return
    end
    if not fs.exists("bunker") then fs.makeDir("bunker") end
    for _, f in ipairs({"config.lua", "client.lua"}) do
        if fs.exists("disk/" .. f) then
            local src = fs.open("disk/" .. f, "r")
            local dst = fs.open("bunker/" .. f, "w")
            dst.write(src.readAll())
            dst.close(); src.close()
            print("  -> bunker/" .. f)
        end
    end
    local st = fs.open("bunker/startup.lua", "w")
    st.write('shell.run("bunker/client ' .. roomId .. '")\n')
    st.close()
    print("Client (" .. roomId .. ") eingerichtet. Autostart aktiviert.")

else
    print("Unbekannte Rolle: " .. tostring(choice))
    print("Benutzung: install server | install client <raum_id>")
end
