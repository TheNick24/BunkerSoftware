-- ============================================
-- MAMDANI OS - HTTP INSTALLER
--
-- Downloads the repository files over HTTP from BASE_URL. Host the repo
-- somewhere reachable (GitHub raw, your own web server, ...) and run this
-- on a computer:
--
--   Admin computer (gets the whole repo layout):
--       wget run <BASE_URL>/tools/install.lua
--
--   Target computer (one-time bootstrap: only the receiver, flat):
--       wget run <BASE_URL>/tools/install.lua receiver
--
-- BASE_URL must point at the REPOSITORY ROOT, so that BASE_URL/lib/network.lua
-- etc. resolve. Example (GitHub):
--   https://raw.githubusercontent.com/<user>/BunkerSoftware/main
-- ============================================

local BASE_URL = "https://raw.githubusercontent.com/TheNick24/BunkerSoftware/dev"

-- Everything the ADMIN computer needs (repo layout, relative paths).
local ALL_FILES = {
    "lib/bunkerlib.lua",
    "lib/network.lua",
    "lib/crypto.lua",
    "lib/status.lua",
    "lib/drivers.lua",
    "lib/actions.lua",
    "lib/doors.lua",
    "lib/monitor.lua",
    "lib/client.lua",
    "control/startup.lua",
    "client/entrance/startup.lua",
    "client/meroom/startup.lua",
    "client/distributor1/startup.lua",
    "client/control/startup.lua",
    "remote/startup.lua",
    "deploy/startup.lua",
    "deploy/receiver.lua",
    "tools/install.lua",
}

-- Follows redirects (http.get does not do that on its own).
local function httpGet(url, redirects)
    redirects = redirects or 0
    local res = http.get(url)
    if not res then return nil, "no response" end
    local code = res.getResponseCode()
    if code == 200 then
        local data = res.readAll()
        res.close()
        return data
    end
    if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
        local loc = res.getResponseHeaders() and res.getResponseHeaders()["location"]
        res.close()
        if loc and redirects < 5 then
            if loc:sub(1, 1) == "/" then
                local scheme, host = url:match("^(https?://[^/]+)")
                loc = (scheme or "") .. loc
            end
            return httpGet(loc, redirects + 1)
        end
    end
    res.close()
    return nil, "HTTP " .. tostring(code)
end

local function download(rel, localRel)
    localRel = localRel or rel
    local url = BASE_URL .. "/" .. rel
    local data, err = httpGet(url)
    if not data then
        term.setTextColor(colors.red)
        print("FAILED: " .. rel .. " (" .. tostring(err) .. ")")
        term.setTextColor(colors.white)
        return false
    end
    local dir = fs.getDir(localRel)
    if dir ~= "" and dir ~= "." and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local f = fs.open(localRel, "w")
    f.write(data)
    f.close()
    term.setTextColor(colors.green)
    print("saved " .. localRel .. " (" .. #data .. " b)")
    term.setTextColor(colors.white)
    return true
end

-- ============ MAIN ============
local args = { ... }
local mode = (args[1] or "all"):lower()
local quiet = mode == "quiet" -- used by `deploy update` (no banner/instructions)
if quiet then mode = "all" end

if not quiet then
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("=== MAMDANI OS - HTTP INSTALLER ===")
    term.setTextColor(colors.gray)
    print("Source: " .. BASE_URL)
    term.setTextColor(colors.white)
end

if not http then
    term.setTextColor(colors.red)
    print("HTTP API is disabled on this server/license!")
    term.setTextColor(colors.white)
    return
end

if mode == "receiver" then
    -- bootstraps the receiver FLAT into the root folder, so the command
    -- `receiver` works (deploy/startup.lua also looks for receiver.lua there)
    local ok = download("deploy/receiver.lua", "receiver.lua")
    print("")
    if ok then
        term.setTextColor(colors.yellow)
        print("Now run: receiver")
    end
    term.setTextColor(colors.white)
    return
end

-- full repo (admin computer)
local files = ALL_FILES
local okCount, failCount = 0, 0
for _, rel in ipairs(files) do
    if download(rel) then okCount = okCount + 1 else failCount = failCount + 1 end
end
print("")
if failCount == 0 then
    term.setTextColor(colors.green)
    print("Done. " .. okCount .. " files installed.")
else
    term.setTextColor(colors.yellow)
    print("Done. " .. okCount .. " ok, " .. failCount .. " failed.")
end
term.setTextColor(colors.yellow)
if not quiet then
    print("Next: run `deploy` (and set TARGETS in deploy/startup.lua).")
end
term.setTextColor(colors.white)