--- Pure Lua implementation of RC4 stream cipher.
-- Used by ADEPT PDF encryption (V=1, V=2, V=3).
-- This is the "arcfour" / "RC4" algorithm as described in RFC 6229.

local ffi = require("ffi")

local rc4 = {}

--- Initialize RC4 keystream state from key.
-- @param key string (bytes) the encryption key
-- @return table with S-box state and i,j indices
function rc4.init(key)
    local S = ffi.new("uint8_t[256]")
    for i = 0, 255 do
        S[i] = i
    end
    local j = 0
    for i = 0, 255 do
        j = (j + S[i] + key:byte((i % #key) + 1)) % 256
        S[i], S[j] = S[j], S[i]
    end
    return { S = S, i = 0, j = 0 }
end

--- Process data through RC4 keystream (encrypt or decrypt — same operation).
-- @param state table from rc4.init()
-- @param data string (bytes) input data
-- @return string (bytes) output data (same length)
function rc4.crypt(state, data)
    local S = state.S
    local ii = state.i
    local jj = state.j
    local out = {}
    for n = 1, #data do
        ii = (ii + 1) % 256
        jj = (jj + S[ii]) % 256
        S[ii], S[jj] = S[jj], S[ii]
        local k = S[(S[ii] + S[jj]) % 256]
        out[n] = string.char(bit.band(bit.bxor(data:byte(n), k), 0xFF))
    end
    state.i = ii
    state.j = jj
    return table.concat(out)
end

return rc4
