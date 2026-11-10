-- Real KOReader LuaJIT/libz; compression behavior is covered by zlib_spec.lua.
package.path = (os.getenv("PLUGIN_PATH") or "/opt/plugin") .. "/?.lua;" .. package.path
local ffi = require("ffi")
require("ffi/loadlib")
local order = assert(arg[1])
assert(order == "fastdict-first" or order == "acsm-first")

-- Competing ABI from Floating Dictionary / Page Scrubber:
-- https://github.com/DisastrousPatience83/Floating-Dictionary.koplugin/blob/dfec69162c3fdb302ebc6696025f771cd680bc0a/dictzip.lua
local function loadFastDictBindings()
    ffi.cdef([[
        typedef struct fastdict_z_stream {
            const uint8_t *next_in;
            unsigned avail_in;
            unsigned long total_in;
            uint8_t *next_out;
            unsigned avail_out;
            unsigned long total_out;
            const char *msg;
            void *state;
            void *zalloc;
            void *zfree;
            void *opaque;
            int data_type;
            unsigned long adler;
            unsigned long reserved;
        } fastdict_z_stream;
        int inflateInit2_(fastdict_z_stream *strm, int windowBits, const char *version, int stream_size);
        int inflate(fastdict_z_stream *strm, int flush);
        int inflateEnd(fastdict_z_stream *strm);
        const char *zlibVersion(void);
    ]])
end

if order == "fastdict-first" then
    loadFastDictBindings()
end
local zlib = require("adobe.util.zlib")
if order == "acsm-first" then
    loadFastDictBindings()
end

-- KOReader's own wrapper compresses real data independently of ACSM's types.
local data = "zlib load order"
local wrapped = require("ffi/zlib").zlib_compress(data)
local raw = wrapped:sub(3, -5) -- strip the zlib header and Adler-32 trailer

-- rawInflater is the conversion path that failed in issue #27.
local inflater = assert(zlib.rawInflater())
local chunks = {}
assert(inflater:update(raw, #raw, function(ptr, len)
    chunks[#chunks + 1] = ffi.string(ptr, len)
    return true
end))
inflater:finalize()
assert(table.concat(chunks) == data)

assert(zlib.inflateRaw(raw) == data)

-- The other plugin must keep working too, including when ACSM loads first.
local libz = ffi.loadlib("z", 1)
local stream = ffi.new("fastdict_z_stream[1]")
assert(libz.inflateInit2_(stream, -15, libz.zlibVersion(), ffi.sizeof(stream[0])) == 0)
local out = ffi.new("uint8_t[?]", #data)
stream[0].next_in = ffi.cast("const uint8_t *", raw)
stream[0].avail_in = #raw
stream[0].next_out = out
stream[0].avail_out = #data
local result = libz.inflate(stream, 0)
assert(libz.inflateEnd(stream) == 0)
assert(result == 1)
assert(ffi.string(out, #data) == data)
