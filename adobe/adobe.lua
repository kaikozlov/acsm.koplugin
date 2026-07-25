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
    { name = "ADE 1.7.2", version = "ADE WIN 9,0,1131,27", hobbes = "9.0.1131.27", os = "Windows Vista", build = 1131 },
    { name = "ADE 2.0.1", version = "2.0.1.78765", hobbes = "9.3.58046", os = "Windows Vista", build = 78765 },
    { name = "ADE 3.0.1", version = "3.0.1.91394", hobbes = "10.0.85385", os = "Windows 8", build = 91394 },
    { name = "ADE 4.0.3", version = "4.0.3.123281", hobbes = "12.0.123217", os = "Windows 8", build = 123281 },
    {
        name = "ADE 4.5.10",
        version = "com.adobe.adobedigitaleditions.exe v4.5.10.186048",
        hobbes = "12.5.4.186049",
        os = "Windows 8",
        build = 186048,
    },
    {
        name = "ADE 4.5.11",
        version = "com.adobe.adobedigitaleditions.exe v4.5.11.187303",
        hobbes = "12.5.4.187298",
        os = "Windows 8",
        build = 187303,
    },
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
        return nil, tostring(code)
    end
    local body = table.concat(resp)
    if type(code) == "number" and (code < 200 or code >= 300) then
        return nil, "HTTP " .. tostring(code) .. (body ~= "" and (": " .. body) or "")
    end
    if body == "" then
        logger.info("[ACSM] HTTP request returned an empty body, status=", code)
        return nil, "Empty HTTP response" .. (code and (" (status " .. tostring(code) .. ")") or "")
    end
    logger.info("[ACSM] HTTP response: status=", code, "body_len=", #body)
    return body, code
end

local function deserializeResponse(body, context)
    local ok, parsed = pcall(xml.deserialize, body)
    if not ok then
        return nil, context .. " returned malformed XML: " .. tostring(parsed)
    end
    if type(parsed) ~= "table" then
        return nil, context .. " returned an invalid XML document"
    end
    return parsed
end

local function serverError(parsed, fallback)
    local err = parsed and parsed.error
    if type(err) == "table" and err._attr and err._attr.data then
        return err._attr.data
    end
    if type(err) == "string" then
        return err
    end
    return fallback or "Unknown Adobe server error"
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
    local privateLicenseKey, err = creds.licenseKey:topkcs8()
    if not privateLicenseKey then
        return nil, err
    end
    return {
        deviceKey = base64.encode(creds.deviceKey.key),
        privateLicenseKey = base64.encode(privateLicenseKey),
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
    if
        not serialized.deviceKey
        or not serialized.privateLicenseKey
        or not serialized.user
        or not serialized.pkcs12
        or not serialized.deviceUUID
        or not serialized.fingerprint
    then
        return nil, "Serialized activation is incomplete"
    end

    local privateLicenseKey = base64.decode(serialized.privateLicenseKey)
    if not privateLicenseKey or privateLicenseKey == "" then
        return nil, "Serialized private license key is invalid"
    end
    local licenseKey, keyErr = crypto.key.new(privateLicenseKey)
    if not licenseKey then
        return nil, keyErr or "Could not restore private license key"
    end

    local deviceKey, deviceKeyErr = crypto.deviceKey.new(base64.decode(serialized.deviceKey))
    if not deviceKey then
        return nil, "Serialized device key is invalid: " .. tostring(deviceKeyErr)
    end

    return {
        creds = {
            deviceKey = deviceKey,
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
    local response, requestErr = adeptGet(url.build(util.endpoint(adobe.EDEN_URL, "AuthenticationServiceInfo")))
    if not response then
        return nil, "AuthenticationServiceInfo request failed: " .. tostring(requestErr)
    end

    logger.info("[ACSM] getAuthenticationServiceInfo: parsing response...")
    local parsed, parseErr = deserializeResponse(response, "AuthenticationServiceInfo")
    if not parsed then
        return nil, parseErr
    end
    if parsed.error then
        return nil, "AuthenticationServiceInfo error: " .. serverError(parsed, response)
    end

    local info = parsed.authenticationServiceInfo
    if type(info) ~= "table" or not info.certificate or type(info.signInMethods) ~= "table" then
        return nil, "AuthenticationServiceInfo returned an unexpected response"
    end

    local raw = info.signInMethods.signInMethod
    if type(raw) ~= "table" then
        return nil, "AuthenticationServiceInfo did not provide sign-in methods"
    end
    local methods = {}
    for i, m in ipairs(raw) do
        methods[i] = {
            name = m[1],
            method = m._attr and m._attr.method,
        }
    end
    logger.info("[ACSM] getAuthenticationServiceInfo: got", #methods, "sign-in methods")
    return { certificate = info.certificate, methods = methods }
end

function adobe.signIn(method, username, password, authCert)
    logger.info("[ACSM] signIn: method=", method)
    local deviceKey, deviceKeyErr = crypto.deviceKey.new()
    if not deviceKey then
        return nil, deviceKeyErr
    end
    logger.info("[ACSM] signIn: generated device key")

    local authKey, authKeyErr = crypto.key.new()
    if not authKey then
        return nil, authKeyErr
    end
    local licenseKey, licenseKeyErr = crypto.key.new()
    if not licenseKey then
        return nil, licenseKeyErr
    end
    logger.info("[ACSM] signIn: generated auth and license keys")

    local login, loginErr = crypto.encryptLogin(username, password, deviceKey, authCert)
    if not login then
        return nil, "Could not encrypt login credentials: " .. tostring(loginErr)
    end

    local publicAuthKey, publicAuthErr = authKey.pkey:tostring("public", "DER")
    local privateAuthKey, privateAuthErr = authKey:topkcs8()
    local publicLicenseKey, publicLicenseErr = licenseKey.pkey:tostring("public", "DER")
    local privateLicenseKey, privateLicenseErr = licenseKey:topkcs8()
    if not publicAuthKey or not privateAuthKey or not publicLicenseKey or not privateLicenseKey then
        return nil, "Could not export generated keys: " .. tostring(publicAuthErr or privateAuthErr or publicLicenseErr or privateLicenseErr)
    end

    local encryptedPrivateAuthKey, encryptedAuthErr = deviceKey:encrypt(privateAuthKey)
    if not encryptedPrivateAuthKey then
        return nil, encryptedAuthErr
    end
    local encryptedPrivateLicenseKey, encryptedLicenseErr = deviceKey:encrypt(privateLicenseKey)
    if not encryptedPrivateLicenseKey then
        return nil, encryptedLicenseErr
    end

    local signInRequest = xml.adobe({
        _attr = { method = method },
        signInData = login,
        publicAuthKey = base64.encode(publicAuthKey),
        encryptedPrivateAuthKey = base64.encode(encryptedPrivateAuthKey),
        publicLicenseKey = base64.encode(publicLicenseKey),
        encryptedPrivateLicenseKey = base64.encode(encryptedPrivateLicenseKey),
    }, "signIn")

    logger.info("[ACSM] signIn: sending sign-in request...")
    local response, requestErr = adeptPost(url.build(util.endpoint(adobe.EDEN_URL, "SignInDirect")), signInRequest)
    if not response then
        return nil, "Sign-in request failed: " .. tostring(requestErr)
    end
    local resp, parseErr = deserializeResponse(response, "SignInDirect")
    if not resp then
        return nil, parseErr
    end
    logger.info("[ACSM] signIn: got response")

    if resp.error then
        return nil, "Server returned error: " .. serverError(resp, response)
    end
    local credentials = resp.credentials
    if
        type(credentials) ~= "table"
        or not credentials.encryptedPrivateLicenseKey
        or not credentials.licenseCertificate
        or not credentials.user
        or not credentials.pkcs12
    then
        return nil, "Server returned unexpected sign-in response"
    end

    local encryptedRemoteKey = base64.decode(credentials.encryptedPrivateLicenseKey)
    local remotePrivateKey, decryptErr = deviceKey:decrypt(encryptedRemoteKey)
    if not remotePrivateKey then
        return nil, "Could not decrypt returned private license key: " .. tostring(decryptErr)
    end
    if remotePrivateKey ~= privateLicenseKey then
        local replacementKey, replacementErr = crypto.key.new(remotePrivateKey)
        if not replacementKey then
            return nil, replacementErr
        end
        licenseKey = replacementKey
    end

    local returnedUsername = credentials.username
    if type(returnedUsername) == "table" then
        returnedUsername = returnedUsername[1]
    end
    return {
        deviceKey = deviceKey,
        authKey = authKey,
        licenseKey = licenseKey,
        licenseCert = credentials.licenseCertificate,
        user = credentials.user,
        username = returnedUsername,
        pkcs12 = credentials.pkcs12,
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
    local serial, serialErr = crypto.serial()
    if not serial then
        return nil, serialErr
    end
    local fingerprint, fingerprintErr = crypto.fingerprint(serial, deviceKey)
    if not fingerprint then
        return nil, fingerprintErr
    end

    logger.info("[ACSM] activate: decoding pkcs12...")
    local pkcs12Key, pkcs12Err = crypto.decodepkcs12(pkcs12, deviceKey)
    if not pkcs12Key then
        return nil, "Could not decode PKCS12: " .. tostring(pkcs12Err)
    end
    local nonce, nonceErr = crypto.nonce()
    if not nonce then
        return nil, nonceErr
    end
    logger.info("[ACSM] activate: building activation request, fingerprint=", fingerprint)

    local activationRequest, buildErr = xml.adobeSigned("activate", pkcs12Key, {
        _attr = { requestType = "initial" },
        fingerprint = fingerprint,
        deviceType = "standalone",
        clientOS = adobe.VERSION.os,
        clientLocale = "en",
        clientVersion = adobe.VERSION.version,
        targetDevice = adobe.targetDevice(fingerprint),
        nonce = nonce,
        expiration = util.expiration(10), -- 10 minutes
        user = user,
    })
    if not activationRequest then
        return nil, "Could not build activation request: " .. tostring(buildErr)
    end

    logger.info("[ACSM] activate: sending activation request...")
    local response, requestErr = adeptPost(url.build(util.endpoint(adobe.EDEN_URL, "Activate")), activationRequest)
    if not response then
        return nil, "Activation request failed: " .. tostring(requestErr)
    end
    logger.info("[ACSM] activate: parsing activation response...")
    local resp, parseErr = deserializeResponse(response, "Activate")
    if not resp then
        return nil, parseErr
    end
    if resp.error then
        local err = serverError(resp, response)
        logger.warn("[ACSM] activate: server returned error:", err)
        return nil, "Server returned error: " .. err
    end
    if type(resp.activationToken) ~= "table" or not resp.activationToken.device then
        return nil, "Server returned unexpected activation response"
    end
    logger.info("[ACSM] activate: success, device=", resp.activationToken.device)
    return resp.activationToken.device, fingerprint
end
return adobe
