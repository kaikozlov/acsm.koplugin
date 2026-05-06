#!/usr/bin/env python3
"""Dump per-stream hashes from Python's ACTUAL ineptpdf decryptor.
This uses ineptpdf's real genkey_v2 + decrypt_rc4 pipeline."""
import sys, os, hashlib, types, importlib.util

DEDRM_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'reference', 'DeDRM_tools', 'DeDRM_plugin')

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

def hex_hash(data):
    return hashlib.sha256(data).hexdigest()[:16]

def genkey_v2(book_key, objid, genno):
    """Real genkey_v2 from ineptpdf."""
    import struct
    objid_packed = struct.pack('<L', objid)[:3]
    genno_packed = struct.pack('<L', genno)[:2]
    key = book_key + objid_packed + genno_packed
    return hashlib.md5(key).digest()[:min(len(book_key) + 5, 16)]

def decrypt_rc4(data, objid, genno, book_key):
    """Real RC4 decryption from ineptpdf."""
    if len(data) == 0:
        return data
    key = genkey_v2(book_key, objid, genno)
    cipher = ARC4.new(key)
    return cipher.decrypt(data)

def audit(encrypted_path, book_key_hex, V):
    book_key = bytes.fromhex(book_key_hex)
    V = int(V)

    with open(encrypted_path, 'rb') as inf:
        doc = ineptpdf.PDFDocument()
        parser = ineptpdf.PDFParser(doc, inf)
        doc.xrefs = parser.read_xref()
        doc.ready = True

        # Get encrypt objid
        trailer = None
        for xref in reversed(doc.xrefs):
            if 'Root' in xref.trailer:
                trailer = xref.trailer
                break
        enc_objid = trailer['Encrypt'].objid

        # Get all objids
        objids = set()
        for xref in doc.xrefs:
            for oid in xref.objids():
                objids.add(oid)
        objids.discard(enc_objid)
        objids.discard(0)

        stream_hashes = {}
        for objid in sorted(objids):
            obj = doc.getobj(objid)
            if obj is None:
                continue
            if isinstance(obj, ineptpdf.PDFStream):
                data = obj.rawdata
                if isinstance(data, bytearray):
                    data = bytes(data)
                decrypted = decrypt_rc4(data, objid, 0, book_key)
                h = hex_hash(decrypted)
                stream_hashes[objid] = h

        print(f"Decrypted {len(stream_hashes)} streams (enc_objid={enc_objid})")
        for objid in sorted(stream_hashes):
            obj = doc.getobj(objid)
            n_val = obj.dic.get('N', None) if isinstance(obj, ineptpdf.PDFStream) else None
            extra = f" N={n_val}" if n_val else ""
            print(f"  {objid:6d} -> {stream_hashes[objid]}{extra}")

        # Specifically check 5852 and 6120
        for oid in [5852, 6120]:
            obj = doc.getobj(oid)
            if obj and isinstance(obj, ineptpdf.PDFStream):
                data = obj.rawdata
                if isinstance(data, bytearray): data = bytes(data)
                dec = decrypt_rc4(data, oid, 0, book_key)
                print(f"\n  SPECIAL {oid}: rawdata_len={len(data)} decrypted_len={len(dec)} hash={hex_hash(dec)}")
                print(f"    first 32 bytes decrypted: {dec[:32].hex()}")
                print(f"    dic: {dict((k, str(v)[:40]) for k, v in obj.dic.items())}")
            elif obj:
                print(f"\n  SPECIAL {oid}: {type(obj).__name__} (not a stream)")
                if isinstance(obj, dict):
                    print(f"    keys: {list(obj.keys())}")
            else:
                print(f"\n  SPECIAL {oid}: None")

if __name__ == '__main__':
    if len(sys.argv) != 4:
        print("Usage: py_stream_hashes.py <encrypted.pdf> <book_key_hex> <V>", file=sys.stderr)
        sys.exit(1)
    audit(sys.argv[1], sys.argv[2], sys.argv[3])
