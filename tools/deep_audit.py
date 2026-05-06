#!/usr/bin/env python3
"""Deep audit: compare per-object decryption between Lua and Python reference.
Uses ineptpdf.py's actual parser to read the PDF, then decrypts streams
with Crypto.Cipher and reports per-object hashes.

Usage:
  python3 tools/deep_audit.py <encrypted.pdf> <book_key_hex> <V>
"""

import sys, os, hashlib, types, importlib.util, struct

# ---- Patch-load ineptpdf.py ----
DEDRM_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'reference', 'DeDRM_tools', 'DeDRM_plugin')

utilities_mod = types.ModuleType('utilities')
class SafeUnbuffered:
    def __init__(self, stream):
        self.stream = stream
    def write(self, data):
        self.stream.write(data); self.stream.flush()
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


def hex_hash(data):
    return hashlib.sha256(data).hexdigest()[:16]


def audit(encrypted_path, book_key_hex, V):
    book_key = bytes.fromhex(book_key_hex)
    V = int(V)

    print(f"=== {os.path.basename(encrypted_path)} ===")
    print(f"  Book key: {len(book_key)} bytes, V={V}")

    with open(encrypted_path, 'rb') as inf:
        doc = ineptpdf.PDFDocument()
        parser = ineptpdf.PDFParser(doc, inf)
        doc.xrefs = parser.read_xref()
        doc.ready = True

        # Find trailer
        trailer = None
        for xref in reversed(doc.xrefs):
            if 'Root' in xref.trailer:
                trailer = xref.trailer
                break
        if trailer is None:
            raise ValueError("No Root in any trailer")

        # Get Encrypt dict
        enc_ref = trailer['Encrypt']
        enc_dict = ineptpdf.dict_value(enc_ref)
        enc_objid = enc_ref.objid

        V_enc = int(enc_dict.get('V', 4))
        EBX_type = int(enc_dict.get('EBX_ENCRYPTIONTYPE', 6))
        length = int(enc_dict.get('Length', 128)) // 8

        print(f"  V={V_enc}, type={EBX_type}, length={length}")

        # Determine genkey version
        if V_enc != 4:
            genkey_version = 2
        elif EBX_type == 6:
            genkey_version = 2
        elif EBX_type == 3:
            genkey_version = 3
        else:
            genkey_version = 2

        print(f"  Genkey: v{genkey_version}")

        # Get all objids
        objids = set()
        for xref in doc.xrefs:
            for oid in xref.objids():
                objids.add(oid)
        objids.discard(enc_objid)
        objids.discard(0)

        stream_hashes = {}
        stream_count = 0

        for objid in sorted(objids):
            obj = doc.getobj(objid)
            if obj is None:
                continue
            
            # Is it a stream?
            if isinstance(obj, ineptpdf.PDFStream):
                data = obj.rawdata
                if isinstance(data, bytearray):
                    data = bytes(data)

                # Decrypt
                decrypted = _decrypt_stream(data, objid, 0, book_key, genkey_version)
                h = hex_hash(decrypted)
                stream_hashes[objid] = h
                stream_count += 1

        print(f"  Decrypted {stream_count} streams")
        for objid in sorted(stream_hashes):
            print(f"    obj {objid:6d} → {stream_hashes[objid]}")

    return stream_hashes


def _genkey_v2(book_key, objid, genno):
    """ADEPT genkey v2: book_key + 3 bytes of objid LE + 2 bytes genno LE."""
    key = bytearray(book_key)
    key.append(objid & 0xFF)
    key.append((objid >> 8) & 0xFF)
    key.append((objid >> 16) & 0xFF)
    key.append(0)
    key.append(0)
    return bytes(key[:16])


def _decrypt_stream(data, objid, genno, book_key, genkey_version):
    if genkey_version == 2:
        if len(data) < 16:
            return data
        key = _genkey_v2(book_key, objid, genno)
        s = bytes(data[:16])
        obj_key = bytes(a ^ b for a, b in zip(s, key))
        cipher = ARC4.new(obj_key)
        result = cipher.decrypt(data)
        return bytes(result)
    else:
        if genno != 0:
            return data
        cipher = AES.new(book_key, AES.MODE_CBC, b'\x00' * 16)
        result = cipher.decrypt(data)[16:]
        return bytes(result)


if __name__ == '__main__':
    if len(sys.argv) != 4:
        print("Usage: deep_audit.py <encrypted.pdf> <book_key_hex> <V>", file=sys.stderr)
        sys.exit(1)
    audit(sys.argv[1], sys.argv[2], sys.argv[3])
