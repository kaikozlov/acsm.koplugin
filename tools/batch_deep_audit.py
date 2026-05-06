#!/usr/bin/env python3
"""Batch deep audit: decrypt streams from all 11 PDFs and compare Lua vs Python.
Only compares streams that BOTH implementations decrypt."""
import sys, os, hashlib, types, importlib.util, json, subprocess, re

PROJECT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
MANIFEST_PATH = os.path.join(PROJECT_DIR, 'tools/batch_output/manifest.json')

# ---- Patch-load ineptpdf ----
DEDRM_DIR = os.path.join(PROJECT_DIR, 'reference', 'DeDRM_tools', 'DeDRM_plugin')
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

from Crypto.Cipher import ARC4, AES

def py_audit(encrypted_path, book_key_hex, V):
    book_key = bytes.fromhex(book_key_hex)
    V = int(V)
    hashes = {}

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

        enc_ref = trailer['Encrypt']
        enc_dict = ineptpdf.dict_value(enc_ref)
        V_enc = int(enc_dict.get('V', 4))
        EBX_type = int(enc_dict.get('EBX_ENCRYPTIONTYPE', 6))
        genkey_version = 2 if V_enc != 4 or EBX_type == 6 else 3

        objids = set()
        for xref in doc.xrefs:
            for oid in xref.objids():
                objids.add(oid)
        objids.discard(enc_ref.objid)
        objids.discard(0)

        for objid in sorted(objids):
            obj = doc.getobj(objid)
            if obj is None or not isinstance(obj, ineptpdf.PDFStream):
                continue
            data = obj.rawdata
            if isinstance(data, bytearray):
                data = bytes(data)

            if genkey_version == 2:
                if len(data) < 16:
                    hashes[objid] = hashlib.sha256(data).hexdigest()[:16]
                    continue
                key = bytearray(book_key[:16])
                key.append(objid & 0xFF)
                key.append((objid >> 8) & 0xFF)
                key.append((objid >> 16) & 0xFF)
                key.append(0); key.append(0)
                key = bytes(key[:16])
                s = bytes(data[:16])
                obj_key = bytes(a ^ b for a, b in zip(s, key))
                cipher = ARC4.new(obj_key)
                result = bytes(cipher.decrypt(data))
                hashes[objid] = hashlib.sha256(result).hexdigest()[:16]
            else:
                cipher = AES.new(book_key, AES.MODE_CBC, b'\x00' * 16)
                result = bytes(cipher.decrypt(data)[16:])
                hashes[objid] = hashlib.sha256(result).hexdigest()[:16]

    return hashes


def lua_audit(enc_docker_path, book_key_hex, V):
    """Run lua_audit.lua inside Docker."""
    project = PROJECT_DIR
    cmd = [
        'docker', 'run', '--rm',
        '-v', f'{project}:/opt/acsm.koplugin',
        'acsm-test',
        '/opt/lib/koreader/luajit',
        '/opt/acsm.koplugin/tools/lua_audit.lua',
        enc_docker_path, book_key_hex, str(V)
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    hashes = {}
    for line in result.stdout.split('\n'):
        m = re.search(r'obj\s+(\d+)\s+→\s+([0-9a-f]+)', line)
        if m:
            hashes[int(m.group(1))] = m.group(2)
    return hashes


def main():
    single_book = None
    if len(sys.argv) > 2 and sys.argv[1] == '--book':
        single_book = sys.argv[2]

    with open(MANIFEST_PATH) as f:
        manifest = json.load(f)

    books = [r for r in manifest['results'] if r['status'] == 'ready_for_python']
    if single_book:
        books = [b for b in books if b['name'] == single_book]

    print(f"Deep-auditing {len(books)} books (per-stream hash comparison)...\n")

    total_match = 0
    total_mismatch = 0
    total_only_py = 0
    total_only_lua = 0

    for book in books:
        name = book['name']
        print(f"  {name}")

        enc_docker = book['encrypted_path']
        # Translate to host for Python
        enc_host = enc_docker.replace('/opt/acsm.koplugin', PROJECT_DIR)

        py = py_audit(enc_host, book['book_key_hex'], book['V'])
        lua = lua_audit(enc_docker, book['book_key_hex'], book['V'])

        py_ids = set(py.keys())
        lua_ids = set(lua.keys())

        match = 0
        mismatch = 0
        for objid in py_ids & lua_ids:
            if py[objid] == lua[objid]:
                match += 1
            else:
                mismatch += 1
                print(f"    MISMATCH obj {objid}: py={py[objid]} lua={lua[objid]}")

        only_py = len(py_ids - lua_ids)
        only_lua = len(lua_ids - py_ids)

        print(f"    Py: {len(py)} streams, Lua: {len(lua)} streams")
        print(f"    Match: {match}, Mismatch: {mismatch}, Only Py: {only_py}, Only Lua: {only_lua}")

        if mismatch == 0 and match > 0:
            print(f"    ✅ All overlapping streams match! ({match}/{match})")
        elif mismatch > 0:
            print(f"    ❌ {mismatch} stream MISMATCHES")

        total_match += match
        total_mismatch += mismatch
        total_only_py += only_py
        total_only_lua += only_lua
        print()

    print(f"{'='*60}")
    print(f"TOTAL: {total_match} match, {total_mismatch} mismatch, "
          f"{total_only_py} only in Py, {total_only_lua} only in Lua")
    print(f"{'='*60}")


if __name__ == '__main__':
    main()
