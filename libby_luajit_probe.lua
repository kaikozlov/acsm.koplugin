local root = (...)

package.path = table.concat({
    "./?.lua",
    "./?/init.lua",
    "./?/?.lua",
    package.path,
}, ";")

package.preload["logger"] = function()
    local logger = {}
    function logger.warn(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        io.stderr:write(table.concat(parts, " "), "\n")
    end
    return logger
end

package.preload["util"] = function()
    local util = {}
    function util.trim(s)
        if type(s) ~= "string" then
            return s
        end
        return (s:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    function util.tableGetValue(tbl, ...)
        local value = tbl
        for i = 1, select("#", ...) do
            if type(value) ~= "table" then
                return nil
            end
            value = value[select(i, ...)]
        end
        return value
    end
    return util
end

package.preload["socketutil"] = function()
    local ltn12 = require("ltn12")
    local socketutil = {
        FILE_BLOCK_TIMEOUT = 15,
        FILE_TOTAL_TIMEOUT = 60,
        DEFAULT_BLOCK_TIMEOUT = 60,
        DEFAULT_TOTAL_TIMEOUT = -1,
        block_timeout = 60,
        total_timeout = -1,
    }
    function socketutil:set_timeout(block_timeout, total_timeout)
        self.block_timeout = block_timeout or self.DEFAULT_BLOCK_TIMEOUT
        self.total_timeout = total_timeout or self.DEFAULT_TOTAL_TIMEOUT
    end
    function socketutil:reset_timeout()
        self.block_timeout = self.DEFAULT_BLOCK_TIMEOUT
        self.total_timeout = self.DEFAULT_TOTAL_TIMEOUT
    end
    function socketutil.table_sink(t)
        return ltn12.sink.table(t or {})
    end
    return socketutil
end

package.preload["json"] = function()
    local json = {}

    local function is_array(tbl)
        if type(tbl) ~= "table" then
            return false
        end
        local max = 0
        local count = 0
        for key in pairs(tbl) do
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
                return false
            end
            if key > max then
                max = key
            end
            count = count + 1
        end
        return max == count
    end

    local function encode_string(value)
        local replacements = {
            ["\\"] = "\\\\",
            ['"'] = '\\"',
            ["\b"] = "\\b",
            ["\f"] = "\\f",
            ["\n"] = "\\n",
            ["\r"] = "\\r",
            ["\t"] = "\\t",
        }
        return '"' .. value:gsub('[%z\1-\31\\"]', function(ch)
            return replacements[ch] or string.format("\\u%04x", ch:byte())
        end) .. '"'
    end

    local function encode_value(value)
        local kind = type(value)
        if kind == "nil" then
            return "null"
        elseif kind == "boolean" or kind == "number" then
            return tostring(value)
        elseif kind == "string" then
            return encode_string(value)
        elseif kind == "table" then
            if is_array(value) then
                local parts = {}
                for i = 1, #value do
                    parts[#parts + 1] = encode_value(value[i])
                end
                return "[" .. table.concat(parts, ",") .. "]"
            end
            local parts = {}
            for key, item in pairs(value) do
                parts[#parts + 1] = encode_string(tostring(key)) .. ":" .. encode_value(item)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
        error("unsupported json type: " .. kind)
    end

    local function decode_error(text, pos, msg)
        error(string.format("json decode error at %d: %s near %q", pos, msg, text:sub(pos, pos + 20)))
    end

    local function skip_ws(text, pos)
        local _, next_pos = text:find("^[ \n\r\t]*", pos)
        return (next_pos or pos - 1) + 1
    end

    local parse_value

    local function parse_string(text, pos)
        pos = pos + 1
        local out = {}
        while pos <= #text do
            local ch = text:sub(pos, pos)
            if ch == '"' then
                return table.concat(out), pos + 1
            elseif ch == "\\" then
                local esc = text:sub(pos + 1, pos + 1)
                local map = {
                    ['"'] = '"',
                    ["\\"] = "\\",
                    ["/"] = "/",
                    b = "\b",
                    f = "\f",
                    n = "\n",
                    r = "\r",
                    t = "\t",
                }
                if map[esc] then
                    out[#out + 1] = map[esc]
                    pos = pos + 2
                elseif esc == "u" then
                    local hex = text:sub(pos + 2, pos + 5)
                    if not hex:match("^[0-9a-fA-F]+$") then
                        decode_error(text, pos, "invalid unicode escape")
                    end
                    local code = tonumber(hex, 16)
                    if code < 128 then
                        out[#out + 1] = string.char(code)
                    else
                        out[#out + 1] = utf8.char(code)
                    end
                    pos = pos + 6
                else
                    decode_error(text, pos, "invalid escape")
                end
            else
                out[#out + 1] = ch
                pos = pos + 1
            end
        end
        decode_error(text, pos, "unterminated string")
    end

    local function parse_number(text, pos)
        local s, e = text:find("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
        if not s then
            decode_error(text, pos, "invalid number")
        end
        local num = tonumber(text:sub(s, e))
        if num == nil then
            decode_error(text, pos, "invalid number value")
        end
        return num, e + 1
    end

    local function parse_array(text, pos)
        pos = skip_ws(text, pos + 1)
        local arr = {}
        if text:sub(pos, pos) == "]" then
            return arr, pos + 1
        end
        while true do
            local value
            value, pos = parse_value(text, pos)
            arr[#arr + 1] = value
            pos = skip_ws(text, pos)
            local ch = text:sub(pos, pos)
            if ch == "]" then
                return arr, pos + 1
            elseif ch ~= "," then
                decode_error(text, pos, "expected ',' or ']'")
            end
            pos = skip_ws(text, pos + 1)
        end
    end

    local function parse_object(text, pos)
        pos = skip_ws(text, pos + 1)
        local obj = {}
        if text:sub(pos, pos) == "}" then
            return obj, pos + 1
        end
        while true do
            if text:sub(pos, pos) ~= '"' then
                decode_error(text, pos, "expected string key")
            end
            local key
            key, pos = parse_string(text, pos)
            pos = skip_ws(text, pos)
            if text:sub(pos, pos) ~= ":" then
                decode_error(text, pos, "expected ':'")
            end
            pos = skip_ws(text, pos + 1)
            obj[key], pos = parse_value(text, pos)
            pos = skip_ws(text, pos)
            local ch = text:sub(pos, pos)
            if ch == "}" then
                return obj, pos + 1
            elseif ch ~= "," then
                decode_error(text, pos, "expected ',' or '}'")
            end
            pos = skip_ws(text, pos + 1)
        end
    end

    function parse_value(text, pos)
        pos = skip_ws(text, pos)
        local ch = text:sub(pos, pos)
        if ch == '"' then
            return parse_string(text, pos)
        elseif ch == "{" then
            return parse_object(text, pos)
        elseif ch == "[" then
            return parse_array(text, pos)
        elseif ch == "-" or ch:match("%d") then
            return parse_number(text, pos)
        elseif text:sub(pos, pos + 3) == "true" then
            return true, pos + 4
        elseif text:sub(pos, pos + 4) == "false" then
            return false, pos + 5
        elseif text:sub(pos, pos + 3) == "null" then
            return nil, pos + 4
        end
        decode_error(text, pos, "unexpected token")
    end

    function json.encode(value)
        return encode_value(value)
    end

    function json.decode(text)
        local value, pos = parse_value(text, 1)
        pos = skip_ws(text, pos)
        if pos <= #text then
            decode_error(text, pos, "trailing content")
        end
        return value
    end

    return json
end

local function decodeJwtPayload(token)
    local mime = require("mime")
    local payload = token:match("^[^.]+%.([^.]+)%.")
    if not payload then
        return nil
    end
    payload = payload:gsub("-", "+"):gsub("_", "/")
    payload = payload .. string.rep("=", (4 - (#payload % 4)) % 4)
    local decoded = mime.unb64(payload)
    if not decoded then
        return nil
    end
    return require("json").decode(decoded)
end

local function printJson(label, value)
    local json = require("json")
    io.stdout:write(label, ": ", json.encode(value), "\n")
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", [['"'"']]) .. "'"
end

local function runCommand(command)
    local handle = assert(io.popen(command .. " 2>&1", "r"))
    local output = handle:read("*a")
    local ok, _, status = handle:close()
    return ok == true, output, status
end

local function runCurlRequest(opts)
    local parts = {
        "curl",
        "--compressed",
        "-sS",
        "-X", shellQuote(opts.method or "GET"),
    }
    for name, value in pairs(opts.headers or {}) do
        parts[#parts + 1] = "-H"
        parts[#parts + 1] = shellQuote(name .. ": " .. tostring(value))
    end
    if opts.body ~= nil then
        parts[#parts + 1] = "--data-binary"
        parts[#parts + 1] = shellQuote(opts.body)
    end
    parts[#parts + 1] = shellQuote(opts.url)
    parts[#parts + 1] = "-w"
    parts[#parts + 1] = shellQuote("\n__CURL_STATUS__:%{http_code}\n")
    local ok, output, status = runCommand(table.concat(parts, " "))
    if not ok then
        return nil, output, status
    end
    local body, status_code = output:match("^(.*)\n__CURL_STATUS__:(%d+)\n?$")
    return {
        code = tonumber(status_code),
        body = body or output,
    }
end

local function commonHeaders(accept_language)
    return {
        ["Accept"] = "application/json",
        ["Accept-Encoding"] = "gzip",
        ["Accept-Language"] = accept_language or "en-US",
        ["Cache-Control"] = "no-cache",
        ["Pragma"] = "no-cache",
        ["Origin"] = "https://libbyapp.com",
        ["Referer"] = "https://libbyapp.com/",
        ["Sec-Fetch-Dest"] = "empty",
        ["Sec-Fetch-Mode"] = "cors",
        ["Sec-Fetch-Site"] = "same-site",
        ["Sec-GPC"] = "1",
        ["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            .. "(KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
        ["sec-ch-ua"] = '"Chromium";v="146", "Not-A.Brand";v="24", "Brave";v="146"',
        ["sec-ch-ua-mobile"] = "?0",
        ["sec-ch-ua-platform"] = '"macOS"',
    }
end

local function decodeJsonBody(response)
    if not response or type(response.body) ~= "string" or response.body == "" then
        return nil
    end
    local ok, decoded = pcall(require("json").decode, response.body)
    if ok then
        return decoded
    end
    return nil
end

local function runCurlFlow(base_token)
    local chip_headers = commonHeaders("zk")
    chip_headers["Authorization"] = "Bearer " .. base_token
    chip_headers["Content-Length"] = "0"

    local chip_res, chip_err = runCurlRequest({
        url = "https://sentry.libbyapp.com/chip?c=d%3A21.1.2&s=0&v=26605d39",
        method = "POST",
        headers = chip_headers,
        body = "",
    })
    if not chip_res then
        io.stderr:write("curl_chip_failed: ", tostring(chip_err), "\n")
        os.exit(3)
    end
    printJson("curl_chip_status", { code = chip_res.code })
    local chip = decodeJsonBody(chip_res) or {}
    printJson("curl_chip_response", chip)

    local chip_token = chip.identity
    if type(chip_token) ~= "string" or chip_token == "" then
        io.stderr:write("curl_chip_missing_identity\n")
        os.exit(3)
    end
    local chip_payload = decodeJwtPayload(chip_token)
    printJson("curl_chip_identity_payload", chip_payload and chip_payload.chip or {})

    local sync_headers = commonHeaders("en-US")
    sync_headers["Authorization"] = "Bearer " .. chip_token
    local sync_res, sync_err = runCurlRequest({
        url = "https://sentry.libbyapp.com/chip/sync?c=d%3A21.1.2&s=0&v=26605d39",
        method = "GET",
        headers = sync_headers,
    })
    if not sync_res then
        io.stderr:write("curl_sync_failed: ", tostring(sync_err), "\n")
        os.exit(3)
    end
    local sync = decodeJsonBody(sync_res) or {}
    printJson("curl_sync_status", { code = sync_res.code })
    printJson("curl_sync_summary", {
        result = sync.result,
        card_count = #(sync.cards or {}),
        loan_count = #(sync.loans or {}),
    })

    local fulfill_headers = commonHeaders("en-US")
    fulfill_headers["Authorization"] = "Bearer " .. chip_token
    local fulfill_res, fulfill_err = runCurlRequest({
        url = "https://sentry.libbyapp.com/card/85287774/loan/1009122/fulfill/ebook-epub-adobe",
        method = "GET",
        headers = fulfill_headers,
    })
    if not fulfill_res then
        io.stderr:write("curl_fulfill_failed: ", tostring(fulfill_err), "\n")
        os.exit(4)
    end
    printJson("curl_fulfill_status", { code = fulfill_res.code })
    local fulfill = decodeJsonBody(fulfill_res)
    if fulfill then
        printJson("curl_fulfill_response", fulfill)
    else
        io.stdout:write("curl_fulfill_body: ", fulfill_res.body, "\n")
    end
    if fulfill_res.code ~= 200 then
        os.exit(4)
    end
end

local LibbyClient = require("libby_client")

local BASE_TOKEN = os.getenv("LIBBY_BASE_TOKEN") or "eyJhbGciOiJSUzI1NiJ9.eyJhdWQiOiJyZWFkaXZlcnNlIiwiaXNzIjoic2VudHJ5IiwiY2hpcCI6eyJpZCI6IjI2NjA1ZDM5LTlhMmUtNDU3OC04MWYxLThiZDUwNDE0YWFkYyIsInByaSI6IjI2NjA1ZDM5LTlhMmUtNDU3OC04MWYxLThiZDUwNDE0YWFkYyIsImFnIjpudWxsLCJhY2NvdW50cyI6W3siYWciOjMyOTM3NzQyLCJpZCI6IjEwMTQ5NTIzMiIsInR5cCI6ImxpYnJhcnkiLCJjYXJkcyI6W3siaWQiOiI4NTI4Nzc3NCIsIm5hbWUiOiIyMTMwNTAwNDQxMzg2OCIsImxpYiI6eyJpZCI6IjcyIiwia2V5IjoibnNscy1jaGFtcGFpZ25wdWJsaWMifX1dfV19LCJleHAiOjE3NzU4NzQxOTN9.dtbFB0oHyvsEm2kj1h8srgFAo4OmfvjXTw704KcdjwwF_1__FVJlcnU9BU8IT67u_mamBADeNhpkky_hP1orQWLoyLGVRq9ygy2mdoxlq2lmcfkPQ9_taMvUmXfJTA_kPLK3MD_XLlkqZ3s0f1domORnmKbQT09OmutEvEE-iKdQj3poCdJ-yruWbMUp_SPGZaDwQQL4IpPPdxOt50Nf4DByJ8cEzV7gfCCw1yCLxdKsmJL-0tSvkPDRJVAWdzEsoZe1M0hb7-BdYi30ivhh8mErr4fo6gClpFiV6kPL_mUEebuacDP-Cy81xKsZlz8UOtSlnJYkMzZ9QuwVvpEJ0A"
local CARD_ID = os.getenv("LIBBY_CARD_ID") or "85287774"
local LOAN_ID = os.getenv("LIBBY_LOAN_ID") or "1009122"
local POLL_INTERVAL = tonumber(os.getenv("LIBBY_POLL_INTERVAL_SECONDS")) or 1

local function buildClient(identity_token)
    return LibbyClient:new({
        identity_token = identity_token,
        timeout_block = 15,
        timeout_total = 60,
    })
end

local function chipSummary(token)
    local payload = decodeJwtPayload(token or "")
    return payload and payload.chip or {}
end

local function runLuaCloneFulfillFlow(source_token)
    local source_client = buildClient(source_token)
    local target_client = buildClient(nil)

    local initial_chip, initial_err = target_client:getChip(true, false)
    if not initial_chip then
        io.stderr:write("target_initial_chip_failed: ", tostring(initial_err), "\n")
        os.exit(5)
    end
    printJson("target_initial_chip_response", initial_chip)
    printJson("target_initial_identity_payload", chipSummary(target_client.identity_token))

    local code_result, code_err = target_client:generateCloneCode("pointer")
    if not code_result then
        io.stderr:write("target_generate_code_failed: ", tostring(code_err), "\n")
        os.exit(5)
    end
    printJson("target_code_response", code_result)

    local blessed, bless_source_err = source_client:cloneByCode(code_result.code)
    if not blessed then
        io.stderr:write("source_redeem_failed: ", tostring(bless_source_err), "\n")
        os.exit(5)
    end
    printJson("source_redeem_response", blessed)
    printJson("source_identity_payload", chipSummary(source_client.identity_token))

    local blessing, blessing_result = target_client:waitForCloneBlessing(
        code_result.code,
        "pointer",
        code_result.expiry,
        POLL_INTERVAL
    )
    if not blessing then
        io.stderr:write("target_wait_for_blessing_failed: ", tostring(blessing_result), "\n")
        os.exit(5)
    end
    printJson("target_blessing_response", blessing_result)
    printJson("target_pre_clone_identity_payload", chipSummary(target_client.identity_token))

    local clone_result, clone_err = target_client:cloneByBlessing(blessing)
    if not clone_result then
        io.stderr:write("target_clone_failed: ", tostring(clone_err), "\n")
        os.exit(6)
    end
    printJson("target_clone_response", clone_result)
    printJson("target_post_clone_identity_payload", chipSummary(target_client.identity_token))

    local sync_result, sync_err = target_client:sync()
    if not sync_result then
        io.stderr:write("target_sync_failed: ", tostring(sync_err), "\n")
        os.exit(6)
    end
    printJson("target_sync_summary", {
        result = sync_result.result,
        card_count = #(sync_result.cards or {}),
        loan_count = #(sync_result.loans or {}),
    })

    local contents, fulfill_err = target_client:fulfillLoanFile(LOAN_ID, CARD_ID, LibbyClient.Formats.EBookEPubAdobe)
    if not contents then
        io.stderr:write("target_fulfill_failed: ", tostring(fulfill_err), "\n")
        os.exit(7)
    end
    io.stdout:write("target_fulfill_bytes: ", tostring(#contents), "\n")
    io.stdout:write(contents:sub(1, 200), "\n")
end

if arg and arg[1] == "curl" then
    local base_payload = decodeJwtPayload(BASE_TOKEN)
    printJson("base_payload_chip", base_payload and base_payload.chip or {})
    runCurlFlow(BASE_TOKEN)
    os.exit(0)
end

if arg and arg[1] == "clone-fulfill" then
    local base_payload = decodeJwtPayload(BASE_TOKEN)
    printJson("base_payload_chip", base_payload and base_payload.chip or {})
    runLuaCloneFulfillFlow(BASE_TOKEN)
    os.exit(0)
end

if arg and arg[1] == "plugin-fulfill" then
    local client = buildClient(BASE_TOKEN)
    local base_payload = decodeJwtPayload(BASE_TOKEN)
    printJson("base_payload_chip", base_payload and base_payload.chip or {})
    local contents, fulfill_err = client:fulfillLoanFile("1009122", "85287774", LibbyClient.Formats.EBookEPubAdobe)
    if not contents then
        io.stderr:write("fulfill_failed: ", tostring(fulfill_err), "\n")
        os.exit(2)
    end
    io.stdout:write("fulfill_bytes: ", tostring(#contents), "\n")
    io.stdout:write(contents:sub(1, 200), "\n")
    os.exit(0)
end

local client = buildClient(BASE_TOKEN)

local base_payload = decodeJwtPayload(BASE_TOKEN)
printJson("base_payload_chip", base_payload and base_payload.chip or {})

local chip, chip_err = client:getChip(true, true)
if not chip then
    io.stderr:write("chip_failed: ", tostring(chip_err), "\n")
    os.exit(1)
end

printJson("chip_response", chip)

local chip_payload = decodeJwtPayload(client.identity_token or "")
printJson("chip_identity_payload", chip_payload and chip_payload.chip or {})

local sync_res, sync_err = client:sync()
if not sync_res then
    io.stderr:write("sync_failed: ", tostring(sync_err), "\n")
    os.exit(1)
end

printJson("sync_summary", {
    result = sync_res.result,
    card_count = #(sync_res.cards or {}),
    loan_count = #(sync_res.loans or {}),
})

local contents, fulfill_err = client:fulfillLoanFile("1009122", "85287774", LibbyClient.Formats.EBookEPubAdobe)
if not contents then
    io.stderr:write("fulfill_failed: ", tostring(fulfill_err), "\n")
    os.exit(2)
end

if type(contents) == "string" then
    io.stdout:write("fulfill_bytes: ", tostring(#contents), "\n")
    io.stdout:write(contents:sub(1, 200), "\n")
else
    printJson("fulfill_result", contents)
end
