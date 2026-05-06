#!/usr/bin/env python3
"""Decrypt Adobe ADEPT PDFs using the reference ineptpdf.py implementation,
bypassing the RSA/hardening steps with pre-extracted book keys.

Usage:
  python3 tools/decrypt_pdf_ref.py <encrypted.pdf> <bookkey_hex> <V> <output.pdf>

Strategy:
  1. Monkey-patch ineptpdf's PDFDocument to skip RSA decrypt
  2. Inject the pre-extracted book key + genkey/decipher directly
  3. Use the full PDFSerializer to serialize decrypted output
  4. This ensures we use the EXACT same PDF parser logic as the reference
"""

import sys
import os
import types

# --- Setup import path for ineptpdf ---
DEDRM_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'reference', 'DeDRM_tools', 'DeDRM_plugin')

# Create stubs for calibre compat code BEFORE importing ineptpdf
import types

utilities = types.ModuleType('utilities')
class SafeUnbuffered:
    def __init__(self, stream):
        self.stream = stream
    def write(self, data):
        self.stream.write(data)
        self.stream.flush()
    def __getattr__(self, attr):
        return getattr(self.stream, attr)
utilities.SafeUnbuffered = SafeUnbuffered

argv_utils = types.ModuleType('argv_utils')
argv_utils.unicode_argv = lambda x: sys.argv

# Register stubs so relative imports resolve
sys.modules['utilities'] = utilities
sys.modules['argv_utils'] = argv_utils

# Load ineptpdf.py as a standalone module (bypass package-relative imports)
import importlib.util
spec = importlib.util.spec_from_file_location("ineptpdf", os.path.join(DEDRM_DIR, "ineptpdf.py"))
ineptpdf = importlib.util.module_from_spec(spec)
sys.modules['ineptpdf'] = ineptpdf

# Replace the relative import with our stubs before executing
import_line = 'from .utilities import SafeUnbuffered\n'
argv_line = 'from .argv_utils import unicode_argv\n'

with open(os.path.join(DEDRM_DIR, "ineptpdf.py"), 'r') as f:
    source = f.read()

# Patch relative imports to absolute (use our stubs)
source = source.replace(import_line, 'from utilities import SafeUnbuffered\n')
source = source.replace(argv_line, 'from argv_utils import unicode_argv\n')

# Execute the patched source
exec(compile(source, os.path.join(DEDRM_DIR, "ineptpdf.py"), 'exec'), ineptpdf.__dict__)

# Override STRICT to be lenient
ineptpdf.STRICT = False


# --- Monkey-patch: inject book key directly ---
# Save original for reference
_original_initialize = ineptpdf.PDFDocument.initialize

def _initialize_with_bookkey(self, bookkey, V):
    """Initialize PDFDocument with a pre-extracted book key.
    
    Args:
        bookkey: Raw book key bytes
        V: The V value (2 or 3) — determines genkey_v2 vs genkey_v3
    """
    (docid, param) = self.encryption
    
    self.is_printable = self.is_modifiable = self.is_extractable = True
    self.decrypt_key = bookkey
    
    if V == 3:
        self.genkey = self.genkey_v3
    else:
        self.genkey = self.genkey_v2
    
    self.decipher = self.decrypt_rc4
    self.ready = True


# --- Main ---
def decrypt_with_bookkey(encrypted_path, bookkey, V, output_path):
    """Decrypt an encrypted PDF using a pre-extracted book key.
    
    Uses the full PDFSerializer from ineptpdf.py to ensure
    identical parsing and serialization logic.
    """
    with open(encrypted_path, 'rb') as inf:
        doc = ineptpdf.PDFDocument()
        parser = ineptpdf.PDFParser(doc, inf)
        
        # Read xref and encryption info using the full parser
        doc.xrefs = parser.read_xref()
        
        # Find the trailer with Root
        trailer = None
        for xref in reversed(doc.xrefs):
            if 'Root' in xref.trailer:
                trailer = xref.trailer
                break
        if trailer is None:
            raise ValueError("No /Root in any trailer")
        
        # Extract encryption params
        # Temporarily mark ready so resolve1() works
        doc.ready = True
        if 'Encrypt' in trailer:
            encrypt_ref = trailer['Encrypt']
            enc_dict = ineptpdf.dict_value(encrypt_ref)
            encrypt_objid = encrypt_ref.objid
            doc.encrypt_objid = encrypt_objid
            doc_id = ineptpdf.list_value(trailer.get('ID', [b'\x00'*16]))
            doc.encryption = (doc_id, enc_dict)
        else:
            raise ValueError("No /Encrypt in trailer — not an encrypted PDF")
        
        # Initialize root
        if 'Root' in trailer:
            doc.set_root(ineptpdf.dict_value(trailer['Root']))
        
        # Now re-init with our book key (sets genkey, decipher, ready properly)
        _, param = doc.encryption
        _initialize_with_bookkey(doc, bookkey, V)
        
        # Now serialize — objects are transparently decrypted on getobj()
        with open(output_path, 'wb') as outf:
            serializer = _SkipInitPDFSerializer(doc, inf, bookkey, V)
            serializer.dump(outf)
    
    return True


class _SkipInitPDFSerializer:
    """A minimal replacement for ineptpdf.PDFSerializer that skips 
    the doc.initialize() call (since we already injected the book key)."""
    
    def __init__(self, doc, inf, bookkey, V):
        self.doc = doc
        inf.seek(0)
        self.version = inf.read(8)
        self.objids = objids = set()
        for xref in reversed(doc.xrefs):
            for objid in xref.objids():
                objids.add(objid)
        trailer = dict(doc.xrefs[-1].trailer)
        trailer.pop('Prev', None)
        trailer.pop('XRefStm', None)
        if 'Encrypt' in trailer:
            encrypt_ref = trailer.pop('Encrypt')
            if hasattr(encrypt_ref, 'objid'):
                objids.remove(encrypt_ref.objid)
        self.trailer = trailer
    
    def dump(self, outf):
        self.outf = outf
        self.write(self.version)
        self.write(b'\n%\xe2\xe3\xcf\xd3\n')
        doc = self.doc
        objids = self.objids
        xrefs_map = {}
        maxobj = max(objids) if objids else 0
        trailer = dict(self.trailer)
        trailer['Size'] = maxobj + 1
        
        for objid in objids:
            obj = doc.getobj(objid)
            if isinstance(obj, ineptpdf.PDFObjStmRef):
                xrefs_map[objid] = obj
                continue
            if obj is not None:
                try:
                    genno = obj.genno
                except AttributeError:
                    genno = 0
                xrefs_map[objid] = (self.tell(), genno)
                self._serialize_indirect(objid, obj)
        
        startxref = self.tell()
        
        if not ineptpdf.gen_xref_stm:
            self.write(b'xref\n')
            self.write(b'0 %d\n' % (maxobj + 1,))
            for objid in range(0, maxobj + 1):
                if objid in xrefs_map:
                    self.write(b"%010d 00000 n \n" % xrefs_map[objid][0])
                else:
                    self.write(b"%010d %05d f \n" % (0, 65535))
            self.write(b'trailer\n')
            self._serialize_object(trailer)
            self.write(b'\nstartxref\n%d\n%%%%EOF' % startxref)
        else:
            self._dump_xref_stream(startxref, xrefs_map, maxobj, trailer)
    
    def _dump_xref_stream(self, startxref, xrefs_map, maxobj, trailer):
        import struct as _struct, zlib as _zlib
        
        maxoffset = max(startxref, maxobj)
        maxindex = ineptpdf.PDFObjStmRef.maxindex
        fl2 = 2
        power = 65536
        while maxoffset >= power:
            fl2 += 1
            power *= 256
        fl3 = 1
        power = 256
        while maxindex >= power:
            fl3 += 1
            power *= 256
        
        index = []
        first = None
        prev = None
        data_frags = []
        
        maxobj += 1
        xrefs_map[maxobj] = (startxref, 0)
        
        for objid in sorted(xrefs_map):
            if first is None:
                first = objid
            elif objid != prev + 1:
                index.extend((first, prev - first + 1))
                first = objid
            prev = objid
            objref = xrefs_map[objid]
            if isinstance(objref, ineptpdf.PDFObjStmRef):
                f1, f2, f3 = 2, objref.stmid, objref.index
            else:
                f1, f2, f3 = 1, objref[0], 0
            data_frags.append(_struct.pack('>B', f1))
            data_frags.append(_struct.pack('>L', f2)[-fl2:])
            data_frags.append(_struct.pack('>L', f3)[-fl3:])
        
        index.extend((first, prev - first + 1))
        data = _zlib.compress(b''.join(data_frags))
        dic = {'Type': ineptpdf.LITERAL_XREF, 'Size': prev + 1, 'Index': index,
               'W': [1, fl2, fl3], 'Length': len(data),
               'Filter': ineptpdf.LITERALS_FLATE_DECODE[0],
               'Root': trailer['Root']}
        if 'Info' in trailer:
            dic['Info'] = trailer['Info']
        xrefstm = ineptpdf.PDFStream(dic, data)
        self._serialize_indirect(maxobj, xrefstm)
        self.write(b'startxref\n%d\n%%%%EOF' % startxref)
    
    def write(self, data):
        self.outf.write(data)
        self.last = data[-1:]
    
    def tell(self):
        return self.outf.tell()
    
    def _escape_string(self, string):
        string = string.replace(b'\\', b'\\\\')
        string = string.replace(b'\n', b'\\n')
        string = string.replace(b'(', b'\\(')
        string = string.replace(b')', b'\\)')
        return string
    
    def _serialize_object(self, obj):
        import binascii as _binascii
        from decimal import Decimal as _Decimal
        
        if isinstance(obj, dict):
            if 'ResFork' in obj and 'Type' in obj and 'Subtype' not in obj \
               and isinstance(obj['Type'], int):
                obj['Subtype'] = obj['Type']
                del obj['Type']
            self.write(b'<<')
            for key, val in obj.items():
                self.write(str(ineptpdf.LIT(key.encode('utf-8'))).encode('utf-8'))
                self._serialize_object(val)
            self.write(b'>>')
        elif isinstance(obj, list):
            self.write(b'[')
            for val in obj:
                self._serialize_object(val)
            self.write(b']')
        elif isinstance(obj, bytearray):
            self.write(b'(%s)' % self._escape_string(obj))
        elif isinstance(obj, bytes):
            self.write(b'<%s>' % _binascii.hexlify(obj).upper())
        elif isinstance(obj, str):
            self.write(b'(%s)' % self._escape_string(obj.encode('utf-8')))
        elif isinstance(obj, bool):
            if self.last.isalnum():
                self.write(b' ')
            self.write(str(obj).lower().encode('utf-8'))
        elif isinstance(obj, int):
            if self.last.isalnum():
                self.write(b' ')
            self.write(str(obj).encode('utf-8'))
        elif isinstance(obj, _Decimal):
            if self.last.isalnum():
                self.write(b' ')
            self.write(str(obj).encode('utf-8'))
        elif isinstance(obj, ineptpdf.PDFObjRef):
            if self.last.isalnum():
                self.write(b' ')
            self.write(b'%d %d R' % (obj.objid, 0))
        elif isinstance(obj, ineptpdf.PDFStream):
            if obj.dic.get('Type') == ineptpdf.LITERAL_OBJSTM and not ineptpdf.gen_xref_stm:
                self.write(b'(deleted)')
            else:
                data = obj.get_decdata()
                dic = obj.get_decdic()
                if 'Length' in dic:
                    dic['Length'] = len(data)
                self._serialize_object(dic)
                self.write(b'stream\n')
                self.write(data)
                self.write(b'\nendstream')
        else:
            data = str(obj).encode('utf-8')
            if bytes([data[0]]).isalnum() and self.last.isalnum():
                self.write(b' ')
            self.write(data)
    
    def _serialize_indirect(self, objid, obj):
        self.write(b'%d 0 obj' % (objid,))
        self._serialize_object(obj)
        if self.last.isalnum():
            self.write(b'\n')
        self.write(b'endobj\n')


def main():
    if len(sys.argv) != 5:
        print(f"Usage: {sys.argv[0]} <encrypted.pdf> <bookkey_hex> <V> <output.pdf>")
        sys.exit(1)
    
    encrypted_path = sys.argv[1]
    bookkey = bytes.fromhex(sys.argv[2])
    V = int(sys.argv[3])
    output_path = sys.argv[4]
    
    print(f"Reference decrypt: {os.path.basename(encrypted_path)}")
    print(f"  bookkey: {len(bookkey)} bytes, V={V}")
    print(f"  genkey: {'v3' if V == 3 else 'v2'}, cipher: RC4")
    
    try:
        decrypt_with_bookkey(encrypted_path, bookkey, V, output_path)
    except Exception as e:
        print(f"  FAILED: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
    
    out_size = os.path.getsize(output_path)
    print(f"  → {output_path} ({out_size:,} bytes)")


if __name__ == '__main__':
    main()
