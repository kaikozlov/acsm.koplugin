local fulfillment = {}

local http = require("socket.http")
local url = require("socket.url")
local ltn12 = require("ltn12")
local xml2lua = require("xml2lua")
local domhandler = require("xmlhandler.dom")

local util = require("adobe.util.util")
local crypto = require("adobe.util.crypto")
local xml = require("adobe.util.xml")
local adobe = require("adobe.adobe")
local epub = require("adobe.epub")
local nativecrypto = require("adobe.util.nativecrypto")

local ADEPT = "http://ns.adobe.com/adept"
local ASN_NS_TAG = 1
local ASN_CHILD = 2
local ASN_END_TAG = 3
local ASN_TEXT = 4
local ASN_ATTRIBUTE = 5

local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function xmlEscape(s)
    return (tostring(s)
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeFile(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

local function adeptPost(endpoint, body)
    local resp = {}
    local _, code = http.request({
        url = endpoint,
        sink = ltn12.sink.table(resp),
        method = "POST",
        headers = {
            ["Content-Type"] = "application/vnd.adobe.adept+xml",
            ["User-Agent"] = "book2png",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
    })
    return table.concat(resp), code
end

local function httpGet(endpoint)
    local resp = {}
    local _, code = http.request({
        url = endpoint,
        sink = ltn12.sink.table(resp),
        headers = { ["User-Agent"] = "book2png" },
    })
    return table.concat(resp), code
end

local function parseXmlDom(xmlString)
    local handler = domhandler:new()
    handler.options.commentNode = 0
    handler.options.piNode = 0
    handler.options.dtdNode = 0
    handler.options.declNode = 0
    local parser = xml2lua.parser(handler)
    parser:parse(xmlString)
    return handler.root
end

local function nsMapFor(node, nsMap)
    local childNsMap = {}
    for k, v in pairs(nsMap or {}) do
        childNsMap[k] = v
    end
    for ak, av in pairs(node._attr or {}) do
        if ak == "xmlns" then
            childNsMap[""] = av
        else
            local prefix = ak:match("^xmlns:(.+)$")
            if prefix then
                childNsMap[prefix] = av
            end
        end
    end
    return childNsMap
end

local function resolveNodeName(node, nsMap)
    local ownNs = node._attr and node._attr.xmlns or nil
    local prefix, localname = node._name:match("^(.-):(.+)$")
    if prefix then
        return nsMap[prefix] or "", localname
    end
    return ownNs or nsMap[""] or "", node._name
end

local function firstElement(node, nsMap, localname, namespace)
    for _, child in ipairs(node._children or {}) do
        if child._type == "ELEMENT" then
            local childNsMap = nsMapFor(child, nsMap)
            local childNs, childName = resolveNodeName(child, nsMap)
            if childName == localname and (namespace == nil or childNs == namespace) then
                return child, childNsMap
            end
        end
    end
    return nil, nil
end

local function textOf(node)
    local parts = {}
    for _, child in ipairs(node._children or {}) do
        if child._type == "TEXT" then
            local trimmed = child._text and child._text:match("^%s*(.-)%s*$") or ""
            if trimmed ~= "" then
                parts[#parts + 1] = trimmed
            end
        end
    end
    return table.concat(parts)
end

local function childText(node, nsMap, localname, namespace)
    local child = firstElement(node, nsMap, localname, namespace)
    if not child then return nil end
    return textOf(child)
end

local function findDescendant(node, nsMap, localname, namespace)
    local found, foundNsMap = firstElement(node, nsMap, localname, namespace)
    if found then return found, foundNsMap end

    for _, child in ipairs(node._children or {}) do
        if child._type == "ELEMENT" then
            local childNsMap = nsMapFor(child, nsMap)
            local desc, descNsMap = findDescendant(child, childNsMap, localname, namespace)
            if desc then return desc, descNsMap end
        end
    end
    return nil, nil
end

local function collectNotifyUrls(node, nsMap, urls)
    urls = urls or {}
    for _, child in ipairs(node._children or {}) do
        if child._type == "ELEMENT" then
            local childNsMap = nsMapFor(child, nsMap)
            local childNs, childName = resolveNodeName(child, nsMap)
            if childNs == ADEPT and childName == "notify" then
                local notifyUrl = childText(child, childNsMap, "notifyURL", ADEPT)
                if notifyUrl and notifyUrl ~= "" then
                    urls[#urls + 1] = notifyUrl
                end
            end
            collectNotifyUrls(child, childNsMap, urls)
        end
    end
    return urls
end

local function serializeNode(node)
    local attrs = {}
    for ak, av in pairs(node._attr or {}) do
        attrs[#attrs + 1] = { ak, av }
    end
    table.sort(attrs, function(a, b) return a[1] < b[1] end)

    local parts = { "<" .. node._name }
    for _, attr in ipairs(attrs) do
        parts[#parts + 1] = " " .. attr[1] .. '="' .. xmlEscape(attr[2]) .. '"'
    end

    if not node._children or #node._children == 0 then
        parts[#parts + 1] = "/>"
        return table.concat(parts)
    end

    parts[#parts + 1] = ">"
    for _, child in ipairs(node._children) do
        if child._type == "TEXT" then
            parts[#parts + 1] = xmlEscape(child._text or "")
        elseif child._type == "ELEMENT" then
            parts[#parts + 1] = serializeNode(child)
        end
    end
    parts[#parts + 1] = "</" .. node._name .. ">"
    return table.concat(parts)
end

local function firstElementChild(node)
    if node and node._type == "ELEMENT" then
        return node
    end
    for _, child in ipairs(node._children or {}) do
        if child._type == "ELEMENT" then
            return child
        end
    end
    return nil
end

local function appendHashString(buf, value)
    local len = #value
    buf[#buf + 1] = string.char(math.floor(len / 256))
    buf[#buf + 1] = string.char(len % 256)
    buf[#buf + 1] = value
end

local function buildAdobeHashBuffer(node, nsMap, buf)
    local childNsMap = nsMapFor(node, nsMap)
    local namespace, localname = resolveNodeName(node, childNsMap)

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
    local document = parseXmlDom(xmlString)
    local root = firstElementChild(document)
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

    print("  Operator auth: " .. authURL)
    local resp = adeptPost(authURL, body)
    local parsed = xml.deserialize(resp or "")
    if parsed and parsed.error then
        return nil, "Operator auth failed: " .. (parsed.error._attr and parsed.error._attr.data or resp)
    end
    print("  Operator auth successful")
    return true
end

function fulfillment.initLicenseService(activationURL, operatorURL, userUUID, signingKey)
    local nonce = crypto.nonce()
    local expiration = util.expiration(10)

    local body = '<?xml version="1.0"?>\n'
    body = body .. '<adept:licenseServiceRequest xmlns:adept="' .. ADEPT .. '" identity="user">\n'
    body = body .. '  <adept:operatorURL>' .. xmlEscape(operatorURL) .. '</adept:operatorURL>\n'
    body = body .. '  <adept:nonce>' .. nonce .. '</adept:nonce>\n'
    body = body .. '  <adept:expiration>' .. expiration .. '</adept:expiration>\n'
    body = body .. '  <adept:user>' .. userUUID .. '</adept:user>\n'
    local sig, sigErr = signXmlBody(body .. '</adept:licenseServiceRequest>', signingKey)
    if not sig then return nil, "InitLicenseService signing failed: " .. sigErr end
    body = body .. '  <adept:signature>' .. sig .. '</adept:signature>\n'
    body = body .. '</adept:licenseServiceRequest>'

    local initURL = activationURL:gsub("/+$", "") .. "/InitLicenseService"
    print("  InitLicenseService: " .. initURL)
    local resp = adeptPost(initURL, body)
    local parsed = xml.deserialize(resp or "")
    if parsed and parsed.error then
        return nil, "InitLicenseService error: " .. (parsed.error._attr and parsed.error._attr.data or resp)
    end
    print("  InitLicenseService successful")
    return true
end

function fulfillment.fulfill(acsmPath, userUUID, deviceUUID, fingerprint, signingKey)
    local acsmContent = readFile(acsmPath)
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

    writeFile("/tmp/fulfill_unsigned.xml", body)

    local sig, sigErr = signXmlBody(body, signingKey)
    if not sig then return nil, "Fulfill signing failed: " .. sigErr end
    body = body:gsub("</adept:fulfill>$", "<adept:signature>" .. sig .. "</adept:signature></adept:fulfill>")

    local fulfillURL = operatorURL:gsub("/+$", "") .. "/Fulfill"
    print("  Fulfill: " .. fulfillURL)
    writeFile("/tmp/fulfill_request.xml", body)

    local resp, code = adeptPost(fulfillURL, body)
    if not resp or resp == "" then
        return nil, "Fulfill request failed: " .. tostring(code)
    end
    writeFile("/tmp/fulfill_response.xml", resp)

    local parsed = xml.deserialize(resp)
    if parsed.error then
        return nil, "Fulfill error: " .. (parsed.error._attr and parsed.error._attr.data or resp)
    end

    local root = parseXmlDom(resp)
    local rootNsMap = { adept = ADEPT, [""] = ADEPT }
    local fr, frNsMap = findDescendant(root, rootNsMap, "fulfillmentResult", ADEPT)
    if not fr then
        return nil, "No fulfillmentResult in response"
    end
    local rii, riiNsMap = firstElement(fr, frNsMap, "resourceItemInfo", ADEPT)
    if not rii then
        return nil, "No resourceItemInfo in response"
    end
    local licenseTokenNode, licenseTokenNsMap = firstElement(rii, riiNsMap, "licenseToken", ADEPT)
    if not licenseTokenNode then
        return nil, "No licenseToken in response"
    end

    return {
        response = resp,
        operatorURL = operatorURL,
        src = childText(rii, riiNsMap, "src", ADEPT),
        encryptedKey = childText(licenseTokenNode, licenseTokenNsMap, "encryptedKey", ADEPT),
        keyType = childText(licenseTokenNode, licenseTokenNsMap, "keyType", ADEPT),
        licenseURL = childText(licenseTokenNode, licenseTokenNsMap, "licenseURL", ADEPT),
        licenseTokenXml = serializeNode(licenseTokenNode),
        notifyURLs = collectNotifyUrls(fr, frNsMap, {}),
    }
end

function fulfillment.downloadBook(srcUrl, outputPath)
    local out = assert(io.open(outputPath, "wb"))
    local _, code = http.request({
        url = srcUrl,
        sink = ltn12.sink.file(out),
        headers = { ["User-Agent"] = "book2png" },
    })
    local data = readFile(outputPath)
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

function fulfillment.getLicenseServiceCert(operatorURL, licenseURL)
    local infoUrl = operatorURL:gsub("/+$", "") .. "/LicenseServiceInfo?licenseURL=" .. licenseURL
    local resp, code = httpGet(infoUrl)
    if not resp or resp == "" then
        return nil, "LicenseServiceInfo request failed: " .. tostring(code)
    end
    local parsed = xml.deserialize(resp)
    if parsed.error then
        return nil, parsed.error._attr and parsed.error._attr.data or resp
    end

    local info = parsed.licenseServiceInfo or parsed
    local cert = info.certificate
    if type(cert) == "table" then cert = cert[1] end
    local returnedUrl = info.licenseURL
    if type(returnedUrl) == "table" then returnedUrl = returnedUrl[1] end
    if not cert then
        return nil, "No certificate in license service response"
    end
    return {
        certificate = cert,
        licenseURL = returnedUrl or licenseURL,
    }
end

function fulfillment.buildRightsXml(licenseTokenXml, licenseServiceInfo)
    local rights = '<?xml version="1.0"?>\n'
    rights = rights .. '<adept:rights xmlns:adept="' .. ADEPT .. '">\n'
    rights = rights .. licenseTokenXml .. "\n"
    rights = rights .. '  <adept:licenseServiceInfo>\n'
    rights = rights .. '    <adept:licenseURL>' .. xmlEscape(licenseServiceInfo.licenseURL) .. '</adept:licenseURL>\n'
    rights = rights .. '    <adept:certificate>' .. licenseServiceInfo.certificate .. '</adept:certificate>\n'
    rights = rights .. '  </adept:licenseServiceInfo>\n'
    rights = rights .. '</adept:rights>'
    return rights
end

function fulfillment.injectRightsXml(epubPath, rightsXml, outputPath)
    local tmpDir = os.tmpname()
    os.remove(tmpDir)
    assert(os.execute("mkdir -p " .. shellQuote(tmpDir .. "/META-INF")))
    writeFile(tmpDir .. "/META-INF/rights.xml", rightsXml)
    assert(os.execute("cp " .. shellQuote(epubPath) .. " " .. shellQuote(outputPath)))
    assert(os.execute("cd " .. shellQuote(tmpDir) .. " && zip -q -u " .. shellQuote(outputPath) .. " META-INF/rights.xml"))
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

    print("  Notify: " .. notifyURL)
    adeptPost(notifyURL, body)
    return true
end

function fulfillment.process(acsmPath, outputPath, creds, deviceUUID, fingerprint, authCert)
    outputPath = outputPath or acsmPath:gsub("%.acsm$", ".epub")

    local userUUID = creds.user
    if type(userUUID) == "table" then userUUID = userUUID[1] end

    print("Extracting certificate from PKCS12...")
    local userCert, certErr = fulfillment.extractCertFromPKCS12(creds.pkcs12, creds.deviceKey)
    if not userCert then return nil, "Failed to extract cert: " .. certErr end

    local acsmContent = readFile(acsmPath)
    if not acsmContent then
        return nil, "Cannot open ACSM file: " .. tostring(acsmPath)
    end
    local acsmParsed = xml.deserialize(acsmContent)
    local operatorURL = acsmParsed.fulfillmentToken.operatorURL
    if type(operatorURL) == "table" then operatorURL = operatorURL[1] end
    if not operatorURL then return nil, "No operatorURL in ACSM" end

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

    print("\nStep 1: Operator Auth")
    local ok, err = fulfillment.operatorAuth(operatorURL, userUUID, userCert, creds.licenseCert, authCert)
    if not ok then return nil, err end

    print("\nStep 2: InitLicenseService")
    ok, err = fulfillment.initLicenseService(activationURL, operatorURL, userUUID, pkcs12Key)
    if not ok then return nil, err end

    print("\nStep 3: Fulfill")
    local result
    result, err = fulfillment.fulfill(acsmPath, userUUID, deviceUUID, fingerprint, pkcs12Key)
    if err and err:find("E_ADEPT_DISTRIBUTOR_AUTH") then
        print("  Distributor auth failed, retrying operator auth...")
        fulfillment.operatorAuth(operatorURL, userUUID, userCert, creds.licenseCert, authCert)
        result, err = fulfillment.fulfill(acsmPath, userUUID, deviceUUID, fingerprint, pkcs12Key)
    end
    if err then return nil, err end

    print("\nStep 4: Extracting download info")
    print("  Download URL: " .. tostring(result.src))
    print("  Key type: " .. tostring(result.keyType))

    print("\nStep 5: Downloading book")
    local tmpEpub = os.tmpname() .. ".epub"
    local _, downloadErr = fulfillment.downloadBook(result.src, tmpEpub)
    if downloadErr then return nil, downloadErr end

    print("\nStep 6: Decrypting book key")
    local bookKey, bookKeyErr = fulfillment.decryptBookKey(result.encryptedKey, creds.licenseKey)
    if not bookKey then return nil, "Failed to decrypt book key: " .. bookKeyErr end

    print("\nStep 7: Decrypting EPUB")
    local decryptedInfo, decryptErr = epub.decryptAdobeEpub(tmpEpub, outputPath, bookKey)
    os.remove(tmpEpub)
    if not decryptedInfo then return nil, "Failed to decrypt EPUB: " .. decryptErr end

    if result.notifyURLs and #result.notifyURLs > 0 then
        print("\nStep 8: Sending notifications")
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
