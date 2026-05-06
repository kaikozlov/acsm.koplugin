#!/usr/bin/env python3
"""Dump ALL object IDs from Python's ineptpdf for the encrypted PDF."""
import sys, os, types, importlib.util, json

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
output_json = sys.argv[2] if len(sys.argv) > 2 else None

with open(enc_path, 'rb') as inf:
    doc = ineptpdf.PDFDocument()
    parser = ineptpdf.PDFParser(doc, inf)
    doc.xrefs = parser.read_xref()
    doc.ready = True

    # Collect all xref entries
    all_ids = set()
    for xref in doc.xrefs:
        if isinstance(xref, ineptpdf.PDFXRef):
            all_ids.update(xref.objids())
        elif isinstance(xref, ineptpdf.PDFXRefStream):
            all_ids.update(xref.objids())

    # Also try brute-force: doc.getobj(i) for max range
    # Find max objid from xrefs
    max_id = 0
    for xref in doc.xrefs:
        try:
            max_id = max(max_id, xref.get_first() + len(xref))
        except:
            pass
    # Also check the trailer /Size
    for xref in doc.xrefs:
        try:
            trailer = xref.get_trailer()
            if trailer and 'Size' in trailer:
                max_id = max(max_id, trailer['Size'])
        except:
            pass

    print(f"Max ID range: {max_id}")
    print(f"Xref IDs found: {len(all_ids)}")

    # Brute force check for objects 5800-6200
    found = {}
    for i in range(5800, 6200):
        obj = doc.getobj(i)
        if obj is not None:
            typename = type(obj).__name__
            is_stream = isinstance(obj, ineptpdf.PDFStream)
            found[i] = {"type": typename, "is_stream": is_stream}

    print(f"\nObjects 5800-6200 ({len(found)} found):")
    for objid in sorted(found.keys()):
        info = found[objid]
        marker = " <-- EXTRA" if objid not in all_ids else ""
        stream_mark = " [STREAM]" if info["is_stream"] else ""
        print(f"  {objid}: {info['type']}{stream_mark}{marker}")

    # Check objects 5852 and 6120 specifically
    for oid in [5852, 6120]:
        obj = doc.getobj(oid)
        if obj:
            print(f"\n  OBJECT {oid}: {type(obj).__name__}")
            if isinstance(obj, ineptpdf.PDFStream):
                print(f"    dic keys: {list(obj.dic.keys())}")
                print(f"    rawdata length: {len(obj.rawdata) if obj.rawdata else 0}")
            elif isinstance(obj, dict):
                print(f"    keys: {list(obj.keys())}")
        else:
            print(f"\n  OBJECT {oid}: None")

    if output_json:
        with open(output_json, 'w') as f:
            json.dump(found, f, indent=2)
