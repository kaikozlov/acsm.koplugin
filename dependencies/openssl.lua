-- NGX logging stub
ngx = {}
ngx.NOTICE = "[notice]"
ngx.DEBUG = "[debug]"
ngx.ERR = "[error]"
ngx.INFO = "[info]"
ngx.WARN = "[warn]"

ngx.debug = false

function ngx.log(...)
    -- get info about the function that called us
    local info = debug.getinfo(2, "Sl")
    -- turn our arguments into a string
    local args = {...}; local str = ""
    -- remove the first argument (the log level)
    local level = args[1]
    if level == ngx.DEBUG and ngx.debug == false then
        return
    end
    table.remove(args, 1)
    for i, v in ipairs(args) do 
        str = str .. v 
    end
    -- get the file name after the last slash
    local file = string.match(info.short_src, "[^/]+$")
    -- print the info
    print(os.date("%Y/%m/%d %X") .. " " .. level .. " " .. file .. ":" .. info.currentline .. ": " .. str)
end
-- END NGX logging stub

local ffi = require("ffi")
local C = ffi.C
local ffi_cast = ffi.cast
local ffi_str = ffi.string

local format_error = require("openssl.err").format_error

local OPENSSL_30, BORINGSSL
local library_loaded = false

local function try_require_modules()
  package.loaded["openssl.version"] = nil

  local pok, lib = pcall(require, "openssl.version")
  if pok then
    OPENSSL_30 = lib.OPENSSL_30
    BORINGSSL = lib.BORINGSSL

    require "openssl.include.crypto"
    require "openssl.include.objects"
  else
    package.loaded["openssl.version"] = nil
  end
end


local _M = {
  _VERSION = '0.8.10',
}

local libcrypto_name
local lib_candidates = _G.KO_ACSM_OPENSSL_CANDIDATES or {
  { crypto = "libs/libcrypto.so.57", ssl = "libs/libssl.so.60" },
  { crypto = "libs/libcrypto.so.3", ssl = "libs/libssl.so.3" },
  { crypto = "./libs/libcrypto.so.57", ssl = "./libs/libssl.so.60" },
  { crypto = "./libs/libcrypto.so.3", ssl = "./libs/libssl.so.3" },
  { crypto = "crypto", ssl = "ssl" },
  { crypto = "libcrypto.so", ssl = "libssl.so" },
  { crypto = "crypto.so.3", ssl = "ssl.so.3" },
  { crypto = "libcrypto.so.3", ssl = "libssl.so.3" },
  { crypto = "crypto.so.1.1", ssl = "ssl.so.1.1" },
  { crypto = "libcrypto.so.1.1", ssl = "libssl.so.1.1" },
  { crypto = "crypto.so.1.0", ssl = "ssl.so.1.0" },
  { crypto = "libcrypto.so.1.0", ssl = "libssl.so.1.0" },
  { crypto = "libcrypto.so.57", ssl = "libssl.so.60" },
}

function _M.load_library()
  if library_loaded then
    return libcrypto_name
  end
  local errors = {}
  for _, candidate in ipairs(lib_candidates) do
    -- true: load to global namespae
    local pok, err = pcall(ffi.load, candidate.crypto, true)
    if pok then
      libcrypto_name = candidate.crypto
      pcall(ffi.load, candidate.ssl, true)
      library_loaded = true

      try_require_modules()

      return libcrypto_name
    end
    errors[#errors + 1] = string.format("%s: %s", candidate.crypto, tostring(err))
  end

  return false, "unable to load crypto library (" .. table.concat(errors, "; ") .. ")"
end

function _M.load_modules()
  _M.bn = require("openssl.bn")
  _M.cipher = require("openssl.cipher")
  _M.digest = require("openssl.digest")
  _M.hmac = require("openssl.hmac")
  _M.kdf = require("openssl.kdf")
  _M.pkey = require("openssl.pkey")
  _M.objects = require("openssl.objects")
  _M.rand = require("openssl.rand")
  _M.version = require("openssl.version")
  _M.x509 = require("openssl.x509")
  _M.altname = require("openssl.x509.altname")
  _M.chain = require("openssl.x509.chain")
  _M.csr = require("openssl.x509.csr")
  _M.crl = require("openssl.x509.crl")
  _M.extension = require("openssl.x509.extension")
  _M.extensions = require("openssl.x509.extensions")
  _M.name = require("openssl.x509.name")
  _M.revoked = require("openssl.x509.revoked")
  _M.store = require("openssl.x509.store")
  _M.pkcs12 = require("openssl.pkcs12")
  _M.ssl = require("openssl.ssl")
  _M.ssl_ctx = require("openssl.ssl_ctx")

  if OPENSSL_30 then
    _M.provider = require("openssl.provider")
    _M.mac = require("openssl.mac")
    _M.ctx = require("openssl.ctx")
  end

  _M.bignum = _M.bn
end

function _M.luaossl_compat()
  _M.load_modules()

  _M.csr.setSubject = _M.csr.set_subject_name
  _M.csr.setPublicKey = _M.csr.set_pubkey

  _M.x509.setPublicKey = _M.x509.set_pubkey
  _M.x509.getPublicKey = _M.x509.get_pubkey
  _M.x509.setSerial = _M.x509.set_serial_number
  _M.x509.getSerial = _M.x509.get_serial_number
  _M.x509.setSubject = _M.x509.set_subject_name
  _M.x509.getSubject = _M.x509.get_subject_name
  _M.x509.setIssuer = _M.x509.set_issuer_name
  _M.x509.getIssuer = _M.x509.get_issuer_name
  _M.x509.getOCSP = _M.x509.get_ocsp_url

  local pkey_new = _M.pkey.new
  _M.pkey.new = function(a, b)
    if type(a) == "string" then
      return pkey_new(a, b and unpack(b))
    else
      return pkey_new(a, b)
    end
  end

  _M.cipher.encrypt = function(self, key, iv, padding)
    return self, _M.cipher.init(self, key, iv, true, not padding)
  end
  _M.cipher.decrypt = function(self, key, iv, padding)
    return self, _M.cipher.init(self, key, iv, false, not padding)
  end

  local digest_update = _M.digest.update
  _M.digest.update = function(self, ...)
    local ok, err = digest_update(self, ...)
    if ok then
      return self
    else
      return nil, err
    end
  end

  local store_verify = _M.store.verify
  _M.store.verify = function(...)
    local ok, err = store_verify(...)
    if err then
      return false, err
    else
      return true, ok
    end
  end

  local kdf_derive = _M.kdf.derive
  local kdf_keys_mappings = {
    iter = "pbkdf2_iter",
    key = "hkdf_key",
    info = "hkdf_info",
    secret = "tls1_prf_secret",
    seed = "tls1_prf_seed",
    maxmem_bytes = "scrypt_maxmem",
    N = "scrypt_N",
    r = "scrypt_r",
    p = "scrypt_p",
  }
  _M.kdf.derive = function(o)
    for k1, k2 in pairs(kdf_keys_mappings) do
      o[k1] = o[k2]
      o[k2] = nil
    end
    local hkdf_mode = o.hkdf_mode
    if hkdf_mode == "extract_and_expand" then
      o.hkdf_mode = _M.kdf.HKDEF_MODE_EXTRACT_AND_EXPAND
    elseif hkdf_mode == "extract_only" then
      o.hkdf_mode = _M.kdf.HKDEF_MODE_EXTRACT_ONLY
    elseif hkdf_mode == "expand_only" then
      o.hkdf_mode = _M.kdf.HKDEF_MODE_EXPAND_ONLY
    end
    return kdf_derive(o)
  end

  _M.pkcs12.new = function(tbl)
    local certs = {}
    local passphrase = tbl.passphrase
    if not tbl.key then
      return nil, "key must be set"
    end
    for _, cert in ipairs(tbl.certs) do
      if not _M.x509.istype(cert) then
        return nil, "certs must contains only x509 instance"
      end
      if cert:check_private_key(tbl.key) then
        tbl.cert = cert
      else
        certs[#certs+1] = cert
      end
    end
    tbl.cacerts = certs
    return _M.pkcs12.encode(tbl, passphrase)
  end

  _M.crl.add = _M.crl.add_revoked
  _M.crl.lookupSerial = _M.crl.get_by_serial

  for mod, tbl in pairs(_M) do
    if type(tbl) == 'table' then

      -- avoid using a same table as the iterrator will change
      local new_tbl = {}
      -- luaossl always error() out
      for k, f in pairs(tbl) do
        if type(f) == 'function' then
          local of = f
          new_tbl[k] = function(...)
            local ret = { of(...) }
            if ret and #ret > 1 and ret[#ret] then
              error(mod .. "." .. k .. "(): " .. ret[#ret])
            end
            return unpack(ret)
          end
        end
      end

      for k, f in pairs(new_tbl) do
        tbl[k] = f
      end

      setmetatable(tbl, {
        __index = function(t, k)
          local tok
          -- handle special case
          if k == 'toPEM' then
            tok = 'to_PEM'
          else
            tok = k:gsub("(%l)(%u)", function(a, b) return a .. "_" .. b:lower() end)
            if tok == k then
              return
            end
          end
          if type(tbl[tok]) == 'function' then
            return tbl[tok]
          end
        end
      })
    end
  end

  -- skip error() conversion
  _M.pkcs12.parse = function(p12, passphrase)
    local r, err = _M.pkcs12.decode(p12, passphrase)
    if err then error(err) end
    return r.key, r.cert, r.cacerts
  end
end

if OPENSSL_30 then
  require "openssl.include.evp"
  local provider = require "openssl.provider"
  local ctx_lib = require "openssl.ctx"
  local fips_provider_ctx

  function _M.set_fips_mode(enable, self_test)
    if (not not enable) == _M.get_fips_mode() then
      return true
    end

    if enable then
      local p, err = provider.load("fips")
      if not p then
        return false, err
      end
      fips_provider_ctx = p
      if self_test then
        local ok, err = p:self_test()
        if not ok then
          return false, err
        end
      end

    elseif fips_provider_ctx then -- disable
      local p = fips_provider_ctx
      fips_provider_ctx = nil
      return p:unload()
    end

    -- set algorithm in fips mode in default ctx
    -- this deny/allow non-FIPS compliant algorithms to be used from EVP interface
    -- and redirect/remove redirect implementation to fips provider
    if C.EVP_default_properties_enable_fips(ctx_lib.get_libctx(), enable and 1 or 0) == 0 then
      return false, format_error("openssl.set_fips_mode: EVP_default_properties_enable_fips")
    end

    return true
  end

  function _M.get_fips_mode()
    local pok = provider.is_available("fips")
    if not pok then
      return false
    end

    return C.EVP_default_properties_is_fips_enabled(ctx_lib.get_libctx()) == 1
  end

else
  function _M.set_fips_mode(enable)
    if (not not enable) == _M.get_fips_mode() then
      return true
    end

    if C.FIPS_mode_set(enable and 1 or 0) == 0 then
      return false, format_error("openssl.set_fips_mode")
    end

    return true
  end

  function _M.get_fips_mode()
    return C.FIPS_mode() == 1
  end
end

function _M.set_default_properties(props)
  if not OPENSSL_30 then
    return nil, "openssl.set_default_properties is only not supported from OpenSSL 3.0"
  end

  local ctx_lib = require "openssl.ctx"

  if C.EVP_set_default_properties(ctx_lib.get_libctx(), props) == 0 then
    return false, format_error("openssl.EVP_set_default_properties")
  end

  return true
end

local function list_legacy(typ, get_nid_cf)
  local typ_lower = string.lower(typ:sub(5)) -- cut off EVP_
  require ("openssl.include.evp." .. typ_lower)

  local ret = {}
  local fn = ffi_cast("fake_openssl_" .. typ_lower .. "_list_fn*",
              function(elem, from, to, arg)
                if elem ~= nil then
                  local nid = get_nid_cf(elem)
                  table.insert(ret, ffi_str(C.OBJ_nid2sn(nid)))
                end
                -- from/to (renamings) are ignored
              end)
  C[typ .. "_do_all_sorted"](fn, nil)
  fn:free()

  return ret
end

local function list_provided(typ)
  local typ_lower = string.lower(typ:sub(5)) -- cut off EVP_
  local typ_ptr = typ .. "*"
  require ("openssl.include.evp." .. typ_lower)
  local ctx_lib = require "openssl.ctx"

  local ret = {}

  local fn = ffi_cast("fake_openssl_" .. typ_lower .. "_provided_list_fn*",
              function(elem, _)
                elem = ffi_cast(typ_ptr, elem)
                local name = ffi_str(C[typ .. "_get0_name"](elem))
                -- alternate names are ignored, retrieve use TYPE_names_do_all
                local prov = ffi_str(C.OSSL_PROVIDER_get0_name(C[typ .. "_get0_provider"](elem)))
                table.insert(ret, name .. " @ " .. prov)
              end)

  C[typ .. "_do_all_provided"](ctx_lib.get_libctx(), fn, nil)
  fn:free()

  table.sort(ret)
  return ret
end

function _M.list_cipher_algorithms()
  if BORINGSSL then
    return nil, "openssl.list_cipher_algorithms is not supported on BoringSSL"
  end

  require "openssl.include.evp.cipher"
  local ret = list_legacy("EVP_CIPHER",
              OPENSSL_30 and C.EVP_CIPHER_get_nid or C.EVP_CIPHER_nid)

  if OPENSSL_30 then
    local ret_provided = list_provided("EVP_CIPHER")
    for _, r in ipairs(ret_provided) do
      table.insert(ret, r)
    end
  end

  return ret
end

function _M.list_digest_algorithms()
  if BORINGSSL then
    return nil, "openssl.list_digest_algorithms is not supported on BoringSSL"
  end

  require "openssl.include.evp.md"
  local ret = list_legacy("EVP_MD",
              OPENSSL_30 and C.EVP_MD_get_type or C.EVP_MD_type)

  if OPENSSL_30 then
    local ret_provided = list_provided("EVP_MD")
    for _, r in ipairs(ret_provided) do
      table.insert(ret, r)
    end
  end

  return ret
end

function _M.list_mac_algorithms()
  if not OPENSSL_30 then
    return nil, "openssl.list_mac_algorithms is only supported from OpenSSL 3.0"
  end

  return list_provided("EVP_MAC")
end

function _M.list_kdf_algorithms()
  if not OPENSSL_30 then
    return nil, "openssl.list_kdf_algorithms is only supported from OpenSSL 3.0"
  end

  return list_provided("EVP_KDF")
end

local valid_ssl_protocols = {
  ["SSLv3"]   = 0x0300,
  ["TLSv1"]   = 0x0301,
  ["TLSv1.1"] = 0x0302,
  ["TLSv1.2"] = 0x0303,
  ["TLSv1.3"] = 0x0304,
}

function _M.list_ssl_ciphers(cipher_list, ciphersuites, protocol)
  local ssl_lib = require("openssl.ssl")
  local ssl_macro = require("openssl.include.ssl")

  if protocol then
    if not valid_ssl_protocols[protocol] then
      return nil, "unknown protocol \"" .. protocol .. "\""
    end
    protocol = valid_ssl_protocols[protocol]
  end

  local ssl_ctx = C.SSL_CTX_new(C.TLS_server_method())
  if ssl_ctx == nil then
    return nil, format_error("SSL_CTX_new")
  end
  ffi.gc(ssl_ctx, C.SSL_CTX_free)

  local ssl = C.SSL_new(ssl_ctx)
  if ssl == nil then
    return nil, format_error("SSL_new")
  end
  ffi.gc(ssl, C.SSL_free)

  if protocol then
    if ssl_macro.SSL_set_min_proto_version(ssl, protocol) == 0 or
    ssl_macro.SSL_set_max_proto_version(ssl, protocol) == 0 then
        return nil, format_error("SSL_set_min/max_proto_version")
    end
  end

  ssl = { ctx = ssl }

  local ok, err
  if cipher_list then
    ok, err = ssl_lib.set_cipher_list(ssl, cipher_list)
    if not ok then
      return nil, err
    end
  end

  if ciphersuites then
    ok, err = ssl_lib.set_ciphersuites(ssl, ciphersuites)
    if not ok then
      return nil, err
    end
  end

  return ssl_lib.get_ciphers(ssl)
end

return _M
