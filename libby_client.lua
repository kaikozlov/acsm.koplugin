local json = require("json")
local ltn12 = require("ltn12")
local logger = require("logger")
local socket = require("socket")
local http = require("socket.http")
local socketutil = require("socketutil")
local url = require("socket.url")
local util = require("util")

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

local USER_AGENT = table.concat({
    "Mozilla/5.0",
    "(Macintosh;",
    "Intel",
    "Mac",
    "OS",
    "X",
    "11_1)",
    "AppleWebKit/605.1.15",
    "(KHTML,",
    "like",
    "Gecko)",
    "Version/14.0.2",
    "Safari/605.1.15",
}, " ")

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

function LibbyClient:new(opts)
    opts = opts or {}
    local instance = setmetatable({}, self)
    instance.identity_token = opts.identity_token
    instance.cookies = {}
    instance.max_retries = tonumber(opts.max_retries) or 1
    instance.timeout_block = tonumber(opts.timeout_block) or socketutil.FILE_BLOCK_TIMEOUT
    instance.timeout_total = tonumber(opts.timeout_total) or socketutil.FILE_TOTAL_TIMEOUT
    instance.user_agent = opts.user_agent or USER_AGENT
    instance.api_base = opts.api_base or "https://sentry.libbyapp.com/"
    return instance
end

function LibbyClient:setIdentityToken(token)
    self.identity_token = token
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
    return {
        ["User-Agent"] = self.user_agent,
        ["Accept"] = "application/json",
        ["Referer"] = "https://libbyapp.com/",
        ["Cache-Control"] = "no-cache",
        ["Pragma"] = "no-cache",
    }
end

function LibbyClient:_requestRaw(endpoint, opts)
    opts = opts or {}

    local request_url = endpoint
    if not request_url:match("^https?://") then
        request_url = self.api_base .. endpoint
    end

    local query = buildQuery(opts.query)
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

    self:updateCookies(response_headers)

    return {
        body = table.concat(chunks),
        code = tonumber(code) or code,
        headers = normalizeHeaders(response_headers),
        status = status,
        url = request_url,
    }
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
        return nil, message, response.code, decoded
    end

    if opts and opts.decode_response == false then
        return response.body or "", nil, response.code
    end

    return decoded, nil, response.code
end

function LibbyClient:sendRequest(endpoint, opts)
    opts = opts or {}
    local result, err, status, decoded = self:_sendRequest(endpoint, opts)
    if status == 403 and not opts._retried_after_refresh and opts.authenticated ~= false and self.identity_token then
        logger.warn("[Libby] Encountered auth error, refreshing chip")
        local chip_opts = {
            query = { client = "dewey" },
            method = "POST",
            force_post = true,
            authenticated = true,
            _retried_after_refresh = true,
        }
        local chip, chip_err = self:_sendRequest("chip", chip_opts)
        if chip and chip.identity then
            self.identity_token = chip.identity
            opts._retried_after_refresh = true
            return self:sendRequest(endpoint, opts)
        end
        return nil, chip_err or err
    end

    if not result then
        if type(decoded) == "table" then
            return nil, decoded
        end
        return nil, err
    end
    return result
end

function LibbyClient:getChip(update_internal_token, authenticated)
    local res, err = self:sendRequest("chip", {
        query = { client = "dewey" },
        method = "POST",
        force_post = true,
        authenticated = authenticated,
    })
    if not res then
        return nil, err
    end
    if update_internal_token ~= false and res.identity then
        self.identity_token = res.identity
    end
    return res
end

function LibbyClient:cloneByCode(code)
    if not self.isValidSyncCode(code) then
        return nil, "Invalid setup code"
    end
    return self:sendRequest("chip/clone/code", {
        params = { code = code },
    })
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

function LibbyClient:fulfillLoanFile(loan_id, card_id, format_id)
    if format_id ~= LibbyClient.Formats.EBookEPubAdobe then
        return nil, 'Unsupported format "' .. tostring(format_id) .. '"'
    end

    return self:sendRequest("card/" .. tostring(card_id) .. "/loan/" .. tostring(loan_id) .. "/fulfill/" .. tostring(format_id), {
        headers = {
            ["User-Agent"] = self.user_agent,
            ["Accept"] = "*/*",
            ["Referer"] = "https://libbyapp.com/",
            ["Cache-Control"] = "no-cache",
            ["Pragma"] = "no-cache",
        },
        decode_response = false,
    })
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
