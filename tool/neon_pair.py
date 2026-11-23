# Research tool (docs/neon-super-rom.md): DUMPS=<folder with tropical.bin and neon.bin> python3 tool/neon_pair.py
# Pairs the firmware places that use the field byte (Tropical settings+0x1EF) with Neon's (settings+0x203)
# by code shape: the instruction classes around each place (registers and numbers left out).
import re, sys
import os
U=os.environ.get('DUMPS', '.') + '/'
T=open(U+'tropical.bin','rb').read()
N=open(U+'neon.bin','rb').read()
FW0,FW1=0x11000,0x110000
def sites(b,off):
    pat=re.compile(rb'[\x80-\x9f][\xf8\xf9]'+bytes([off&0xff])+rb'['+re.escape(bytes([(off>>8)|(t<<4) for t in range(16)]))+rb']',re.S)
    return [m.start() for m in pat.finditer(b,FW0,FW1) if m.start()%2==0]
def is32(w): return (w&0xF800) in (0xE800,0xF000,0xF800)
def cls(b,o):
    w=b[o]|b[o+1]<<8
    if is32(w):
        w2=b[o+2]|b[o+3]<<8
        return ('L%02X%X'%(w>>8,(w>>4)&0xF), 4)
    return ('S%X%X'%(w>>12,(w>>9)&7), 2)
def shape(b,at,before=24,after=24):
    # decode forward from a little before (try to land on an instruction boundary)
    out=[];o=at-before
    while o<at+after:
        c,n=cls(b,o); out.append(c); o+=n
    return out
def score(a,b):
    # longest common subsequence length, normalised
    m=[[0]*(len(b)+1) for _ in range(len(a)+1)]
    for i in range(len(a)):
        for j in range(len(b)):
            m[i+1][j+1]=m[i][j]+1 if a[i]==b[j] else max(m[i][j+1],m[i+1][j])
    return m[len(a)][len(b)]/max(len(a),len(b))
ts=sites(T,0x1EF); ns=sites(N,0x203)
tsh={t:shape(T,t) for t in ts}; nsh={n:shape(N,n) for n in ns}
pairs=[]
for t in ts:
    best=max(((score(tsh[t],nsh[n]),n) for n in ns))
    pairs.append((t,best[1],best[0]))
good=[p for p in pairs if p[2]>=0.75]
print(f'Tropical sites {len(ts)}, Neon sites {len(ns)}, confident pairs {len(good)}')
known={0xAEAC:'bg',0xFD62:'child',0xFED2:'teen',0xFFBC:'adult',0x7C7A:'planet call',0x416B8:'field menu set'}
for t,n,s in pairs:
    tag=''
    for k,v in known.items():
        if abs((t-FW0)-k)<0x200: tag=v
    print(f'  trop fw 0x{t-FW0:05X} -> neon fw 0x{n-FW0:05X}  match {s:.2f} {tag}')
