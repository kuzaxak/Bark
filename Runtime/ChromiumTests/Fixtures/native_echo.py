#!/usr/bin/env python3
"""Test-only native host; registration/allowlists belong to isolated qualification.

Manifest type: stdio. Path: absolute executable path to this file.
Use separate allowed and denied host manifests to exercise allowed_origins.
"""
import json
import struct
import sys


def read_exact(length):
    data = bytearray()
    while len(data) < length:
        chunk = sys.stdin.buffer.read(length - len(data))
        if not chunk:
            raise EOFError
        data.extend(chunk)
    return bytes(data)


try:
    while True:
        length, = struct.unpack('<I', read_exact(4))
        if length > 1024 * 1024:
            raise ValueError('Oversized fixture input')
        message = json.loads(read_exact(length))
        payload = json.dumps({'echo': message.get('echo')}).encode()
        if len(payload) > 1024 * 1024:
            raise ValueError('Oversized fixture output')
        sys.stdout.buffer.write(struct.pack('<I', len(payload)) + payload)
        sys.stdout.buffer.flush()
except EOFError:
    pass
