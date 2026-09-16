from PIL import Image,ImageDraw
from pathlib import Path
import json
root=Path(__file__).resolve().parents[1]/'miniEXView/Assets.xcassets'
im=Image.new('RGB',(1024,1024),'#101923'); d=ImageDraw.Draw(im)
d.rounded_rectangle((90,95,934,925),radius=110,fill='#20262c')
d.rounded_rectangle((180,180,844,558),radius=44,fill='#0a1016')
d.rounded_rectangle((245,265,750,310),radius=8,fill='#d62c3b')
d.rounded_rectangle((245,342,640,372),radius=6,fill='#f2c04f')
d.rounded_rectangle((245,408,530,438),radius=6,fill='#1687c7')
d.polygon([(345,747),(390,635),(435,747),(414,747),(414,811),(369,811),(369,747)],fill='#75d9e7')
d.arc((602,622,820,802),200,340,fill='#4fc3f7',width=34)
d.arc((645,698,782,821),204,337,fill='#4fc3f7',width=28)
d.ellipse((697,818,729,850),fill='#4fc3f7')
d.rounded_rectangle((580,837,667,863),radius=5,fill='#ffc857')
app=root/'AppIcon.appiconset'; im.save(app/'Icon-1024.png')
(app/'Contents.json').write_text(json.dumps({'images':[{'filename':'Icon-1024.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}},indent=2))
prev=root/'AppIconPreview.imageset'; im.save(prev/'Icon-1024.png')
(prev/'Contents.json').write_text(json.dumps({'images':[{'filename':'Icon-1024.png','idiom':'universal'}],'info':{'author':'xcode','version':1}},indent=2))
