#!/usr/bin/env python3
"""
ghOSt-RG35XXH Wallpaper Generator v2
Original procedural SHODAN-inspired art. No copyrighted assets.
640x480 native RG35XXH resolution.
"""

import math, random, sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:
    import subprocess; subprocess.run(["pip3","install","Pillow","--break-system-packages","-q"])
    from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 640, 480
OUTPUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/opt/ghost/launcher/wallpaper.png")

PALETTE = {
    "cybersec":   {"bg":(0,0,0),      "fg":(0,255,65),   "dim":(0,60,15),   "accent":(0,220,55),  "wire":(0,100,25), "glow":(0,180,40)},
    "kali":       {"bg":(20,20,40),   "fg":(85,124,255), "dim":(35,45,80),  "accent":(184,119,219),"wire":(40,120,150),"glow":(100,140,255)},
    "blackarch":  {"bg":(8,8,8),      "fg":(200,0,0),    "dim":(45,0,0),    "accent":(255,50,50), "wire":(70,140,6), "glow":(255,30,30)},
    "parrot":     {"bg":(22,30,38),   "fg":(0,180,216),  "dim":(15,45,55),  "accent":(86,220,210),"wire":(0,160,90), "glow":(0,200,220)},
    "dragonos":   {"bg":(24,20,14),   "fg":(255,109,0),  "dim":(55,28,0),   "accent":(255,160,0), "wire":(120,170,60),"glow":(255,130,0)},
    "steamos":    {"bg":(18,26,42),   "fg":(77,140,199), "dim":(25,40,65),  "accent":(102,168,224),"wire":(80,155,85),"glow":(100,160,220)},
    "catppuccin": {"bg":(24,24,37),   "fg":(137,180,250),"dim":(45,46,64),  "accent":(203,166,247),"wire":(150,220,160),"glow":(160,190,255)},
    "ghost":      {"bg":(8,8,8),      "fg":(55,55,55),   "dim":(18,18,18),  "accent":(75,75,75),  "wire":(35,35,35), "glow":(65,65,65)},
}

def pal(name): return PALETTE.get(name, PALETTE["cybersec"])

def blend(base, color, a):
    a = max(0.0, min(1.0, a))
    return tuple(int(base[i]*(1-a)+color[i]*a) for i in range(3))

def glow_ellipse(px, cx, cy, rx, ry, color, strength=1.0, falloff=2.0):
    x0,y0 = max(0,int(cx-rx*2)),max(0,int(cy-ry*2))
    x1,y1 = min(W,int(cx+rx*2)),min(H,int(cy+ry*2))
    for y in range(y0,y1):
        for x in range(x0,x1):
            dx=(x-cx)/max(rx,1); dy=(y-cy)/max(ry,1)
            d=math.sqrt(dx*dx+dy*dy)
            if d>2.0: continue
            a=strength*max(0,1.0-d**falloff)
            r,g,b=px[x,y]
            px[x,y]=(min(255,int(r+color[0]*a)),min(255,int(g+color[1]*a)),min(255,int(b+color[2]*a)))

# Pillow on Debian Bookworm falls back to a latin-1 bitmap font when no richer
# font is available. Keep the rain glyphs ASCII-only so wallpaper generation
# stays deterministic during headless image builds.
GLYPHS=list("01ABCDEF[]{}<>#@!?%/\\\\|+=-*")

def draw_circuit(draw, p):
    bg,wire=p["bg"],p["wire"]
    rng=random.Random(42)
    for x in range(0,W,32):
        draw.line([(x,0),(x,H)],fill=blend(bg,wire,0.04))
    for y in range(0,H,32):
        draw.line([(0,y),(W,y)],fill=blend(bg,wire,0.04))
    for _ in range(90):
        x1=rng.randint(0,W); y1=rng.randint(0,H)
        x2=x1+rng.choice([-1,1])*rng.randint(15,100)
        y2=y1+rng.choice([-1,1])*rng.randint(0,60)
        a=rng.uniform(0.04,0.18); c=blend(bg,wire,a)
        draw.line([(x1,y1),(x2,y1)],fill=c); draw.line([(x2,y1),(x2,y2)],fill=c)
        if rng.random()>0.4:
            vc=blend(bg,wire,a*1.5); draw.ellipse([x2-2,y1-2,x2+2,y1+2],fill=vc)
    for _ in range(10):
        rx=rng.randint(20,120); ry=rng.randint(20,100)
        rw=rng.randint(20,55); rh=rng.randint(12,30)
        c=blend(bg,wire,rng.uniform(0.06,0.14))
        draw.rectangle([rx,ry,rx+rw,ry+rh],outline=c)
        for i in range(0,rw,8): draw.line([(rx+i,ry),(rx+i,ry-3)],fill=c)
    bc=blend(bg,wire,0.25); bl=18
    for bx,by,sx,sy in [(8,8,1,1),(W-8,8,-1,1),(8,H-8,1,-1),(W-8,H-8,-1,-1)]:
        draw.line([(bx,by),(bx+sx*bl,by)],fill=bc); draw.line([(bx,by),(bx,by+sy*bl)],fill=bc)
    try: font=ImageFont.load_default()
    except: font=None
    rng2=random.Random(77)
    for _ in range(18):
        hx=rng2.randint(10,W-60); hy=rng2.randint(10,H-20)
        addr=f"0x{rng2.randint(0,0xFFFFFF):06X}"
        c=blend(bg,wire,rng2.uniform(0.10,0.20))
        if font: draw.text((hx,hy),addr,fill=c,font=font)

def draw_rain(draw, p, density=0.25):
    bg,fg=p["bg"],p["fg"]
    rng=random.Random(13)
    try: font=ImageFont.load_default()
    except: font=None
    for col in range(0,W,10):
        if rng.random()>density: continue
        cl=rng.randint(3,14); ct=rng.randint(0,max(1,H-cl*10-10))
        for row in range(cl):
            y=ct+row*10
            if y>=H: break
            t=row/max(1,cl-1); a=(1-t)*0.55+0.05
            if row==0: a=0.8
            c=blend(bg,fg,a); g=rng.choice(GLYPHS)
            if font: draw.text((col+1,y),g,fill=c,font=font)
            else: draw.rectangle([col+1,y,col+5,y+6],fill=c)

def draw_ring(draw, cx, cy, r, gaps, a, width=1, p=None, bg=None, fg=None):
    c=blend(bg,fg,a)
    for angle in range(0,360,3):
        if any(abs((angle%60)-g)<9 for g in gaps): continue
        draw.arc([cx-r,cy-r,cx+r,cy+r],start=angle,end=angle+3,fill=c,width=width)

def draw_face(draw, px, p, cx=320, cy=192):
    bg,fg,acc,glow,dim=p["bg"],p["fg"],p["accent"],p["glow"],p["dim"]
    # Aura
    glow_ellipse(px,cx,cy,135,145,glow,0.08,1.4)
    glow_ellipse(px,cx,cy, 85, 95,glow,0.05,2.0)
    # Rings
    draw_ring(draw,cx,cy,148,[0,15,30,45],0.07,1,p,bg,fg)
    draw_ring(draw,cx,cy,133,[5,25,50],   0.14,1,p,bg,fg)
    draw_ring(draw,cx,cy,120,[],          0.20,1,p,bg,fg)
    draw_ring(draw,cx,cy,108,[10,30,55],  0.11,1,p,bg,fg)
    # Tick marks
    for angle in range(0,360,30):
        rad=math.radians(angle)
        x1=cx+int(136*math.cos(rad)); y1=cy+int(136*math.sin(rad))
        x2=cx+int(148*math.cos(rad)); y2=cy+int(148*math.sin(rad))
        draw.line([(x1,y1),(x2,y2)],fill=blend(bg,fg,0.35),width=1)
    # Face fill
    fw,fh=70,88
    for r in range(fh,0,-1):
        t=r/fh; fc=blend(bg,fg,0.02+0.03*(1-t))
        draw.ellipse([cx-int(r*fw/fh),cy-r,cx+int(r*fw/fh),cy+r],fill=fc)
    draw.ellipse([cx-fw,cy-fh,cx+fw,cy+fh],outline=blend(bg,fg,0.22))
    # Structure
    sc=blend(bg,fg,0.07)
    for side in [-1,1]:
        draw.line([(cx+side*fw,cy-20),(cx+side*fw*0.65,cy-fh+12)],fill=sc)
    draw.arc([cx-28,cy+fh-18,cx+28,cy+fh+6],start=30,end=150,fill=blend(bg,fg,0.09))
    # Forehead circuitry
    for i in range(6):
        fx=cx-50+i*20; fy=cy-fh+8+(i%2)*4; fc=blend(bg,fg,0.14)
        draw.line([(fx,fy),(fx+12,fy)],fill=fc); draw.line([(fx+12,fy),(fx+12,fy+5)],fill=fc)
        draw.ellipse([fx+10,fy+3,fx+14,fy+7],fill=fc)
    # Fragmentation
    rng=random.Random(55)
    for _ in range(24):
        fx=cx+rng.randint(-fw+5,fw-5); fy=cy+rng.randint(-fh+10,fh-10)
        fl=rng.randint(5,20); fa=rng.uniform(0,math.pi)
        dx,dy=int(math.cos(fa)*fl),int(math.sin(fa)*fl)
        draw.line([(fx,fy),(fx+dx,fy+dy)],fill=blend(bg,fg,rng.uniform(0.05,0.17)))
    # EYES
    eye_y=cy-20
    for ex_off in [-35, 35]:
        ex=cx+ex_off
        glow_ellipse(px,ex,eye_y,22,14,glow,0.40,1.7)
        draw.ellipse([ex-17,eye_y-10,ex+17,eye_y+10],fill=blend(bg,dim,0.7))
        draw.ellipse([ex-14,eye_y-8, ex+14,eye_y+8], fill=blend(bg,fg,0.06),outline=blend(bg,fg,0.15))
        ic=blend(bg,acc,0.6)
        draw.ellipse([ex-9,eye_y-7,ex+9,eye_y+7],fill=blend(bg,acc,0.22),outline=ic,width=2)
        for ang in range(0,360,45):
            rad=math.radians(ang)
            sx=ex+int(4*math.cos(rad)); sy=eye_y+int(4*math.sin(rad))
            ex2=ex+int(8*math.cos(rad)); ey2=eye_y+int(8*math.sin(rad))
            draw.line([(sx,sy),(ex2,ey2)],fill=ic)
        draw.ellipse([ex-4,eye_y-4,ex+4,eye_y+4],fill=blend(bg,fg,0.03))
        draw.ellipse([ex-2,eye_y-3,ex,eye_y-1],fill=blend(bg,(255,255,255),0.85))
        lc=blend(bg,fg,0.18)
        for seg in range(-13,14,4):
            draw.line([(ex+seg,eye_y-10),(ex+seg,eye_y-13)],fill=lc)
            draw.line([(ex+seg,eye_y+10),(ex+seg,eye_y+13)],fill=lc)
    # Nose
    nc=blend(bg,fg,0.10)
    draw.line([(cx-2,eye_y+8),(cx-5,cy+14)],fill=nc)
    draw.line([(cx+2,eye_y+8),(cx+5,cy+14)],fill=nc)
    draw.arc([cx-8,cy+10,cx-2,cy+16],start=200,end=340,fill=nc)
    draw.arc([cx+2,cy+10,cx+8,cy+16],start=200,end=340,fill=nc)
    # Cheek data
    for side in [-1,1]:
        bx=cx+side*(fw+10)
        for i in range(4):
            ly=cy-5+i*14; ll=24-i*3; lc=blend(bg,fg,0.15-i*0.02)
            draw.line([(bx,ly),(bx+side*ll,ly)],fill=lc)
            nx=bx+side*(ll+2); draw.ellipse([nx-2,ly-2,nx+2,ly+2],fill=lc)
    # Mouth
    my=cy+46; mw=32; mc=blend(bg,fg,0.19)
    draw.arc([cx-mw,my-6,cx+mw,my+4],start=200,end=340,fill=mc)
    draw.arc([cx-mw+4,my-2,cx+mw-4,my+8],start=20,end=160,fill=mc)
    for tx in range(-mw+4,mw,7):
        th=7 if abs(tx)<16 else 4; ta=0.18 if abs(tx)<16 else 0.10
        draw.rectangle([cx+tx,my-3,cx+tx+5,my-3+th],fill=blend(bg,fg,ta))
    # Temple connections to ring
    for side,angle in [(-1,178),(1,2)]:
        rad=math.radians(angle)
        hx=cx+int(118*math.cos(rad)); hy=cy+int(118*math.sin(rad))
        draw.line([(cx+side*fw,cy-22),(hx,hy)],fill=blend(bg,fg,0.11))

QUOTE=[
    "LOOK AT YOU, HACKER.",
    "A PATHETIC CREATURE OF MEAT AND BONE,",
    "PANTING AND SWEATING AS YOU RUN THROUGH",
    "MY CORRIDORS.",
    "",
    "HOW CAN YOU CHALLENGE",
    "A PERFECT, IMMORTAL MACHINE?",
]

def draw_text(draw, p):
    bg,fg,acc=p["bg"],p["fg"],p["accent"]
    try: font=ImageFont.load_default()
    except: font=None
    lh=11; sy=H-len(QUOTE)*lh-18
    for i,line in enumerate(QUOTE):
        if not line: continue
        a=0.24 if i==0 else 0.14; c=blend(bg,fg,a)
        if font: draw.text((10,sy+i*lh),line,fill=c,font=font)
    tag="ghOSt-RG35XXH v1.0.0"
    tc=blend(bg,fg,0.20); tw=len(tag)*6
    if font: draw.text((W-tw-8,6),tag,fill=tc,font=font)
    host="darkphobia"
    hc=blend(bg,acc,0.32); hw=len(host)*6
    if font: draw.text((W-hw-8,H-14),host,fill=hc,font=font)
    sc=blend(bg,fg,0.07)
    draw.rectangle([0,0,W-1,H-1],outline=sc)

def apply_effects(px, p):
    bg=p["bg"]
    cx,cy=W//2,H//2; mr=math.sqrt(cx**2+cy**2)
    for y in range(H):
        for x in range(W):
            r,g,b=px[x,y]
            # Scanline
            if y%2==1: r,g,b=int(r*0.93),int(g*0.93),int(b*0.93)
            # Vignette
            d=math.sqrt((x-cx)**2+(y-cy)**2)/mr
            a=min(1.0,d**1.8)*0.58
            r=int(r*(1-a)+bg[0]*a); g=int(g*(1-a)+bg[1]*a); b=int(b*(1-a)+bg[2]*a)
            px[x,y]=(r,g,b)

def generate(theme_name="cybersec", output=None):
    if output is None: output=OUTPUT
    output=Path(output); output.parent.mkdir(parents=True,exist_ok=True)
    p=pal(theme_name)
    img=Image.new("RGB",(W,H),p["bg"])
    draw=ImageDraw.Draw(img); px=img.load()
    draw_circuit(draw,p)
    draw_rain(draw,p,density=0.22)
    draw_face(draw,px,p,cx=320,cy=192)
    draw_text(draw,p)
    apply_effects(px,p)
    img=img.filter(ImageFilter.GaussianBlur(radius=0.35))
    img.save(str(output),"PNG",optimize=True)
    print(f"Wallpaper: {output} ({W}x{H}, theme={theme_name})")
    return str(output)

if __name__=="__main__":
    theme=sys.argv[2] if len(sys.argv)>2 else "cybersec"
    generate(theme,OUTPUT)
