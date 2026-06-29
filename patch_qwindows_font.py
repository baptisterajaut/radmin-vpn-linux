#!/usr/bin/env python3
# Patch Qt's qwindows.dll platform plugin to stop crashing on malformed font
# name-table offsets under Wine.
#
# Root cause (see run.sh comment): QWindowsFontDatabase reads a self-relative
# UTF-16 name offset from a GDI OUTLINETEXTMETRIC/font-data buffer and does
#     QString::fromUtf16(buffer + offset, -1)
# Under Wine, GetOutlineTextMetricsW/GetFontData fill that offset with garbage
# for some host fonts (observed 0xC0000000 and 0x40dde2c4). buffer+offset then
# points to unmapped memory and the -1 (auto-length) NUL-scan in fromUtf16
# faults (0xc0000005). On real Windows the page happens to be committed so it
# only yields garbage, never a crash.
#
# Fix: at the crashing call site (qwindows+0x5f50d) bound-check the offset.
# A valid otmp name offset is tiny (< 64 KiB). If it is out of range, call
# fromUtf16(buffer, 0) instead -> returns an empty QString with no dereference.
# Normal fonts (small valid offset) are completely unaffected.
#
# Idempotent: detects an already-patched file and does nothing. Keeps a .orig
# backup next to the dll the first time it patches.
import struct, sys, os

SITE_RVA  = 0x5f50d   # mov eax,[ebx+0xd4]; add eax,ebx; push -1; push eax
BACK_RVA  = 0x5f518   # lea eax,[esp+0x1c]; push eax; call fromUtf16
CAVE_RVA  = 0x11e89   # 39-byte 0xCC pad run
ORIG_SITE = bytes.fromhex("8b83d4000000" "03c3" "6aff" "50")  # 11 bytes

def rva2off(secs, rva):
    for va, vs, ptr, rs in secs:
        if va <= rva < va + max(vs, rs):
            return ptr + (rva - va)
    raise ValueError(f"rva {rva:#x} not in any section")

def main(path):
    d = bytearray(open(path, "rb").read())
    pe = struct.unpack_from("<I", d, 0x3c)[0]
    if d[pe:pe+2] != b"PE":
        sys.exit("not a PE")
    nsec = struct.unpack_from("<H", d, pe+6)[0]
    opt  = pe + 24
    imgbase = struct.unpack_from("<I", d, opt+28)[0]
    sh = opt + struct.unpack_from("<H", d, pe+20)[0]
    secs = []
    for i in range(nsec):
        o = sh + i*40
        vs, va, rs, ptr = struct.unpack_from("<IIII", d, o+8)
        secs.append((va, vs, ptr, rs))

    site = rva2off(secs, SITE_RVA)
    cave = rva2off(secs, CAVE_RVA)

    if d[site] == 0xE9:
        print("qwindows.dll already patched; nothing to do.")
        return 0
    if bytes(d[site:site+11]) != ORIG_SITE:
        sys.exit(f"unexpected bytes at site: {bytes(d[site:site+11]).hex()} "
                 f"(expected {ORIG_SITE.hex()}) -- wrong/newer qwindows.dll, aborting")

    site_va = imgbase + SITE_RVA
    back_va = imgbase + BACK_RVA
    cave_va = imgbase + CAVE_RVA

    # ---- build cave ----
    cave_bytes = bytearray()
    cave_bytes += bytes.fromhex("8b83d4000000")          # mov eax,[ebx+0xd4]
    cave_bytes += bytes.fromhex("3d00000100")            # cmp eax,0x10000
    jae_at = len(cave_bytes)
    cave_bytes += bytes.fromhex("7300")                  # jae rel8 -> bad (fix below)
    cave_bytes += bytes.fromhex("03c3")                  # add eax,ebx
    cave_bytes += bytes.fromhex("68ffffffff")            # push 0xffffffff (size=-1)
    cave_bytes += bytes.fromhex("50")                    # push eax (ptr)
    # jmp back (good path)
    here = cave_va + len(cave_bytes)
    cave_bytes += b"\xe9" + struct.pack("<i", back_va - (here + 5))
    # bad path (jae lands here): size=0, ptr=ebx (valid, never read)
    bad_off = len(cave_bytes)
    cave_bytes += bytes.fromhex("6a00")                  # push 0 (size=0)
    cave_bytes += bytes.fromhex("53")                    # push ebx (ptr)
    here = cave_va + len(cave_bytes)
    cave_bytes += b"\xe9" + struct.pack("<i", back_va - (here + 5))

    # fix jae rel8 (displacement from end of the 2-byte jae to bad_off)
    rel = bad_off - (jae_at + 2)
    assert 0 <= rel <= 0x7f, f"jae rel out of range: {rel}"
    cave_bytes[jae_at+1] = rel
    assert len(cave_bytes) <= 39, f"cave too big: {len(cave_bytes)}"

    # ---- write cave ----
    if any(b != 0xCC for b in d[cave:cave+len(cave_bytes)]):
        sys.exit("cave region not free (expected 0xCC padding)")
    d[cave:cave+len(cave_bytes)] = cave_bytes

    # ---- write site: jmp cave (5) + nop padding to 11 ----
    patch = b"\xe9" + struct.pack("<i", cave_va - (site_va + 5))
    patch += b"\x90" * (11 - len(patch))
    d[site:site+11] = patch

    if not os.path.exists(path + ".orig"):
        os.rename(path, path + ".orig")
        open(path, "wb").write(d)   # recreate at original name
    else:
        open(path, "wb").write(d)
    print(f"patched {path}\n  site {SITE_RVA:#x} -> jmp cave {CAVE_RVA:#x}, "
          f"cave {len(cave_bytes)} bytes, back {BACK_RVA:#x}")
    return 0

if __name__ == "__main__":
    p = sys.argv[1] if len(sys.argv) > 1 else "qwindows.dll"
    sys.exit(main(p))
