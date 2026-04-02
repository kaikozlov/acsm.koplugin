local adobe = {}

-- load required modules
local http   = require("socket.http")       -- HTTP(S)
local url    = require("socket.url")        -- URL manipulation
local util   = require("adobe.util.util")   -- basic utility functions
local crypto = require("adobe.util.crypto") -- crypto helper
local xml    = require("adobe.util.xml")    -- xml helper
local base64 = require("adobe.util.util").base64
local ltn12  = require("ltn12")             -- HTTP(S) request/response

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
    local response = http.request(url.build(util.endpoint(adobe.EDEN_URL, "AuthenticationServiceInfo")))
    local info = xml.deserialize(response).authenticationServiceInfo

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
    local deviceKey = crypto.deviceKey.new()

    local authKey = crypto.key.new()
    local licenseKey = crypto.key.new()

    local login = crypto.encryptLogin(username, password, deviceKey, authCert)
    local signInRequest = xml.adobe({
        _attr = { method = method},
        signInData = login,
        publicAuthKey = base64.encode(authKey.pkey:tostring("public", "DER")),
        encryptedPrivateAuthKey = base64.encode(deviceKey:encrypt(authKey:topkcs8())),
        publicLicenseKey = base64.encode(licenseKey.pkey:tostring("public", "DER")),
        encryptedPrivateLicenseKey = base64.encode(deviceKey:encrypt(licenseKey:topkcs8()))
    }, "signIn")

    local resp = {}
    http.request{
        url = url.build(util.endpoint(adobe.EDEN_URL, "SignInDirect")),
        sink = ltn12.sink.table(resp),
        method = "POST",
        headers = { ["Content-Type"] = "application/vnd.adobe.adept+xml" },
        source = ltn12.source.string(signInRequest)
    }
    resp = table.concat(resp)
    resp = xml.deserialize(resp)

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
    local serial = crypto.serial()
    local fingerprint = crypto.fingerprint(serial, deviceKey)
    local pkcs12Key = crypto.decodepkcs12(pkcs12, deviceKey)

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

    local resp = {}
    http.request{
         url = url.build(util.endpoint(adobe.EDEN_URL, "Activate")),
         sink = ltn12.sink.table(resp),
         method = "POST",
         headers = { ["Content-Type"] = "application/vnd.adobe.adept+xml" },
         source = ltn12.source.string(activationRequest)
    }
    resp = table.concat(resp)
    resp = xml.deserialize(resp) 
    if resp.error ~= nil then
        error("Server returned error: " .. resp.error._attr.data)
    end
    
    return resp.activationToken.device, fingerprint
end
return adobe
