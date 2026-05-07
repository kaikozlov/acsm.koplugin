--- Integration tests: zlib inflate round-trip (P2)
-- Verifies zlib.inflateRaw (one-shot) and zlib.rawInflater (streaming)
-- using KOReader's bundled libz via FFI.
-- Test data is generated at runtime using libz's deflate.

describe("zlib inflate", function()
    local zlib, ffi, libz

    -- zlib constants
    local Z_OK = 0
    local Z_STREAM_END = 1
    local Z_FINISH = 4
    local Z_DEFAULT_COMPRESSION = -1
    local CHUNK_SIZE = 32768

    setup(function()
        ffi = require("ffi")

        -- Add deflate FFI defs (inflate defs already loaded by zlib.lua)
        ffi.cdef [[
            int deflateInit2_(z_stream *strm, int level, int method,
                              int windowBits, int memLevel, int strategy,
                              const char *version, int stream_size);
            int deflate(z_stream *strm, int flush);
            int deflateEnd(z_stream *strm);
        ]]

        zlib = require("adobe.util.zlib")

        -- Load libz the same way zlib.lua does
        local ok
        if ffi.loadlib then
            ok, libz = pcall(ffi.loadlib, "z", "1")
        end
        if not ok then
            libz = ffi.load("z")
        end
    end)

    --- Helper: compress data with zlib-wrapped deflate (2-byte header + checksum)
    local function zlibDeflate(data)
        local stream = ffi.new("z_stream[1]")
        local rc = libz.deflateInit2_(
            stream, Z_DEFAULT_COMPRESSION, 8,  -- method = DEFLATED
            15,                                 -- windowBits = 15 (zlib-wrapped)
            8,                                  -- memLevel
            0,                                  -- strategy = default
            libz.zlibVersion(), ffi.sizeof(stream[0])
        )
        if rc ~= Z_OK then
            return nil, "deflateInit2 failed: " .. rc
        end

        stream[0].next_in = ffi.cast("Bytef *", data)
        stream[0].avail_in = #data

        local outbuf = ffi.new("uint8_t[?]", #data + 256)
        stream[0].next_out = outbuf
        stream[0].avail_out = #data + 256

        rc = libz.deflate(stream, Z_FINISH)
        if rc ~= Z_STREAM_END then
            libz.deflateEnd(stream)
            return nil, "deflate failed: " .. rc
        end

        local produced = (#data + 256) - tonumber(stream[0].avail_out)
        libz.deflateEnd(stream)
        return ffi.string(outbuf, produced)
    end

    --- Helper: compress data with raw deflate (no zlib header)
    local function rawDeflate(data)
        local stream = ffi.new("z_stream[1]")
        local rc = libz.deflateInit2_(
            stream, Z_DEFAULT_COMPRESSION, 8,  -- method = DEFLATED
            -15,                                 -- windowBits = -15 (raw, no header)
            8,                                   -- memLevel
            0,                                   -- strategy = default
            libz.zlibVersion(), ffi.sizeof(stream[0])
        )
        if rc ~= Z_OK then
            return nil, "deflateInit2 failed: " .. rc
        end

        stream[0].next_in = ffi.cast("Bytef *", data)
        stream[0].avail_in = #data

        local outbuf = ffi.new("uint8_t[?]", #data + 256)
        stream[0].next_out = outbuf
        stream[0].avail_out = #data + 256

        rc = libz.deflate(stream, Z_FINISH)
        if rc ~= Z_STREAM_END then
            libz.deflateEnd(stream)
            return nil, "deflate failed: " .. rc
        end

        local produced = (#data + 256) - tonumber(stream[0].avail_out)
        libz.deflateEnd(stream)
        return ffi.string(outbuf, produced)
    end

    describe("inflateRaw (one-shot)", function()
        it("round-trips a short string", function()
            local data = "Hello, zlib!"
            local compressed = assert(rawDeflate(data))
            local inflated = assert(zlib.inflateRaw(compressed))
            assert.are.equal(data, inflated)
        end)

        it("round-trips empty data", function()
            local data = ""
            local compressed = assert(rawDeflate(data))
            local inflated = assert(zlib.inflateRaw(compressed))
            assert.are.equal(data, inflated)
        end)

        it("round-trips binary data with null bytes", function()
            local parts = {}
            for i = 0, 255 do
                parts[#parts + 1] = string.char(i)
            end
            local data = table.concat(parts)
            local compressed = assert(rawDeflate(data))
            local inflated = assert(zlib.inflateRaw(compressed))
            assert.are.equal(data, inflated)
        end)

        it("round-trips data larger than CHUNK_SIZE", function()
            -- Generate > 32KB of data to test chunked inflation
            local data = string.rep("The quick brown fox jumps over the lazy dog. ", 1500)
            assert.is.truthy(#data > CHUNK_SIZE)
            local compressed = assert(rawDeflate(data))
            local inflated = assert(zlib.inflateRaw(compressed))
            assert.are.equal(data, inflated)
        end)

        it("round-trips repeated pattern (highly compressible)", function()
            local data = string.rep("A", 10000)
            local compressed = assert(rawDeflate(data))
            -- Should compress very well
            assert.is.truthy(#compressed < #data)
            local inflated = assert(zlib.inflateRaw(compressed))
            assert.are.equal(data, inflated)
        end)
    end)

    describe("rawInflater (streaming)", function()
        it("round-trips data fed in small chunks", function()
            local data = "Streaming inflation test with multiple chunks of data."
            local compressed = assert(rawDeflate(data))

            local inflater = assert(zlib.rawInflater())
            local chunks = {}
            local sink = function(ptr, len)
                chunks[#chunks + 1] = ffi.string(ptr, len)
                return true
            end

            -- Feed compressed data in 4-byte chunks
            local offset = 1
            while offset <= #compressed do
                local chunk = compressed:sub(offset, math.min(offset + 3, #compressed))
                assert(inflater:update(chunk, #chunk, sink))
                offset = offset + #chunk
            end
            inflater:finalize()

            assert.are.equal(data, table.concat(chunks))
        end)

        it("round-trips large data in single chunk", function()
            local data = string.rep("Large streaming test. ", 2000)
            local compressed = assert(rawDeflate(data))

            local inflater = assert(zlib.rawInflater())
            local chunks = {}
            local sink = function(ptr, len)
                chunks[#chunks + 1] = ffi.string(ptr, len)
                return true
            end

            assert(inflater:update(compressed, #compressed, sink))
            inflater:finalize()

            assert.are.equal(data, table.concat(chunks))
        end)

        it("errors on update after finalize", function()
            local data = "test"
            local compressed = assert(rawDeflate(data))

            local inflater = assert(zlib.rawInflater())
            local sink = function() return true end
            assert(inflater:update(compressed, #compressed, sink))
            inflater:finalize()

            local ok, err = inflater:update("more", 4, sink)
            assert.is_nil(ok)
            assert.is.truthy(err)
        end)

        it("allows sink to abort with error", function()
            local data = "test data"
            local compressed = assert(rawDeflate(data))

            local inflater = assert(zlib.rawInflater())
            local call_count = 0
            local sink = function(ptr, len)
                call_count = call_count + 1
                return nil, "sink aborted"
            end

            local ok, err = inflater:update(compressed, #compressed, sink)
            -- The sink error should propagate
            assert.is_nil(ok)
            assert.are.equal("sink aborted", err)
            inflater:finalize()
        end)
    end)

    describe("inflater (zlib-wrapped, streaming)", function()
        it("round-trips zlib-wrapped compressed data", function()
            local data = "Hello, zlib-wrapped inflater!"
            local compressed = assert(zlibDeflate(data))

            local inflater = assert(zlib.inflater())
            local chunks = {}
            local sink = function(ptr, len)
                chunks[#chunks + 1] = ffi.string(ptr, len)
                return true
            end

            assert(inflater:update(compressed, #compressed, sink))
            inflater:finalize()

            assert.are.equal(data, table.concat(chunks))
        end)

        it("handles data larger than CHUNK_SIZE", function()
            local data = string.rep("zlib-wrapped large data test. ", 2000)
            assert.is.truthy(#data > CHUNK_SIZE)
            local compressed = assert(zlibDeflate(data))

            local inflater = assert(zlib.inflater())
            local chunks = {}
            local sink = function(ptr, len)
                chunks[#chunks + 1] = ffi.string(ptr, len)
                return true
            end

            assert(inflater:update(compressed, #compressed, sink))
            inflater:finalize()

            assert.are.equal(data, table.concat(chunks))
        end)

        it("round-trips binary data with null bytes", function()
            local parts = {}
            for i = 0, 255 do
                parts[#parts + 1] = string.char(i)
            end
            local data = table.concat(parts)
            local compressed = assert(zlibDeflate(data))

            local inflater = assert(zlib.inflater())
            local chunks = {}
            local sink = function(ptr, len)
                chunks[#chunks + 1] = ffi.string(ptr, len)
                return true
            end

            assert(inflater:update(compressed, #compressed, sink))
            inflater:finalize()

            assert.are.equal(data, table.concat(chunks))
        end)

        it("feeds data in small chunks", function()
            local data = "Streaming zlib-wrapped inflation with chunked input."
            local compressed = assert(zlibDeflate(data))

            local inflater = assert(zlib.inflater())
            local chunks = {}
            local sink = function(ptr, len)
                chunks[#chunks + 1] = ffi.string(ptr, len)
                return true
            end

            -- Feed compressed data in 4-byte chunks
            local offset = 1
            while offset <= #compressed do
                local chunk = compressed:sub(offset, math.min(offset + 3, #compressed))
                assert(inflater:update(chunk, #chunk, sink))
                offset = offset + #chunk
            end
            inflater:finalize()

            assert.are.equal(data, table.concat(chunks))
        end)

        it("errors on update after finalize", function()
            local data = "test"
            local compressed = assert(zlibDeflate(data))

            local inflater = assert(zlib.inflater())
            local sink = function() return true end
            assert(inflater:update(compressed, #compressed, sink))
            inflater:finalize()

            local ok, err = inflater:update("more", 4, sink)
            assert.is_nil(ok)
            assert.is.truthy(err)
        end)

        it("cannot decompress raw-deflate data (missing zlib header)", function()
            -- rawInflater uses windowBits=-15; inflater uses windowBits=15.
            -- Raw-deflate data has no 2-byte zlib header, so the zlib inflater should fail.
            local data = "raw deflate data"
            local rawCompressed = assert(rawDeflate(data))

            local inflater = assert(zlib.inflater())
            local sink = function() return true end
            local ok, err = inflater:update(rawCompressed, #rawCompressed, sink)
            assert.is_nil(ok)
            assert.is.truthy(err)
            inflater:finalize()
        end)

        it("errors on invalid compressed data", function()
            local inflater = assert(zlib.inflater())
            local sink = function() return true end
            local ok, err = inflater:update("not-valid-zlib-data", 19, sink)
            assert.is_nil(ok)
            assert.is.truthy(err)
            inflater:finalize()
        end)
    end)

    describe("one-shot vs streaming equivalence", function()
        it("produces identical output for same input", function()
            local data = string.rep("Equivalence test data. ", 500)
            local compressed = assert(rawDeflate(data))

            -- One-shot
            local oneshot = assert(zlib.inflateRaw(compressed))

            -- Streaming
            local inflater = assert(zlib.rawInflater())
            local chunks = {}
            local sink = function(ptr, len)
                chunks[#chunks + 1] = ffi.string(ptr, len)
                return true
            end
            assert(inflater:update(compressed, #compressed, sink))
            inflater:finalize()
            local streaming = table.concat(chunks)

            assert.are.equal(oneshot, streaming)
            assert.are.equal(data, oneshot)
        end)
    end)
end)
