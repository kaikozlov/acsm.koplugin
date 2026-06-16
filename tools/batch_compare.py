#!/usr/bin/env python3
"""Cross-validation comparison script.

Reads the manifest from batch_cross_validate.lua output,
runs the Python reference decryption on each book, and compares
byte-for-byte against the Lua-decrypted output.

Usage:
  python3 tools/batch_compare.py
  python3 tools/batch_compare.py --book dracula   # single book
"""

import sys
import os
import json
import hashlib
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.join(SCRIPT_DIR, '..')
OUTPUT_DIR = os.path.join(SCRIPT_DIR, 'batch_output')
MANIFEST_PATH = os.path.join(OUTPUT_DIR, 'manifest.json')
DECRYPT_SCRIPT = os.path.join(SCRIPT_DIR, 'decrypt_pdf_ref.py')


def sha256_file(path):
    """Return SHA256 hex of file contents."""
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def run_python_decrypt(encrypted_path, book_key_hex, V, output_path):
    """Run the Python reference decryption inside Docker (Crypto available)."""
    # Convert host paths to Docker paths
    docker_enc = encrypted_path.replace(PROJECT_DIR, '/opt/acsm.koplugin')
    docker_out = output_path.replace(PROJECT_DIR, '/opt/acsm.koplugin')
    
    cmd = [
        'docker', 'run', '--rm',
        '-v', f'{PROJECT_DIR}:/opt/acsm.koplugin',
        'acsm-test',
        'python3', '/opt/acsm.koplugin/tools/decrypt_pdf_ref_docker.py',
        docker_enc, book_key_hex, str(V), docker_out
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        print(f"    Python decrypt FAILED (exit {result.returncode})")
        if result.stderr:
            for line in result.stderr.strip().split('\n')[:10]:
                print(f"    | {line}")
        return False
    if not os.path.exists(output_path):
        print(f"    Python decrypt produced no output file")
        return False
    return True


def main():
    # Parse args
    single_book = None
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == '--book':
        single_book = args[1]

    if not os.path.exists(MANIFEST_PATH):
        print(f"ERROR: Manifest not found at {MANIFEST_PATH}")
        print("Run batch_cross_validate.lua inside Docker first:")
        print("  just shell")
        print("  cd /opt/lib/koreader")
        print("  luajit /opt/acsm.koplugin/tools/batch_cross_validate.lua")
        sys.exit(1)

    with open(MANIFEST_PATH) as f:
        manifest = json.load(f)

    books = [r for r in manifest['results'] if r['status'] == 'ready_for_python']
    
    # Translate Docker paths to host paths
    for book in books:
        for key in ('encrypted_path', 'lua_decrypted_path', 'dir'):
            if key in book:
                book[key] = book[key].replace('/opt/acsm.koplugin/tools/batch_output', 
                                              os.path.join(PROJECT_DIR, 'tools/batch_output'))
    
    if single_book:
        books = [b for b in books if b['name'] == single_book]
        if not books:
            print(f"Book '{single_book}' not found in manifest (status must be 'ready_for_python')")
            sys.exit(1)

    print(f"Cross-validating {len(books)} books against Python reference...")
    print()

    passed = 0
    failed = 0
    errors = 0

    for book in books:
        name = book['name']
        book_dir = book['dir']
        encrypted_path = book['encrypted_path']
        book_key_hex = book['book_key_hex']
        V = book['V']
        py_output = os.path.join(book_dir, 'python_decrypted.pdf')

        print(f"  {name}")
        print(f"    Encrypted: {book['encrypted_size']:,} bytes")
        print(f"    Book key: {len(bytes.fromhex(book_key_hex))} bytes, V={V}")
        print(f"    Lua output: {book.get('lua_decrypted_size', '?')} bytes, SHA256={book.get('lua_sha256', '?')}")

        if not os.path.exists(encrypted_path):
            print(f"    ERROR: encrypted PDF missing at {encrypted_path}")
            errors += 1
            continue

        # Run Python reference
        if not run_python_decrypt(encrypted_path, book_key_hex, V, py_output):
            errors += 1
            continue

        py_size = os.path.getsize(py_output)
        py_hash = sha256_file(py_output)
        lua_hash = book.get('lua_sha256', '')
        lua_path = book.get('lua_decrypted_path', '')

        print(f"    Python output: {py_size:,} bytes, SHA256={py_hash}")

        if py_hash == lua_hash:
            print(f"    ✅ MATCH — identical output")
            passed += 1
        else:
            print(f"    ❌ MISMATCH")
            if lua_path and os.path.exists(lua_path) and os.path.exists(py_output):
                # Compare files
                with open(lua_path, 'rb') as fl, open(py_output, 'rb') as fp:
                    lua_data = fl.read()
                    py_data = fp.read()
                
                if len(lua_data) != len(py_data):
                    print(f"    Size: Lua={len(lua_data)}, Python={len(py_data)}")
                
                # Find first difference
                diff_count = 0
                first_diff = None
                min_len = min(len(lua_data), len(py_data))
                for i in range(min_len):
                    if lua_data[i] != py_data[i]:
                        diff_count += 1
                        if first_diff is None:
                            first_diff = i
                        if diff_count >= 10:
                            break
                
                if first_diff is not None:
                    print(f"    First diff at byte {first_diff}:")
                    print(f"      Lua:    {lua_data[max(0,first_diff-2):first_diff+16].hex()}")
                    print(f"      Python: {py_data[max(0,first_diff-2):first_diff+16].hex()}")
                    print(f"    Total diffs found: {diff_count}+")
            
            failed += 1

    print()
    print(f"Results: {passed} passed, {failed} failed, {errors} errors")
    if failed > 0 or errors > 0:
        sys.exit(1)


if __name__ == '__main__':
    main()
