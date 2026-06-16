local zlib = {}

local ffi = require("ffi")

local isAndroid = pcall(require, "android")

ffi.cdef([[
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
]])

--- Resolve the system library directory for a given architecture.
-- Duplicated from nativecrypto.lua — cannot require() a shared module on Android
-- because KOReader's monolbtic resolver intercepts the require and fails.
-- See nativecrypto.lua for rationale.
local function systemLibDir(arch)
    if arch == "arm64" or arch == "x64" then
        return "/system/lib64"
    else
        return "/system/lib"
    end
end

--- Copy a system .so to the app's data dir and load it via FFI.
-- Duplicated from nativecrypto.lua for the same reason.
local function androidCopyLoad(lib_name, arch, data_dir)
    local sys_dir = systemLibDir(arch)
    local sys_path = sys_dir .. "/lib" .. lib_name .. ".so"
    local tagged_name = "lib" .. lib_name .. "." .. arch .. ".so"
    local local_path = data_dir .. "/" .. tagged_name

    -- Clean up legacy untagged cache
    local legacy = data_dir .. "/lib" .. lib_name .. ".so"
    local f = io.open(legacy, "rb")
    if f then
        f:close()
        os.remove(legacy)
    end

    local cached = io.open(local_path, "rb")
    if cached then
        cached:close()
    else
        local src = io.open(sys_path, "rb")
        if src then
            local data = src:read("*a")
            src:close()
            local dst = io.open(local_path, "wb")
            if dst then
                dst:write(data)
                dst:close()
            end
        end
    end

    return ffi.load(local_path)
end

-- Exposed for testing.
_zlib_systemLibDir = systemLibDir

pcall(require, "ffi/loadlib")

local libz
if isAndroid then
    -- Same as nativecrypto.lua: monolbtic doesn't export zlib symbols.
    local android = require("android")
    libz = androidCopyLoad("z", jit.arch, android.dir)
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

local buildInflater

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
        elseif rc ~= Z_OK and not (rc == Z_BUF_ERROR and produced > 0) then
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

    return buildInflater(stream)
end

--- Create a streaming zlib inflater (handles zlib header, not raw deflate).
function zlib.inflater()
    local stream = ffi.new("z_stream[1]")
    local rc = libz.inflateInit2_(stream, 15, libz.zlibVersion(), ffi.sizeof(stream[0]))
    if rc ~= Z_OK then
        return nil, "inflateInit2 failed: " .. tostring(rc)
    end
    return buildInflater(stream)
end

function buildInflater(stream)
    local outbuf = ffi.new("uint8_t[?]", CHUNK_SIZE)
    local finished = false

    local inflater = {}

    --- Inflate a chunk of compressed data.
    -- @param chunk     FFI pointer or Lua string containing compressed data
    -- @param chunk_len length of the chunk in bytes
    -- @param sink      function(ptr, len) called with each output block
    function inflater:update(chunk, chunk_len, sink)
        if finished then
            return nil, "inflater already finalized"
        end
        stream[0].next_in = ffi.cast("Bytef *", chunk)
        stream[0].avail_in = chunk_len

        while stream[0].avail_in > 0 do
            stream[0].next_out = outbuf
            stream[0].avail_out = CHUNK_SIZE

            local rc = libz.inflate(stream, Z_NO_FLUSH)
            local produced = CHUNK_SIZE - tonumber(stream[0].avail_out)
            if produced > 0 and sink then
                local ok, err = sink(outbuf, produced)
                if not ok then
                    return nil, err
                end
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
        return true
    end

    function inflater:finalize()
        if not finished then
            libz.inflateEnd(stream)
        end
        finished = true
    end

    inflater.close = inflater.finalize

    return inflater
end

return zlib
