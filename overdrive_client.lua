local json = require("json")
local ltn12 = require("ltn12")
local socket = require("socket")
local http = require("socket.http")
local socketutil = require("socketutil")
local url = require("socket.url")

local OverDriveClient = {}
OverDriveClient.__index = OverDriveClient

OverDriveClient.MAX_PER_PAGE = 24

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

local function trimError(err)
    if type(err) ~= "string" then
        return tostring(err)
    end
    return err:gsub("^.-: ", "")
end

function OverDriveClient:new(opts)
    opts = opts or {}
    local instance = setmetatable({}, self)
    instance.max_retries = tonumber(opts.max_retries) or 1
    instance.timeout_block = tonumber(opts.timeout_block) or socketutil.FILE_BLOCK_TIMEOUT
    instance.timeout_total = tonumber(opts.timeout_total) or socketutil.FILE_TOTAL_TIMEOUT
    instance.user_agent = opts.user_agent or USER_AGENT
    instance.api_base = opts.api_base or "https://thunder.api.overdrive.com/v2/"
    return instance
end

function OverDriveClient:defaultHeaders()
    return {
        ["User-Agent"] = self.user_agent,
        ["Accept"] = "application/json",
        ["Referer"] = "https://libbyapp.com/",
        ["Origin"] = "https://libbyapp.com",
        ["Cache-Control"] = "no-cache",
        ["Pragma"] = "no-cache",
    }
end

function OverDriveClient:defaultQuery(paging)
    local query = {
        ["x-client-id"] = "dewey",
    }
    if paging then
        query.page = 1
        query.perPage = self.MAX_PER_PAGE
    end
    return query
end

function OverDriveClient:_requestRaw(endpoint, opts)
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

    return {
        body = table.concat(chunks),
        code = tonumber(code) or code,
        headers = normalizeHeaders(response_headers),
        status = status,
        url = request_url,
    }
end

function OverDriveClient:_decodeResponse(response)
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

function OverDriveClient:sendRequest(endpoint, opts)
    local response, err = self:_requestRaw(endpoint, opts)
    if not response then
        return nil, err
    end

    local decoded = self:_decodeResponse(response)
    if response.code and response.code >= 400 then
        if type(decoded) == "string" and decoded ~= "" then
            return nil, decoded
        end
        return nil, "HTTP " .. tostring(response.code)
    end

    return decoded
end

function OverDriveClient:libraries(opts)
    opts = opts or {}
    local query = self:defaultQuery(true)
    if type(opts.website_ids) == "table" and #opts.website_ids > 0 then
        query.websiteIds = table.concat(opts.website_ids, ",")
    end
    if type(opts.library_keys) == "table" and #opts.library_keys > 0 then
        query.libraryKeys = table.concat(opts.library_keys, ",")
    end
    if opts.page then
        query.page = opts.page
    end
    if opts.per_page then
        query.perPage = opts.per_page
    end
    return self:sendRequest("libraries/", {
        query = query,
    })
end

function OverDriveClient:mediaSearch(library_keys, search_query, opts)
    opts = opts or {}
    local query = self:defaultQuery()
    query.libraryKey = library_keys
    query.query = search_query
    if opts.max_items then
        query.maxItems = opts.max_items
    end
    if opts.show_only_available ~= nil then
        query.showOnlyAvailable = tostring(not not opts.show_only_available)
    end
    if opts.format then
        query.format = opts.format
    end
    return self:sendRequest("media/search/", {
        query = query,
    })
end

function OverDriveClient.isSiteAvailable(site)
    if type(site) ~= "table" then
        return false
    end
    return not not (site.isAvailable or (tonumber(site.luckyDayAvailableCopies) or 0) > 0)
end

function OverDriveClient.isSiteAvailabilityBetter(a, b)
    if b == nil then
        return true
    end
    for _, rule in ipairs({
        { key = "isAvailable", default = false, transform = function(v) return v and 1 or 0 end },
        { key = "luckyDayAvailableCopies", default = 0, transform = function(v) return tonumber(v) or 0 end },
        { key = "estimatedWaitDays", default = 9999, transform = function(v) return -1 * (tonumber(v) or 9999) end },
        { key = "holdsRatio", default = 9999, transform = function(v) return -1 * (tonumber(v) or 9999) end },
        { key = "ownedCopies", default = 0, transform = function(v) return tonumber(v) or 0 end },
    }) do
        local value_a = a[rule.key]
        local value_b = b[rule.key]
        if value_a == nil then
            value_a = rule.default
        end
        if value_b == nil then
            value_b = rule.default
        end
        if rule.transform then
            value_a = rule.transform(value_a)
            value_b = rule.transform(value_b)
        end
        if value_a ~= value_b then
            return value_a > value_b
        end
    end
    return tostring(a.advantageKey or "") < tostring(b.advantageKey or "")
end

return OverDriveClient
