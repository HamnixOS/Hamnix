#!/usr/bin/env python3
# Structural DE screendump analyzer. Reads a PNG/PPM framebuffer dump and
# asserts a REAL desktop is present: (1) a panel bar — a near-full-width
# horizontal band of a distinct color at the top OR bottom edge; (2) at
# least one app-window rectangle in the central area — a contiguous block
# whose color differs from the root backdrop AND the panel. Prints a JSON
# verdict and exits 0 (structure present) / 1 (blank/flat).
import sys, json
from collections import Counter
from PIL import Image

def load(path):
    return Image.open(path).convert('RGB')

def dominant(im):
    w,h=im.size; px=im.load(); c=Counter()
    for y in range(0,h,3):
        for x in range(0,w,3):
            c[px[x,y]]+=1
    return c

def near(a,b,t=18):
    return abs(a[0]-b[0])<=t and abs(a[1]-b[1])<=t and abs(a[2]-b[2])<=t

def row_band(im, y, root):
    # fraction of pixels in row y that are NOT the root backdrop color
    w,h=im.size; px=im.load(); n=0
    for x in range(0,w,2):
        if not near(px[x,y],root): n+=1
    return n/(w//2)

def detect_panel(im, root):
    # A panel is a horizontal band near top or bottom where most of the
    # row differs from root AND is fairly uniform (a bar color). Scan the
    # top 40px and bottom 40px.
    w,h=im.size
    best=None
    for label,ys in (("top",range(0,40)),("bottom",range(h-40,h))):
        for y in ys:
            frac=row_band(im,y,root)
            if frac>=0.55:
                if best is None or frac>best[2]:
                    best=(label,y,frac)
    return best

def detect_window(im, root, panel_color):
    # Look in the central region for a contiguous run of non-root,
    # non-panel pixels forming a window. Count the largest connected-ish
    # block by scanning rows for long runs and clustering.
    w,h=im.size; px=im.load()
    x0,x1=int(w*0.10),int(w*0.92)
    y0,y1=int(h*0.10),int(h*0.90)
    # count distinct "content" colors and the max horizontal run
    content=0; maxrun=0
    rows_with_window=0
    for y in range(y0,y1,2):
        run=0; rowhit=0
        for x in range(x0,x1,2):
            p=px[x,y]
            isroot=near(p,root)
            ispanel=panel_color is not None and near(p,panel_color)
            if not isroot and not ispanel:
                run+=1; content+=1; rowhit+=1
                if run>maxrun: maxrun=run
            else:
                run=0
        if rowhit>=20:
            rows_with_window+=1
    return content, maxrun, rows_with_window

def main():
    path=sys.argv[1]
    im=load(path)
    w,h=im.size
    c=dominant(im)
    root=c.most_common(1)[0][0]
    distinct=len(c)
    panel=detect_panel(im,root)
    panel_color=None
    if panel:
        px=im.load(); panel_color=px[w//2,panel[1]]
    content,maxrun,rows=detect_window(im,root,panel_color)
    # Decision thresholds: a real window paints a wide block over many
    # rows. A bare green+cursor frame has ~0 content rows.
    has_panel = panel is not None
    has_window = rows>=30 and maxrun>=40 and content>=1500
    verdict = has_panel and has_window
    out=dict(path=path,size=[w,h],distinct=distinct,root=list(root),
             panel=(list(panel) if panel else None),
             window_content_px=content,window_max_run=maxrun,
             window_rows=rows,has_panel=has_panel,has_window=has_window,
             pass_=verdict)
    print(json.dumps(out,indent=2))
    sys.exit(0 if verdict else 1)

main()
