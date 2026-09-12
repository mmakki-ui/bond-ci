#!/usr/bin/env python3
# pathsim v4.0 — boundary-aware path emulator, scenario registry.
#
# =============================================================================
# U39 -- THE S1-S9 TRIAGE AGAINST ADR-002, AND WHY THIS FILE GREW A PULL ARM.
#
# THE MEASUREMENT THAT SETTLES IT, run 2026-09-05 on b-ci-gates (worktree of
# dev f84e30a), Ubuntu-24.04, go1.22.2:
#
#     cd p4-bondagg/daemon && CGO_ENABLED=0 go build -o /tmp/bond-agg .
#     cd ../sim && SIM_ONLY=S1 python3 -u pathsim.py
#       S1 below-sat: fwd=0/600 loss=100.00% ... data0=0 data1=0
#       FAIL S1 below-sat
#       == LADDER: 0/1 PASS ==
#     /tmp/cli.S1.log:
#       AGG_MODE=client was the EIF push datapath and it is DELETED
#       (ADR-002 / U128). Use AGG_MODE=pull-client.
#     /tmp/srv.S1.log: the same line for AGG_MODE=server.
#
# So the triage is not a judgement call about which bars still describe the
# product. `reset()` launched AGG_MODE=server and AGG_MODE=client, main.go:63-70
# log.Fatalf's on BOTH, and every scenario in this file went through `reset()`.
# S1-S9 have therefore measured NOTHING since U128 deleted the push entry
# points -- not a weaker thing, nothing: zero frames, two dead daemons, a 100%
# loss verdict, exit 1. `continue-on-error: true` on the `ladder` job is what
# kept that invisible.
#
#   S1 below-sat        NEITHER as written. Its SUBJECT (push client rate share)
#   S2 aggregate        is deleted code. S2/S3 additionally gate the EIF picker
#   S2b overload        + Estr/CapEst estimator pair, S6/S7 gate FEC K-tiers --
#   S3 estimator-adapt  and the pull pivot DROPPED FEC outright (ADR-002 sec 2 /
#   S4 death            frame.go: "fseq32: parsed and discarded"). S1/S4/S5/S8/
#   S5 overlap-jitter   S9 assert datapath-agnostic invariants (in-order, no
#   S6 fec-1pct         dup, loss bound) but every threshold in them was
#   S7 fec-5pct         CALIBRATED against the push client's AIMD, so they are
#   S8 burst            not portable as numbers either.
#   S9 chaos
#
# NONE of the nine is retired as a record: the push tree they exercise is
# preserved at the annotated tag `eif-push-reference` (87cbf42), the same tag
# main.go's refusal names, and they still run against a binary built from it:
#
#     git checkout eif-push-reference -- p4-bondagg/daemon
#     cd p4-bondagg/daemon && go build -o /tmp/bond-agg .
#     cd ../sim && SIM_PUSH_REFERENCE=1 python3 pathsim.py
#
# They are simply not in the GATED set any more, because a bar whose subject
# does not exist in the shipped binary cannot gate the shipped binary. That is
# the same disposition `eif-model` already carries (emulator-gate.yml), and it
# is what lets `ladder` drop `continue-on-error`.
#
# WHAT REPLACES THEM: P1/P2 below, which launch the datapath that SHIPS --
# `AGG_MODE=pull-client` (daemon) against the `p4-bondagg/server` binary, the
# pair both procd stanzas run (U111). They are a SMOKE CHECK, deliberately:
# ADR-004 makes `rig-paired` the deterministic oracle for the pull datapath, and
# pathsim spawns real UDP daemons, so anything with a tight numeric threshold
# would flake here. P1/P2 assert only what real daemons over a real socket must
# do on every run -- frames arrive, both links carry some, no duplicate reaches
# WireGuard's side, and a dead link does not take the stream with it.
# =============================================================================
import socket, threading, time, random, struct, heapq, sys, os, re, subprocess, itertools

SHIMA=("127.0.0.1",59404); SRV=("127.0.0.1",59403)
CLI_LISTEN=("127.0.0.1",59402); FAKEWG=("127.0.0.1",51999)
BIN="/tmp/bond-agg"; ONLY=os.environ.get("SIM_ONLY","")
# The pull SERVER is a separate Go module (p4-bondagg/server) with its own
# main() and no AGG_MODE at all -- the deleted `AGG_MODE=server` was the PUSH
# server and is not this. Build it with:
#   cd p4-bondagg/server && CGO_ENABLED=0 go build -o /tmp/bond-agg-server .
SRVBIN=os.environ.get("AGG_SERVER_BIN","/tmp/bond-agg-server")
KEYFILE=os.environ.get("AGG_KEY_FILE","/tmp/pathsim-transport.key")
# Id base for prime() frames, chosen far above any scenario's npkts so a
# straggling primed frame is IDENTIFIABLE in the delivered set rather than
# silently counted as a scenario packet.
PRIME_BASE=900000
# Opt-in, never on in CI: run the nine push-reference scenarios instead of the
# pull set. Only meaningful against a binary built from tag eif-push-reference.
PUSH_REF=os.environ.get("SIM_PUSH_REFERENCE","")=="1"

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
            # U39: mask FlagAuth (0x8) OFF before classifying. It is a MODIFIER
            # BIT inside the 4-bit flag nibble, not a flag value of its own
            # (daemon/auth.go:83-91, `base: fl &^ FlagAuth` at :332), so a
            # SIGNED data frame reads 0x8 here and the old `&0x0F` counted every
            # one of them as CONTROL. The push arm ran unsigned, so this was
            # invisible until the pull arm turned a key on: data0=0 data1=0 while
            # 862 of 1000 frames were delivered. Values 0..3 are unaffected.
            if (data[1]&0x07)==0:
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

def reset_pull(name):
    """U39. The SHIPPED datapath: p4-bondagg/server (its own module, no
    AGG_MODE) peered with the daemon at AGG_MODE=pull-client, through the same
    shim as `reset()` -- SHIMA(59404) is what the client dials, SRV(59403) is
    what the server binds, FAKEWG(51999) is where the server writes.

    Two env keys are deliberately NOT set, and both are refusals, not defaults:
      AGG_W       pullrun.go:141 rejects it outside AGG_MODE=client|server.
      AGG_SCHED   left unset so the arm measures the INHERITED `max` -- the
                  datapath a stanza that predates U17 lands on, which is the
                  one worth smoke-checking. `speed`/`lightning` have their own
                  deterministic oracle in rig-paired (ADR-004).

    AGG_KEY_FILE IS SET, AND IT IS NOT DECORATION -- a keyless pair DEADLOCKS
    in this topology and the deadlock is documented in the server's own source.
    server/rx.go:150-159: with no key, an unauthenticated ping on a link the
    server has never accepted DATA on draws NO echo, so the endpoint is learned
    only from a DATA frame. Meanwhile the client marks a link dead unless it has
    RECEIVED something inside DeadIval (pullrun.go:604,
    `SetAlive(RxAge(now) <= DeadIval)`), and a dead link is never drawn from
    (pull.go:1501). Neither side moves first. MEASURED keyless, 2026-09-05:
    `enq=600 drawn=0 stale=600 ... up=false | ... up=false` on the client,
    `echonoep=185` on the server, fwd=0/600. With a key the same source says it
    does not arise ("the authenticated ping above learns the endpoint first"),
    and a key file is what P5 actually installs on a box -- so the KEYED pair is
    the shipped configuration, not a workaround for the emulator."""
    if not os.path.exists(SRVBIN):
        print(f"FAIL {name}: no pull server binary at {SRVBIN}. Build it:")
        print("  cd p4-bondagg/server && CGO_ENABLED=0 go build -o /tmp/bond-agg-server .")
        return False
    CUR[0]=name
    random.seed(hash(name)&0xffff)
    daemons_down()
    with glock: got.clear(); gtimes.clear()
    cnt[0]=cnt[1]=0; dcnt[0]=dcnt[1]=0; seen.clear(); dupseq[0]=0
    for k in SH: SH[k]=[0,0]
    defaults()
    # One shared secret, 32 bytes hex, both peers. Fixed literal: this is an
    # emulator on loopback, the key is not a secret, and a random one would make
    # the run non-reproducible for no gain.
    with open(KEYFILE,'w') as kf: kf.write("a"*64+"\n")
    e=dict(os.environ); e.pop("AGG_MODE",None); e.pop("AGG_W",None)
    e.update(AGG_LISTEN="127.0.0.1:59403",AGG_WG="127.0.0.1:51999",AGG_KEY_FILE=KEYFILE)
    DAE.append(subprocess.Popen([SRVBIN],env=e,stderr=open(f'/tmp/srv.{name}.log','w')))
    time.sleep(0.5)
    e=dict(os.environ); e.pop("AGG_W",None)
    e.update(AGG_MODE="pull-client",AGG_LISTEN="127.0.0.1:59402",AGG_SERVER="127.0.0.1:59404",AGG_PATHS="lo,lo",AGG_KEY_FILE=KEYFILE)
    DAE.append(subprocess.Popen([BIN],env=e,stderr=open(f'/tmp/cli.{name}.log','w')))
    # SHORT settle, then PRIME, and the reason is a real property of this
    # datapath rather than emulator impatience. A pull link starts ALIVE
    # (pull.go:1163) and the control tick then re-derives it every tick as
    # `RxAge(now) <= DeadIval` (pullrun.go:604, DeadIval = 600ms, main.go:50).
    # The only thing that arrives to refresh RxAge is the server's echo, and the
    # server's echoBudget pays for echo bytes out of DATA bytes already received
    # (server/echo.go:190-212 -- "with no data there is nothing for the meter to
    # meter, so shedding costs nothing"). So on a COLD pair the sequence has to
    # be data-first: offer inside the opening DeadIval, the server earns credit,
    # the echo comes back, and the links stay up from then on.
    #
    # MEASURED with a 1.5s settle instead, 2026-09-05: client
    # `enq=600 drawn=0 stale=600 ... up=false`, server
    # `authok=166 echoshed=166 echonoep=0` -- every echo shed for want of credit,
    # every frame aged out unsent, fwd=0/600. That is the emulator starting the
    # stream after the window shut, not a defect in the datapath: on a box the
    # tunnel carries traffic from the moment it is up.
    time.sleep(0.35)
    prime()
    return True

def prime(n=80, pps=400):
    """Fire a short offer to earn the server its first echo credit, then drop
    what it produced. Kept separate from send_stream because send_stream ends
    with a 2s drain, and a 2s gap here would put the measured stream back
    outside the DeadIval window this exists to stay inside."""
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    iv=1.0/pps; t0=time.monotonic()
    for i in range(n):
        s.sendto(struct.pack(">I",PRIME_BASE+i)+b"x"*1196, CLI_LISTEN)
        dl=t0+(i+1)*iv-time.monotonic()
        if dl>0: time.sleep(dl)
    s.close(); time.sleep(0.25)
    clear_counters()

def clear_counters():
    """Zero every accumulator WITHOUT touching the daemons -- the point of the
    prime is that the pair stays warm across it."""
    with glock: got.clear(); gtimes.clear()
    cnt[0]=cnt[1]=0; dcnt[0]=dcnt[1]=0; seen.clear(); dupseq[0]=0
    for k in SH: SH[k]=[0,0]

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

def verdict(name, npkts, extra_ok=True, lossbar=0.01, need_echo=None, note=""):
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
    ok=inorder and dup==0 and lossf<=lossbar and extra_ok
    print(("PASS " if ok else "FAIL ")+name)
    return ok

def S1():
    reset("S1"); send_stream(600,100)
    share1=dcnt[1]/max(1,(dcnt[0]+dcnt[1]))
    return verdict("S1 below-sat",600,extra_ok=(share1<0.08),lossbar=0.005,note=f"p1share={share1:.1%}")
def S2():
    reset("S2"); send_stream(2800,280)
    share1=dcnt[1]/max(1,(dcnt[0]+dcnt[1]))
    with glock: tl=len([x for x in set(got) if x>=900])
    tailok = tl >= (2800-900)*0.985
    return verdict("S2 aggregate",2800,extra_ok=(share1>0.25 and tailok),lossbar=0.06,note=f"p1share={share1:.1%} tail900={tl}/{2800-900} (ramp txdrop=conservation)")
def S2b():
    reset("S2b"); send_stream(3400,425)
    with glock: n=len(set(got))
    return verdict("S2b overload-backpressure",3400,extra_ok=(n>=1800),lossbar=0.50,note=f"delivered={n}")
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
    return verdict("S3 estimator-adapt",4000,extra_ok=(thr>=1.5 and p0<=1000 and calm<=3.0),lossbar=0.55,note=f"late_thr={thr:.2f}Mb p0rate={p0}kb median_peerloss={calm}% (thr bar=72% of post-cut capacity ceiling; transitions are stochastic inside the fixed window)")
def S4():
    reset("S4")
    def kill(): P[0].dead=True
    send_stream(1000,140,hooks=[(2.8,kill)])
    with glock: tail=len([x for x in set(got) if x>=600])
    return verdict("S4 death",1000,extra_ok=(tail>=392),lossbar=0.12,note=f"tail={tail}/400")
def S5():
    reset("S5"); P[0].base=0.150; P[0].jit=0.040; P[1].base=0.150; P[1].jit=0.040
    send_stream(1000,250)
    return verdict("S5 overlap-jitter",1000,lossbar=0.01)
def S6():
    reset("S6"); P[0].loss=0.01; P[1].loss=0.01
    send_stream(3000,250); time.sleep(0.5)
    k=k_steady()
    return verdict("S6 fec-1pct",3000,extra_ok=(k=="20"),lossbar=0.008,note=f"K={k} (residual: double-loss groups + lost parity + pre-arm ~0.45%)")
def S7():
    reset("S7"); P[0].loss=0.05; P[1].loss=0.05
    send_stream(3000,250); time.sleep(0.5)
    k=k_steady()
    return verdict("S7 fec-5pct",3000,extra_ok=(k in ("8","12")),lossbar=0.035,note=f"K={k} (single-parity residual at 5%: multi-loss groups + lost parity; raw rides the 4.5 tier boundary)")
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


# ---- U39: the PULL arm. This is the datapath that ships. --------------------
#
# WHY THE BARS ARE SHAPED THE WAY THEY ARE. These spawn real UDP daemons and
# real sockets, so a per-run numeric threshold is a flake generator -- that is
# the documented reason `ladder` was continue-on-error in the first place, and
# repeating the mistake in the pull arm would just re-earn it. Each bar below
# asserts a property that is TRUE OR THE DATAPATH IS BROKEN, with no tuned
# constant on the near side of it:
#   * frames arrive at all (the push arm's silent-death mode was fwd=0/N);
#   * BOTH links carry data (N is discovered from the wire; one silent link is
#     a bond that is not bonding);
#   * nothing is duplicated into WireGuard's replay window (delivery is ON
#     ARRIVAL and there is no dedup below this point -- server/main.go);
#   * killing a link does not kill the stream.
# Absolute throughput and per-link SHARE belong to rig-paired (ADR-004), which
# compares PAIRED runs instead of asserting an absolute.

def pull_verdict(name, npkts, extra_ok=True, lossbar=0.05, note=""):
    """verdict() with the IN-ORDER bar removed, because in-order arrival is not
    this datapath's contract and asserting it would be asserting a property the
    design explicitly gave up.

    server/main.go's own start-up line says it: "delivery: ON ARRIVAL -- no
    reorder ring, no hold, no dedup here. Reorder tolerance and duplicate
    rejection are WireGuard's anti-replay window". The client says the same
    (pullrun.go's pull-rx line). So what is gated here is what WireGuard's
    window actually needs: NO DUPLICATE reaches it (there is no dedup below this
    point, so a duplicate is a real defect), the loss stays inside the bar, and
    the REORDER SPREAD stays inside the window rather than merely being
    non-zero. MaxReorderSpreadMS=350 and WGReplayWindow=2048 are the server's
    constants; the depth bar below is that window, so a run that reordered
    deeper than WireGuard can absorb goes RED even though every frame arrived."""
    with glock:
        g=list(got)
    # Drop the PRIME tail. clear_counters() runs 0.25s after the last prime
    # packet leaves, but the model path itself adds queueing+latency on top of
    # that, so a few primed frames land AFTER the counters are zeroed. They are
    # sent with ids from PRIME_BASE precisely so they can be identified rather
    # than guessed at: without this the first run measured fwd=603/600,
    # loss=-0.50% and reorder_depth=900078, all three of them the prime.
    strays=len([x for x in g if x>=PRIME_BASE])
    g=[x for x in g if x<PRIME_BASE]
    dup=len(g)-len(set(g))
    lossf=(npkts-len(set(g)))/npkts
    # Reorder DEPTH: how far back a frame ever landed behind the high-water
    # mark. This is the quantity WGReplayWindow bounds.
    hi=-1; depth=0
    for x in g:
        if x>hi: hi=x
        elif hi-x>depth: depth=hi-x
    WGReplayWindow=2048
    ok = dup==0 and lossf<=lossbar and depth<WGReplayWindow and extra_ok
    print(f"{name}: fwd={len(set(g))}/{npkts} loss={lossf:.2%} dup={dup} "
          f"reorder_depth={depth}/{WGReplayWindow} data0={dcnt[0]} data1={dcnt[1]} primestrays={strays} {note}")
    print(("PASS " if ok else "FAIL ")+name)
    return ok

def P1():
    """Below-saturation smoke on the shipped pull pair. The loss bar is loose on
    purpose: the assertion is that the bond CARRIES and that BOTH links carry,
    not that it carries a measured fraction -- that comparison is rig-paired's,
    per ADR-004."""
    if not reset_pull("P1"): return False
    send_stream(600,100)
    # PRESENCE FLOOR, not a share bar, and the distinction is the whole point.
    # Equal share at N=2 is 50%; this asks for 10%, five times below it, so it
    # can never become a rate-share assertion by accident -- share comparisons
    # are rig-paired's (ADR-004).
    #
    # It is 10% rather than the >0 it started as because >0 IS VACUOUS HERE, and
    # that was measured, not guessed. Seeding P[1].dead=True right after warm-up
    # (link 1 carries nothing for the whole stream) still left data1=46: the
    # prime's own frames and what was in flight. 46 > 0, so the bar passed on a
    # link that was dead. A floor above the prime's residue is what makes it
    # bite -- seeded 46 vs floor 60 goes RED, real 300 passes with 5x margin.
    floor=600//10
    both = dcnt[0]>=floor and dcnt[1]>=floor
    return pull_verdict("P1 pull below-sat (pull-client + p4-bondagg/server)",600,
                        extra_ok=both,lossbar=0.10,
                        note=f"bothlinks={both} (floor {floor}/link = 10% of offer, "
                             f"equal share is 50%) sched=max(inherited)")

def P2():
    """A link dies mid-stream and the bond keeps delivering. Same shape as the
    push arm's S4, but the tail bar is a PRESENCE FLOOR rather than S4's tuned
    392/400: this asserts SURVIVAL, which is the invariant, and leaves the
    magnitude of the dip to rig-paired."""
    if not reset_pull("P2"): return False
    def kill(): P[0].dead=True
    send_stream(1000,140,hooks=[(2.8,kill)])
    # TWO corrections to the bar this started as (`set(got)` filtered only by
    # `x>=600`, floor `>0`), both of them the trap P1's comment already
    # documents and neither of them theoretical -- measured on this file with
    # BOTH links seeded dead, i.e. nothing was delivered at all:
    # `tail_after_kill=4/400`, `extra_ok=(tail>0)` TRUE, and the SURVIVAL bar
    # PASSED on a dead stream. P2 only went FAIL on the loss bar, at 60.80%
    # against a 0.60 bar -- a 0.8-point margin of timing.
    #
    #   (1) PRIME ids are >= PRIME_BASE = 900000, which is >= 600, so every
    #       straggling prime frame counted as a post-kill survivor. `x<PRIME_BASE`
    #       is the same filter `pull_verdict` already applies to `g` (:457-458);
    #       omitting it here is what made the residue readable as delivery.
    #   (2) A floor of ONE is vacuous even after that filter, for the same
    #       reason P1's `>0` was: frames already in flight when the hook runs
    #       land after it. The floor is 10% of the 400-frame post-kill window,
    #       five times below the ~100% a surviving link actually delivers.
    #
    # MARGIN, from the 5-run stability series recorded in emulator-gate.yml's
    # `ladder` comment: the real tail ran 269-405 of 400, so the worst measured
    # healthy run clears this floor by 6.7x, and a dead stream (prime residue
    # only, measured 4 and now filtered to 0) is FAR below it.
    with glock: tail=len([x for x in set(got) if 600<=x<PRIME_BASE])
    floor=400//10
    return pull_verdict("P2 pull link-death (stream survives the loss of link 0)",1000,
                        extra_ok=(tail>=floor),lossbar=0.60,
                        note=f"tail_after_kill={tail}/400 (floor {floor} = 10% of the post-kill "
                             f"window, prime ids >={PRIME_BASE} excluded: SURVIVAL, not a tuned fraction)")

# The nine push scenarios are the eif-push-reference set (see this file's
# header). They are OFF unless SIM_PUSH_REFERENCE=1, because against the shipped
# binary all nine are fwd=0/N -- both of their daemons refuse to start.
PUSH=[("S1",S1),("S2",S2),("S2b",S2b),("S3",S3),("S4",S4),("S5",S5),("S6",S6),("S7",S7),("S8",S8),("S9",S9)]
PULL=[("P1",P1),("P2",P2)]
ALL = PUSH if PUSH_REF else PULL
if PUSH_REF:
    print("== pathsim: SIM_PUSH_REFERENCE=1 -- running the PUSH REFERENCE ladder.")
    print("== These bars need a binary built from tag eif-push-reference; against")
    print("== the shipped daemon every one of them is fwd=0/N (ADR-002 / U128).")
R=[]
for name,fn in ALL:
    if ONLY and name!=ONLY: continue
    R.append(fn())
daemons_down()
if not R:
    print(f"== LADDER: NO SCENARIO RAN (SIM_ONLY={ONLY!r} matched nothing in "
          f"{[n for n,_ in ALL]}) -- an empty ladder is a FAILURE, not a pass ==")
    sys.exit(1)
print(f"== LADDER: {sum(R)}/{len(R)} PASS ==")
sys.exit(0 if all(R) else 1)
