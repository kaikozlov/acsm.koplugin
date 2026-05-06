#!/usr/bin/env python3
"""Decrypt PDF using ineptpdf.py with a pre-extracted book key.
Runs inside Docker where Crypto is available (unlike host).

Usage inside Docker:
  cd /opt/acsm.koplugin
  python3 tools/decrypt_pdf_ref_docker.py <encrypted.pdf> <bookkey_hex> <V> <output.pdf>
"""

import sys, os, zlib, io, types, importlib.util

# ---- Setup ineptpdf.py as a standalone module (no relative imports) ----
DEDRM_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'reference', 'DeDRM_tools', 'DeDRM_plugin')

# Stubs
utilities_mod = types.ModuleType('utilities')
class SafeUnbuffered:
    def __init__(self, stream):
        self.stream = stream
    def write(self, data):
        self.stream.write(data)
        self.stream.flush()
    def __getattr__(self, attr):
        return getattr(self.stream, attr)
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

# ---- The actual decrypt logic ----

def decrypt(encrypted_path, bookkey_hex, V, output_path):
    bookkey = bytes.fromhex(bookkey_hex)
    V = int(V)
    
    with open(encrypted_path, 'rb') as inf:
        # Read the PDF using ineptpdf's full parser
        doc = ineptpdf.PDFDocument()
        parser = ineptpdf.PDFParser(doc, inf)
        doc.xrefs = parser.read_xref()
        
        # Find trailer with Root
        trailer = None
        for xref in reversed(doc.xrefs):
            if 'Root' in xref.trailer:
                trailer = xref.trailer
                break
        if trailer is None:
            raise ValueError("No /Root")
        
        # Mark ready so we can resolve references
        doc.ready = True
        
        # Resolve Encrypt dict
        encrypt_ref = trailer['Encrypt']
        enc_dict = ineptpdf.dict_value(encrypt_ref)
        encrypt_objid = encrypt_ref.objid
        
        # Get doc ID
        doc_id = ineptpdf.list_value(trailer.get('ID', [b'\x00' * 16]))
        doc.encryption = (doc_id, enc_dict)
        doc.encrypt_objid = encrypt_objid
        
        # Set root
        doc.set_root(ineptpdf.dict_value(trailer['Root']))
        
        # ---- Inject book key (replaces the RSA decrypt step) ----
        _, param = doc.encryption
        V_actual = int(param.get('V', 4))
        EBX_type = int(param.get('EBX_ENCRYPTIONTYPE', 6))
        length = int(param.get('Length', 128)) // 8
        
        # Determine genkey version and cipher
        if V_actual != 4:
            genkey_version = 2
        else:
            if EBX_type == 6:
                genkey_version = 2
            elif EBX_type == 3:
                genkey_version = 3
            else:
                genkey_version = 2
        
        from Crypto.Cipher import AES
        from Crypto.Cipher import ARC4
        
        if genkey_version == 3:
            if bookkey is None or len(bookkey) == 0:
                raise ValueError("No book key for AES")
            cipher = AES.new(bookkey, AES.MODE_CBC, b'\x00' * 16)
        else:
            if len(bookkey) != 16:
                raise ValueError(f"Wrong book key length for RC4: {len(bookkey)}")
            cipher = ARC4.new(bookkey)
        
        # Set the genkey and decipher callable
        doc.genkey_version = genkey_version
        doc.decipher = lambda objid, genno, data, \
            doc=doc, cipher=cipher, gv=genkey_version: _decipher(doc, objid, genno, data, cipher, gv)
        
        # Now serialize using ineptpdf's own serializer
        inf.seek(0)
        serializer = ineptpdf.PDFSerializer.__new__(ineptpdf.PDFSerializer)
        serializer.doc = doc
        serializer.version = inf.read(8)
        serializer.objids = set()
        for xref in reversed(doc.xrefs):
            for oid in xref.objids():
                serializer.objids.add(oid)
        serializer.trailer = trailer
        
        # Remove Encrypt from trailer for output
        serializer.trailer = dict(serializer.trailer)
        serializer.trailer.pop('Encrypt', None)
        serializer.trailer.pop('Prev', None)
        serializer.trailer.pop('XRefStm', None)
        
        # Add doc ID back if needed
        if 'ID' not in serializer.trailer and doc_id:
            serializer.trailer['ID'] = doc_id
        
        with open(output_path, 'wb') as outf:
            serializer.dump(outf)


def _decipher(doc, objid, genno, data, cipher, genkey_version):
    """Replicate ineptpdf's decipher logic."""
    # Must re-key for each object
    if genkey_version == 2:
        s = data[:16]
        if isinstance(s, bytearray):
            s = bytes(s)
        from Crypto.Cipher import ARC4
        key = bytes(a ^ b for a, b in zip(s, doc.bookkey[:16]))
        obj_cipher = ARC4.new(key)
        return obj_cipher.decrypt(data)
    else:  # v3
        if genno != 0:
            return data  # already handled
        # 16-byte random prefix + plaintext
        return cipher.decrypt(data)[16:]


if __name__ == '__main__':
    if len(sys.argv) != 5:
        print("Usage: decrypt_pdf_ref_docker.py <encrypted.pdf> <bookkey_hex> <V> <output.pdf>", file=sys.stderr)
        sys.exit(1)
    
    decrypt(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
    print(f"OK: {os.path.getsize(sys.argv[4])} bytes")
