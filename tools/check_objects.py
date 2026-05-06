#!/usr/bin/env python3
"""Check what high-numbered objects in the encrypted PDF are."""
import sys, os, types, importlib.util

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

enc_path = sys.argv[1]

with open(enc_path, 'rb') as inf:
    doc = ineptpdf.PDFDocument()
    parser = ineptpdf.PDFParser(doc, inf)
    doc.xrefs = parser.read_xref()
    doc.ready = True

    for objid in range(6090, 6118):
        obj = doc.getobj(objid)
        if obj:
            typename = '?'
            if isinstance(obj, ineptpdf.PDFStream):
                t = obj.dic.get('Type', '?')
                if isinstance(t, ineptpdf.PSBaseParser):
                    typename = str(t)
                else:
                    typename = str(t)
            print(f'  obj {objid}: {type(obj).__name__}, Type={typename}')
        else:
            print(f'  obj {objid}: None')
