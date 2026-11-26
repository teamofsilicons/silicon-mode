#!/usr/bin/env python3
"""Builds the provider logo data in App/Sources/Design/ProviderMark.swift from the official logo
files in this folder (see SOURCES.md).

    python3 -I App/Resources/Logos/generate.py [preview-dir]

Each SVG is flattened (groups, transforms, CSS classes, gradients resolved; arcs, rects, circles turned
into cubic paths) and placed into the 100x100 box whose inscribed circle is the mark, over the
brand's ground colour. The output replaces the block between the BEGIN/END GENERATED BRAND DATA
markers. With a preview dir it also writes one SVG per mark there. Logo files are only read as data.
Needs only the Python standard library.
"""
import math
import os
import re
import sys
import xml.etree.ElementTree as ET

SVGNS = '{http://www.w3.org/2000/svg}'
XLINK = '{http://www.w3.org/1999/xlink}href'

NAMED = {
    'black': '000000', 'white': 'FFFFFF', 'red': 'FF0000', 'green': '008000', 'blue': '0000FF',
    'yellow': 'FFFF00', 'gray': '808080', 'grey': '808080', 'orange': 'FFA500', 'purple': '800080',
}

INHERITED = ['fill', 'fill-opacity', 'fill-rule', 'stroke', 'stroke-width', 'stroke-opacity',
             'stroke-linecap', 'stroke-linejoin', 'stroke-miterlimit', 'color', 'visibility']
PROPS = INHERITED + ['opacity', 'display', 'stop-color', 'stop-opacity', 'clip-path', 'mask', 'filter',
                     'transform-origin']


# ---------- matrices ----------
I = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)


def mul(m, n):  # m then applied after n: result(p) = m(n(p))
    a, b, c, d, e, f = m
    A, B, C, D, E, F = n
    return (a * A + c * B, b * A + d * B, a * C + c * D, b * C + d * D, a * E + c * F + e, b * E + d * F + f)


def ap(m, x, y):
    a, b, c, d, e, f = m
    return (a * x + c * y + e, b * x + d * y + f)


def det(m):
    return m[0] * m[3] - m[1] * m[2]


NUM = r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?'


def parse_transform(s):
    m = I
    if not s:
        return m
    for name, args in re.findall(r'(\w+)\s*\(([^)]*)\)', s):
        v = [float(x) for x in re.findall(NUM, args)]
        if name == 'matrix':
            t = tuple(v[:6])
        elif name == 'translate':
            t = (1, 0, 0, 1, v[0], v[1] if len(v) > 1 else 0)
        elif name == 'scale':
            t = (v[0], 0, 0, v[1] if len(v) > 1 else v[0], 0, 0)
        elif name == 'rotate':
            r = math.radians(v[0])
            t = (math.cos(r), math.sin(r), -math.sin(r), math.cos(r), 0, 0)
            if len(v) == 3:
                t = mul((1, 0, 0, 1, v[1], v[2]), mul(t, (1, 0, 0, 1, -v[1], -v[2])))
        elif name == 'skewX':
            t = (1, 0, math.tan(math.radians(v[0])), 1, 0, 0)
        elif name == 'skewY':
            t = (1, math.tan(math.radians(v[0])), 0, 1, 0, 0)
        else:
            continue
        m = mul(m, t)
    return m


# ---------- path data ----------
class Scan:
    def __init__(self, d):
        self.d, self.i = d, 0

    def skip(self):
        while self.i < len(self.d) and self.d[self.i] in ' ,\t\n\r':
            self.i += 1

    def peek_cmd(self):
        self.skip()
        if self.i < len(self.d) and self.d[self.i].isalpha() and self.d[self.i] not in 'eE':
            return self.d[self.i]
        return None

    def done(self):
        self.skip()
        return self.i >= len(self.d)

    def num(self):
        self.skip()
        m = re.compile(NUM).match(self.d, self.i)
        if not m:
            raise ValueError('bad number at %d: %r' % (self.i, self.d[self.i:self.i + 20]))
        self.i = m.end()
        return float(m.group(0))

    def flag(self):
        self.skip()
        c = self.d[self.i]
        if c not in '01':
            raise ValueError('bad flag at %d' % self.i)
        self.i += 1
        return c == '1'


def arc_to_cubics(x0, y0, rx, ry, phi_deg, large, sweep, x1, y1):
    if (x0, y0) == (x1, y1):
        return []
    rx, ry = abs(rx), abs(ry)
    if rx == 0 or ry == 0:
        return [('L', x1, y1)]
    phi = math.radians(phi_deg)
    cp, sp = math.cos(phi), math.sin(phi)
    dx, dy = (x0 - x1) / 2, (y0 - y1) / 2
    x1p, y1p = cp * dx + sp * dy, -sp * dx + cp * dy
    lam = x1p ** 2 / rx ** 2 + y1p ** 2 / ry ** 2
    if lam > 1:
        k = math.sqrt(lam)
        rx, ry = rx * k, ry * k
    num = max(0.0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    coef = 0 if den == 0 else math.sqrt(num / den)
    if large == sweep:
        coef = -coef
    cxp, cyp = coef * rx * y1p / ry, -coef * ry * x1p / rx
    cx = cp * cxp - sp * cyp + (x0 + x1) / 2
    cy = sp * cxp + cp * cyp + (y0 + y1) / 2

    def ang(ux, uy, vx, vy):
        l = math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
        if l == 0:
            return 0
        a = math.acos(max(-1, min(1, (ux * vx + uy * vy) / l)))
        return -a if ux * vy - uy * vx < 0 else a

    ux, uy = (x1p - cxp) / rx, (y1p - cyp) / ry
    vx, vy = (-x1p - cxp) / rx, (-y1p - cyp) / ry
    t1 = ang(1, 0, ux, uy)
    dt = ang(ux, uy, vx, vy)
    if not sweep and dt > 0:
        dt -= 2 * math.pi
    if sweep and dt < 0:
        dt += 2 * math.pi
    segs = max(1, int(math.ceil(abs(dt) / (math.pi / 2) - 1e-9)))
    delta = dt / segs
    k = 4 / 3 * math.tan(delta / 4)

    def mp(x, y):
        return (cx + rx * x * cp - ry * y * sp, cy + rx * x * sp + ry * y * cp)

    out = []
    th = t1
    for i in range(segs):
        c1, s1 = math.cos(th), math.sin(th)
        th2 = th + delta
        c2, s2 = math.cos(th2), math.sin(th2)
        p1 = mp(c1 - k * s1, s1 + k * c1)
        p2 = mp(c2 + k * s2, s2 - k * c2)
        e = (x1, y1) if i == segs - 1 else mp(c2, s2)
        out.append(('C', p1[0], p1[1], p2[0], p2[1], e[0], e[1]))
        th = th2
    return out


def parse_path(d):
    sc = Scan(d)
    segs = []
    cx = cy = sx = sy = 0.0
    cmd = None
    last_c = last_q = None
    arity = {'M': 2, 'L': 2, 'H': 1, 'V': 1, 'C': 6, 'S': 4, 'Q': 4, 'T': 2, 'A': 7, 'Z': 0}
    while not sc.done():
        c = sc.peek_cmd()
        if c:
            cmd = c
            sc.i += 1
            if cmd in 'zZ':
                segs.append(('Z',))
                cx, cy = sx, sy
                last_c = last_q = None
                continue
        elif cmd is None:
            raise ValueError('path without command')
        U = cmd.upper()
        rel = cmd.islower()
        n = arity[U]
        if U == 'A':
            args = [sc.num(), sc.num(), sc.num(), sc.flag(), sc.flag(), sc.num(), sc.num()]
        else:
            args = [sc.num() for _ in range(n)]
        ox, oy = (cx, cy) if rel else (0.0, 0.0)
        if U == 'M':
            cx, cy = args[0] + ox, args[1] + oy
            sx, sy = cx, cy
            segs.append(('M', cx, cy))
            cmd = 'l' if rel else 'L'
            last_c = last_q = None
        elif U == 'L':
            cx, cy = args[0] + ox, args[1] + oy
            segs.append(('L', cx, cy))
            last_c = last_q = None
        elif U == 'H':
            cx = args[0] + ox
            segs.append(('L', cx, cy))
            last_c = last_q = None
        elif U == 'V':
            cy = args[0] + oy
            segs.append(('L', cx, cy))
            last_c = last_q = None
        elif U == 'C':
            x1, y1, x2, y2, x, y = args
            seg = ('C', x1 + ox, y1 + oy, x2 + ox, y2 + oy, x + ox, y + oy)
            segs.append(seg)
            last_c = (seg[3], seg[4])
            last_q = None
            cx, cy = seg[5], seg[6]
        elif U == 'S':
            x2, y2, x, y = args
            c1 = (2 * cx - last_c[0], 2 * cy - last_c[1]) if last_c else (cx, cy)
            seg = ('C', c1[0], c1[1], x2 + ox, y2 + oy, x + ox, y + oy)
            segs.append(seg)
            last_c = (seg[3], seg[4])
            last_q = None
            cx, cy = seg[5], seg[6]
        elif U == 'Q':
            x1, y1, x, y = args
            seg = ('Q', x1 + ox, y1 + oy, x + ox, y + oy)
            segs.append(seg)
            last_q = (seg[1], seg[2])
            last_c = None
            cx, cy = seg[3], seg[4]
        elif U == 'T':
            x, y = args
            c1 = (2 * cx - last_q[0], 2 * cy - last_q[1]) if last_q else (cx, cy)
            seg = ('Q', c1[0], c1[1], x + ox, y + oy)
            segs.append(seg)
            last_q = c1
            last_c = None
            cx, cy = seg[3], seg[4]
        elif U == 'A':
            rx, ry, rot, la, sw, x, y = args
            ex, ey = x + ox, y + oy
            segs.extend(arc_to_cubics(cx, cy, rx, ry, rot, bool(la), bool(sw), ex, ey))
            cx, cy = ex, ey
            last_c = last_q = None
    return segs


def tx_segs(segs, m):
    out = []
    for s in segs:
        if s[0] == 'Z':
            out.append(s)
            continue
        pts = s[1:]
        q = []
        for j in range(0, len(pts), 2):
            q.extend(ap(m, pts[j], pts[j + 1]))
        out.append((s[0],) + tuple(q))
    return out


def seg_bbox(segs):
    xs, ys = [], []
    cur = (0, 0)
    start = (0, 0)
    for s in segs:
        if s[0] == 'M':
            cur = start = (s[1], s[2])
            xs.append(cur[0]); ys.append(cur[1])
        elif s[0] == 'L':
            cur = (s[1], s[2])
            xs.append(cur[0]); ys.append(cur[1])
        elif s[0] == 'C':
            p0 = cur
            for k in range(1, 17):
                u = k / 16
                v = 1 - u
                x = v ** 3 * p0[0] + 3 * v * v * u * s[1] + 3 * v * u * u * s[3] + u ** 3 * s[5]
                y = v ** 3 * p0[1] + 3 * v * v * u * s[2] + 3 * v * u * u * s[4] + u ** 3 * s[6]
                xs.append(x); ys.append(y)
            cur = (s[5], s[6])
        elif s[0] == 'Q':
            p0 = cur
            for k in range(1, 17):
                u = k / 16
                v = 1 - u
                x = v * v * p0[0] + 2 * v * u * s[1] + u * u * s[3]
                y = v * v * p0[1] + 2 * v * u * s[2] + u * u * s[4]
                xs.append(x); ys.append(y)
            cur = (s[3], s[4])
        elif s[0] == 'Z':
            cur = start
    if not xs:
        return None
    return (min(xs), min(ys), max(xs), max(ys))


def fmt(v, prec):
    s = ('%.' + str(prec) + 'f') % v
    if '.' in s:
        s = s.rstrip('0').rstrip('.')
    if s in ('-0', ''):
        s = '0'
    if s.startswith('0.'):
        s = s[1:]
    elif s.startswith('-0.'):
        s = '-' + s[2:]
    return s


def segs_to_d(segs, prec=2):
    out = []
    for s in segs:
        nums = [fmt(v, prec) for v in s[1:]]
        part = s[0]
        for j, n in enumerate(nums):
            if j == 0 or n.startswith('-'):
                part += n
            elif n.startswith('.') and ('.' in nums[j - 1] or 'e' in nums[j - 1]):
                part += n
            else:
                part += ' ' + n
        out.append(part)
    return ''.join(out)


# ---------- shapes ----------
def L(el, name, default=0.0, ref=100.0):
    v = el.get(name)
    if v is None:
        return default
    v = v.strip()
    if v.endswith('%'):
        return float(v[:-1]) / 100 * ref
    return float(re.match(NUM, v).group(0))


def ellipse_segs(cx, cy, rx, ry):
    k = 0.5522847498
    return [('M', cx + rx, cy),
            ('C', cx + rx, cy + k * ry, cx + k * rx, cy + ry, cx, cy + ry),
            ('C', cx - k * rx, cy + ry, cx - rx, cy + k * ry, cx - rx, cy),
            ('C', cx - rx, cy - k * ry, cx - k * rx, cy - ry, cx, cy - ry),
            ('C', cx + k * rx, cy - ry, cx + rx, cy - k * ry, cx + rx, cy),
            ('Z',)]


def rect_segs(x, y, w, h, rx, ry):
    if rx <= 0 and ry <= 0:
        return [('M', x, y), ('L', x + w, y), ('L', x + w, y + h), ('L', x, y + h), ('Z',)]
    rx = min(rx, w / 2)
    ry = min(ry, h / 2)
    k = 0.5522847498
    return [('M', x + rx, y), ('L', x + w - rx, y),
            ('C', x + w - rx + k * rx, y, x + w, y + ry - k * ry, x + w, y + ry),
            ('L', x + w, y + h - ry),
            ('C', x + w, y + h - ry + k * ry, x + w - rx + k * rx, y + h, x + w - rx, y + h),
            ('L', x + rx, y + h),
            ('C', x + rx - k * rx, y + h, x, y + h - ry + k * ry, x, y + h - ry),
            ('L', x, y + ry),
            ('C', x, y + ry - k * ry, x + rx - k * rx, y, x + rx, y),
            ('Z',)]


def shape_segs(el, tag):
    if tag == 'path':
        d = el.get('d')
        return parse_path(d) if d else None
    if tag == 'rect':
        w, h = L(el, 'width'), L(el, 'height')
        if w <= 0 or h <= 0:
            return None
        rxv, ryv = el.get('rx'), el.get('ry')
        rx = L(el, 'rx') if rxv is not None else (L(el, 'ry') if ryv is not None else 0)
        ry = L(el, 'ry') if ryv is not None else rx
        return rect_segs(L(el, 'x'), L(el, 'y'), w, h, rx, ry)
    if tag == 'circle':
        r = L(el, 'r')
        return ellipse_segs(L(el, 'cx'), L(el, 'cy'), r, r) if r > 0 else None
    if tag == 'ellipse':
        return ellipse_segs(L(el, 'cx'), L(el, 'cy'), L(el, 'rx'), L(el, 'ry'))
    if tag in ('polygon', 'polyline'):
        v = [float(x) for x in re.findall(NUM, el.get('points', ''))]
        if len(v) < 4:
            return None
        s = [('M', v[0], v[1])] + [('L', v[j], v[j + 1]) for j in range(2, len(v) - 1, 2)]
        if tag == 'polygon':
            s.append(('Z',))
        return s
    if tag == 'line':
        return [('M', L(el, 'x1'), L(el, 'y1')), ('L', L(el, 'x2'), L(el, 'y2'))]
    return None


# ---------- colors / css ----------
def parse_color(v):
    """-> (hex 'RRGGBB', alpha) or None for none/transparent."""
    if v is None:
        return None
    v = v.strip()
    if v in ('none', 'transparent'):
        return None
    if v.lower() in NAMED:
        return (NAMED[v.lower()], 1.0)
    if v.startswith('#'):
        h = v[1:]
        if len(h) in (3, 4):
            a = int(h[3] * 2, 16) / 255 if len(h) == 4 else 1.0
            return (''.join(ch * 2 for ch in h[:3]).upper(), a)
        if len(h) in (6, 8):
            a = int(h[6:8], 16) / 255 if len(h) == 8 else 1.0
            return (h[:6].upper(), a)
    m = re.match(r'rgba?\(([^)]*)\)', v)
    if m:
        parts = [p for p in re.split(r'[\s,/]+', m.group(1).strip()) if p]
        vals = []
        for p in parts[:3]:
            vals.append(round(float(p[:-1]) * 2.55) if p.endswith('%') else round(float(p)))
        a = float(parts[3]) if len(parts) > 3 else 1.0
        return ('%02X%02X%02X' % tuple(vals), a)
    raise ValueError('color? %r' % v)


def parse_decls(s):
    out = {}
    for part in s.split(';'):
        if ':' in part:
            k, v = part.split(':', 1)
            out[k.strip()] = v.strip()
    return out


def parse_css(css, scheme):
    css = re.sub(r'/\*.*?\*/', '', css, flags=re.S)
    rules = []
    # pull out @media blocks
    out_css = ''
    i = 0
    media = []
    while True:
        m = re.search(r'@media([^{]*)\{', css[i:])
        if not m:
            out_css += css[i:]
            break
        start = i + m.start()
        out_css += css[i:start]
        j = i + m.end()
        depth = 1
        while depth and j < len(css):
            if css[j] == '{':
                depth += 1
            elif css[j] == '}':
                depth -= 1
            j += 1
        media.append((m.group(1), css[i + m.end():j - 1]))
        i = j
    blocks = [out_css]
    for cond, body in media:
        if 'prefers-color-scheme' in cond:
            if scheme in cond:
                blocks.append(body)
        # other media ignored
    for b in blocks:
        for sel, body in re.findall(r'([^{}]+)\{([^{}]*)\}', b):
            for s in sel.split(','):
                rules.append((s.strip(), parse_decls(body)))
    return rules


class Doc:
    def __init__(self, text, scheme='light'):
        if re.search(r'<!DOCTYPE|<!ENTITY', text, re.I):
            raise ValueError('refusing DTD/entities')
        # strip namespace prefixes like ns0: that some exporters emit
        self.root = ET.fromstring(text)
        self.scheme = scheme
        self.ids = {}
        css = ''
        for el in self.root.iter():
            if el.get('id'):
                self.ids[el.get('id')] = el
            if tag_of(el) == 'style' and el.text:
                css += el.text + '\n'
        self.rules = parse_css(css, scheme)
        self.vars = {}
        for sel, decl in self.rules:
            if sel in (':root', 'svg', 'html'):
                for k, v in decl.items():
                    if k.startswith('--'):
                        self.vars[k] = v
        self.layers = []
        self.warnings = []

    def css_for(self, el):
        tag = tag_of(el)
        classes = (el.get('class') or '').split()
        eid = el.get('id')
        out = {}
        for prio in (0, 1, 2):
            for sel, decl in self.rules:
                m = re.fullmatch(r'([a-zA-Z]*)((?:\.[\w-]+)*)(#[\w-]+)?', sel)
                if not m or sel in ('',):
                    continue
                t, cls, sid = m.group(1), m.group(2), m.group(3)
                p = 2 if sid else (1 if cls else 0)
                if p != prio:
                    continue
                if t and t != tag:
                    continue
                if cls and not all(c in classes for c in cls.split('.')[1:]):
                    continue
                if sid and sid[1:] != eid:
                    continue
                if not t and not cls and not sid:
                    continue
                out.update(decl)
        return out

    def resolve_var(self, v):
        if v is None:
            return v
        for _ in range(5):
            m = re.search(r'var\((--[\w-]+)\s*(?:,\s*([^)]*))?\)', v)
            if not m:
                break
            v = v[:m.start()] + self.vars.get(m.group(1), m.group(2) or '') + v[m.end():]
        return v

    def style(self, el, parent):
        st = {k: parent[k] for k in INHERITED if k in parent}
        for k in PROPS:
            if el.get(k) is not None:
                st[k] = el.get(k)
        st.update({k: v for k, v in self.css_for(el).items()})
        if el.get('style'):
            st.update(parse_decls(el.get('style')))
        for k in list(st):
            st[k] = self.resolve_var(st[k])
        if 'fill' not in st and 'fill' not in parent:
            pass
        return st


def tag_of(el):
    t = el.tag
    if isinstance(t, str) and '}' in t:
        t = t.split('}', 1)[1]
    return t


def viewport_matrix(el, vw, vh):
    vb = el.get('viewBox')
    x, y = L(el, 'x'), L(el, 'y')
    w = L(el, 'width', vw) if el.get('width') else vw
    h = L(el, 'height', vh) if el.get('height') else vh
    if not vb:
        return (1, 0, 0, 1, x, y), w, h
    bx, by, bw, bh = [float(v) for v in re.findall(NUM, vb)]
    if w is None:
        w, h = bw, bh
    par = (el.get('preserveAspectRatio') or 'xMidYMid meet').split()
    align = par[0]
    slice_ = len(par) > 1 and par[1] == 'slice'
    sx, sy = w / bw, h / bh
    if align != 'none':
        s = max(sx, sy) if slice_ else min(sx, sy)
        sx = sy = s
    tx = x - bx * sx
    ty = y - by * sy
    if align != 'none':
        if 'xMid' in align:
            tx += (w - bw * sx) / 2
        elif 'xMax' in align:
            tx += (w - bw * sx)
        if 'YMid' in align:
            ty += (h - bh * sy) / 2
        elif 'YMax' in align:
            ty += (h - bh * sy)
    return (sx, 0, 0, sy, tx, ty), bw, bh


SKIP = {'defs', 'clipPath', 'mask', 'linearGradient', 'radialGradient', 'filter', 'style', 'title', 'desc',
        'metadata', 'foreignObject', 'pattern', 'symbol', 'marker'}


def num_or(v, d):
    try:
        return float(v)
    except (TypeError, ValueError):
        return d


def gradient(doc, gid, el_bbox_local, ctm):
    g = doc.ids.get(gid)
    if g is None:
        doc.warnings.append('missing gradient ' + gid)
        return None
    chain = [g]
    while True:
        h = chain[-1].get(XLINK) or chain[-1].get('href')
        if not h or not h.startswith('#') or h[1:] not in doc.ids:
            break
        chain.append(doc.ids[h[1:]])

    def attr(name):
        for c in chain:
            if c.get(name) is not None:
                return c.get(name)
        return None

    stops_el = next((c for c in chain if any(tag_of(s) == 'stop' for s in c)), None)
    stops = []
    if stops_el is not None:
        for s in stops_el:
            if tag_of(s) != 'stop':
                continue
            st = parse_decls(s.get('style') or '')
            off = s.get('offset', '0')
            off = float(off[:-1]) / 100 if off.endswith('%') else float(off)
            col = parse_color(doc.resolve_var(st.get('stop-color') or s.get('stop-color') or '#000'))
            op = float(st.get('stop-opacity') or s.get('stop-opacity') or 1)
            if col is None:
                col = ('000000', 0)
            off = max(off, stops[-1][0] if stops else 0)
            stops.append((off, col[0], col[1] * op))
    units = attr('gradientUnits') or 'objectBoundingBox'
    gt = parse_transform(attr('gradientTransform'))
    kind = tag_of(g)
    if units == 'objectBoundingBox':
        x0, y0, x1, y1 = el_bbox_local
        base = mul(ctm, mul((x1 - x0, 0, 0, y1 - y0, x0, y0), gt))

        def val(name, d):
            v = attr(name)
            if v is None:
                return d
            return float(v[:-1]) / 100 if v.endswith('%') else float(v)
    else:
        base = mul(ctm, gt)

        def val(name, d):
            v = attr(name)
            if v is None:
                return d
            return float(v[:-1]) / 100 * 100 if v.endswith('%') else float(v)
    if kind == 'linearGradient':
        p0 = ap(base, val('x1', 0), val('y1', 0))
        p1 = ap(base, val('x2', 1 if units == 'objectBoundingBox' else 100), val('y2', 0))
        return {'type': 'linear', 'stops': stops, 'start': p0, 'end': p1}
    cx, cy = val('cx', .5 if units == 'objectBoundingBox' else 50), val('cy', .5 if units == 'objectBoundingBox' else 50)
    r = val('r', .5 if units == 'objectBoundingBox' else 50)
    c = ap(base, cx, cy)
    # keep the full ellipse frame: radius vectors along x and y
    ex = ap(base, cx + r, cy)
    ey = ap(base, cx, cy + r)
    return {'type': 'radial', 'stops': stops, 'center': c, 'rx': (ex[0] - c[0], ex[1] - c[1]),
            'ry': (ey[0] - c[0], ey[1] - c[1])}


def paint(doc, v, opacity, el_bbox_local, ctm, color):
    if v is None:
        return None
    v = v.strip()
    if v == 'currentColor':
        v = color or '#000'
    if v.startswith('url('):
        gid = re.match(r'url\(\s*["\']?#([^)"\']+)', v).group(1)
        g = gradient(doc, gid, el_bbox_local, ctm)
        if g is None:
            return None
        if opacity != 1:
            g['stops'] = [(o, c, a * opacity) for o, c, a in g['stops']]
        return g
    c = parse_color(v)
    if c is None:
        return None
    return {'type': 'solid', 'color': c[0], 'alpha': c[1] * opacity}


def walk(doc, el, ctm, parent_style, opacity, vw, vh, path_idx):
    tag = tag_of(el)
    if tag in SKIP:
        return
    st = doc.style(el, parent_style)
    if st.get('display') == 'none' or st.get('visibility') == 'hidden':
        return
    m = mul(ctm, parse_transform(el.get('transform')))
    op = opacity * float(st.get('opacity', 1) or 1)
    if st.get('mask'):
        doc.warnings.append('mask ignored on <%s> %s' % (tag, path_idx))
    if st.get('filter'):
        doc.warnings.append('filter ignored on <%s> %s' % (tag, path_idx))
    if st.get('clip-path') and st.get('clip-path') != 'none':
        doc.warnings.append('clip-path ignored on <%s> %s' % (tag, path_idx))
    if tag == 'svg':
        vm, nvw, nvh = viewport_matrix(el, vw, vh)
        m2 = mul(m, vm) if el is not doc.root else m
        for k, c in enumerate(el):
            walk(doc, c, m2, st, op, nvw, nvh, path_idx + [k])
        return
    if tag in ('g', 'a', 'switch'):
        for k, c in enumerate(el):
            walk(doc, c, m, st, op, vw, vh, path_idx + [k])
        return
    if tag == 'use':
        h = el.get(XLINK) or el.get('href')
        if h and h[1:] in doc.ids:
            m2 = mul(m, (1, 0, 0, 1, L(el, 'x'), L(el, 'y')))
            walk(doc, doc.ids[h[1:]], m2, st, op, vw, vh, path_idx + ['use'])
        return
    segs = shape_segs(el, tag)
    if not segs:
        return
    local_bbox = seg_bbox(segs)
    fill_v = st.get('fill', '#000')
    fo = float(st.get('fill-opacity', 1) or 1)
    so = float(st.get('stroke-opacity', 1) or 1)
    color = st.get('color')
    fill = None if tag == 'line' else paint(doc, fill_v, op * fo, local_bbox, m, color)
    stroke = None
    sv = st.get('stroke')
    if sv and sv != 'none':
        sp = paint(doc, sv, op * so, local_bbox, m, color)
        if sp:
            w = float(re.match(NUM, st.get('stroke-width', '1')).group(0))
            scale = math.sqrt(abs(det(m)))
            stroke = {'paint': sp, 'width': w * scale, 'cap': st.get('stroke-linecap', 'butt'),
                      'join': st.get('stroke-linejoin', 'miter'),
                      'miter': float(st.get('stroke-miterlimit', 4))}
    if fill is None and stroke is None:
        return
    gsegs = tx_segs(segs, m)
    doc.layers.append({'segs': gsegs, 'fill': fill, 'stroke': stroke,
                       'evenOdd': st.get('fill-rule') == 'evenodd', 'tag': tag,
                       'id': el.get('id') or '', 'where': '/'.join(map(str, path_idx))})


def load(path, scheme='light'):
    text = open(path, encoding='utf-8').read()
    doc = Doc(text, scheme)
    r = doc.root
    vb = r.get('viewBox')
    if vb:
        bx, by, bw, bh = [float(v) for v in re.findall(NUM, vb)]
    else:
        bw, bh = L(r, 'width', 100), L(r, 'height', 100)
        bx = by = 0
    m = (1, 0, 0, 1, 0, 0)
    walk(doc, r, m, {'fill': '#000'}, 1.0, bw, bh, [])
    doc.viewbox = (bx, by, bw, bh)
    return doc

S = sys.modules[__name__]
HERE = os.path.dirname(os.path.abspath(__file__))
LOGOS = HERE
SWIFT = os.path.normpath(os.path.join(HERE, '..', '..', 'Sources', 'Design', 'ProviderMark.swift'))
PREVIEW = sys.argv[1] if len(sys.argv) > 1 else None


# ---------- helpers ----------
def solid(hexv, alpha=1.0):
    return {'type': 'solid', 'color': hexv.upper(), 'alpha': alpha}


def rect(x, y, w, h):
    return [('M', x, y), ('L', x + w, y), ('L', x + w, y + h), ('L', x, y + h), ('Z',)]


def poly(pts):
    return [('M',) + tuple(pts[0])] + [('L',) + tuple(p) for p in pts[1:]] + [('Z',)]


def circle(cx, cy, r):
    return S.ellipse_segs(cx, cy, r, r)


def layer(segs, paint, evenodd=False, stroke=None, note=''):
    return {'segs': segs, 'fill': paint, 'stroke': stroke, 'evenOdd': evenodd, 'tag': note}


def logo(name, scheme='light'):
    return S.load(os.path.join(LOGOS, name), scheme).layers


def subpaths(segs):
    out, cur = [], []
    for s in segs:
        if s[0] == 'M' and cur:
            out.append(cur)
            cur = []
        cur.append(s)
    if cur:
        out.append(cur)
    return out


def tx_paint(p, m):
    if p is None:
        return None
    p = dict(p)
    if p['type'] == 'linear':
        p['start'] = S.ap(m, *p['start'])
        p['end'] = S.ap(m, *p['end'])
    elif p['type'] == 'radial':
        c = S.ap(m, *p['center'])
        a, b, cc, d = m[0], m[1], m[2], m[3]
        p['rx'] = (a * p['rx'][0] + cc * p['rx'][1], b * p['rx'][0] + d * p['rx'][1])
        p['ry'] = (a * p['ry'][0] + cc * p['ry'][1], b * p['ry'][0] + d * p['ry'][1])
        p['center'] = c
    elif p['type'] == 'mesh':
        x0, y0 = S.ap(m, p['rect'][0], p['rect'][1])
        x1, y1 = S.ap(m, p['rect'][0] + p['rect'][2], p['rect'][1] + p['rect'][3])
        p['rect'] = (x0, y0, x1 - x0, y1 - y0)
    return p


def tx_layer(l, m):
    l = dict(l)
    l['segs'] = S.tx_segs(l['segs'], m)
    l['fill'] = tx_paint(l['fill'], m)
    if l['stroke']:
        st = dict(l['stroke'])
        st['paint'] = tx_paint(st['paint'], m)
        st['width'] = st['width'] * math.sqrt(abs(S.det(m)))
        l['stroke'] = st
    return l


def bbox_of(layers):
    bs = []
    for l in layers:
        b = S.seg_bbox(l['segs'])
        if l['stroke']:
            w = l['stroke']['width'] / 2
            b = (b[0] - w, b[1] - w, b[2] + w, b[3] + w)
        bs.append(b)
    return (min(b[0] for b in bs), min(b[1] for b in bs), max(b[2] for b in bs), max(b[3] for b in bs))


def place_icon(layers, box, zoom=1.0, dx=0.0, dy=0.0):
    """Maps the source square `box` (x, y, w, h) onto the 100x100 disc box, scaled by `zoom`."""
    x, y, w, h = box
    s = 100.0 / max(w, h) * zoom
    cx, cy = x + w / 2, y + h / 2
    m = (s, 0, 0, s, 50 - cx * s + dx, 50 - cy * s + dy)
    return [tx_layer(l, m) for l in layers]


def place_fit(layers, size, dx=0.0, dy=0.0):
    """Fits the layers' bounds so the larger side spans `size` of the disc, centred."""
    b = bbox_of(layers)
    w, h = b[2] - b[0], b[3] - b[1]
    s = 100.0 * size / max(w, h)
    cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
    m = (s, 0, 0, s, 50 - cx * s + dx, 50 - cy * s + dy)
    return [tx_layer(l, m) for l in layers]


def recolor(layers, hexv, alpha=1.0):
    out = []
    for l in layers:
        l = dict(l)
        if l['fill']:
            l['fill'] = solid(hexv, alpha)
        if l['stroke']:
            st = dict(l['stroke'])
            st['paint'] = solid(hexv, alpha)
            l['stroke'] = st
        out.append(l)
    return out


def pick(layers, keep):
    return [layers[i] for i in keep]


def lum(hexv):
    r, g, b = (int(hexv[i:i + 2], 16) / 255 for i in (0, 2, 4))
    f = lambda c: c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4  # noqa: E731
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)


# ---------- reconstructions from official rasters ----------
def aider_layers():
    # Pixel "a" from aider.chat/assets/icons/apple-touch-icon.png (180 px): 6 columns x 5 rows of
    # 19.25 x 29.9 px cells starting at (35.5, 14.5). Measured from the image.
    cw, ch, x0, y0 = 19.25, 29.9, 35.5, 14.5
    cells = {0: [(1, 3)], 1: [(4, 1)], 2: [(1, 4)], 3: [(0, 1), (4, 1)], 4: [(1, 3), (5, 1)]}
    segs = []
    for row, runs in cells.items():
        for c, n in runs:
            segs += rect(x0 + c * cw, y0 + row * ch, n * cw, ch)
    return [layer(segs, solid('00FEB4'), note='aider-a')]


def plandex_layers():
    # Chevrons fitted to images/plandex-logo-thumb.png (600 px): edge lines least-squares fitted
    # on the alpha mask, colours fitted as linear gradients over each shape.
    left = [(268, 0.5), (19.45, 288.3), (268, 599.5), (268, 439.2), (149.93, 299.42), (268, 159.7)]
    right = [(330.2, 0), (578.6, 288.3), (330.2, 599.2), (330.2, 439.0), (448.1, 299.4), (330.2, 159.9)]
    lp = {'type': 'linear', 'stops': [(0, 'BA96F9', 1), (0.5, 'E07BF8', 1), (1, 'FF60F6', 1)],
          'start': (76.1, 364.5), 'end': (373.3, 150.7)}
    rp = {'type': 'linear', 'stops': [(0, '41EFA4', 1), (0.5, '61F7E0', 1), (1, '82FFFF', 1)],
          'start': (522.3, 364.3), 'end': (227.8, 151.7)}
    return [layer(poly(left), lp, note='plandex-left'), layer(poly(right), rp, note='plandex-right')]


def codebuff_layers():
    # "✦_" from codebuff.com/favicon/apple-touch-icon.png (128 px): a four-point sparkle (each side a
    # cubic fitted to the measured row widths) and the underscore bar.
    cx, cy, r, u, v = 36.0, 36.1, 26.0, 9.0, 5.25
    pts = []
    segs = [('M', cx, cy - r)]
    # quarter: from (0,-r) to (r,0) with P1=(u,-v), P2=(v,-u); rotate 90° each time
    for q in range(4):
        def rot(x, y, q=q):
            for _ in range(q):
                x, y = -y, x
            return (cx + x, cy + y)
        p1, p2, p3 = rot(u, -v), rot(v, -u), rot(r, 0)
        segs.append(('C', p1[0], p1[1], p2[0], p2[1], p3[0], p3[1]))
    segs.append(('Z',))
    bar = rect(64.1, 64.0, 39.9, 8.0)
    return [layer(segs, solid('FFFFFF'), note='codebuff-star'), layer(bar, solid('FFFFFF'), note='codebuff-bar')]


# The favicon colours its arch with ten blurred ellipses under a mask. That field was rendered without
# the mask (librsvg, 544 px) and sampled on a 6x6 grid over the arch bounds (7x7 px average per point);
# SwiftUI draws it back as a MeshGradient clipped to the arch.
ANTIGRAVITY_MESH = [
    '8FCE53', 'D6D93B', 'EAB027', 'F5563B', 'FC423D', 'FB413D',
    '9AD751', 'AFD554', '86A77A', 'BF696B', 'F44745', 'FB413E',
    '5BC761', '5EB78B', '3D91D7', '5B80D8', 'AF6999', 'DC5366',
    '21AA94', '3194D8', '3287FC', '3887FD', '5C8AF0', '8285D8',
    '2593D6', '2F88F9', '3187FF', '3186FF', '3A89FE', '4B8BFA',
    '2F88F9', '3186FF', '3186FF', '3186FF', '3286FF', '3486FE',
]


def antigravity_mesh(arch_layer):
    b = S.seg_bbox(arch_layer['segs'])
    return {'type': 'mesh', 'cols': 6, 'rows': 6, 'colors': ANTIGRAVITY_MESH,
            'rect': (b[0], b[1], b[2] - b[0], b[3] - b[1])}


def geminicli_layers():
    # lobe-icons Gemini CLI (reproduces the official VS Code companion icon): gradient frame, dark
    # face, chevron. The frame becomes the disc ring; the chevron is the hole in the face path.
    ls = logo('geminicli-color.svg')
    frame, face = ls[0], ls[1]
    subs = subpaths(face['segs'])
    # the chevron is the smallest subpath
    chevron = min(subs, key=lambda s: (lambda b: (b[2] - b[0]) * (b[3] - b[1]))(S.seg_bbox(s)))
    grad = frame['fill']
    return chevron, grad


BR = {}


def brand(key, disc, layers, source, note='', ring=None):
    BR[key] = {'disc': disc, 'layers': layers, 'source': source, 'note': note, 'ring': ring}


# ---------- brands ----------
def build():
    # Claude Code: the Claude spark as on the Claude app icon (ivory spark on Claude orange).
    l = recolor(logo('claude-code.svg'), 'FAF9F5')
    brand('claude', solid('D97757'), place_fit(l, 0.70), 'claude.com/icon.svg')

    # OpenAI / Codex: the 2025 OpenAI blossom exactly as openai.com/favicon.svg (black on a white disc).
    l = logo('openai.svg')
    brand('openai', solid('FFFFFF'), place_icon(pick(l, [1]), (0, 0, 180, 180)), 'openai.com/favicon.svg')

    # opencode: favicon-v3 (white frame, grey core, near-black ground).
    l = logo('opencode.svg')
    brand('opencode', solid('131010'), place_icon(pick(l, [1, 2]), (0, 0, 512, 512), zoom=1.02),
          'opencode favicon-v3.svg')

    # pi: pi.dev logo (three-colour pixel "pi") on black, like the pi app icon.
    l = logo('pi.svg')
    brand('pi', solid('111111'), place_fit(l, 0.56), 'pi.dev/logo-auto.svg')

    # Hermes Agent: the app icon portrait (icon-master.svg), white ground.
    l = logo('hermes-agent.svg')
    brand('hermes', solid('FFFFFF'), place_icon(pick(l, [1]), (0, 0, 1024, 1024), zoom=1.06, dy=-1.5),
          'hermes-agent assets/icon-master.svg')

    # OpenClaw: openclaw.ai favicon mascot (dark eyes, grey highlights) on a dark disc.
    l = logo('openclaw.svg')
    brand('openclaw', solid('1A1C22'), place_fit(l, 0.78, dy=1.0), 'openclaw.ai/favicon.svg')

    # Antigravity: the favicon arch on its white disc, colour field as a mesh gradient.
    l = logo('antigravity.svg')
    arch = dict(l[1])
    arch['fill'] = antigravity_mesh(arch)
    brand('antigravity', solid('FFFFFF'), place_icon([arch], (3, 3, 130, 130)), 'antigravity.google/favicon.svg')

    # Gemini CLI: chevron and gradient frame (as a ring) on the dark face colour.
    chev, grad = geminicli_layers()
    m_src = [layer(chev, grad)]
    ring = layer(circle(12, 12, 12 - 0.72), None, stroke={'paint': grad, 'width': 1.44, 'cap': 'butt',
                                                         'join': 'miter', 'miter': 4})
    placed = place_icon(m_src + [ring], (0, 0, 24, 24))
    brand('gemini', solid('1E1E2E'), placed, 'lobe-icons geminicli-color (= official Gemini CLI icon)')

    # Jules: white octopus on Jules purple (jules.google og image).
    l = recolor(logo('jules.svg'), 'FFFFFF')
    brand('jules', solid('642CC2'), place_fit(l, 0.60, dy=0.5), 'jules.google/favicon.svg')

    # Grok: grok.com favicon mark, white on black.
    l = logo('grok.svg')
    brand('grok', solid('050505'), place_icon(pick(l, [2, 3]), (0, 0, 512, 512), zoom=1.04), 'grok.com/images/favicon.svg')

    # Cursor: cursor.com favicon (cube) on its dark ground.
    l = logo('cursor.svg')
    brand('cursor', solid('14120B'), place_icon(pick(l, [2]), (0, 0, 512, 512), zoom=1.0), 'cursor.com favicon.svg')

    # Amp: ampcode.com favicon (cream wordmark on dark green-black gradient).
    l = logo('amp.svg')
    bg = l[0]['fill']
    disc = dict(bg)
    disc = tx_paint(disc, (100 / 1024, 0, 0, 100 / 1024, 0, 0))
    brand('amp', disc, place_fit(pick(l, [4]), 0.74), 'ampcode.com/favicon.svg', ring='light')

    # Factory (droid): factory.ai favicon, white flower on black.
    l = logo('factory.svg')
    brand('factory', solid('020202'), place_icon(pick(l, [1]), (0, 0, 508, 508), zoom=1.05), 'factory.ai/favicon.svg')

    # Kiro: kiro.dev icon (white ghost on Kiro purple).
    l = logo('kiro.svg')
    brand('kiro', solid('9046FF'), place_icon(pick(l, [1, 2, 3]), (0, 0, 1200, 1200), zoom=1.0), 'kiro.dev/icon.svg')

    # Aider: the pixel "a" of the aider.chat app icon (mint on dark green).
    disc = {'type': 'linear', 'stops': [(0, '00552C', 1), (1, '00331C', 1)], 'start': (50, 0), 'end': (50, 100)}
    brand('aider', disc, place_icon(aider_layers(), (0, 0, 180, 180), zoom=0.9, dy=0.5),
          'aider.chat/assets/icons/apple-touch-icon.png (traced)')

    # Qwen Code: the Qwen Code mark (blue) on white.
    l = logo('qwen-code.svg')
    brand('qwen', solid('FFFFFF'), place_fit(l, 0.66), 'QwenLM/qwen-code qwen-code-logo.svg')

    # Crush: Charm's heartbit mascot on Charm purple (crush notification icon).
    l = logo('crush.svg')
    brand('crush', solid('6B50FF'), place_fit(l, 0.64, dy=0.5), 'charmbracelet/crush heartbit.svg')

    # goose: desktop app icon (black goose on white).
    l = logo('goose.svg')
    brand('goose', solid('FFFFFF'), place_icon(pick(l, [1]), (200, 200, 1648, 1648), zoom=1.0), 'goose ui/desktop icon.svg')

    # GitHub Copilot: Primer octicon copilot-24, white on GitHub dark.
    l = recolor(logo('copilot.svg'), 'FFFFFF')
    brand('copilot', solid('1F2328'), place_fit(l, 0.62), 'primer/octicons copilot-24.svg')

    # Amazon Q: the Q hexagon (gradient) on AWS squid ink.
    l = logo('amazon-q.svg')
    brand('amazonq', solid('232F3E'), place_fit(l, 0.70), 'aws-toolkit-vscode amazonq/q-gradient.svg')

    # Kimi: K and blue dot, white on black (Kimi app icon).
    l = logo('kimi.svg')
    l = [dict(l[0]), recolor([l[1]], 'FFFFFF')[0]]
    brand('kimi', solid('000000'), place_fit(l, 0.56, dx=-0.5), 'lobe-icons kimi-color (= official Kimi logo)')

    # Cline: cline-app-icon.svg (white robot on slate).
    l = logo('cline.svg')
    brand('cline', solid('343B42'), place_icon(pick(l, [1, 2, 3]), (0, 0, 1024, 1024), zoom=1.0), 'cline assets/branding/cline-app-icon.svg')

    # Roo Code: kangaroo, white on black (extension icon).
    l = recolor(logo('roo-code.svg'), 'FFFFFF')
    brand('roo', solid('000000'), place_fit(l, 0.70, dy=-0.5), 'RooCodeInc/Roo-Code src/assets/icons/icon.svg')

    # Continue: JetBrains plugin icon (already a disc).
    l = logo('continue.svg')
    brand('continueDev', solid('F3F3F3'), place_icon(pick(l, [1]), (0, 0, 300, 300)), 'continuedev/continue pluginIcon_dark.svg')

    # Windsurf: windsurf.com favicon (wave on cream).
    l = logo('windsurf.svg')
    brand('windsurf', solid('F9F3E9'), place_icon(pick(l, [1]), (0, 0, 1024, 1024), zoom=1.02), 'windsurf.com/favicon.svg')

    # Augment: augmentcode.com favicon glyph, black on light.
    l = logo('augment.svg')
    brand('augment', solid('F5F5F7'), place_fit(l, 0.64, dy=0.5), 'augmentcode.com/favicon.svg')

    # Letta: the Letta mark (from the letta.com wordmark), white on Letta charcoal.
    l = recolor(pick(logo('letta.svg'), [0, 1]), 'FFFFFF')
    brand('letta', solid('202020'), place_fit(l, 0.52), 'letta.com header wordmark (mark only)')

    # Kilo Code: yellow ground, black "kilo" letters (the holes of the yellow plate).
    l = logo('kilo-code.svg')
    plate = l[1]
    subs = subpaths(plate['segs'])
    letters = [s for s in subs if S.seg_bbox(s) != (0.0, 0.0, 512.0, 512.0)]
    segs = [x for s in letters for x in s]
    brand('kilo', solid('FFDD00'), place_fit([layer(segs, solid('000000'), evenodd=True)], 0.60),
          'Kilo-Org/kilocode pluginIcon.svg')

    # OpenHands: openhands.dev favicon (white hands on the dark gradient).
    l = logo('openhands.svg')
    disc = tx_paint(l[0]['fill'], (100 / 1024, 0, 0, 100 / 1024, 0, 0))
    brand('openhands', disc, place_icon(l[1:], (0, 0, 1024, 1024), zoom=1.02), 'openhands.dev/favicon.svg', ring='light')

    # Codebuff: the "✦_" prompt mark, white on Codebuff charcoal.
    brand('codebuff', solid('222222'), place_fit(codebuff_layers(), 0.62, dy=1.5),
          'codebuff.com favicon/apple-touch-icon.png (traced)')

    # Plandex: the two gradient chevrons on dark.
    brand('plandex', solid('111214'), place_fit(plandex_layers(), 0.58), 'plandex-ai/plandex images/plandex-logo-thumb.png (traced)')

    # Junie: JetBrains Junie mark (green) on black.
    l = logo('junie.svg')
    brand('junie', solid('000000'), place_fit(l, 0.56), 'junie.jetbrains.com header logo')

    # T3 Code: T3 lettering, white on black.
    l = logo('t3code.svg')
    brand('t3', solid('000000'), place_icon(pick(l, [1]), (0, 0, 128, 128), zoom=1.0), 'pingdotgg/t3code assets/prod/logo.svg')

    # Silicon Omni: Team of Silicons mark (teamofsilicons.com/logo.svg), ivory on near-black.
    l = recolor(logo('tos.svg'), 'EDE8E0')
    brand('omni', solid('181818'), place_fit(l, 0.58), 'teamofsilicons.com/logo.svg')

    # Zed (not in the catalog; kept for aliases): simple-icons Zed mark, white on Zed's dark blue.
    l = recolor(logo('zed.svg'), 'FFFFFF')
    brand('zed', solid('0E2A5C'), place_fit(l, 0.54), 'simple-icons zed (CC0)')


# ---------- emit ----------
def fmtn(v, prec=2):
    """Swift number literal (needs a leading zero, unlike path data)."""
    t = S.fmt(v, prec)
    if t.startswith('.'):
        t = '0' + t
    elif t.startswith('-.'):
        t = '-0' + t[1:]
    return t


def swift_stops(stops):
    return '[' + ', '.join('.init(%s, "%s"%s)' % (fmtn(o), c, '' if a >= 0.999 else ', %s' % fmtn(a, 3)) for o, c, a in stops) + ']'


def swift_paint(p):
    if p['type'] == 'solid':
        return '.color("%s"%s)' % (p['color'], '' if p['alpha'] >= 0.999 else ', %s' % fmtn(p['alpha'], 3))
    if p['type'] == 'linear':
        return '.linear(%s, from: (%s, %s), to: (%s, %s))' % (swift_stops(p['stops']), fmtn(p['start'][0]), fmtn(p['start'][1]),
                                                             fmtn(p['end'][0]), fmtn(p['end'][1]))
    if p['type'] == 'mesh':
        r = p['rect']
        return '.mesh(columns: %d, rows: %d, in: (%s, %s, %s, %s), colors: [%s])' % (
            p['cols'], p['rows'], fmtn(r[0]), fmtn(r[1]), fmtn(r[2]), fmtn(r[3]),
            ', '.join('"%s"' % c for c in p['colors']))
    raise ValueError(p['type'])


def swift_layer(l):
    d = S.segs_to_d(l['segs'], 2)
    if l['stroke']:
        st = l['stroke']
        return '.stroke("%s", %s, width: %s, cap: .%s)' % (d, swift_paint(st['paint']), fmtn(st['width']), st['cap'])
    return '.fill("%s", %s%s)' % (d, swift_paint(l['fill']), ', evenOdd: true' if l['evenOdd'] else '')


def svg_paint(p, defs):
    if p['type'] == 'solid':
        return '#%s" fill-opacity="%.3f' % (p['color'], p['alpha'])
    gid = 'g%d' % len(defs)
    if p['type'] == 'linear':
        stops = ''.join('<stop offset="%.4f" stop-color="#%s" stop-opacity="%.3f"/>' % s for s in p['stops'])
        defs.append('<linearGradient id="%s" gradientUnits="userSpaceOnUse" x1="%f" y1="%f" x2="%f" y2="%f">%s</linearGradient>'
                    % (gid, *p['start'], *p['end'], stops))
        return 'url(#%s)' % gid
    if p['type'] == 'mesh':
        # preview only: a coarse pattern of the mesh colours
        x, y, w, h = p['rect']
        cells = []
        for j in range(p['rows']):
            for i in range(p['cols']):
                cw, ch = w / (p['cols'] - 1), h / (p['rows'] - 1)
                cells.append('<rect x="%f" y="%f" width="%f" height="%f" fill="#%s"/>' % (
                    x + (i - 0.5) * cw, y + (j - 0.5) * ch, cw, ch, p['colors'][j * p['cols'] + i]))
        defs.append('<pattern id="%s" patternUnits="userSpaceOnUse" x="0" y="0" width="200" height="200">%s</pattern>'
                    % (gid, ''.join(cells)))
        return 'url(#%s)' % gid
    raise ValueError(p['type'])


def preview(key, b):
    os.makedirs(PREVIEW, exist_ok=True)
    defs, body = [], []
    body.append('<circle cx="50" cy="50" r="50" fill="%s"/>' % svg_paint(b['disc'], defs))
    for l in b['layers']:
        d = S.segs_to_d(l['segs'], 2)
        if l['stroke']:
            st = l['stroke']
            body.append('<path d="%s" fill="none" stroke="%s" stroke-width="%f" stroke-linecap="%s"/>'
                        % (d, svg_paint(st['paint'], defs).replace('fill-opacity', 'stroke-opacity'), st['width'], st['cap']))
        else:
            body.append('<path d="%s" fill="%s"%s/>' % (d, svg_paint(l['fill'], defs), ' fill-rule="evenodd"' if l['evenOdd'] else ''))
    ring = b['ring_kind']
    body.append('<circle cx="50" cy="50" r="49.5" fill="none" stroke="%s" stroke-width="1"/>' %
                ('rgba(255,255,255,0.16)' if ring == 'light' else 'rgba(0,0,0,0.10)'))
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><defs><clipPath id="disc"><circle cx="50" cy="50" r="50"/></clipPath>%s</defs>'
           '<g clip-path="url(#disc)">%s</g></svg>') % (''.join(defs), ''.join(body))
    open(os.path.join(PREVIEW, key + '.svg'), 'w').write(svg)


def disc_lum(p):
    if p['type'] == 'solid':
        return lum(p['color'])
    return sum(lum(s[1]) for s in p['stops']) / len(p['stops'])


BEGIN = '    // BEGIN GENERATED BRAND DATA\n'
END = '    // END GENERATED BRAND DATA\n'


def main():
    build()
    out = []
    for key, b in BR.items():
        b['ring_kind'] = b['ring'] or ('light' if disc_lum(b['disc']) < 0.35 else 'dark')
        if PREVIEW:
            preview(key, b)
        out.append('    /// %s' % b['source'])
        out.append('    static let %s = BrandMark(disc: %s, ring: .%s, layers: [' % (key, swift_paint(b['disc']), b['ring_kind']))
        for l in b['layers']:
            out.append('        ' + swift_layer(l) + ',')
        out.append('    ])')
        out.append('')
    src = open(SWIFT, encoding='utf-8').read()
    i, j = src.index(BEGIN) + len(BEGIN), src.index(END)
    open(SWIFT, 'w', encoding='utf-8').write(src[:i] + '\n'.join(out) + src[j:])
    print('%d brands -> %s' % (len(BR), os.path.relpath(SWIFT)))


main()
