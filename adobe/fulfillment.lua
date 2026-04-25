local fulfillment = {}

local DataStorage = require("datastorage")
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local socket = require("socket")
local socketutil = require("socketutil")
local koutil = require("util")

local adobe = require("adobe.adobe")
local crypto = require("adobe.util.crypto")
local dom = require("adobe.util.dom")
local epub = require("adobe.epub")
local nativecrypto = require("adobe.util.nativecrypto")
local util = require("adobe.util.util")
local xml = require("adobe.util.xml")

local ADEPT = "http://ns.adobe.com/adept"
local ASN_NS_TAG = 1
local ASN_CHILD = 2
local ASN_END_TAG = 3
local ASN_TEXT = 4
local ASN_ATTRIBUTE = 5

local function requestToString(request)
    local sink, resp = socketutil.table_sink({})
    request.sink = sink
    request.headers = request.headers or {}
    request.headers["User-Agent"] = request.headers["User-Agent"] or socketutil.USER_AGENT

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local ok, code = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()
    if not ok then
        return nil, code
    end
    local body = table.concat(resp)
    if body == "" and not code then
        return nil, "request failed"
    end
    return body, code
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

local function collectNotifyUrls(node, nsMap, urls)
    urls = urls or {}
    for _, child in ipairs(node._children or {}) do
        if child._type == "ELEMENT" then
            local childNsMap = dom.nsMapFor(child, nsMap)
            local childNs, childName = dom.resolveNodeName(child, nsMap)
            if childNs == ADEPT and childName == "notify" then
                local notifyUrl = dom.childText(child, childNsMap, "notifyURL", ADEPT)
                if notifyUrl and notifyUrl ~= "" then
                    urls[#urls + 1] = notifyUrl
                end
            end
            collectNotifyUrls(child, childNsMap, urls)
        end
    end
    return urls
end

local function appendHashString(buf, value)
    local len = #value
    buf[#buf + 1] = string.char(math.floor(len / 256))
    buf[#buf + 1] = string.char(len % 256)
    buf[#buf + 1] = value
end

local function buildAdobeHashBuffer(node, nsMap, buf)
    local childNsMap = dom.nsMapFor(node, nsMap)
    local namespace, localname = dom.resolveNodeName(node, childNsMap)

    if namespace == ADEPT and (localname == "hmac" or localname == "signature") then
        return
    end

    buf[#buf + 1] = string.char(ASN_NS_TAG)
    appendHashString(buf, namespace)
    appendHashString(buf, localname)

    local attrs = {}
    for ak, av in pairs(node._attr or {}) do
        if not ak:match("^xmlns") then
            attrs[#attrs + 1] = { ak = ak, av = av }
        end
    end
    table.sort(attrs, function(a, b) return a.ak < b.ak end)

    for _, attr in ipairs(attrs) do
        buf[#buf + 1] = string.char(ASN_ATTRIBUTE)
        local prefix, attrLocal = attr.ak:match("^(.-):(.+)$")
        if prefix then
            appendHashString(buf, childNsMap[prefix] or "")
            appendHashString(buf, attrLocal)
        else
            appendHashString(buf, "")
            appendHashString(buf, attr.ak)
        end
        appendHashString(buf, attr.av)
    end

    buf[#buf + 1] = string.char(ASN_CHILD)
    for _, child in ipairs(node._children or {}) do
        if child._type == "TEXT" then
            local trimmed = (child._text or ""):match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then
                local offset = 1
                while offset <= #trimmed do
                    local chunk = trimmed:sub(offset, offset + 0x7FFE)
                    buf[#buf + 1] = string.char(ASN_TEXT)
                    appendHashString(buf, chunk)
                    offset = offset + #chunk
                end
            end
        elseif child._type == "ELEMENT" then
            buildAdobeHashBuffer(child, childNsMap, buf)
        end
    end

    buf[#buf + 1] = string.char(ASN_END_TAG)
end

local function adobeDigest(xmlString)
    local document = dom.parse(xmlString)
    local root = dom.firstElementChild(document)
    if not root then
        return nil, "Missing XML root element"
    end

    local buf = {}
    buildAdobeHashBuffer(root, {}, buf)

    return nativecrypto.sha1(table.concat(buf))
end

local function signXmlBody(xmlString, signingKey)
    local hashBytes, err = adobeDigest(xmlString)
    if not hashBytes then
        return nil, err
    end

    local signature, signErr = signingKey:sign_raw(hashBytes, nativecrypto.RSA_PKCS1_PADDING)
    if not signature then
        return nil, signErr
    end
    return util.base64.encode(signature)
end

function fulfillment.extractCertFromPKCS12(pkcs12B64, deviceKey)
    local pass = util.base64.encode(deviceKey.key)
    local decoded, err = nativecrypto.parse_pkcs12(util.base64.decode(pkcs12B64), pass)
    if err then return nil, err end
    return util.base64.encode(decoded.cert_der)
end

function fulfillment.operatorAuth(operatorURL, userUUID, userCert, licenseCert, authCert)
    local authURL = operatorURL:gsub("/Fulfill$", ""):gsub("/+$", "") .. "/Auth"
    local body = '<?xml version="1.0"?>\n'
    body = body .. '<adept:credentials xmlns:adept="' .. ADEPT .. '">\n'
    body = body .. '  <adept:user>' .. userUUID .. '</adept:user>\n'
    body = body .. '  <adept:certificate>' .. userCert .. '</adept:certificate>\n'
    body = body .. '  <adept:licenseCertificate>' .. licenseCert .. '</adept:licenseCertificate>\n'
    body = body .. '  <adept:authenticationCertificate>' .. authCert .. '</adept:authenticationCertificate>\n'
    body = body .. '</adept:credentials>'

    logger.info("[ACSM] Operator auth:", authURL)
    local resp, err = adeptPost(authURL, body)
    if not resp then
        return nil, "Operator auth failed: " .. tostring(err)
    end
    local parsed = xml.deserialize(resp or "")
    if parsed and parsed.error then
        return nil, "Operator auth failed: " .. (parsed.error._attr and parsed.error._attr.data or resp)
    end
    return true
end

function fulfillment.initLicenseService(activationURL, operatorURL, userUUID, signingKey)
    local nonce = crypto.nonce()
    local expiration = util.expiration(10)

    local body = '<?xml version="1.0"?>\n'
    body = body .. '<adept:licenseServiceRequest xmlns:adept="' .. ADEPT .. '" identity="user">\n'
    body = body .. '  <adept:operatorURL>' .. dom.xmlEscape(operatorURL) .. '</adept:operatorURL>\n'
    body = body .. '  <adept:nonce>' .. nonce .. '</adept:nonce>\n'
    body = body .. '  <adept:expiration>' .. expiration .. '</adept:expiration>\n'
    body = body .. '  <adept:user>' .. userUUID .. '</adept:user>\n'
    local sig, sigErr = signXmlBody(body .. '</adept:licenseServiceRequest>', signingKey)
    if not sig then return nil, "InitLicenseService signing failed: " .. sigErr end
    body = body .. '  <adept:signature>' .. sig .. '</adept:signature>\n'
    body = body .. '</adept:licenseServiceRequest>'

    local initURL = activationURL:gsub("/+$", "") .. "/InitLicenseService"
    logger.info("[ACSM] InitLicenseService:", initURL)
    local resp, err = adeptPost(initURL, body)
    if not resp then
        return nil, "InitLicenseService failed: " .. tostring(err)
    end
    local parsed = xml.deserialize(resp or "")
    if parsed and parsed.error then
        return nil, "InitLicenseService error: " .. (parsed.error._attr and parsed.error._attr.data or resp)
    end
    return true
end

function fulfillment.fulfill(acsmPath, userUUID, deviceUUID, fingerprint, signingKey)
    local acsmContent = koutil.readFromFile(acsmPath, "rb")
    if not acsmContent then
        return nil, "Cannot open ACSM file: " .. tostring(acsmPath)
    end

    local acsmParsed = xml.deserialize(acsmContent)
    local token = acsmParsed.fulfillmentToken
    if not token then return nil, "No fulfillmentToken in ACSM" end

    local operatorURL = token.operatorURL
    if type(operatorURL) == "table" then operatorURL = operatorURL[1] end
    if not operatorURL then return nil, "No operatorURL in ACSM" end

    local acsmXml = acsmContent:gsub("^<%?xml[^?]*%?>%s*", ""):gsub("%s+$", "")
    local body = '<?xml version="1.0"?>'
    body = body .. '<adept:fulfill xmlns:adept="' .. ADEPT .. '">'
    body = body .. '<adept:user>' .. userUUID .. '</adept:user>'
    body = body .. '<adept:device>' .. deviceUUID .. '</adept:device>'
    body = body .. '<adept:deviceType>standalone</adept:deviceType>'
    body = body .. acsmXml
    body = body .. '<adept:targetDevice>'
    body = body .. '<adept:softwareVersion>' .. adobe.VERSION.hobbes .. '</adept:softwareVersion>'
    body = body .. '<adept:clientOS>' .. adobe.VERSION.os .. '</adept:clientOS>'
    body = body .. '<adept:clientLocale>en</adept:clientLocale>'
    body = body .. '<adept:clientVersion>' .. adobe.VERSION.version .. '</adept:clientVersion>'
    body = body .. '<adept:deviceType>standalone</adept:deviceType>'
    body = body .. '<adept:productName>ADOBE Digitial Editions</adept:productName>'
    body = body .. '<adept:fingerprint>' .. fingerprint .. '</adept:fingerprint>'
    body = body .. '<adept:activationToken>'
    body = body .. '<adept:user>' .. userUUID .. '</adept:user>'
    body = body .. '<adept:device>' .. deviceUUID .. '</adept:device>'
    body = body .. '</adept:activationToken>'
    body = body .. '</adept:targetDevice>'
    body = body .. '</adept:fulfill>'

    local sig, sigErr = signXmlBody(body, signingKey)
    if not sig then return nil, "Fulfill signing failed: " .. sigErr end
    body = body:gsub("</adept:fulfill>$", "<adept:signature>" .. sig .. "</adept:signature></adept:fulfill>")

    local fulfillURL = operatorURL:gsub("/+$", "") .. "/Fulfill"
    logger.info("[ACSM] Fulfill:", fulfillURL)

    local resp, code = adeptPost(fulfillURL, body)
    if not resp or resp == "" then
        return nil, "Fulfill request failed: " .. tostring(code)
    end

    local parsed = xml.deserialize(resp)
    if parsed.error then
        return nil, "Fulfill error: " .. (parsed.error._attr and parsed.error._attr.data or resp)
    end

    local root = dom.parse(resp)
    local rootNsMap = { adept = ADEPT, [""] = ADEPT }
    local fr, frNsMap = dom.findDescendant(root, rootNsMap, "fulfillmentResult", ADEPT)
    if not fr then
        return nil, "No fulfillmentResult in response"
    end
    local rii, riiNsMap = dom.firstElement(fr, frNsMap, "resourceItemInfo", ADEPT)
    if not rii then
        return nil, "No resourceItemInfo in response"
    end
    local licenseTokenNode, licenseTokenNsMap = dom.firstElement(rii, riiNsMap, "licenseToken", ADEPT)
    if not licenseTokenNode then
        return nil, "No licenseToken in response"
    end

    return {
        response = resp,
        operatorURL = operatorURL,
        src = dom.childText(rii, riiNsMap, "src", ADEPT),
        encryptedKey = dom.childText(licenseTokenNode, licenseTokenNsMap, "encryptedKey", ADEPT),
        keyType = dom.childText(licenseTokenNode, licenseTokenNsMap, "keyType", ADEPT),
        licenseURL = dom.childText(licenseTokenNode, licenseTokenNsMap, "licenseURL", ADEPT),
        licenseTokenXml = dom.serializeNode(licenseTokenNode),
        notifyURLs = collectNotifyUrls(fr, frNsMap, {}),
    }
end

function fulfillment.downloadBook(srcUrl, outputPath)
    local handle, err = io.open(outputPath, "wb")
    if not handle then
        return nil, err
    end

    local sink, sinkErr = socketutil.file_sink(handle)
    if not sink then
        return nil, sinkErr
    end

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local ok, code = pcall(function()
        return socket.skip(1, http.request({
            url = srcUrl,
            sink = sink,
            headers = { ["User-Agent"] = socketutil.USER_AGENT },
        }))
    end)
    socketutil:reset_timeout()
    if not ok then
        return nil, code
    end

    local data = koutil.readFromFile(outputPath, "rb")
    if not data or data == "" then
        return nil, "Book download failed: " .. tostring(code)
    end
    return data
end

function fulfillment.decryptBookKey(encryptedKeyB64, licenseKey)
    if not encryptedKeyB64 then
        return nil, "Missing encryptedKey"
    end
    local decrypted, err = licenseKey.pkey:decrypt(util.base64.decode(encryptedKeyB64), nativecrypto.RSA_PKCS1_PADDING)
    if err then return nil, err end
    return decrypted
end

function fulfillment.notify(notifyURL, userUUID, deviceUUID, signingKey)
    local nonce = crypto.nonce()
    local expiration = util.expiration(10)

    local body = '<?xml version="1.0"?>\n'
    body = body .. '<adept:notification xmlns:adept="' .. ADEPT .. '">\n'
    body = body .. '  <adept:user>' .. userUUID .. '</adept:user>\n'
    body = body .. '  <adept:device>' .. deviceUUID .. '</adept:device>\n'
    body = body .. '  <adept:nonce>' .. nonce .. '</adept:nonce>\n'
    body = body .. '  <adept:expiration>' .. expiration .. '</adept:expiration>\n'
    local sig, sigErr = signXmlBody(body .. '</adept:notification>', signingKey)
    if not sig then return nil, sigErr end
    body = body .. '  <adept:signature>' .. sig .. '</adept:signature>\n'
    body = body .. '</adept:notification>'

    logger.info("[ACSM] Notify:", notifyURL)
    adeptPost(notifyURL, body)
    return true
end

function fulfillment.process(acsmPath, outputPath, creds, deviceUUID, fingerprint, authCert)
    outputPath = outputPath or acsmPath:gsub("%.acsm$", ".epub")
    logger.info("[ACSM] fulfillment.process: acsmPath=", acsmPath, "outputPath=", outputPath)

    local userUUID = creds.user
    if type(userUUID) == "table" then userUUID = userUUID[1] end

    logger.info("[ACSM] fulfillment.process: extracting user cert from PKCS12...")
    local userCert, certErr = fulfillment.extractCertFromPKCS12(creds.pkcs12, creds.deviceKey)
    if not userCert then return nil, "Failed to extract cert: " .. certErr end
    logger.info("[ACSM] fulfillment.process: got user cert")

    logger.info("[ACSM] fulfillment.process: reading ACSM file...")
    local acsmContent = koutil.readFromFile(acsmPath, "rb")
    if not acsmContent then
        return nil, "Cannot open ACSM file: " .. tostring(acsmPath)
    end
    local acsmParsed = xml.deserialize(acsmContent)
    local operatorURL = acsmParsed.fulfillmentToken.operatorURL
    if type(operatorURL) == "table" then operatorURL = operatorURL[1] end
    if not operatorURL then return nil, "No operatorURL in ACSM" end
    logger.info("[ACSM] fulfillment.process: operatorURL=", operatorURL)

    logger.info("[ACSM] fulfillment.process: decoding pkcs12...")
    local pkcs12Key = crypto.decodepkcs12(creds.pkcs12, creds.deviceKey)
    local activationURL = creds.activationURL or "https://adeactivate.adobe.com/adept"
    if not creds.activationURL and creds.activationXml then
        local activationParsed = xml.deserialize(creds.activationXml)
        local activationToken = activationParsed.activationInfo and activationParsed.activationInfo.activationToken
            or activationParsed.activationToken
        if activationToken and activationToken.activationURL then
            activationURL = activationToken.activationURL
            if type(activationURL) == "table" then activationURL = activationURL[1] end
        end
    end

    logger.info("[ACSM] fulfillment.process: doing operator auth...")
    local ok, err = fulfillment.operatorAuth(operatorURL, userUUID, userCert, creds.licenseCert, authCert)
    if not ok then return nil, err end
    logger.info("[ACSM] fulfillment.process: operator auth done, init license service...")

    ok, err = fulfillment.initLicenseService(activationURL, operatorURL, userUUID, pkcs12Key)
    if not ok then return nil, err end
    logger.info("[ACSM] fulfillment.process: license service initialized, fulfilling...")

    local result
    result, err = fulfillment.fulfill(acsmPath, userUUID, deviceUUID, fingerprint, pkcs12Key)
    if err and err:find("E_ADEPT_DISTRIBUTOR_AUTH") then
        logger.info("[ACSM] fulfillment.process: got DISTRIBUTOR_AUTH error, retrying operator auth...")
        fulfillment.operatorAuth(operatorURL, userUUID, userCert, creds.licenseCert, authCert)
        result, err = fulfillment.fulfill(acsmPath, userUUID, deviceUUID, fingerprint, pkcs12Key)
    end
    if err then return nil, err end
    logger.info("[ACSM] fulfillment.process: fulfillment OK, download URL=", result.src)

    local cacheDir = DataStorage:getDataDir() .. "/cache/acsm.koplugin"
    logger.info("[ACSM] fulfillment.process: ensuring cache dir=", cacheDir)
    koutil.makePath(cacheDir)
    local tmpEpub = cacheDir .. "/fulfillment.epub"
    logger.info("[ACSM] fulfillment.process: downloading book to", tmpEpub)
    local _, downloadErr = fulfillment.downloadBook(result.src, tmpEpub)
    if downloadErr then return nil, downloadErr end
    logger.info("[ACSM] fulfillment.process: download complete, decrypting book key...")

    local bookKey, bookKeyErr = fulfillment.decryptBookKey(result.encryptedKey, creds.licenseKey)
    if not bookKey then return nil, "Failed to decrypt book key: " .. bookKeyErr end
    logger.info("[ACSM] fulfillment.process: book key decrypted, decrypting EPUB...")

    local decryptedInfo, decryptErr = epub.decryptAdobeEpub(tmpEpub, outputPath, bookKey)
    os.remove(tmpEpub)
    if not decryptedInfo then return nil, "Failed to decrypt EPUB: " .. decryptErr end
    logger.info("[ACSM] fulfillment.process: EPUB decrypted to", outputPath)

    if result.notifyURLs and #result.notifyURLs > 0 then
        for _, notifyURL in ipairs(result.notifyURLs) do
            fulfillment.notify(notifyURL, userUUID, deviceUUID, pkcs12Key)
        end
    end

    return {
        outputPath = outputPath,
        bookKey = bookKey,
        decryptedEntries = decryptedInfo.decryptedEntries,
        remainingEncryptionXml = decryptedInfo.remainingEncryptionXml,
        response = result.response,
    }
end

return fulfillment
