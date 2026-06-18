#!/usr/bin/env python3
# Minimal RFB/VNC client: grabs one full framebuffer (Raw encoding) -> PPM.
# Usage: vncshot.py HOST PORT OUT.ppm   (no-auth servers only, e.g. qemu -vnc)
import socket, struct, sys

host, port, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.create_connection((host, port), timeout=20)
s.settimeout(20)

def recvn(n):
    b = b''
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise IOError("eof")
        b += c
    return b

ver = recvn(12)                       # "RFB 003.008\n"
s.sendall(b"RFB 003.008\n")
ntypes = recvn(1)[0]
types = recvn(ntypes)
if 1 not in types:                    # 1 = None (no auth)
    raise SystemExit("server requires auth: %r" % list(types))
s.sendall(b"\x01")                    # choose None
res = struct.unpack(">I", recvn(4))[0]
if res != 0:
    raise SystemExit("security result failed: %d" % res)
s.sendall(b"\x01")                    # ClientInit: shared=1
w, h = struct.unpack(">HH", recvn(4))
recvn(16)                             # server pixel-format (ignored)
nlen = struct.unpack(">I", recvn(4))[0]
recvn(nlen)                           # desktop name

# SetPixelFormat: 32bpp, depth24, little-endian, true-color, R<<16 G<<8 B<<0
pf = struct.pack(">BBBB HHH BBB xxx", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
s.sendall(struct.pack(">B xxx", 0) + pf)
# SetEncodings: just Raw(0)
s.sendall(struct.pack(">BxH i", 2, 1, 0))
# FramebufferUpdateRequest: full, non-incremental
s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))

mtype = recvn(1)[0]
while mtype != 0:                     # skip non-update msgs
    mtype = recvn(1)[0]
recvn(1)
nrects = struct.unpack(">H", recvn(2))[0]
canvas = bytearray(w * h * 3)
for _ in range(nrects):
    rx, ry, rw, rh, enc = struct.unpack(">HHHHi", recvn(12))
    if enc != 0:
        raise SystemExit("unexpected encoding %d" % enc)
    data = recvn(rw * rh * 4)
    for row in range(rh):
        for col in range(rw):
            si = (row * rw + col) * 4
            di = ((ry + row) * w + (rx + col)) * 3
            canvas[di] = data[si + 2]     # R
            canvas[di + 1] = data[si + 1] # G
            canvas[di + 2] = data[si]     # B
with open(out, "wb") as f:
    f.write(b"P6\n%d %d\n255\n" % (w, h))
    f.write(bytes(canvas))
print("wrote %s (%dx%d, %d rects)" % (out, w, h, nrects))
