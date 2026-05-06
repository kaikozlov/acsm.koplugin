#!/usr/bin/env python3
"""Batch stream-level hash comparison: Python ineptpdf vs Lua implementation.
Runs both sides and compares per-stream SHA256 hashes for all PDFs."""
import sys, os, hashlib, types, importlib.util, struct, subprocess, json

DEDRM_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'reference', 'DeDRM_tools', 'DeDRM_plugin')

# Load ineptpdf
utilities_mod = types.ModuleType('utilities')
class SafeUnbuffered:
    def __init__(self, stream): self.stream = stream
    def write(self, data): self.stream.write(data); self.stream.flush()
    def __getattr__(self, a): return getattr(self.stream, a)
utilities_mod.SafeUnbuffered = SafeUnbuffered
argv_mod = types.ModuleType('argv_utils')
argv_mod.unicode_argv = lambda x: sys.argv
sys.modules['utilities'] = utilities_mod
sys.modules['argv_utils'] = argv_mod
source = open(os.path.join(DEDRM_DIR, 'ineptpdf.py')).read()
source = source.replace('from .utilities import SafeUnbuffered\n', 'from utilities import SafeUnbuffered\n')
source = source.replace('from .argv_utils import unicode_argv\n', 'from argv_utils import unicode_argv\n')
spec = importlib.util.spec_from_file_location('ineptpdf', os.path.join(DEDRM_DIR, 'ineptpdf.py'))
ineptpdf = importlib.util.module_from_spec(spec)
sys.modules['ineptpdf'] = ineptpdf
exec(compile(source, os.path.join(DEDRM_DIR, 'ineptpdf.py'), 'exec'), ineptpdf.__dict__)
ineptpdf.STRICT = False

from Crypto.Cipher import ARC4

def genkey_v2(book_key, objid, genno):
    objid_packed = struct.pack('<L', objid)[:3]
    genno_packed = struct.pack('<L', genno)[:2]
    key = book_key + objid_packed + genno_packed
    return hashlib.md5(key).digest()[:min(len(book_key) + 5, 16)]

def decrypt_rc4(data, objid, genno, book_key):
    if not data or len(data) == 0:
        return data
    key = genkey_v2(book_key, objid, genno)
    cipher = ARC4.new(key)
    return cipher.decrypt(data)

def short_hash(data):
    if not data:
        return "EMPTY"
    return hashlib.sha256(data).hexdigest()[:16]

def py_stream_hashes(encrypted_path, book_key_hex, V):
    book_key = bytes.fromhex(book_key_hex)
    with open(encrypted_path, 'rb') as inf:
        doc = ineptpdf.PDFDocument()
        parser = ineptpdf.PDFParser(doc, inf)
        doc.xrefs = parser.read_xref()
        doc.ready = True
        trailer = None
        for xref in reversed(doc.xrefs):
            if 'Root' in xref.trailer:
                trailer = xref.trailer
                break
        enc_objid = trailer['Encrypt'].objid

        objids = set()
        for xref in doc.xrefs:
            for oid in xref.objids():
                objids.add(oid)
        objids.discard(enc_objid)
        objids.discard(0)

        hashes = {}
        for objid in sorted(objids):
            obj = doc.getobj(objid)
            if obj is None:
                continue
            if isinstance(obj, ineptpdf.PDFStream):
                data = obj.rawdata
                if isinstance(data, bytearray):
                    data = bytes(data)
                decrypted = decrypt_rc4(data, objid, 0, book_key)
                hashes[objid] = short_hash(decrypted)
        return hashes, enc_objid

def lua_stream_hashes(encrypted_path, book_key_hex):
    """Run Lua side via Docker and parse output."""
    docker_enc = encrypted_path.replace('/Users/kai/dev/projects/acsm.koplugin', '/opt/acsm.koplugin')
    # Write a temp Lua script that takes args
    lua_script = f"""
local pdfdoc = require("adobe.pdf.pdfdoc")
local pdfcrypt = require("adobe.pdf.pdfcrypt")
local rc4 = require("adobe.pdf.rc4")
local sha2 = require("ffi/sha2")
local function short_hash(data)
    if not data or #data == 0 then return "EMPTY" end
    return sha2.sha256(data):sub(1, 16)
end
local enc_path = "{docker_enc}"
local book_key = sha2.hex2bin("{book_key_hex}")
local doc = pdfdoc.PDFDocument:new()
local ok, err = doc:open(enc_path)
if not ok then print("OPEN_FAIL: " .. tostring(err)); os.exit(1) end
doc:set_decipher(function(objid, genno, data)
    if type(data) ~= "string" or #data == 0 then return data end
    local key = pdfcrypt.genkey_v2(book_key, objid, genno)
    local state = rc4.init(key)
    return rc4.crypt(state, data)
end)
local ids = doc:allObjids()
local enc_objid = doc.encrypt_objid
for _, objid in ipairs(ids) do
    if objid == enc_objid then goto continue end
    local obj = doc:getobj(objid)
    if not obj then goto continue end
    if type(obj) == "table" and obj.dic and obj.rawdata then
        local data = obj:get_decdata()
        print(string.format("%d -> %s", objid, short_hash(data)))
    end
    ::continue::
end
doc:close()
"""
    script_path = "/tmp/_batch_compare.lua"
    with open(script_path, 'w') as f:
        f.write(lua_script)

    cmd = [
        'docker', 'run', '--rm', '--platform', 'linux/arm64',
        '-v', '/Users/kai/dev/projects/acsm.koplugin:/opt/acsm.koplugin',
        '-v', '/tmp:/hosttmp',
        'acsm-test',
        'bash', '-c',
        f'cd /opt/lib/koreader && LUA_PATH="/opt/acsm.koplugin/?.lua;/opt/acsm.koplugin/?/init.lua;$LUA_PATH" ./luajit /hosttmp/_batch_compare.lua 2>/dev/null'
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        print(f"    Lua error: {result.stderr[:200]}")
        return None, None

    hashes = {}
    for line in result.stdout.strip().split('\n'):
        line = line.strip()
        if ' -> ' in line:
            parts = line.split(' -> ')
            hashes[int(parts[0])] = parts[1]
    return hashes, result.stdout

def main():
    manifest_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'batch_output', 'manifest.json')
    with open(manifest_path) as f:
        manifest = json.load(f)

    results = []
    for book in manifest['results']:
        name = book['name']
        enc_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'batch_output', name, 'encrypted.pdf')
        book_key = book['book_key_hex']
        V = book['V']

        if not os.path.exists(enc_path):
            print(f"\n{name}: SKIP (no encrypted PDF)")
            continue

        print(f"\n{'='*60}")
        print(f"{name}")
        print(f"{'='*60}")

        # Python side
        print(f"  Python: hashing streams...", end=' ', flush=True)
        py_hashes, enc_objid = py_stream_hashes(enc_path, book_key, V)
        print(f"{len(py_hashes)} streams (enc_objid={enc_objid})")

        # Lua side
        print(f"  Lua:    hashing streams...", end=' ', flush=True)
        lua_hashes, lua_output = lua_stream_hashes(enc_path, book_key)
        if lua_hashes is None:
            print("FAILED")
            results.append((name, 'LUA_ERROR', 0, 0, 0))
            continue
        print(f"{len(lua_hashes)} streams")

        # Compare
        py_ids = set(py_hashes.keys())
        lua_ids = set(lua_hashes.keys())
        only_py = sorted(py_ids - lua_ids)
        only_lua = sorted(lua_ids - lua_ids)
        common = py_ids & lua_ids

        hash_mismatches = []
        for oid in sorted(common):
            # EMPTY vs e3b0c44298fc1c14 is same thing (empty data)
            if py_hashes[oid] == lua_hashes[oid]:
                continue
            if py_hashes[oid] == "e3b0c44298fc1c14" and lua_hashes[oid] == "EMPTY":
                continue
            hash_mismatches.append(oid)

        if not only_py and not only_lua and not hash_mismatches:
            print(f"  ✅ PERFECT MATCH — {len(common)} streams, all identical")
            results.append((name, 'MATCH', len(common), 0, 0))
        else:
            status = 'MISMATCH'
            if only_py:
                print(f"  Only in Python ({len(only_py)}): {only_py[:10]}{'...' if len(only_py) > 10 else ''}")
            if only_lua:
                print(f"  Only in Lua ({len(only_lua)}): {only_lua[:10]}{'...' if len(only_lua) > 10 else ''}")
            if hash_mismatches:
                print(f"  Hash mismatches ({len(hash_mismatches)}): {hash_mismatches[:10]}{'...' if len(hash_mismatches) > 10 else ''}")
                for oid in hash_mismatches[:5]:
                    print(f"    obj {oid}: Lua={lua_hashes.get(oid, '?')} Python={py_hashes.get(oid, '?')}")
            results.append((name, status, len(common), len(only_py) + len(only_lua), len(hash_mismatches)))

    # Summary
    print(f"\n{'='*60}")
    print("SUMMARY")
    print(f"{'='*60}")
    matches = sum(1 for _, s, _, _, _ in results if s == 'MATCH')
    total = len(results)
    for name, status, common, extra, mismatches in results:
        mark = "✅" if status == "MATCH" else "❌"
        extra_info = ""
        if extra > 0:
            extra_info += f", {extra} unique objects"
        if mismatches > 0:
            extra_info += f", {mismatches} hash mismatches"
        print(f"  {mark} {name}: {common} common streams{extra_info}")

    print(f"\n  {matches}/{total} books match perfectly")
    if matches < total:
        sys.exit(1)

if __name__ == '__main__':
    main()
