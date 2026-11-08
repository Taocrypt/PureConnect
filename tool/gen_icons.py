"""Regenerates launcher icons for all platforms from icons/v5/*.svg (run from zju_connect_flutter/)."""
import cairosvg, re, io, os
from PIL import Image, ImageDraw
import numpy as np
SRC='../icons/v5'
variants=['a1','a2','b1','b2']
res='android/app/src/main/res'
dens={'mdpi':48,'hdpi':72,'xhdpi':96,'xxhdpi':144,'xxxhdpi':192}
H=2048
ICO=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)]
os.makedirs('assets/icon',exist_ok=True)
for v in variants:
    s=open(f'{SRC}/{v}.svg').read()
    m=re.search(r'<rect width="512" height="512" rx="120" fill="([^"]+)"/>',s)
    bgc=m.group(1); glyph_svg=s.replace(m.group(0),'')
    g=Image.open(io.BytesIO(cairosvg.svg2png(bytestring=glyph_svg.encode(),output_width=H,output_height=H))).convert('RGBA')
    a=np.array(g); bg=np.array([int(bgc[i:i+2],16) for i in (1,3,5)])
    hole=(np.abs(a[...,:3].astype(int)-bg).sum(-1)<30)&(a[...,3]>0)
    a[hole,3]=0; g=Image.fromarray(a)
    bbox=g.getbbox(); g=g.crop(bbox)
    sc=(H*256/512)/(bbox[3]-bbox[1]); g=g.resize((round(g.width*sc),round(g.height*sc)),Image.LANCZOS)
    def place(canvas,scale=1.0):
        gg=g.resize((round(g.width*scale),round(g.height*scale)),Image.LANCZOS)
        canvas.alpha_composite(gg,((canvas.width-gg.width)//2,(canvas.height-gg.height)//2)); return canvas
    full=Image.new('RGBA',(H,H),(0,0,0,0)); ImageDraw.Draw(full).rounded_rectangle((0,0,H-1,H-1),radius=H*120//512,fill=bgc); place(full)
    fg=place(Image.new('RGBA',(H,H),(0,0,0,0)),72/108)
    mm=np.array(fg); mm[...,:3]=255; mono=Image.fromarray(mm)
    name='ic_launcher' if v=='a1' else f'ic_launcher_{v}'
    for d,px in dens.items():
        full.resize((px,px),Image.LANCZOS).save(f'{res}/mipmap-{d}/{name}.png')
        q=px*108//48
        fg.resize((q,q),Image.LANCZOS).save(f'{res}/mipmap-{d}/{name}_foreground.png')
        mono.resize((q,q),Image.LANCZOS).save(f'{res}/mipmap-{d}/{name}_monochrome.png')
    os.makedirs(f'{res}/mipmap-anydpi-v26',exist_ok=True)
    open(f'{res}/mipmap-anydpi-v26/{name}.xml','w').write(f'''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/{name}_background"/>
    <foreground android:drawable="@mipmap/{name}_foreground"/>
    <monochrome android:drawable="@mipmap/{name}_monochrome"/>
</adaptive-icon>
''')
    open(f'{res}/values/{name}_background.xml','w').write(f'<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="{name}_background">{bgc}</color>\n</resources>\n')
    full.resize((512,512),Image.LANCZOS).save(f"assets/icon/{v}.png")
    full.resize((256,256),Image.LANCZOS).save(f'assets/icon/{v}.ico',sizes=ICO)
    if v=='a1':
        full.resize((1024,1024),Image.LANCZOS).save('assets/icon/pureconnect_1024.png')
        full.resize((256,256),Image.LANCZOS).save('windows/runner/resources/app_icon.ico',sizes=ICO)
        mac=Image.new('RGBA',(H,H),(0,0,0,0)); inner=full.resize((round(H*824/1024),)*2,Image.LANCZOS); mac.alpha_composite(inner,((H-inner.width)//2,)*2)
        for z in [16,32,64,128,256,512,1024]: mac.resize((z,z),Image.LANCZOS).save(f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{z}.png')
