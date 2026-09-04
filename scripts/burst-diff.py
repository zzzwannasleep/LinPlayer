# -*- coding: utf-8 -*-
"""连拍的相邻两张差了多少。只看画面区(去掉顶栏和底部控制条)。"""
import sys, os, struct, zlib

def load(p):
    # 只用标准库读 PNG:自检机器上不保证有 Pillow,而这一步不值得为它加依赖
    d = open(p, 'rb').read()
    pos, w, h, idat, bd, ct = 8, 0, 0, b'', 0, 0
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos+4])[0]
        typ = d[pos+4:pos+8]
        body = d[pos+8:pos+8+ln]
        if typ == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', body[:10])
        elif typ == b'IDAT':
            idat += body
        pos += 12 + ln
    assert bd == 8 and ct in (2, 6), 'PNG 不是 8 位 RGB/RGBA:bd=%d ct=%d' % (bd, ct)
    ch = 3 if ct == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * ch
    out = bytearray(w * h * ch)
    prev = bytearray(stride)
    o = 0
    for y in range(h):
        f = raw[o]; o += 1
        line = bytearray(raw[o:o+stride]); o += stride
        if f == 1:
            for i in range(ch, stride): line[i] = (line[i] + line[i-ch]) & 255
        elif f == 2:
            for i in range(stride): line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i-ch] if i >= ch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i-ch] if i >= ch else 0
                c = prev[i-ch] if i >= ch else 0
                b = prev[i]
                pp = a + b - c
                pa, pb, pc = abs(pp-a), abs(pp-b), abs(pp-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        out[y*stride:(y+1)*stride] = line
        prev = line
    return w, h, ch, bytes(out)

def main():
    base, pre, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
    imgs = []
    for i in range(1, n+1):
        p = os.path.join(base, '%s-%d.png' % (pre, i))
        if os.path.exists(p):
            imgs.append((i, load(p)))
    if len(imgs) < 2:
        print('[连拍] ✗ 只拿到 %d 张,量不了' % len(imgs)); return
    w, h, ch, _ = imgs[0][1]
    # 画面区:去掉顶栏 6% 和底部控制条 18%,只留中间那块纯画面
    y0, y1 = int(h*0.06), int(h*0.82)
    worst = 0.0
    for k in range(1, len(imgs)):
        _, (_, _, _, a) = imgs[k-1]
        _, (_, _, _, b) = imgs[k]
        diff = 0; tot = 0
        for y in range(y0, y1, 4):           # 每 4 行取一行,够了
            ro = y*w*ch
            for x in range(0, w, 4):
                o = ro + x*ch
                tot += 1
                if abs(a[o]-b[o]) + abs(a[o+1]-b[o+1]) + abs(a[o+2]-b[o+2]) > 24:
                    diff += 1
        pct = diff*100.0/max(tot, 1)
        worst = max(worst, pct)
        print('  第 %d→%d 张:差 %.2f%%' % (k, k+1, pct))
    print('[连拍] 暂停下相邻两张最大差 %.2f%%' % worst)
    print('[连拍] ✓ 暂停时画面是定住的' if worst < 1.0
          else '[连拍] ✗ 暂停时画面在变 —— 这就是「暂停了还在抽搐」')

main()
