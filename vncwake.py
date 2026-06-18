#!/usr/bin/env python3
# Connect to a no-auth VNC server, nudge the pointer (wake display), grab framebuffer -> PPM.
import socket, struct, sys, time
host, port, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
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
if 1 not in types: raise SystemExit("auth required %r"%list(types))
s.sendall(b"\x01")
if struct.unpack(">I",recvn(4))[0]!=0: raise SystemExit("sec fail")
s.sendall(b"\x01")
w,h=struct.unpack(">HH",recvn(4)); recvn(16)
nlen=struct.unpack(">I",recvn(4))[0]; recvn(nlen)
pf=struct.pack(">BBBB HHH BBB xxx",32,24,0,1,255,255,255,16,8,0)
s.sendall(struct.pack(">B xxx",0)+pf)
s.sendall(struct.pack(">BxH i",2,1,0))
# wake: move pointer around, no buttons
for (x,y) in [(640,400),(200,200),(640,400),(641,401)]:
    s.sendall(struct.pack(">BBHH",5,0,x,y)); time.sleep(0.2)
time.sleep(1.5)
s.sendall(struct.pack(">BBHHHH",3,0,0,0,w,h))
mt=recvn(1)[0]
while mt!=0: mt=recvn(1)[0]
recvn(1); nr=struct.unpack(">H",recvn(2))[0]
canvas=bytearray(w*h*3)
for _ in range(nr):
    rx,ry,rw,rh,enc=struct.unpack(">HHHHi",recvn(12))
    if enc!=0: raise SystemExit("enc %d"%enc)
    d=recvn(rw*rh*4)
    for row in range(rh):
        for col in range(rw):
            si=(row*rw+col)*4; di=((ry+row)*w+(rx+col))*3
            canvas[di]=d[si+2]; canvas[di+1]=d[si+1]; canvas[di+2]=d[si]
open(out,"wb").write(b"P6\n%d %d\n255\n"%(w,h)+bytes(canvas))
print("wrote %s %dx%d %drects"%(out,w,h,nr))
