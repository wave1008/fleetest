# 「run 全体のロック」のページの図(images/run_lock/{ja,en}/*.png)を作り直す。文言は T の ja/en を対で直す。
# 実行: python3 docs/user-docs/images/run_lock/gen_diagrams.py(Google Chrome のヘッドレスで 2 倍の PNG を書く)
# 部品と配色は images/fleet/gen_diagrams.py と揃える(あちらは import すると描画まで走るので写している)
# 図の中の文字は数字と日本語の間に空白を入れない(1本・3台)
import subprocess, os, tempfile
from html import escape
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT=os.path.dirname(os.path.abspath(__file__))
FONT="'Hiragino Sans','Hiragino Kaku Gothic ProN','Helvetica Neue',Arial,sans-serif"
C=dict(ink="#1f2937",sub="#6b7280",line="#9ca3af",ft="#0e7490",ftBg="#e0f2fe",dev="#15803d",devBg="#dcfce7",
       file="#374151",fileBg="#f3f4f6",sb="#b45309",sbBg="#fffbeb",no="#b91c1c",noBg="#fee2e2")
def svg(w,h,body):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{FONT}">
<defs><marker id="ah" markerWidth="10" markerHeight="10" refX="9" refY="5" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{C['line']}"/></marker><marker id="ahk" markerWidth="10" markerHeight="10" refX="9" refY="5" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{C['ink']}"/></marker><marker id="ahg" markerWidth="10" markerHeight="10" refX="9" refY="5" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{C['dev']}"/></marker><marker id="ahf" markerWidth="10" markerHeight="10" refX="9" refY="5" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{C['ft']}"/></marker></defs>
<rect width="{w}" height="{h}" fill="#ffffff" rx="16"/>{body}</svg>'''
def lane(x,y,w,h,label,color,stroke="#e5e7eb",fill="none"):
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="{fill}" stroke="{stroke}" stroke-width="2" stroke-dasharray="6 6"/>'
            f'<text x="{x+18}" y="{y+32}" font-size="17" font-weight="700" fill="{color}">{escape(label)}</text>')
def code(x,y,lines,ts=14,color=None):
    return "".join(f'<text x="{x}" y="{y+i*(ts+7)}" font-size="{ts}" font-family="Menlo,monospace" xml:space="preserve" fill="{color or C["ink"]}">{escape(l)}</text>'
                   for i,l in enumerate(lines))
def text(x,y,lines,ts=14,color=None,weight=400,anchor="start",lh=None):
    lh=lh or ts+8
    return "".join(f'<text x="{x}" y="{y+i*lh}" text-anchor="{anchor}" font-size="{ts}" font-weight="{weight}" fill="{color or C["ink"]}">{escape(l)}</text>'
                   for i,l in enumerate(lines))
T={
 "ja":dict(
   head='withRunLock("resource1") が複数のデバイスで実行された場合',
   rows=["デバイス1","デバイス2","デバイス3"],
   localLane="run を開始したマシン", remoteLane="リモートマシン",
   server="ロックのサーバー",
   mReq="ロックを要求", mReqSsh="ロックを要求(ssh 越し)", mGrant="渡す", mRel="返す",
   p1held=["ロックを持つ"], p2wait=["待つ"], p2held=["ロックを持つ"],
   pxwait=["待つ"], pxheld=["ロックを持つ"],
 ),
 "en":dict(
   head='When withRunLock("resource1") runs on several devices',
   rows=["Device 1","Device 2","Device 3"],
   localLane="Machine that started the run", remoteLane="Remote machine",
   server="Lock server",
   mReq="Requests the lock", mReqSsh="Requests the lock (over ssh)", mGrant="Grants", mRel="Returns",
   p1held=["Holds the lock"], p2wait=["Waits"], p2held=["Holds the lock"],
   pxwait=["Waits"], pxheld=["Holds the lock"],
 ),
}

def sequence(t):
    W=1200
    D=40  # 枠の見出しとアクターの箱が重ならないよう、時間の軸を下げる
    b=text(40,44,[t["head"]],ts=18,weight=700,color=C["ft"])
    X={"p1":190,"p2":420,"srv":650,"px":1030}
    TOP=150+D; END=830+D
    H=END+24+20  # 枠の下端(END+24)の下に、左右と同じ 20 の余白
    # 手元の枠はサーバーの箱(右端 X["srv"]+100)から 40 で閉じ、リモートの枠(910 から)との間を空けてマシンの隔たりを見せる
    b+=lane(20,64,X["srv"]+140-20,END-64+24,t["localLane"],C["ink"],stroke=C["line"])
    b+=lane(910,64,270,END-64+24,t["remoteLane"],C["ft"],stroke=C["ft"],fill="#f8fdff")
    for k,(name,fill,stroke) in {"p1":(t["rows"][0],C["devBg"],C["dev"]),"p2":(t["rows"][1],C["devBg"],C["dev"]),
                                 "srv":(t["server"],C["ftBg"],C["ft"]),"px":(t["rows"][2],C["devBg"],C["dev"])}.items():
        x=X[k]
        b+=f'<line x1="{x}" y1="{TOP}" x2="{x}" y2="{END}" stroke="{C["line"]}" stroke-width="2" stroke-dasharray="4 5"/>'
        b+=f'<rect x="{x-100}" y="{TOP-52}" width="200" height="52" rx="10" fill="{fill}" stroke="{stroke}" stroke-width="2"/>'
        b+=text(x,TOP-21,[name],ts=15,weight=700,color=stroke,anchor="middle")
    def act(k,y1,y2,kind):
        fill,stroke,dash={"held":(C["devBg"],C["dev"],""),"wait":(C["sbBg"],C["sb"],' stroke-dasharray="5 4"')}[kind]
        return f'<rect x="{X[k]-9}" y="{y1+D}" width="18" height="{y2-y1}" rx="4" fill="{fill}" stroke="{stroke}" stroke-width="2"{dash}/>'
    b+=act("p1",236,500,"held"); b+=act("p2",290,540,"wait"); b+=act("p2",540,660,"held")
    b+=act("px",380,700,"wait"); b+=act("px",700,800,"held")
    b+=text(X["p1"]+16,370+D,t["p1held"],ts=13,weight=700,color=C["dev"])
    b+=text(X["p2"]+16,400+D,t["p2wait"],ts=13,weight=700,color=C["sb"],lh=19)
    b+=text(X["p2"]+16,605+D,t["p2held"],ts=13,weight=700,color=C["dev"])
    b+=text(X["px"]+16,500+D,t["pxwait"],ts=13,weight=700,color=C["sb"],lh=19)
    b+=text(X["px"]+16,745+D,t["pxheld"],ts=13,weight=700,color=C["dev"],lh=19)
    def msg(a,c,y,label,kind,lx=None):
        y+=D
        x1,x2=X[a],X[c]
        x1+=10 if x2>x1 else -10
        x2+=-10 if x2>x1 else 10
        color,dash,mk={"req":(C["ink"],"","ahk"),"rel":(C["ink"],"","ahk"),"grant":(C["dev"],' stroke-dasharray="7 5"',"ahg")}[kind]
        weight=700 if kind=="req" else 400
        lc=C["no"] if kind=="req" else color
        # ラベルは途中の縦線に掛からない区間の中央に置く(デバイス1 ↔ サーバーはデバイス2 の線より右)
        lo,hi=sorted((X[a],X[c]))
        if lo==X["p1"] and hi==X["srv"]: lo=X["p2"]
        return (f'<line x1="{x1}" y1="{y}" x2="{x2}" y2="{y}" stroke="{color}" stroke-width="2.5"{dash} marker-end="url(#{mk})"/>'
                f'<text x="{lx if lx is not None else (lo+hi)/2}" y="{y-8}" text-anchor="middle" font-size="13" font-weight="{weight}" fill="{lc}">{escape(label)}</text>')
    # 要求の矢印の根元の上(「ロックを要求」の行より上)に呼び出しを置く。縦線を中心にして隣の縦線へ届かせない
    CALL='withRunLock("resource1")'
    def call(k,y,lines,up=30,dx=0):
        # dx: 縦線から中心をずらす量(右の「ロックを要求」に場所を空ける)
        y+=D; x=X[k]+dx; n=len(lines)
        # 白い下地で縦線を隠す(Menlo 14px は1文字およそ 8.5px)
        return "".join(f'<rect x="{x-len(l)*4.25-4}" y="{y-up-(n-1-i)*19-14}" width="{len(l)*8.5+8}" height="18" fill="#ffffff"/><text x="{x}" y="{y-up-(n-1-i)*19}" text-anchor="middle" font-size="14" font-weight="700" font-family="Menlo,monospace" fill="{C["ink"]}">{escape(l)}</text>'
                       for i,l in enumerate(lines))
    b+=call("p1",200,[CALL],up=8)
    b+=call("p2",290,[CALL],up=8,dx=-92)  # 下地がデバイス1 の帯(右端 X["p1"]+9)に掛からない位置
    b+=call("px",380,[CALL],up=8,dx=40)  # 右端が枠(右端 1180)の内側に収まる量
    b+=msg("p1","srv",200,t["mReq"],"req")
    b+=msg("srv","p1",236,t["mGrant"],"grant")
    b+=msg("p2","srv",290,t["mReq"],"req",lx=(X["p2"]-92+len(CALL)*4.25+X["srv"])/2)
    b+=msg("px","srv",380,t["mReqSsh"],"req",lx=(X["srv"]+X["px"]+40-len(CALL)*4.25)/2)
    b+=msg("p1","srv",500,t["mRel"],"rel")
    b+=msg("srv","p2",540,t["mGrant"],"grant")
    b+=msg("p2","srv",660,t["mRel"],"rel")
    b+=msg("srv","px",700,t["mGrant"],"grant")
    b+=msg("px","srv",800,t["mRel"],"rel")
    return svg(W,H,b)

def render(name,lang,svgtext,w,h):
    os.makedirs(f"{OUT}/{lang}",exist_ok=True)
    html=f"<html><body style='margin:0;background:#fff'>{svgtext}</body></html>"
    p=os.path.join(tempfile.gettempdir(),f"ft_diagram_{name}_{lang}.html"); open(p,"w").write(html)
    out=f"{OUT}/{lang}/{name}.png"
    subprocess.run([CHROME,"--headless=new","--disable-gpu","--hide-scrollbars","--force-device-scale-factor=2",f"--window-size={w},{h}",f"--screenshot={out}",f"file://{p}"],check=True,capture_output=True)
    print(out)
for lang,t in T.items():
    render("run_lock_sequence",lang,sequence(t),1200,914)  # 高さは sequence の H と同じ
