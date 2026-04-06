local json = require("json")
local ltn12 = require("ltn12")
local logger = require("logger")
local mime = require("mime")
local socket = require("socket")
local http = require("socket.http")
local socketutil = require("socketutil")
local url = require("socket.url")
local util = require("util")
local zlib = require("adobe.util.zlib")

local LibbyClient = {}
LibbyClient.__index = LibbyClient

LibbyClient.Formats = {
    EBookEPubAdobe = "ebook-epub-adobe",
    EBookEPubOpen = "ebook-epub-open",
    EBookPDFAdobe = "ebook-pdf-adobe",
    EBookPDFOpen = "ebook-pdf-open",
    EBookKindle = "ebook-kindle",
    MagazineOverDrive = "magazine-overdrive",
}

local BROWSER_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36"

-- Libby web app sends c= / s= (and often v= when authenticated) on sentry.libbyapp.com requests.
-- Omitting these yields JSON {"result":"client_upgrade_required"} on routes like open/... .
-- Bump if the API starts returning client_upgrade_required again while c/s are present.
local WEB_CLIENT_BUILD = "d:21.1.2"

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", [['"'"']]) .. "'"
end

local function buildQuery(query)
    if not query then
        return nil
    end

    local parts = {}
    for key, value in pairs(query) do
        if type(value) == "table" then
            for _, item in ipairs(value) do
                parts[#parts + 1] = url.escape(key) .. "=" .. url.escape(tostring(item))
            end
        elseif value ~= nil then
            parts[#parts + 1] = url.escape(key) .. "=" .. url.escape(tostring(value))
        end
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, "&")
end

local function normalizeHeaders(headers)
    local normalized = {}
    for key, value in pairs(headers or {}) do
        normalized[tostring(key):lower()] = value
    end
    return normalized
end

local function shouldCaptureCookiesForUrl(request_url)
    if type(request_url) ~= "string" then
        return false
    end
    return request_url:find("libbyapp.com", 1, true) ~= nil
end

local function splitSetCookieHeader(header_value)
    if type(header_value) ~= "string" or header_value == "" then
        return {}
    end

    local items = {}
    local start_index = 1
    while start_index <= #header_value do
        local next_index = header_value:find(",%s*[%w_%-]+=", start_index)
        if not next_index then
            items[#items + 1] = util.trim(header_value:sub(start_index))
            break
        end
        items[#items + 1] = util.trim(header_value:sub(start_index, next_index - 1))
        start_index = next_index + 1
    end
    return items
end

local function trimError(err)
    if type(err) ~= "string" then
        return tostring(err)
    end
    return err:gsub("^.-: ", "")
end

local function redactHeaderValue(name, value)
    if value == nil then
        return nil
    end
    local normalized_name = tostring(name):lower()
    if normalized_name == "authorization" or normalized_name == "cookie" or normalized_name == "set-cookie" or normalized_name == "set-cookie2" then
        local text = tostring(value)
        return string.format("<redacted:%d>", #text)
    end
    return tostring(value)
end

local function summarizeHeaders(headers)
    local parts = {}
    for name, value in pairs(headers or {}) do
        parts[#parts + 1] = tostring(name) .. "=" .. tostring(redactHeaderValue(name, value))
    end
    table.sort(parts)
    return table.concat(parts, ", ")
end

local function previewBody(body)
    if body == nil then
        return ""
    end
    local text = tostring(body):gsub("[%c]", " ")
    if #text > 240 then
        text = text:sub(1, 240) .. "..."
    end
    return text
end

local function countTableKeys(tbl)
    local count = 0
    for _key, _value in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

local function decodeBase64Url(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    local normalized = value:gsub("-", "+"):gsub("_", "/")
    local padding = #normalized % 4
    if padding > 0 then
        normalized = normalized .. string.rep("=", 4 - padding)
    end
    return mime.unb64(normalized)
end

local function extractChipVersionHint(identity_token)
    if type(identity_token) ~= "string" then
        return nil
    end
    local payload_segment = identity_token:match("^[^.]+%.([^.]+)%.")
    if not payload_segment then
        return nil
    end
    local payload_json = decodeBase64Url(payload_segment)
    if not payload_json then
        return nil
    end
    local ok, payload = pcall(json.decode, payload_json)
    if not ok or type(payload) ~= "table" then
        return nil
    end
    local chip = payload.chip
    local chip_id = type(chip) == "table" and chip.id or nil
    if type(chip_id) ~= "string" or chip_id == "" then
        return nil
    end
    return chip_id:match("^([^-]+)") or chip_id:sub(1, 8)
end

function LibbyClient:new(opts)
    opts = opts or {}
    local instance = setmetatable({}, self)
    instance.identity_token = opts.identity_token
    instance.chip_id = opts.chip_id or extractChipVersionHint(opts.identity_token)
    instance.cookies = {}
    instance.max_retries = tonumber(opts.max_retries) or 1
    instance.timeout_block = tonumber(opts.timeout_block) or socketutil.FILE_BLOCK_TIMEOUT
    instance.timeout_total = tonumber(opts.timeout_total) or socketutil.FILE_TOTAL_TIMEOUT
    instance.user_agent = opts.user_agent or BROWSER_USER_AGENT
    instance.api_base = opts.api_base or "https://sentry.libbyapp.com/"
    instance.curl_binary = opts.curl_binary or "curl"
    instance.use_curl = opts.use_curl ~= false
    instance._curl_available = nil
    instance._curl_availability_logged = false
    return instance
end

function LibbyClient:setIdentityToken(token)
    self.identity_token = token
    self.chip_id = extractChipVersionHint(token) or self.chip_id
end

function LibbyClient:buildChipQuery(_authenticated)
    -- Browser chip requests use the web client c/s(/v) query with no extra
    -- client=dewey parameter, even for anonymous recovery/setup-code flows.
    return {}
end

--- Merge web-style client query for https://sentry.libbyapp.com/ (not used for arbitrary absolute URLs).
function LibbyClient:mergeLibbyApiQuery(request_url, opts)
    opts = opts or {}
    if opts.skip_libby_client_query then
        return opts.query
    end
    if type(request_url) ~= "string" or not request_url:find("sentry.libbyapp.com", 1, true) then
        return opts.query
    end
    local merged = {
        c = WEB_CLIENT_BUILD,
        s = 0,
    }
    -- v mirrors the web client; omit when callers disable auth for this request.
    if self.identity_token and opts.authenticated ~= false then
        local v = self.chip_id or extractChipVersionHint(self.identity_token)
        if v then
            merged.v = v
        end
    end
    if type(opts.query) == "table" then
        for key, value in pairs(opts.query) do
            merged[key] = value
        end
    end
    return merged
end

function LibbyClient:browserCorsHeaders(accept, accept_language)
    return {
        ["User-Agent"] = BROWSER_USER_AGENT,
        ["Accept"] = accept or "application/json",
        ["Accept-Encoding"] = "gzip",
        ["Accept-Language"] = accept_language or "en-US",
        ["Referer"] = "https://libbyapp.com/",
        ["Origin"] = "https://libbyapp.com",
        ["Cache-Control"] = "no-cache",
        ["Pragma"] = "no-cache",
        ["Sec-Fetch-Dest"] = "empty",
        ["Sec-Fetch-Mode"] = "cors",
        ["Sec-Fetch-Site"] = "same-site",
        ["Sec-GPC"] = "1",
        ["sec-ch-ua"] = '"Chromium";v="146", "Not-A.Brand";v="24", "Brave";v="146"',
        ["sec-ch-ua-mobile"] = "?0",
        ["sec-ch-ua-platform"] = '"macOS"',
    }
end

function LibbyClient:getCookieHeader()
    local parts = {}
    for name, value in pairs(self.cookies or {}) do
        parts[#parts + 1] = name .. "=" .. value
    end
    table.sort(parts)
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, "; ")
end

function LibbyClient:updateCookies(response_headers)
    local normalized_headers = normalizeHeaders(response_headers)
    local raw_cookie_headers = {}

    if type(normalized_headers["set-cookie"]) == "string" then
        raw_cookie_headers[#raw_cookie_headers + 1] = normalized_headers["set-cookie"]
    end
    if type(normalized_headers["set-cookie2"]) == "string" then
        raw_cookie_headers[#raw_cookie_headers + 1] = normalized_headers["set-cookie2"]
    end

    for _, raw_cookie_header in ipairs(raw_cookie_headers) do
        for _, cookie_entry in ipairs(splitSetCookieHeader(raw_cookie_header)) do
            local pair = cookie_entry:match("^([^;]+)")
            if pair then
                local name, value = pair:match("^%s*([^=]+)=(.*)$")
                if name and value then
                    name = util.trim(name)
                    value = util.trim(value)
                    if value == "" then
                        self.cookies[name] = nil
                    else
                        self.cookies[name] = value
                    end
                end
            end
        end
    end
end

function LibbyClient.isValidSyncCode(code)
    return type(code) == "string" and code:match("^%d%d%d%d%d%d%d%d$") ~= nil
end

function LibbyClient:defaultHeaders()
    return self:browserCorsHeaders("application/json", "en-US")
end

function LibbyClient:browserFetchHeaders(accept, accept_language)
    local headers = self:browserCorsHeaders(accept or "application/json", accept_language or "en-US")
    headers["Referer"] = ""
    headers["Cache-Control"] = nil
    headers["Pragma"] = nil
    return headers
end

function LibbyClient:chipAcceptLanguage(authenticated, phase)
    if phase == "recovery_pointer" then
        return "zt"
    end
    if phase == "recovery_clone_retry" then
        return "ag"
    end
    if authenticated then
        -- Captured working browser chips use phase-specific odd Accept-Language
        -- values that appear to influence the token class the server mints.
        return "zk"
    end
    return "bh"
end

function LibbyClient:chipHeaders(authenticated, phase)
    return self:browserFetchHeaders("application/json", self:chipAcceptLanguage(authenticated, phase))
end

function LibbyClient:isCurlAvailable()
    if self._curl_available ~= nil then
        return self._curl_available
    end
    local handle = io.popen(self.curl_binary .. " --version >/dev/null 2>&1 && printf 1 || printf 0", "r")
    if not handle then
        self._curl_available = false
        return false
    end
    local output = handle:read("*a") or ""
    handle:close()
    self._curl_available = output:match("1") ~= nil
    if not self._curl_available and not self._curl_availability_logged then
        self._curl_availability_logged = true
        logger.warn("[Libby] curl transport unavailable")
    end
    return self._curl_available
end

function LibbyClient:shouldUseCurl(request_url)
    if not self.use_curl then
        return false
    end
    return self:isCurlAvailable()
end

local function parseCurlHeaderBlocks(header_text)
    local blocks = {}
    local current = nil
    for line in (header_text or ""):gmatch("([^\r\n]*)\r?\n") do
        if line:match("^HTTP/%d") then
            current = { status = line, headers = {} }
            blocks[#blocks + 1] = current
        elseif line == "" then
            current = nil
        elseif current then
            local name, value = line:match("^([^:]+):%s*(.*)$")
            if name then
                local key = name:lower()
                if current.headers[key] then
                    current.headers[key] = current.headers[key] .. ", " .. value
                else
                    current.headers[key] = value
                end
            end
        end
    end
    return blocks[#blocks]
end

function LibbyClient:_requestRawCurl(request_url, opts, headers, body)
    local header_file = os.tmpname()
    local body_file = os.tmpname()
    local body_input_file
    local command = {
        shellQuote(self.curl_binary),
        "--compressed",
        "--silent",
        "--show-error",
        "--location",
        "--connect-timeout", shellQuote(tostring(self.timeout_block)),
        "--max-time", shellQuote(tostring(self.timeout_total)),
        "-X", shellQuote(opts.method or (body and "POST" or "GET")),
        "-D", shellQuote(header_file),
        "-o", shellQuote(body_file),
        "-w", shellQuote("%{http_code}"),
    }

    for name, value in pairs(headers or {}) do
        command[#command + 1] = "-H"
        command[#command + 1] = shellQuote(tostring(name) .. ": " .. tostring(value))
    end

    if body ~= nil then
        body_input_file = os.tmpname()
        local handle, open_err = io.open(body_input_file, "wb")
        if not handle then
            os.remove(header_file)
            os.remove(body_file)
            return nil, open_err
        end
        handle:write(body)
        handle:close()
        command[#command + 1] = "--data-binary"
        command[#command + 1] = "@" .. shellQuote(body_input_file)
    end

    command[#command + 1] = shellQuote(request_url)

    local curl_handle = io.popen(table.concat(command, " "), "r")
    if not curl_handle then
        if body_input_file then os.remove(body_input_file) end
        os.remove(header_file)
        os.remove(body_file)
        return nil, "Unable to start curl"
    end

    local status_code = util.trim(curl_handle:read("*a") or "")
    local ok, _, exit_code = curl_handle:close()
    local header_handle = io.open(header_file, "rb")
    local header_text = header_handle and header_handle:read("*a") or ""
    if header_handle then header_handle:close() end
    local body_handle = io.open(body_file, "rb")
    local response_body = body_handle and body_handle:read("*a") or ""
    if body_handle then body_handle:close() end
    if body_input_file then os.remove(body_input_file) end
    os.remove(header_file)
    os.remove(body_file)

    if not ok then
        return nil, "curl exited with code " .. tostring(exit_code or status_code)
    end

    local parsed = parseCurlHeaderBlocks(header_text) or { headers = {}, status = "HTTP/1.1 " .. tostring(status_code) }
    return {
        body = response_body,
        code = tonumber(status_code) or status_code,
        headers = parsed.headers or {},
        status = parsed.status,
        url = request_url,
        decoded_content = true,
    }
end

function LibbyClient:_requestRawSocket(request_url, opts, headers, body)
    local sink, chunks = socketutil.table_sink({})
    local request = {
        url = request_url,
        method = opts.method or (body and "POST" or "GET"),
        headers = headers,
        sink = sink,
    }

    if body then
        request.source = ltn12.source.string(body)
    end

    socketutil:set_timeout(self.timeout_block, self.timeout_total)
    local ok, code, response_headers, status = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        return nil, trimError(code)
    end

    local response_body = table.concat(chunks)
    local normalized_response_headers = normalizeHeaders(response_headers)
    if normalized_response_headers["content-encoding"] == "gzip" and response_body ~= "" then
        local inflated_body, inflate_err = zlib.inflateGzip(response_body)
        if inflated_body then
            response_body = inflated_body
        else
            logger.warn("[Libby] Failed to inflate gzip response:", trimError(inflate_err))
        end
    end

    return {
        body = response_body,
        code = tonumber(code) or code,
        headers = normalized_response_headers,
        status = status,
        url = request_url,
    }
end

function LibbyClient:_requestRaw(endpoint, opts)
    opts = opts or {}

    local request_url = endpoint
    if not request_url:match("^https?://") then
        request_url = self.api_base .. endpoint
    end

    local merged_query = self:mergeLibbyApiQuery(request_url, opts)
    local query = buildQuery(merged_query)
    if query and query ~= "" then
        request_url = request_url .. (request_url:find("?", 1, true) and "&" or "?") .. query
    end

    local headers = opts.headers or self:defaultHeaders()
    if opts.authenticated ~= false and self.identity_token then
        headers["Authorization"] = "Bearer " .. self.identity_token
    end
    local cookie_header = self:getCookieHeader()
    if cookie_header and headers["Cookie"] == nil and headers["cookie"] == nil then
        headers["Cookie"] = cookie_header
    end

    local body
    if opts.params ~= nil then
        if opts.is_form == false then
            headers["Content-Type"] = "application/json; charset=UTF-8"
            body = json.encode(opts.params)
        else
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            body = buildQuery(opts.params) or ""
        end
        headers["Content-Length"] = tostring(#body)
    elseif opts.method == "POST" and opts.force_post then
        body = ""
        headers["Content-Length"] = "0"
    end

    local use_curl = self:shouldUseCurl(request_url)
    if opts.log_request then
        logger.warn(
            "[Libby] Request:",
            opts.method or (body and "POST" or "GET"),
            request_url,
            "transport=" .. (use_curl and "curl" or "socket"),
            "headers:",
            summarizeHeaders(headers)
        )
    end

    if not self.use_curl then
        return nil, "Libby curl transport disabled"
    end
    if not use_curl then
        return nil, "curl binary unavailable"
    end

    local response, err = self:_requestRawCurl(request_url, opts, headers, body)

    if not response then
        if opts.log_request then
            logger.warn(
                "[Libby] Request failed:",
                opts.method or (body and "POST" or "GET"),
                request_url,
                trimError(err)
            )
        end
        return nil, trimError(err)
    end

    if opts.skip_cookie_capture ~= true and shouldCaptureCookiesForUrl(request_url) then
        self:updateCookies(response.headers)
    end

    if opts.log_request or (tonumber(response.code) or 0) >= 400 then
        logger.warn(
            "[Libby] Response:",
            opts.method or (body and "POST" or "GET"),
            request_url,
            "code=" .. tostring(response.code),
            "status=" .. tostring(response.status),
            "headers:",
            summarizeHeaders(response.headers)
        )
    end

    return response
end

function LibbyClient:_decodeResponse(response)
    if not response then
        return nil, "Missing response"
    end

    local body = response.body or ""
    if body == "" then
        return {}
    end

    local decode_ok, decoded = pcall(json.decode, body)
    if decode_ok then
        return decoded
    end

    return body
end

function LibbyClient:_sendRequest(endpoint, opts)
    local response, err = self:_requestRaw(endpoint, opts)
    if not response then
        return nil, err
    end

    local decoded = self:_decodeResponse(response)
    if response.code and response.code >= 400 then
        local message = "HTTP " .. tostring(response.code)
        if type(decoded) == "table" then
            local upstream = decoded.upstream or {}
            message = upstream.userExplanation or upstream.errorCode or decoded.result or message
        elseif type(decoded) == "string" and decoded ~= "" then
            message = decoded
        end
        logger.warn(
            "[Libby] Error payload:",
            tostring(response.code),
            endpoint,
            previewBody(type(decoded) == "table" and json.encode(decoded) or decoded)
        )
        return nil, message, response.code, decoded
    end

    if opts and opts.decode_response == false then
        if opts.log_request then
            logger.warn("[Libby] Raw response bytes:", endpoint, #(response.body or ""))
        end
        return response.body or "", nil, response.code
    end

    return decoded, nil, response.code
end

function LibbyClient:sendRequest(endpoint, opts)
    opts = opts or {}
    local result, err, status, decoded = self:_sendRequest(endpoint, opts)
    if status == 403 and type(decoded) == "table" and decoded.result == "client_upgrade_required" then
        logger.warn(
            "[Libby] client_upgrade_required:",
            endpoint,
            "(if this persists, bump WEB_CLIENT_BUILD in libby_client.lua for the Libby web app)"
        )
        return nil, "client_upgrade_required"
    end
    if status == 403 and not opts.skip_chip_refresh_on_403 and not opts._retried_after_refresh and opts.authenticated ~= false and self.identity_token then
        logger.warn("[Libby] Encountered auth error, refreshing chip for endpoint:", endpoint)
        local chip, chip_err = self:_sendRequest("chip", {
            query = self:buildChipQuery(true),
            method = "POST",
            force_post = true,
            authenticated = true,
            headers = self:chipHeaders(true),
            _retried_after_refresh = true,
            log_request = true,
        })
        if chip and chip.identity then
            self.identity_token = chip.identity
            if type(chip.chip) == "string" and chip.chip ~= "" then
                self.chip_id = chip.chip:match("^([^-]+)") or chip.chip:sub(1, 8)
            end
            logger.warn(
                "[Libby] Chip refresh succeeded; chip_id=" .. tostring(self.chip_id)
                    .. " cookie_count=" .. tostring(countTableKeys(self.cookies))
            )
            opts._retried_after_refresh = true
            opts.log_request = true
            logger.warn("[Libby] Retrying endpoint after chip refresh:", endpoint)
            return self:sendRequest(endpoint, opts)
        end
        logger.warn("[Libby] Chip refresh failed:", trimError(chip_err))
        return nil, chip_err or err
    end

    if not result then
        if type(decoded) == "table" then
            if decoded.result then
                return nil, tostring(decoded.result)
            end
            return nil, decoded
        end
        return nil, err
    end
    return result
end

function LibbyClient:getChip(update_internal_token, authenticated, phase)
    local res, err = self:sendRequest("chip", {
        query = self:buildChipQuery(authenticated),
        method = "POST",
        force_post = true,
        authenticated = authenticated,
        headers = self:chipHeaders(authenticated, phase),
    })
    if not res then
        return nil, err
    end
    if update_internal_token ~= false and res.identity then
        self.identity_token = res.identity
    end
    if type(res.chip) == "string" and res.chip ~= "" then
        self.chip_id = res.chip:match("^([^-]+)") or res.chip:sub(1, 8)
    end
    return res
end

function LibbyClient:cloneByCode(code)
    if not self.isValidSyncCode(code) then
        return nil, "Invalid setup code"
    end
    return self:sendRequest("chip/clone/code", {
        method = "POST",
        is_form = false,
        params = {
            code = code,
            role = "primary",
        },
        headers = self:browserFetchHeaders("application/json", "en-US"),
        skip_libby_client_query = true,
    })
end

function LibbyClient:generateCloneCode(role, code)
    local query = {}
    if type(role) == "string" and role ~= "" then
        query.role = role
    end
    if type(code) == "string" and code ~= "" then
        query.code = code
    end
    return self:sendRequest("chip/clone/code", {
        query = next(query) and query or nil,
        headers = self:browserFetchHeaders("application/json", "en-US"),
        skip_libby_client_query = true,
    })
end

function LibbyClient:waitForCloneBlessing(code, role, expiry, poll_interval_seconds)
    local current_code = code
    local deadline = tonumber(expiry)
    local poll_interval = tonumber(poll_interval_seconds) or 3

    if not self.isValidSyncCode(current_code) then
        return nil, "Invalid setup code"
    end
    if not deadline or deadline <= 0 then
        deadline = os.time() + 60
    end

    while os.time() <= deadline do
        local result, err = self:generateCloneCode(role, current_code)
        if not result then
            return nil, err
        end
        if result.result == "fulfilled" and type(result.blessing) == "string" and result.blessing ~= "" then
            return result.blessing, result
        end
        if type(result.code) == "string" and result.code ~= "" then
            current_code = result.code
        end
        if tonumber(result.expiry) then
            deadline = tonumber(result.expiry)
        end
        socket.sleep(poll_interval)
    end

    return nil, "Setup code expired"
end

function LibbyClient:acquireCloneChip()
    local res, err = self:_sendRequest("chip", {
        query = self:buildChipQuery(true),
        method = "POST",
        force_post = true,
        authenticated = true,
        headers = self:chipHeaders(true, "recovery_clone_retry"),
        log_request = true,
    })
    if not res then
        return nil, err
    end
    if res.identity then
        self.identity_token = res.identity
    end
    if type(res.chip) == "string" and res.chip ~= "" then
        self.chip_id = res.chip:match("^([^-]+)") or res.chip:sub(1, 8)
    end
    logger.warn(
        "[Libby] Clone chip acquired; chip_id=" .. tostring(self.chip_id)
            .. " primary=" .. tostring(res.primary)
            .. " syncable=" .. tostring(res.syncable)
    )
    return res
end

function LibbyClient:prepareRecoveryPointerSession()
    local chip_res, chip_err = self:getChip(true, true, "recovery_pointer")
    if not chip_res then
        return nil, chip_err
    end
    local sync_res, sync_err = self:sync()
    if not sync_res then
        return nil, sync_err
    end
    return {
        chip = chip_res,
        sync = sync_res,
    }
end

function LibbyClient:waitForRecoveredAccount(timeout_seconds, poll_interval_seconds)
    local deadline = os.time() + (tonumber(timeout_seconds) or 6)
    local poll_interval = tonumber(poll_interval_seconds) or 1

    while os.time() <= deadline do
        local chip_res = self:acquireCloneChip()
        if not chip_res then
            socket.sleep(poll_interval)
        else
            local sync_res, sync_err = self:sync()
            if sync_res and sync_res.result == "synchronized" and type(sync_res.cards) == "table" and #sync_res.cards > 0 then
                return sync_res
            end
            if sync_err then
                logger.warn("[Libby] Recovery sync probe failed:", trimError(sync_err))
            end
            socket.sleep(poll_interval)
        end
    end

    return nil, "Recovery session did not become ready"
end

function LibbyClient:cloneByBlessing(blessing, already_retried)
    if type(blessing) ~= "string" or blessing == "" then
        return nil, "Missing recovery blessing"
    end

    local result, err, status, decoded = self:_sendRequest("chip/clone", {
        method = "POST",
        is_form = false,
        params = { blessing = blessing },
        headers = self:browserFetchHeaders("application/json", "en-US"),
        log_request = true,
        skip_chip_refresh_on_403 = true,
        skip_libby_client_query = true,
    })
    if status == 403 and type(decoded) == "table" and decoded.result == "missing_chip" and not already_retried then
        logger.warn("[Libby] chip/clone returned missing_chip; reacquiring clone chip with ag")
        local chip, chip_err = self:acquireCloneChip()
        if not chip then
            return nil, chip_err or "missing_chip"
        end
        return self:cloneByBlessing(blessing, true)
    end
    if not result then
        if type(decoded) == "table" and decoded.result then
            return nil, tostring(decoded.result)
        end
        return nil, err
    end
    return result
end

function LibbyClient:sync()
    return self:sendRequest("chip/sync")
end

function LibbyClient:isLoggedIn()
    local state, err = self:sync()
    if not state then
        return false, err
    end
    return state.result == "synchronized" and type(state.cards) == "table" and #state.cards > 0
end

function LibbyClient.hasFormat(loan, format_id)
    local formats = loan and loan.formats or {}
    for _, format in ipairs(formats) do
        if format.id == format_id then
            return true
        end
    end
    return false
end

function LibbyClient.getLockedInFormat(loan)
    local formats = loan and loan.formats or {}
    for _, format in ipairs(formats) do
        if format.isLockedIn then
            return format.id
        end
    end
    return nil
end

function LibbyClient.getLoanFormat(loan)
    local locked = LibbyClient.getLockedInFormat(loan)
    if locked then
        if locked == LibbyClient.Formats.EBookEPubAdobe then
            return locked
        end
        return nil, 'Loan is locked to "' .. locked .. '"'
    end

    if LibbyClient.hasFormat(loan, LibbyClient.Formats.EBookEPubAdobe) then
        return LibbyClient.Formats.EBookEPubAdobe
    end

    return nil, "No supported downloadable EPUB format"
end

local function parseIsoUtc(value)
    if type(value) ~= "string" then
        return nil
    end

    local year, month, day, hour, min, sec = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not year then
        return nil
    end

    return os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec),
    })
end

function LibbyClient.isRenewable(loan)
    local renewable_on = loan and loan.renewableOn
    if not renewable_on then
        return false
    end

    local renewable_at = parseIsoUtc(renewable_on)
    if not renewable_at then
        return false
    end

    return renewable_at <= os.time()
end

function LibbyClient.canBorrow(card)
    local loan_limit = util.tableGetValue(card, "limits", "loan") or 0
    local loan_count = util.tableGetValue(card, "counts", "loan") or 0
    return loan_limit > loan_count
end

function LibbyClient.canPlaceHold(card)
    local hold_limit = util.tableGetValue(card, "limits", "hold") or 0
    local hold_count = util.tableGetValue(card, "counts", "hold") or 0
    return hold_limit > hold_count
end

function LibbyClient.canBorrowHold(hold)
    if type(hold) ~= "table" then
        return false
    end
    return not not (hold.isAvailable or (tonumber(hold.luckyDayAvailableCopies) or 0) > 0)
end

local function getPreferredLendingDays(card, media_type)
    local lending_period_type = media_type == "ebook" and "book" or media_type
    local lending_period = util.tableGetValue(card, "lendingPeriods", lending_period_type) or {}
    local preference = lending_period.preference
    if type(preference) == "table" and tonumber(preference[1]) and tonumber(preference[1]) > 0 then
        return tonumber(preference[1])
    end

    local options = lending_period.options or {}
    if #options > 0 and type(options[#options]) == "table" and tonumber(options[#options][1]) then
        return tonumber(options[#options][1])
    end

    return 21
end

function LibbyClient:borrowTitle(title_id, title_format, card_id, days, is_lucky_day_loan)
    days = tonumber(days) or 21
    if days <= 0 then
        return nil, "Invalid lending period"
    end

    return self:sendRequest("card/" .. tostring(card_id) .. "/loan/" .. tostring(title_id), {
        method = "POST",
        is_form = false,
        params = {
            period = days,
            units = "days",
            lucky_day = is_lucky_day_loan and 1 or nil,
            title_format = title_format,
        },
    })
end

local function openLoanPathSegment(loan)
    local media_type = util.tableGetValue(loan, "type", "id") or "ebook"
    if media_type == "audiobook" then
        return "audiobook"
    end
    if media_type == "magazine" then
        return "magazine"
    end
    return "book"
end

--- Primes the session the same way as LibbyClient.prepare_loan in libby-calibre-plugin (open + HEAD).
function LibbyClient:prepareLoan(loan)
    if type(loan) ~= "table" then
        return nil, "Missing loan"
    end
    local card_id = loan.cardId
    local title_id = loan.id
    if not card_id or not title_id then
        return nil, "Loan missing cardId or id"
    end
    local segment = openLoanPathSegment(loan)
    local meta, err = self:sendRequest("open/" .. segment .. "/card/" .. tostring(card_id) .. "/title/" .. tostring(title_id))
    if not meta then
        return nil, err
    end
    local web_base = util.tableGetValue(meta, "urls", "web")
    local message = meta.message
    if type(web_base) ~= "string" or web_base == "" or type(message) ~= "string" or message == "" then
        return true
    end
    local web_url = web_base .. "?" .. message
    local _, head_err = self:sendRequest(web_url, {
        method = "HEAD",
        authenticated = false,
        headers = {
            ["User-Agent"] = self.user_agent,
            ["Accept"] = "*/*",
            ["Accept-Encoding"] = "gzip",
            ["Referer"] = "https://libbyapp.com/",
        },
        skip_cookie_capture = true,
    })
    if head_err then
        logger.warn("[Libby] prepare_loan HEAD failed:", trimError(head_err))
    end
    return true
end

function LibbyClient:borrowMedia(media, card, availability)
    if type(media) ~= "table" or type(card) ~= "table" then
        return nil, "Missing media or card"
    end

    local media_type = util.tableGetValue(media, "type", "id") or "ebook"
    local is_lucky_day_loan = false
    local source = availability or media
    if type(source) == "table" then
        local lucky_copies = tonumber(source.luckyDayAvailableCopies) or 0
        local available_copies = tonumber(source.availableCopies) or 0
        is_lucky_day_loan = lucky_copies > 0 and available_copies <= 0
    end

    return self:borrowTitle(
        media.id,
        media_type,
        card.cardId,
        getPreferredLendingDays(card, media_type),
        is_lucky_day_loan
    )
end

--- @param loan_or_id table|number|string loan table (preferred) or legacy loan id
function LibbyClient:fulfillLoanFile(loan_or_id, card_id_or_format, format_id_opt)
    local loan_id, card_id, format_id, loan
    if type(loan_or_id) == "table" then
        loan = loan_or_id
        format_id = card_id_or_format
        loan_id = loan.id
        card_id = loan.cardId
    else
        loan_id = loan_or_id
        card_id = card_id_or_format
        format_id = format_id_opt
    end

    if format_id ~= LibbyClient.Formats.EBookEPubAdobe then
        return nil, 'Unsupported format "' .. tostring(format_id) .. '"'
    end

    -- Browser-authenticated POST /chip uses c/s/v (not client=dewey) and establishes
    -- the fulfill session. Follow with chip/sync to mirror the web client state refresh.
    local chip_res, chip_err = self:getChip(true, true)
    if not chip_res then
        return nil, chip_err
    end
    local sync_res, sync_err = self:sendRequest("chip/sync", { log_request = true })
    if not sync_res then
        return nil, sync_err
    end
    if type(sync_res) == "table" and sync_res.identity then
        self.identity_token = sync_res.identity
    end

    local endpoint = "card/" .. tostring(card_id) .. "/loan/" .. tostring(loan_id) .. "/fulfill/" .. tostring(format_id)
    local headers = self:browserCorsHeaders("application/json", "en-US")
    local request_opts = {
        headers = headers,
        log_request = true,
        skip_libby_client_query = true,
    }

    local fulfill_response, err = self:sendRequest(endpoint, request_opts)
    if type(fulfill_response) == "table" then
        local fulfill_href = util.tableGetValue(fulfill_response, "fulfill", "href")
        if type(fulfill_href) == "string" and fulfill_href ~= "" then
            logger.warn("[Libby] Fulfill URL received:", fulfill_href)
            return self:sendRequest(fulfill_href, {
                headers = {
                    ["User-Agent"] = BROWSER_USER_AGENT,
                    ["Accept"] = "*/*",
                    ["Referer"] = "https://libbyapp.com/",
                },
                authenticated = false,
                decode_response = false,
                log_request = true,
                skip_chip_refresh_on_403 = true,
                skip_libby_client_query = true,
            })
        end
        if fulfill_response.result then
            return nil, tostring(fulfill_response.result)
        end
    end
    if type(fulfill_response) == "string" and fulfill_response ~= "" then
        return fulfill_response
    end

    return nil, err or "Empty fulfill response"
end

function LibbyClient:returnLoan(loan)
    return self:sendRequest("card/" .. tostring(loan.cardId) .. "/loan/" .. tostring(loan.id), {
        method = "DELETE",
    })
end

function LibbyClient:cancelHold(hold)
    return self:sendRequest("card/" .. tostring(hold.cardId) .. "/hold/" .. tostring(hold.id), {
        method = "DELETE",
    })
end

function LibbyClient:createHold(title_id, card_id)
    return self:sendRequest("card/" .. tostring(card_id) .. "/hold/" .. tostring(title_id), {
        method = "POST",
        is_form = false,
        params = {
            days_to_suspend = 0,
            email_address = "",
        },
    })
end

function LibbyClient:renewTitle(title_id, title_format, card_id, days)
    return self:sendRequest("card/" .. tostring(card_id) .. "/loan/" .. tostring(title_id), {
        method = "PUT",
        is_form = false,
        params = {
            period = tonumber(days) or 21,
            units = "days",
            lucky_day = nil,
            title_format = title_format,
        },
    })
end

function LibbyClient:renewLoan(loan, card)
    return self:renewTitle(
        loan.id,
        loan.type and loan.type.id or "ebook",
        loan.cardId,
        getPreferredLendingDays(card or {}, loan.type and loan.type.id or "ebook")
    )
end

return LibbyClient
