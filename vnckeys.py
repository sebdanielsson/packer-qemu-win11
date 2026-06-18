#!/usr/bin/env python3
# Send keystrokes to a no-auth VNC server (qemu). Reads a small DSL from a file:
#   TEXT:<literal text to type>
#   KEY:<keysym-name>          e.g. Return, Tab, Escape
#   COMBO:<k1>+<k2>            e.g. Super_L+r  (press in order, release reverse)
#   DELAY:<seconds>
# Usage: vnckeys.py HOST PORT script.txt
import socket, struct, sys, time

NAMED = {"Return":0xFF0D,"Enter":0xFF0D,"Tab":0xFF09,"Escape":0xFF1B,
         "BackSpace":0xFF08,"Super_L":0xFFEB,"Super":0xFFEB,"Shift_L":0xFFE1,
         "Control_L":0xFFE3,"Alt_L":0xFFE9,"space":0x20}
host, port, script = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.create_connection((host, port), timeout=20); s.settimeout(20)
def recvn(n):
    b=b''
    while len(b)<n:
        c=s.recv(n-len(b))
        if not c: raise IOError("eof")
        b+=c
    return b
recvn(12); s.sendall(b"RFB 003.008\n")
t=recvn(1)[0]; types=recvn(t)
if 1 not in types: raise SystemExit("auth required")
s.sendall(b"\x01")
if struct.unpack(">I",recvn(4))[0]!=0: raise SystemExit("sec fail")
s.sendall(b"\x01")
recvn(4); recvn(16)
nlen=struct.unpack(">I",recvn(4))[0]; recvn(nlen)

def key(sym, down):
    s.sendall(struct.pack(">BBHI",4,1 if down else 0,0,sym))
def tap(sym):
    key(sym,True); time.sleep(0.03); key(sym,False); time.sleep(0.03)
def keysym_for(ch):
    return NAMED.get(ch, ord(ch))   # Latin-1 printable: keysym == codepoint

for raw in open(script):
    line = raw.rstrip("\n")
    if not line or line.startswith("#"): continue
    cmd, _, arg = line.partition(":")
    if cmd=="TEXT":
        for ch in arg:
            tap(keysym_for(ch))
    elif cmd=="KEY":
        tap(NAMED[arg])
    elif cmd=="COMBO":
        parts=[NAMED.get(p,ord(p) if len(p)==1 else None) for p in arg.split("+")]
        for p in parts: key(p,True);
        time.sleep(0.05)
        for p in reversed(parts): key(p,False)
        time.sleep(0.05)
    elif cmd=="DELAY":
        time.sleep(float(arg))
time.sleep(0.3)
print("keys sent")
