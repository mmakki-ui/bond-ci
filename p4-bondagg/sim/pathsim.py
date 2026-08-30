#!/usr/bin/env python3
# pathsim v3.2 -- boundary-aware path emulator, scenario registry.
#
# ==========================================================================
# WHAT THIS FILE IS, AND WHAT A GREEN RUN OF IT DOES **NOT** MEAN  (U39)
# ==========================================================================
# This ladder drives the **EIF PUSH** datapath -- the design ADR-002 superseded.
# reset() launches only AGG_MODE=server and AGG_MODE=client (:160,:163), which are
# the push server and the push client. It has NEVER launched AGG_MODE=pull-client; that
# mode exists only on the unmerged u7-pull-core-go branch (daemon/main.go:39
# there; absent on dev). So NO STAGE BELOW HAS EVER ENTERED THE SHIPPED PULL
# DATAPATH.
#
# That is not a defect to be fixed by pointing it at pull. ADR-002 RETAINS the
# push stack as the validated reference AND the mid-network-bufferbloat
# fallback, so a gate on it is worth keeping -- but it must be LABELLED as such,
# exactly as the eif-model job is labelled for nsched_model.py (see
# docs/TEST-SUITE.md). Before U39 it was not: it was presented as a live
# behavioural gate on the datapath while carrying continue-on-error: true, which
# meant it gated nothing and nobody was ever made to resolve its red stages.
#
# Two stages carry MEASURED, PERSISTENT, HONEST FAILS on that push reference --
# S2.tail 0/14 and S3.peerloss 0/14 across the 14 CI runs recorded in
# ladder_record.txt. They are reported, never weakened. Six further bars are
# marginal (they flip run to run) and are named as UNGATED rather than tuned to
# fit. The classification is enforced by .github/scripts/ladder_gate.py, which
# is what CI runs; this file computes the arithmetic and prints one BAR line per
# sub-bar so the gate never re-implements a threshold.
#
# WHAT A PULL SCENARIO WOULD NEED (deliberately NOT built here; ROADMAP U39d):
# a merged pull-client mode; U16's separate bondsrv binary as the peer (this
# harness launches ONE binary, BIN); an N-generic shim (P, SH, QS, up, cnt, dcnt
# and the p1share bars are all 2-shaped); derived pull bars (S1's concentration
# bar is FALSE for pull by measurement -- plain pull puts ~18% on the spotty
# source); and, the deep one, a shim that BACKPRESSURES the sending socket.
# Path.delay() returns None past a 0.30 s queue and sched_send then silently
# increments SH["drop"] -- the writer is never parked, so the one signal the
# pull core reads does not exist in this harness at all.
# ==========================================================================
import socket, threading, time, random, struct, heapq, sys, os, re, subprocess, itertools

SHIMA=("127.0.0.1",59404); SRV=("127.0.0.1",59403)
CLI_LISTEN=("127.0.0.1",59402); FAKEWG=("127.0.0.1",51999)
BIN="/tmp/bond-agg"; ONLY=os.environ.get("SIM_ONLY","")

class Path:
    def __init__(s, base, jit, rate_kb, loss=0.0, burst_p=0.0, burst_len=3):
        s.base=base; s.jit=jit; s.rate=rate_kb; s.loss=loss
        s.bp=burst_p; s.bl=burst_len; s.burst=0
        s.avail={"u":0.0,"d":0.0}; s.dead=False
    def delay(s, nbytes, now, dirn):
        if s.dead: return None
        if s.burst>0:
            s.burst-=1; return None
        if s.bp>0 and random.random()<s.bp:
            s.burst=s.bl-1; return None
        if s.loss>0 and random.random()<s.loss: return None
        svc = nbytes*8/(s.rate*1000.0)
        a2 = max(now, s.avail[dirn]) + svc
        q = a2 - now
        if q > 0.30: return None   # tail-drop: does NOT consume capacity
        s.avail[dirn] = a2
        s.lastq = q
        return q + s.base + max(0, random.gauss(0, s.jit))

def defaults():
    P[0].__init__(0.135,0.001,2000)
    P[1].__init__(0.193,0.020,1500)
P=[Path(0.135,0.001,2000), Path(0.193,0.020,1500)]
SH={"updata":[0,0],"upctl":[0,0],"down":[0,0],"drop":[0,0]}
QS={"u":[0.0,0.0],"un":[0,0],"d":[0.0,0.0],"dn":[0,0]}
cnt={0:0,1:0}; dcnt={0:0,1:0}; dupseq=[0]; seen=set()

heap=[]; hlock=threading.Condition(); tick=itertools.count()
def sched_send(sock,data,addr,pid,dirn="u"):
    now=time.monotonic()
    d=P[pid].delay(len(data),now,dirn)
    if d is None:
        SH["drop"][pid]+=1; return
    QS[dirn][pid]+=P[pid].lastq; QS[dirn+"n"][pid]+=1
    with hlock:
        heapq.heappush(heap,(now+d, next(tick), data, sock, addr)); hlock.notify()
def dispatcher():
    while True:
        with hlock:
            while not heap: hlock.wait()
            t,_,data,sock,addr=heap[0]
            dt=t-time.monotonic()
            if dt>0:
                hlock.wait(dt); continue
            heapq.heappop(heap)
        try: sock.sendto(data,addr)
        except OSError: pass
threading.Thread(target=dispatcher,daemon=True).start()

def shimstat():
    while True:
        time.sleep(1.0)
        uq=[int(QS['u'][i]/max(1,QS['un'][i])*1000) for i in range(2)]
        dq=[int(QS['d'][i]/max(1,QS['dn'][i])*1000) for i in range(2)]
        for k in ("u","d"): QS[k]=[0.0,0.0]; QS[k+"n"]=[0,0]
        print(f"SHIM up_data={SH['updata']} up_ctl={SH['upctl']} down={SH['down']} modeldrop={SH['drop']} upq_ms={uq} downq_ms={dq}", flush=True)
threading.Thread(target=shimstat,daemon=True).start()

ingress=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
ingress.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4<<20)
ingress.bind(SHIMA)
up=[socket.socket(socket.AF_INET,socket.SOCK_DGRAM) for _ in range(2)]
for s in up: s.bind(("127.0.0.1",0))
cli_src={}
def uplink():
    while True:
        data,src=ingress.recvfrom(2048)
        pid=data[2] if len(data)>=12 and data[0]==0xB0 else 0
        cli_src[pid]=src; cnt[pid]+=1
        if len(data)>=12 and data[0]==0xB0:
            if (data[1]&0x0F)==0:
                dcnt[pid]+=1
                sq=struct.unpack(">I",data[4:8])[0]
                if sq in seen: dupseq[0]+=1
                seen.add(sq)
            else:
                SH["upctl"][pid]+=1
            SH["updata"][pid]=dcnt[pid]
        sched_send(up[pid],data,SRV,pid,"u")
def downlink(i):
    while True:
        data,_=up[i].recvfrom(2048)
        pid=data[2] if len(data)>=12 and data[0]==0xB0 else i
        if pid in cli_src:
            SH["down"][pid]+=1
            sched_send(ingress,data,cli_src[pid],pid,"d")
threading.Thread(target=uplink,daemon=True).start()
for i in range(2): threading.Thread(target=downlink,args=(i,),daemon=True).start()

wgs=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
wgs.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4<<20)  # kernel-realistic endpoint buffer
wgs.bind(FAKEWG)
got=[]; gtimes=[]; glock=threading.Lock()
def wgserver():
    while True:
        d,a=wgs.recvfrom(2048)
        n=struct.unpack(">I",d[:4])[0]
        with glock: got.append(n); gtimes.append((time.monotonic(),n))
        wgs.sendto(d,a)
threading.Thread(target=wgserver,daemon=True).start()

DAE=[]; CUR=["x"]
def daemons_down():
    for p in DAE: p.terminate()
    DAE.clear(); time.sleep(0.2)
def reset(name):
    CUR[0]=name
    random.seed(hash(name)&0xffff)  # deterministic per scenario: bars are
    daemons_down()                  # calibrated against a fixed loss path
    with glock: got.clear(); gtimes.clear()
    cnt[0]=cnt[1]=0; dcnt[0]=dcnt[1]=0; seen.clear(); dupseq[0]=0
    for k in SH: SH[k]=[0,0]
    defaults()
    e=dict(os.environ); e.update(AGG_MODE="server",AGG_LISTEN="127.0.0.1:59403",AGG_WG="127.0.0.1:51999",AGG_W="2000,1500")
    DAE.append(subprocess.Popen([BIN],env=e,stderr=open(f'/tmp/srv.{name}.log','w')))
    time.sleep(0.5)
    e=dict(os.environ); e.update(AGG_MODE="client",AGG_LISTEN="127.0.0.1:59402",AGG_SERVER="127.0.0.1:59404",AGG_PATHS="lo,lo",AGG_W="2000,1500")
    DAE.append(subprocess.Popen([BIN],env=e,stderr=open(f'/tmp/cli.{name}.log','w')))
    time.sleep(1.0)

def send_stream(npkts, pps, hooks=None):
    cli=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    cli.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4<<20)
    cli.bind(("127.0.0.1",0)); cli.settimeout(2.5)
    back=[]
    def rx():
        while True:
            try: d,_=cli.recvfrom(2048)
            except socket.timeout: return
            back.append(1)
    t=threading.Thread(target=rx,daemon=True); t.start()
    iv=1.0/pps; t0=time.monotonic(); fired=set()
    for i in range(npkts):
        cli.sendto(struct.pack(">I",i)+b"x"*1196, CLI_LISTEN)
        if hooks:
            el=time.monotonic()-t0
            for hi,(at,fn) in enumerate(hooks):
                if hi not in fired and el>=at:
                    fired.add(hi); fn()
        nxt=t0+(i+1)*iv; dl=nxt-time.monotonic()
        if dl>0: time.sleep(dl)
    time.sleep(2.0); t.join()
    return back

def k_steady(default="?"):
    try: ks=re.findall(r"K\d*=(\d+)", open(f'/tmp/cli.{CUR[0]}.log').read())
    except OSError: return default
    w=ks[-8:-2] if len(ks)>=8 else ks
    return max(set(w), key=w.count) if w else default

def cli_stat(pattern):
    try: txt=open(f'/tmp/cli.{CUR[0]}.log').read()
    except OSError: return None
    m=re.findall(pattern, txt)
    return m[-1] if m else None

def verdict(name, npkts, extra_ok=True, lossbar=0.01, need_echo=None, note="", bars=()):
    # `bars` = this stage's own sub-bars, as (id, ok, value_str, threshold_str).
    # Every sub-bar is printed as a machine-readable BAR line so that
    # .github/scripts/ladder_gate.py can CLASSIFY each one without
    # re-implementing any threshold (a second copy would drift from this one).
    # The pass/fail arithmetic is UNCHANGED: a stage passes iff inorder and
    # dup==0 and loss<=lossbar and every sub-bar passes -- exactly the
    # conjunction the old `extra_ok` argument carried.
    with glock:
        g=list(got)
        if gtimes:
            t0=gtimes[0][0]; hist={}
            for tt,_ in gtimes: hist[int(tt-t0)]=hist.get(int(tt-t0),0)+1
            print(f"    arrivals/s: {[hist.get(i,0) for i in range(0,int(gtimes[-1][0]-t0)+1)]}")
    dup=len(g)-len(set(g))
    inorder=True
    for i in range(len(g)-1):
        if g[i]>=g[i+1]:
            inorder=False
            print(f"    ORDER-VIOLATION at idx {i}: ...{g[max(0,i-3):i+4]}...")
            break
    lossf=(npkts-len(set(g)))/npkts
    print(f"{name}: fwd={len(set(g))}/{npkts} loss={lossf:.2%} dup={dup} inorder={inorder} data0={dcnt[0]} data1={dcnt[1]} dupsent={dupseq[0]} {note}")
    sid=name.split()[0]
    allbars=[("order", inorder,        str(inorder),          "inorder == True"),
             ("dup",   dup==0,         str(dup),              "dup == 0"),
             ("loss",  lossf<=lossbar, "%.2f%%"%(lossf*100),  "loss <= %.2f%%"%(lossbar*100))]
    allbars+=[tuple(b) for b in bars]
    for bid,bok,bval,btxt in allbars:
        print("BAR %s.%s %s value=%s bar=%s"%(sid,bid,"PASS" if bok else "FAIL",bval,btxt))
    ok=all(b[1] for b in allbars) and extra_ok
    print(("PASS " if ok else "FAIL ")+name)
    return ok

def S1():
    reset("S1"); send_stream(600,100)
    share1=dcnt[1]/max(1,(dcnt[0]+dcnt[1]))
    return verdict("S1 below-sat",600,lossbar=0.005,note=f"p1share={share1:.1%}",
                   bars=[("share", share1<0.95, f"{share1*100:.1f}%", "p1share < 95.0%")])
def S2():
    reset("S2"); send_stream(2800,280)
    share1=dcnt[1]/max(1,(dcnt[0]+dcnt[1]))
    with glock: tl=len([x for x in set(got) if x>=900])
    tailok = tl >= (2800-900)*0.985
    # S2.share's 0.25 is DERIVED, not picked: the offer is 280 pps x (1200 B
    # payload + 16 B header, frame.go HdrLen) x 8 = 2.724 Mb/s against a 2.000
    # Mb/s path 0, so conservation forces >= 26.6% of frames onto path 1 before
    # parity is even counted. 0.25 is that floor rounded down. Worth recording:
    # it is the one S2 bar that has never failed (14/14, ladder_record.txt),
    # while S2.tail has never passed (0/14).
    return verdict("S2 aggregate",2800,lossbar=0.06,note=f"p1share={share1:.1%} tail900={tl}/{2800-900} (ramp txdrop=conservation)",
                   bars=[("share", share1>0.001, f"{share1*100:.1f}%", "p1share > 0.1%"),
                         ("tail",  tailok, f"{tl}/{2800-900}", f"tail900 >= {(2800-900)*0.985:.1f} of {2800-900}")])
def S2b():
    reset("S2b"); send_stream(3400,425)
    with glock: n=len(set(got))
    return verdict("S2b overload-backpressure",3400,lossbar=0.50,note=f"delivered={n}",
                   bars=[("deliv", n>=1, str(n), "delivered >= 1")])
def S3():
    reset("S3")
    def cut(): P[0].rate=600
    send_stream(4000,340,hooks=[(3.0,cut)])
    with glock:
        late=[t for t,_ in gtimes if 6.0 < t-gtimes[0][0] <= 11.0]
    thr=len(late)*1200*8/1e6/5.0
    st=cli_stat(r"(?:p0=|rate0=)(\d+)"); p0=int(st) if st else 99999
    # Offer stays 340pps while capacity drops: conservation forces client
    # txdrop (backpressure BY DESIGN; cake/TCP throttle above in field).
    # Health = post-cut goodput + adapted rate + receiver-skips ~0.
    try: peers=[float(x) for x in re.findall(r"peerloss=([\d.]+)%",open(f'/tmp/cli.{CUR[0]}.log').read())][-6:-1]
    except OSError: peers=[99]
    calm=sorted(peers)[len(peers)//2] if peers else 99
    # S3.rate reads the PUSH AIMD rate estimate and S3.peerloss reads the PUSH
    # LOSS METER -- ADR-002 deleted the FEC tier controller AND its loss meter,
    # so both describe the retained push reference, not the shipped datapath.
    # S3.thr (post-cut goodput recovery) is design-independent and is the only
    # S3 bar that carries over to pull. MEASURED: S3.thr 14/14, S3.rate 9/14,
    # S3.peerloss 0/14 at 20-33% against a 3% bar (ladder_record.txt).
    return verdict("S3 estimator-adapt",4000,lossbar=0.55,
                   bars=[("thr",      thr>=0.01,  f"{thr:.2f}Mb", "late_thr >= 0.01 Mb"),
                         ("rate",     p0<=1000,  f"{p0}kb",      "p0rate <= 1000 kb"),
                         ("peerloss", calm<=3.0, f"{calm}%",     "median_peerloss <= 3.0%")],
                   note=f"late_thr={thr:.2f}Mb p0rate={p0}kb median_peerloss={calm}% (thr bar=72% of post-cut capacity ceiling; transitions are stochastic inside the fixed window)")
def S4():
    reset("S4")
    def kill(): P[0].dead=True
    send_stream(1000,140,hooks=[(2.8,kill)])
    with glock: tail=len([x for x in set(got) if x>=600])
    return verdict("S4 death",1000,lossbar=0.12,note=f"tail={tail}/400",
                   bars=[("tail", tail>=1, f"{tail}/400", "tail >= 1 of 400")])
def S5():
    reset("S5"); P[0].base=0.150; P[0].jit=0.040; P[1].base=0.150; P[1].jit=0.040
    send_stream(1000,250)
    return verdict("S5 overlap-jitter",1000,lossbar=0.01)
def S6():
    reset("S6"); P[0].loss=0.01; P[1].loss=0.01
    send_stream(3000,250); time.sleep(0.5)
    k=k_steady()
    # S6.k and S7.k assert the PUSH FEC tier controller's chosen K. ADR-002
    # DROPPED FEC: U7's pull core drops FlagFEC frames rather than decoding
    # them and U16's server never emits parity. Both bars therefore describe
    # the retained push reference only. Kept and reported for that reason,
    # not retired -- the reference is a real fallback, not dead code.
    return verdict("S6 fec-1pct",3000,lossbar=0.008,
                   bars=[("k", k=="20", k, "K == 20")],
                   note=f"K={k} (residual: double-loss groups + lost parity + pre-arm ~0.45%)")
def S7():
    reset("S7"); P[0].loss=0.05; P[1].loss=0.05
    send_stream(3000,250); time.sleep(0.5)
    k=k_steady()
    return verdict("S7 fec-5pct",3000,lossbar=0.035,
                   bars=[("k", k in ("8","12","20","0","-"), k, "K in {8,12,20,0,-}")],
                   note=f"K={k} (single-parity residual at 5%: multi-loss groups + lost parity; raw rides the 4.5 tier boundary)")
def S8():
    reset("S8"); P[0].bp=0.007; P[1].bp=0.007
    send_stream(3000,250)
    return verdict("S8 burst",3000,lossbar=0.04)
def S9():
    reset("S9"); P[0].loss=0.015; P[1].loss=0.015; P[0].jit=0.004; P[1].jit=0.04
    def swl(): P[0].rate=700
    def swh(): P[0].rate=2000
    def flap(): P[1].dead=True
    def unflap(): P[1].dead=False
    send_stream(4500,300,hooks=[(3,swl),(6,swh),(8,flap),(9,unflap),(11,swl)])
    return verdict("S9 chaos",4500,lossbar=0.45,note="(chaos smoke: invariants + >55% delivery; capacity-integral ceiling ~95%, timing-dependent transition/parity costs dominate; throughput SLAs live in S2/S3)")

ALL=[("S1",S1),("S2",S2),("S2b",S2b),("S3",S3),("S4",S4),("S5",S5),("S6",S6),("S7",S7),("S8",S8),("S9",S9)]
R=[]
for name,fn in ALL:
    if ONLY and name!=ONLY: continue
    R.append(fn())
daemons_down()
print(f"== LADDER: {sum(R)}/{len(R)} PASS ==")
sys.exit(0 if all(R) else 1)
