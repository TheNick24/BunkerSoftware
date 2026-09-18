-- ============================================
-- MAMDANI OS - module: CRYPTO
-- SHA-256 + PBKDF2-HMAC-SHA256 password hashing.
-- Loaded by bunkerlib.lua (do not require directly).
-- ============================================

local band    = bit32.band
local bxor    = bit32.bxor
local rrotate = bit32.rrotate
local rshift  = bit32.rshift

local SHA256_K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- msg: string; raw=true returns the 32 raw bytes, default returns hex.
local function sha256(msg, raw)
    local len = #msg * 8
    msg = msg .. "\128"
    while #msg % 64 ~= 56 do msg = msg .. "\0" end
    local h32 = math.floor(len / 4294967296)
    local l32 = len % 4294967296
    msg = msg .. string.char(
        0, 0, 0, 0,
        math.floor(h32 / 16777216) % 256, math.floor(h32 / 65536) % 256,
        math.floor(h32 / 256) % 256, h32 % 256,
        math.floor(l32 / 16777216) % 256, math.floor(l32 / 65536) % 256,
        math.floor(l32 / 256) % 256, l32 % 256
    )
    local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    for chunk = 0, #msg - 1, 64 do
        local W = {}
        for t = 0, 15 do
            local o = chunk + t * 4
            W[t] = (string.byte(msg,o+1) or 0) * 16777216
                 + (string.byte(msg,o+2) or 0) * 65536
                 + (string.byte(msg,o+3) or 0) * 256
                 + (string.byte(msg,o+4) or 0)
        end
        for t = 16, 63 do
            local s0 = bxor(rrotate(W[t-15],7), rrotate(W[t-15],18), rshift(W[t-15],3))
            local s1 = bxor(rrotate(W[t-2],17), rrotate(W[t-2],19), rshift(W[t-2],10))
            W[t] = band(W[t-16] + s0 + W[t-7] + s1)
        end
        local a,b,c,d,e,f,g,h = H[1],H[2],H[3],H[4],H[5],H[6],H[7],H[8]
        for t = 0, 63 do
            local S1 = bxor(rrotate(e,6), rrotate(e,11), rrotate(e,25))
            local ch = band(e,f) + band(bxor(e,0xFFFFFFFF),g)
            local t1 = band(h + S1 + ch + SHA256_K[t+1] + W[t])
            local S0 = bxor(rrotate(a,2), rrotate(a,13), rrotate(a,22))
            local maj = band(a,b) + band(a,c) + band(b,c)
            local t2 = band(S0 + maj)
            h=g; g=f; f=e; e=band(d+t1); d=c; c=b; b=a; a=band(t1+t2)
        end
        H[1]=band(H[1]+a); H[2]=band(H[2]+b); H[3]=band(H[3]+c); H[4]=band(H[4]+d)
        H[5]=band(H[5]+e); H[6]=band(H[6]+f); H[7]=band(H[7]+g); H[8]=band(H[8]+h)
    end
    if raw then
        local bin = {}
        for i = 1, 8 do
            local v = H[i]
            bin[i] = string.char(
                math.floor(v / 16777216) % 256,
                math.floor(v / 65536) % 256,
                math.floor(v / 256) % 256,
                v % 256)
        end
        return table.concat(bin)
    end
    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
        H[1],H[2],H[3],H[4],H[5],H[6],H[7],H[8])
end

-- ============ PASSWORD HASHING (PBKDF2-HMAC-SHA256) ============
-- A "real" scheme for stored secrets: random salt + key stretching, so the
-- stored value is not a plain (rainbow-table friendly) SHA-256 of the secret.
-- Stored format: "pbkdf2$<saltHex>$<iterations>$<keyHex>"
-- Legacy hashes (plain sha256 hex) are still verified for compatibility, but
-- re-running "control setup" upgrades them to this format.

local PBKDF2_ITERATIONS = 1000

if os.epoch and os.getComputerID then
    math.randomseed(os.epoch("utc") + os.getComputerID())
end

local HEX = "0123456789abcdef"

local function toHex(s)
    local out = {}
    for i = 1, #s do
        local b = string.byte(s, i)
        local hi = math.floor(b / 16)
        local lo = b % 16
        out[#out + 1] = HEX:sub(hi + 1, hi + 1) .. HEX:sub(lo + 1, lo + 1)
    end
    return table.concat(out)
end

local function fromHex(s)
    s = s:lower()
    local out = {}
    for i = 1, #s - 1, 2 do
        local hi = string.find(HEX, s:sub(i, i), 1) - 1
        local lo = string.find(HEX, s:sub(i + 1, i + 1), 1) - 1
        out[#out + 1] = string.char(hi * 16 + lo)
    end
    return table.concat(out)
end

local function randomBytes(n)
    local out = {}
    for _ = 1, n do out[#out + 1] = string.char(math.random(0, 255)) end
    return table.concat(out)
end

-- HMAC-SHA256. Returns the 32 raw bytes.
local function hmacSha256(key, msg)
    local block = 64
    if #key > block then key = sha256(key, true) end
    local kp = key .. string.rep("\0", block - #key)
    local ipad, opad = {}, {}
    for i = 1, block do
        local b = string.byte(kp, i)
        ipad[i] = string.char(bit32.bxor(b, 0x36))
        opad[i] = string.char(bit32.bxor(b, 0x5c))
    end
    local inner = sha256(table.concat(ipad) .. msg, true)
    return sha256(table.concat(opad) .. inner, true)
end

-- PBKDF2-HMAC-SHA256, single 32-byte block (dkLen = 32). Returns raw bytes.
local function pbkdf2(password, salt, iterations)
    local u = hmacSha256(password, salt .. "\0\0\0\1")
    local t = {}
    for i = 1, #u do t[i] = string.byte(u, i) end
    for _ = 2, iterations do
        u = hmacSha256(password, u)
        for i = 1, #u do t[i] = bit32.bxor(t[i], string.byte(u, i)) end
    end
    local out = {}
    for i = 1, #u do out[i] = string.char(t[i]) end
    return table.concat(out)
end
-- end of PBKDF2 helper section

return function(bunkerlib)
    bunkerlib.sha256 = sha256

    -- Hashes a secret into the portable storage format.
    function bunkerlib.hashPassword(secret, iterations)
        local it = iterations or PBKDF2_ITERATIONS
        local salt = randomBytes(16)
        local dk = pbkdf2(secret, salt, it)
        return "pbkdf2$" .. toHex(salt) .. "$" .. it .. "$" .. toHex(dk)
    end

    -- Verifies a secret against a stored value (new or legacy sha256 format).
    function bunkerlib.verifyPassword(secret, stored)
        if not stored or stored == "" then return false end
        if not stored:match("^pbkdf2%$") then
            return sha256(secret) == stored
        end
        local algo, saltHex, itStr, dkHex = stored:match("^(pbkdf2)%$(%w+)$(%d+)$(%w+)$")
        if not algo then return false end
        local dk = pbkdf2(secret, fromHex(saltHex), tonumber(itStr))
        return toHex(dk) == dkHex
    end
end