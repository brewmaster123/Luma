#!/usr/bin/env python3
"""Create an original code-drawn design illustration; not a native app screenshot."""
from pathlib import Path
from html import escape

ROOT = Path(__file__).resolve().parents[1]
parts = ['''<svg xmlns="http://www.w3.org/2000/svg" width="1400" height="1060" viewBox="0 0 1400 1060">
<defs><linearGradient id="moon" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#efe5ff"/><stop offset=".55" stop-color="#c6b6f4"/><stop offset="1" stop-color="#625079"/></linearGradient><radialGradient id="halo"><stop stop-color="#c6b6f4" stop-opacity=".09"/><stop offset="1" stop-color="#c6b6f4" stop-opacity="0"/></radialGradient></defs>''']
BG = '#0c1120'; CARD = '#171e30'; TEXT = '#f2eff8'; MUTED = '#b2b8c9'; ACCENT = '#c6b6f4'
def rect(x,y,w,h,r=0,fill=CARD,stroke=None):
    parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}"'+(f' stroke="{stroke}"' if stroke else '')+'/>')
def circle(x,y,r,fill,stroke=None):
    parts.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{fill}"'+(f' stroke="{stroke}"' if stroke else '')+'/>')
def text(x,y,s,size=14,color=TEXT,anchor='start',serif=False,weight=400,spacing=0):
    font='DejaVu Serif' if serif else 'DejaVu Sans'
    parts.append(f'<text x="{x}" y="{y}" fill="{color}" font-family="{font}" font-size="{size}" font-weight="{weight}" text-anchor="{anchor}" letter-spacing="{spacing}">{escape(s)}</text>')
def line(x1,y1,x2,y2,color='#30394e'):
    parts.append(f'<path d="M{x1} {y1}L{x2} {y2}" fill="none" stroke="{color}" stroke-width="1.2"/>')
def moon(x,y,r,bg=BG):
    circle(x,y,r,'url(#moon)'); circle(x+r*.55,y-r*.28,r,bg)
def watchicon(x,y,color=ACCENT):
    rect(x-6,y-8,12,16,4,'none',color);line(x-3,y-12,x+3,y-12,color);line(x-3,y+12,x+3,y+12,color)
def check(x,y):
    circle(x,y,6,'none','#aad8c5');parts.append(f'<path d="M{x-3} {y}l2 2 4-4" stroke="#aad8c5" stroke-width="1.2" fill="none"/>')
def wave(x,y):
    for i,h in enumerate([5,11,17,11,6]): line(x+i*4,y-h/2,x+i*4,y+h/2,ACCENT)

rect(0,0,1400,1060,fill='#080d18')
text(70,66,'LUMA',18,spacing=5,weight=600);text(196,66,'IPHONE + APPLE WATCH',11,MUTED,spacing=2)
text(1330,65,'ДИЗАЙН / 01',11,MUTED,anchor='end',spacing=2)
text(70,248,'ПОДСКАЗКА НА ЗАПЯСТЬЕ',11,MUTED,spacing=2)
text(67,324,'Тихий сигнал.',49,serif=True)
text(67,391,'Ближе',49,serif=True)
text(67,458,'к сновидению.',49,serif=True)
text(70,519,'Ваше время. Ваш ритм.',17,MUTED)
text(70,549,'Ничего не нужно выключать.',17,MUTED)
rect(70,594,296,39,20,'none','#30394e');text(218,619,'1 / 2 / 3 / 5 коротких сигналов',12,ACCENT,anchor='middle')
line(70,710,410,710)
text(70,746,'Ночь · Дневник · Настройки',14,MUTED)
text(70,776,'Минимум действий перед сном.',13,MUTED)

# iPhone design — deliberately drawn, no simulated medical measurements.
rect(553,105,404,864,52,'#141823')
rect(560,110,390,850,48,BG,'#454854');rect(570,120,370,830,39,BG)
text(600,148,'21:41',12,weight=600);rect(702,126,106,25,15,'#02040a')
for i,h in enumerate([4,6,8,10]):rect(873+i*4,148-h,2,h,1,TEXT)
rect(897,138,20,10,3,'none',TEXT);rect(900,141,14,4,1,TEXT)
text(755,179,'МАКЕТ · БЕЗ СВЯЗИ С УСТРОЙСТВАМИ',9,MUTED,anchor='middle',spacing=1)
text(594,219,'LUMA',17,weight=600,spacing=4);text(594,240,'Осознанные сновидения',10,MUTED)
circle(894,224,21,CARD);watchicon(894,224)
circle(755,303,70,'url(#halo)');circle(755,303,51,'none','#28253a');circle(755,303,36,'none','#393148')
moon(755,303,23);text(710,279,'✧',15,ACCENT,anchor='middle');circle(800,326,2,ACCENT)
text(755,383,'Тихий сигнал.',26,anchor='middle',serif=True)
text(755,416,'Ближе к сновидению.',26,anchor='middle',serif=True)
text(755,443,'Ничего не нужно выключать.',12,MUTED,anchor='middle')
rect(592,464,326,151,23,CARD,'#252d41');text(611,491,'ВРЕМЯ СИГНАЛА',10,MUTED,spacing=1.4)
text(898,491,'Изменить',10,ACCENT,anchor='end');text(610,538,'05:30',40)
text(611,560,'Следующая сессия · пример',11,MUTED);line(611,577,898,577)
circle(618,596,6,'none',MUTED);line(618,592,618,596,MUTED);line(618,596,621,598,MUTED)
text(634,600,'По выбранному времени',11,MUTED)
rect(592,630,326,171,23,CARD,'#252d41');text(611,657,'КОРОТКИХ СИГНАЛОВ',10,MUTED,spacing=1.3);wave(880,653)
for index,count in enumerate([1,2,3,5]):
    x=611+index*73
    rect(x,675,64,48,14,ACCENT if count==2 else '#111728')
    text(x+32,706,str(count),19,BG if count==2 else TEXT,anchor='middle')
check(617,747);text(633,751,'Каждый сигнал заканчивается сам.',10,MUTED)
text(633,770,'Рисунок вибрации задают часы.',10,MUTED)
rect(592,817,326,52,27,ACCENT);text(755,849,'Подготовить на часах  →',13,BG,anchor='middle',weight=600)
text(755,891,'Как это работает',11,MUTED,anchor='middle');line(578,906,932,906)
moon(635,922,8);text(635,945,'Ночь',9,ACCENT,anchor='middle')
parts.append('<path d="M746 916h8l1 2 1-2h8v14h-8l-1 2-1-2h-8Z" fill="none" stroke="#b2b8c9" stroke-width="1.2"/>')
text(755,945,'Дневник',9,MUTED,anchor='middle')
for y,cx in [(917,876),(922,868),(927,879)]:line(865,y,885,y,MUTED);circle(cx,y,2,BG,MUTED)
text(875,945,'Настройки',9,MUTED,anchor='middle');rect(704,951,102,3,2,TEXT)

# Companion watch illustration.
text(1190,299,'APPLE WATCH',11,MUTED,anchor='middle',spacing=2)
rect(1129,350,122,365,22,'#1a202c');rect(1080,395,220,275,58,'#303540','#4d5260')
rect(1087,402,206,261,51,'#070c16');rect(1300,475,9,33,4,'#3f4651')
text(1109,431,'Luma',10,MUTED);text(1270,431,'21:41',10,MUTED,anchor='end')
moon(1190,473,17,'#070c16');text(1190,526,'05:30',32,anchor='middle')
text(1190,552,'2 коротких сигнала',10,MUTED,anchor='middle');text(1190,569,'Сами затихнут',10,MUTED,anchor='middle')
circle(1185,589,2.5,ACCENT);circle(1195,589,2.5,ACCENT)
rect(1124,609,132,30,16,'#161e2f');text(1190,629,'Проба сигнала',11,ACCENT,anchor='middle')
text(1190,770,'Короткая серия.',15,anchor='middle',serif=True)
text(1190,796,'Автоматическое окончание.',12,MUTED,anchor='middle')
line(70,1005,1330,1005)
text(70,1034,'Иллюстрация дизайна · не скриншот нативной сборки',11,MUTED)
text(1330,1034,'Интерактивные экраны — Interface-preview.html',11,MUTED,anchor='end')
parts.append('</svg>')
(ROOT/'Design/Luma-design.svg').write_text('\n'.join(parts))
print('Created Design/Luma-design.svg')
