local zlib = {}

local ffi = require("ffi")

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
if ffi.loadlib then
    libz = ffi.loadlib("z", "1")
else
    libz = ffi.load("z")
end

local Z_OK = 0
local Z_STREAM_END = 1
local Z_NO_FLUSH = 0
local Z_BUF_ERROR = -5
local CHUNK_SIZE = 32768

local function inflateWithWindowBits(data, window_bits)
    local stream = ffi.new("z_stream[1]")
    stream[0].next_in = ffi.cast("Bytef *", data)
    stream[0].avail_in = #data

    local rc = libz.inflateInit2_(stream, window_bits, libz.zlibVersion(), ffi.sizeof(stream[0]))
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

function zlib.inflateRaw(data)
    return inflateWithWindowBits(data, -15)
end

function zlib.inflateGzip(data)
    return inflateWithWindowBits(data, 15 + 32)
end

return zlib
