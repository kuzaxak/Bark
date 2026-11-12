#!/usr/bin/env python3
"""Writes the C header that names the digest of the bridge's public headers: barc_public_headers_sha256.py OUTPUT HEADER..."""
import hashlib
import os
import sys

output, headers = sys.argv[1], sys.argv[2:]
lines = ''.join(f'{hashlib.sha256(open(header, "rb").read()).hexdigest()}  {os.path.basename(header)}\n' for header in headers)
with open(output, 'w') as result:
    result.write(f'#define BARC_PUBLIC_HEADERS_SHA256 "{hashlib.sha256(lines.encode()).hexdigest()}"\n')
