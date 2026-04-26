local zlib = {}

local ffi = require("ffi")

local isAndroid = pcall(require, "android")

ffi.cdef [[
typedef void *voidpf;
typedef unsigned char Bytef;
typedef unsigned int uInt;
typedef unsigned long uLong;

typedef voidpf (*alloc_func)(voidpf opaque, uInt items, uInt size);
typedef void   (*free_func)(voidpf opaque, voidpf address);

typedef struct z_stream_s {
  Bytef    *next_in;
  uInt     avail_in;
  uLong    total_in;

  Bytef    *next_out;
  uInt     avail_out;
  uLong    total_out;

  char     *msg;
  void     *state;

  alloc_func zalloc;
  free_func  zfree;
  voidpf     opaque;

  int      data_type;
  uLong    adler;
  uLong    reserved;
} z_stream;

const char *zlibVersion(void);
int inflateInit2_(z_stream *strm, int windowBits, const char *version, int stream_size);
int inflate(z_stream *strm, int flush);
int inflateEnd(z_stream *strm);
]]

pcall(require, "ffi/loadlib")

local libz
if isAndroid then
    -- Same as nativecrypto.lua: monolibtic doesn't export zlib symbols.
    -- Copy system libz to app data dir and load from there.
    local android = require("android")
    local sys_libz = "/system/lib64/libz.so"
    local local_libz = android.dir .. "/libz.so"
    local cached = io.open(local_libz, "rb")
    if cached then
        cached:close()
    else
        local src = io.open(sys_libz, "rb")
        if src then
            local data = src:read("*a")
            src:close()
            local dst = io.open(local_libz, "wb")
            if dst then
                dst:write(data)
                dst:close()
            end
        end
    end
    libz = ffi.load(local_libz)
elseif ffi.loadlib then
    libz = ffi.loadlib("z", "1")
else
    libz = ffi.load("z")
end

local Z_OK = 0
local Z_STREAM_END = 1
local Z_NO_FLUSH = 0
local Z_BUF_ERROR = -5
local CHUNK_SIZE = 32768

function zlib.inflateRaw(data)
    local stream = ffi.new("z_stream[1]")
    stream[0].next_in = ffi.cast("Bytef *", data)
    stream[0].avail_in = #data

    local rc = libz.inflateInit2_(stream, -15, libz.zlibVersion(), ffi.sizeof(stream[0]))
    if rc ~= Z_OK then
        return nil, "inflateInit2 failed: " .. tostring(rc)
    end

    local outbuf = ffi.new("uint8_t[?]", CHUNK_SIZE)
    local chunks = {}

    while true do
        stream[0].next_out = outbuf
        stream[0].avail_out = CHUNK_SIZE

        rc = libz.inflate(stream, Z_NO_FLUSH)
        local produced = CHUNK_SIZE - tonumber(stream[0].avail_out)
        if produced > 0 then
            chunks[#chunks + 1] = ffi.string(outbuf, produced)
        end

        if rc == Z_STREAM_END then
            break
        end
        if rc == Z_OK then
            -- keep going
        elseif rc == Z_BUF_ERROR and produced > 0 then
            -- zlib needs another output buffer
        else
            libz.inflateEnd(stream)
            return nil, "inflate failed: " .. tostring(rc)
        end
    end

    libz.inflateEnd(stream)
    return table.concat(chunks)
end

--- Create a streaming raw inflater.
-- Returns an object with :update(chunk) and :finalize() methods.
-- Each :update() returns the inflated output for that chunk.
-- :finalize() cleans up the zlib stream.
-- Peak memory per update: 32KB output buffer (reused).
function zlib.rawInflater()
    local stream = ffi.new("z_stream[1]")
    local rc = libz.inflateInit2_(stream, -15, libz.zlibVersion(), ffi.sizeof(stream[0]))
    if rc ~= Z_OK then
        return nil, "inflateInit2 failed: " .. tostring(rc)
    end

    local outbuf = ffi.new("uint8_t[?]", CHUNK_SIZE)
    local finished = false

    local inflater = {}

    function inflater:update(chunk)
        if finished then return nil, "inflater already finalized" end
        stream[0].next_in = ffi.cast("Bytef *", chunk)
        stream[0].avail_in = #chunk

        local parts = {}
        while stream[0].avail_in > 0 do
            stream[0].next_out = outbuf
            stream[0].avail_out = CHUNK_SIZE

            rc = libz.inflate(stream, Z_NO_FLUSH)
            local produced = CHUNK_SIZE - tonumber(stream[0].avail_out)
            if produced > 0 then
                parts[#parts + 1] = ffi.string(outbuf, produced)
            end

            if rc == Z_STREAM_END then
                finished = true
                break
            end
            if rc ~= Z_OK and (rc ~= Z_BUF_ERROR or produced == 0) then
                libz.inflateEnd(stream)
                return nil, "inflate failed: " .. tostring(rc)
            end
        end
        return table.concat(parts)
    end

    function inflater:finalize()
        if not finished then
            libz.inflateEnd(stream)
        end
        finished = true
    end

    return inflater
end

return zlib
