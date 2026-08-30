# -*- coding: utf-8 -*-
"""列出 .sup(PGS)里每条字幕的起止时间,给 spike-1a-pgs.py 挑测试点用。"""
import struct, sys, io
p = sys.argv[1] if len(sys.argv) > 1 else sys.exit("用法: python spike-1a-pgs-parse.py <某个.sup文件>")
d = io.open(p,'rb').read()
print("文件大小: %.1f MB" % (len(d)/1048576))
off=0; segs={}; shows=[]; cur=None; w=h=0
while off+13 <= len(d):
    if d[off:off+2] != b'PG': print("!! magic 丢失于 offset", off); break
    pts, dts = struct.unpack_from('>II', d, off+2)
    stype = d[off+10]
    size, = struct.unpack_from('>H', d, off+11)
    payload = d[off+13:off+13+size]
    segs[stype] = segs.get(stype,0)+1
    if stype == 0x16 and len(payload) >= 11:      # PCS
        w,h = struct.unpack_from('>HH', payload, 0)
        nobj = payload[10]
        t = pts/90000.0
        if nobj > 0:
            cur = t
        elif cur is not None:
            shows.append((cur, t)); cur=None
    off += 13 + size
names={0x14:'PDS调色板',0x15:'ODS位图',0x16:'PCS合成',0x17:'WDS窗口',0x80:'END'}
print("段统计:", {names.get(k,hex(k)):v for k,v in sorted(segs.items())})
print("视频画布: %dx%d" % (w,h))
print("字幕条数: %d" % len(shows))
print("前 8 条(起, 止, 时长):")
for s,e in shows[:8]:
    print("   %8.3f  ->  %8.3f   (%.2fs)  = %02d:%02d:%06.3f" % (s,e,e-s,int(s//3600),int(s%3600//60),s%60))
# 挑一条足够长的做测试点
best = max(shows[:200], key=lambda x: x[1]-x[0]) if shows else None
if best: print("\n推荐测试时间点(取中点): %.3f  [该条 %.3f~%.3f]" % ((best[0]+best[1])/2, best[0], best[1]))
