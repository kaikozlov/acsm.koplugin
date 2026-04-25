local adobe = {}

-- load required modules
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")

local util = require("adobe.util.util")
local crypto = require("adobe.util.crypto")
local xml = require("adobe.util.xml")
local base64 = require("adobe.util.util").base64

-- Eden2 activation service 
adobe.EDEN_URL = url.parse("https://adeactivate.adobe.com/adept")

adobe.VERSIONS = {
    { name = 'ADE 1.7.2', version = 'ADE WIN 9,0,1131,27', hobbes = '9.0.1131.27', os = 'Windows Vista', build = 1131 },
    { name = 'ADE 2.0.1', version = '2.0.1.78765', hobbes = '9.3.58046', os = 'Windows Vista', build = 78765 },
    { name = 'ADE 3.0.1', version = '3.0.1.91394', hobbes = '10.0.85385', os = 'Windows 8', build = 91394 },
    { name = 'ADE 4.0.3', version = '4.0.3.123281', hobbes = '12.0.123217', os = 'Windows 8', build = 123281 },
    { name = 'ADE 4.5.10', version = 'com.adobe.adobedigitaleditions.exe v4.5.10.186048', hobbes = '12.5.4.186049', os = 'Windows 8', build = 186048 },
    { name = 'ADE 4.5.11', version = 'com.adobe.adobedigitaleditions.exe v4.5.11.187303', hobbes = '12.5.4.187298', os = 'Windows 8', build = 187303 },
}

-- default to 2.0.1
adobe.VERSION = adobe.VERSIONS[2]

local function requestToString(request)
    local sink, resp = socketutil.table_sink({})
    request.sink = sink
    request.headers = request.headers or {}
    request.headers["User-Agent"] = request.headers["User-Agent"] or socketutil.USER_AGENT

    logger.info("[ACSM] HTTP request:", request.method or "GET", request.url)
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local ok, code = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()
    if not ok then
        logger.info("[ACSM] HTTP request failed with exception:", code)
        error(code)
    end
    local body = table.concat(resp)
    if body == "" and not code then
        logger.info("[ACSM] HTTP request returned empty body with no status code")
        error("request failed")
    end
    logger.info("[ACSM] HTTP response: status=", code, "body_len=", #body)
    return body, code
end

local function adeptGet(endpoint)
    return requestToString({
        url = endpoint,
    })
end

local function adeptPost(endpoint, body)
    return requestToString({
        url = endpoint,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/vnd.adobe.adept+xml",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
    })
end


function adobe.serializeActivation(creds, deviceUUID, fingerprint, authCert, activationURL)
    return {
        deviceKey = base64.encode(creds.deviceKey.key),
        privateLicenseKey = base64.encode(creds.licenseKey:topkcs8()),
        licenseCert = creds.licenseCert,
        user = creds.user,
        username = creds.username,
        pkcs12 = creds.pkcs12,
        deviceUUID = deviceUUID,
        fingerprint = fingerprint,
        authCert = authCert,
        activationURL = activationURL or url.build(adobe.EDEN_URL),
    }
end

function adobe.restoreActivation(serialized)
    if type(serialized) ~= "table" then
        return nil, "Serialized activation is missing"
    end
    if not serialized.deviceKey or not serialized.privateLicenseKey or not serialized.user
        or not serialized.pkcs12 or not serialized.deviceUUID or not serialized.fingerprint then
        return nil, "Serialized activation is incomplete"
    end

    local licenseKey, keyErr = crypto.key.new(base64.decode(serialized.privateLicenseKey))
    if not licenseKey then
        return nil, keyErr or "Could not restore private license key"
    end

    return {
        creds = {
            deviceKey = crypto.deviceKey.new(base64.decode(serialized.deviceKey)),
            authKey = nil,
            licenseKey = licenseKey,
            licenseCert = serialized.licenseCert,
            user = serialized.user,
            username = serialized.username,
            pkcs12 = serialized.pkcs12,
            activationURL = serialized.activationURL,
        },
        deviceUUID = serialized.deviceUUID,
        fingerprint = serialized.fingerprint,
        authCert = serialized.authCert,
    }
end

-- get information about the authentication service
function adobe.getAuthenticationServiceInfo()
    logger.info("[ACSM] getAuthenticationServiceInfo: requesting...")
    local response = adeptGet(url.build(util.endpoint(adobe.EDEN_URL, "AuthenticationServiceInfo")))
    logger.info("[ACSM] getAuthenticationServiceInfo: parsing response...")
    local info = xml.deserialize(response).authenticationServiceInfo
    logger.info("[ACSM] getAuthenticationServiceInfo: got", #info.signInMethods.signInMethod, "sign-in methods")

    -- parse the methods into a nicer table
    local raw = info.signInMethods.signInMethod
    local methods = {}
    for i, m in ipairs(raw) do
        methods[i] = {
            name = m[1],
            method = m._attr.method,
        }
    end
    return { certificate = info.certificate, methods = methods }
end

function adobe.signIn(method, username, password, authCert)
    logger.info("[ACSM] signIn: method=", method)
    local deviceKey = crypto.deviceKey.new()
    logger.info("[ACSM] signIn: generated device key")

    local authKey = crypto.key.new()
    local licenseKey = crypto.key.new()
    logger.info("[ACSM] signIn: generated auth and license keys")

    local login = crypto.encryptLogin(username, password, deviceKey, authCert)
    logger.info("[ACSM] signIn: encrypted login, sending sign-in request...")
    local signInRequest = xml.adobe({
        _attr = { method = method},
        signInData = login,
        publicAuthKey = base64.encode(authKey.pkey:tostring("public", "DER")),
        encryptedPrivateAuthKey = base64.encode(deviceKey:encrypt(authKey:topkcs8())),
        publicLicenseKey = base64.encode(licenseKey.pkey:tostring("public", "DER")),
        encryptedPrivateLicenseKey = base64.encode(deviceKey:encrypt(licenseKey:topkcs8()))
    }, "signIn")

    logger.info("[ACSM] signIn: parsing response...")
    local resp = adeptPost(url.build(util.endpoint(adobe.EDEN_URL, "SignInDirect")), signInRequest)
    resp = xml.deserialize(resp)
    logger.info("[ACSM] signIn: got response")

    if resp.error ~= nil then
        error("Server returned error: " .. resp.error._attr.data)
    elseif resp.credentials == nil then
        error("Server returned unexpected response")
    end

    if deviceKey:decrypt(base64.decode(resp.credentials.encryptedPrivateLicenseKey)) ~= licenseKey:topkcs8() then
        local lk, err = crypto.key.new(deviceKey:decrypt(base64.decode(resp.credentials.encryptedPrivateLicenseKey)))
        if err ~= nil then error(err) end
        licenseKey = lk
    end

    return { 
        -- generated
        deviceKey = deviceKey, 
        authKey = authKey, 
        licenseKey = licenseKey,
        -- received 
        licenseCert = resp.credentials.licenseCertificate, 
        user = resp.credentials.user, 
        username = resp.credentials.username[1],
        pkcs12 = resp.credentials.pkcs12
    }
end

function adobe.targetDevice(fingerprint, activationToken)
    return {
        softwareVersion = adobe.VERSION.hobbes,
        clientOS = adobe.VERSION.os,
        clientLocale = "en",
        clientVersion = adobe.VERSION.version,
        deviceType = "standalone",
        productName = "Adobe Digitial Editions", -- [sic]
        fingerprint = fingerprint,
        activationToken = activationToken,
    }
end

function adobe.activate(user, deviceKey, pkcs12)
    logger.info("[ACSM] activate: generating device serial and fingerprint...")
    local serial = crypto.serial()
    local fingerprint = crypto.fingerprint(serial, deviceKey)
    logger.info("[ACSM] activate: decoding pkcs12...")
    local pkcs12Key = crypto.decodepkcs12(pkcs12, deviceKey)
    logger.info("[ACSM] activate: building activation request, fingerprint=", fingerprint)

    local activationRequest = xml.adobeSigned("activate", pkcs12Key, {
        _attr = { requestType = "initial"},
        fingerprint = fingerprint,
        deviceType = "standalone",
        clientOS = adobe.VERSION.os,
        clientLocale = "en",
        clientVersion = adobe.VERSION.version,
        targetDevice = adobe.targetDevice(fingerprint),
        nonce = crypto.nonce(),
        expiration = util.expiration(10), -- 10 minutes
        user = user
    })

    logger.info("[ACSM] activate: sending activation request...")
    local resp = adeptPost(url.build(util.endpoint(adobe.EDEN_URL, "Activate")), activationRequest)
    logger.info("[ACSM] activate: parsing activation response...")
    resp = xml.deserialize(resp)
    if resp.error ~= nil then
        logger.warn("[ACSM] activate: server returned error:", resp.error._attr.data)
        error("Server returned error: " .. resp.error._attr.data)
    end
    logger.info("[ACSM] activate: success, device=", resp.activationToken.device)
    return resp.activationToken.device, fingerprint
end
return adobe
