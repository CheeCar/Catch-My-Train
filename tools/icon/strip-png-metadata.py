#!/usr/bin/env python3
"""Rewrites PNG files keeping only the chunks needed to draw them (no text, time or provenance chunks).

Usage: tools/icon/strip-png-metadata.py <file.png> [...]
"""
import struct
import sys
import zlib

KEEP = {b"IHDR", b"PLTE", b"tRNS", b"IDAT", b"IEND"}
SIGNATURE = b"\x89PNG\r\n\x1a\n"


def strip(path):
    data = open(path, "rb").read()
    if not data.startswith(SIGNATURE):
        raise SystemExit(f"{path} is not a PNG file")
    out, pos = [SIGNATURE], len(SIGNATURE)
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos:pos + 12 + length]
        if kind in KEEP:
            body = chunk[8:8 + length]
            if struct.unpack(">I", chunk[8 + length:])[0] != zlib.crc32(kind + body):
                raise SystemExit(f"{path}: bad checksum in {kind.decode()}")
            out.append(chunk)
        pos += 12 + length
    open(path, "wb").write(b"".join(out))


for name in sys.argv[1:]:
    strip(name)
