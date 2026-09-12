#!/usr/bin/env python3
# ADVERSARIAL AUDIT PROBE for scheduler C.
#  Q1 does lambda seed cap_fn(0)/nominal-capacity anywhere?
#  Q2 is _c_inflight exact vs true (sent - truly-arrived)?
#  Q3 is the app-limited flag masking a real down-ratchet under MID load?
#  Q4 which gate actually throttles C in MID (delay-age vs count-cap vs local-ms)?
#  Q5 does the age-purge charge DELIVERED frames as "lost"?
import sys
sys.path.insert(0, '.')
from ackclock_sim import Sim, make_defs

off2 = 0.85 * (29000 + 78000)

def init_state(defs_fn, label):
    s = Sim(defs_fn(), lambda t: off2, 10.0, 0, sched='C')
    cap0 = [s.defs[i]['cap_fn'](0.0) for i in range(s.N)]
    print(f"\n== INIT STATE ({label}) cap_fn(0)={[round(c) for c in cap0]} ==")
    print(f"  s.lam        = {s.lam}            <- pure? (expect [0.0,..])")
    print(f"  s.lam_used   = {s.lam_used}")
    print(f"  s.lam_peak   = {s.lam_peak}")
    print(f"  s.rttmin     = {s.rttmin}")
    print(f"  s.drain_ewma = {[round(x,1) for x in s.drain_ewma]}   <- SEEDED cap_fn(0)? (used by local_ms gate for ALL scheds incl C)")
    print(f"  s.push_est   = {[round(x,1) for x in s.push_est]}   <- seeded cap0 (ewma/push only)")
    print(f"  s.W          = {[round(x,1) for x in s.W]}   <- seeded cap0 (ack/B only)")
    # is lam derived from cap0 at all? grep the derivation: lam_meas from reading_hist deltas only.
    return s

# --- instrumented single-seed run ---
def traced(defs_fn, label, seed=0):
    s = Sim(defs_fn(), lambda t: off2, 10.0, seed, sched='C')
    # monkey-patch room to count gate-closure reasons on path0 & path1
    gate_stats = {i: dict(calls=0, local_closed=0, delay_closed=0, count_closed=0,
                          pace_closed=0, opened=0, cold=0, probe=0) for i in range(s.N)}
    import types
    orig_run = s.run
    # We replicate the gate logic as an observer using the real internal fns.
    # Instead of patching, run and sample via _do_trace plus post inspection.
    s._do_trace = True; s._trace = []
    res = s.run()
    # reconciliation error: true inflight vs _c_inflight, at END
    true_infl = [s.sent_cum[i] - s.recv_cum_srv[i] for i in range(s.N)]
    rec_infl  = [len(s.flight_ts[i]) for i in range(s.N)]
    print(f"\n== {label} seed={seed} : gp={res['gp']:.0f} loss={res['loss']:.1f}% p50={res['p50']:.0f} "
          f"p95={res['p95']:.0f} qdrops={res['qdrops']:.0f} tdrop={res['tdrop']:.0f} c_lost={res['c_lost']:.0f} ==")
    print(f"  sent_cum={s.sent_cum} recv_cum_srv(TRUE arrivals)={s.recv_cum_srv} recv_reading(echoed)={s.recv_reading}")
    print(f"  removed={s.removed} lost_cum(age-purged)={s.lost_cum}")
    print(f"  TRUE inflight(sent-arrived)={true_infl}  vs  _c_inflight(len flight_ts)={rec_infl}")
    print(f"  rttmin(ms)={[round(1000*r,1) if r else None for r in s.rttmin]} tau(ms)={1000*s.tau:.0f}")
    print(f"  final lam(f/s)={[round(x,1) for x in s.lam]} lam_used={[round(x,1) for x in s.lam_used]}")
    print(f"  final _c_budget(frames)={[round(s._c_budget(i),1) for i in range(s.N)]}")
    # trace summary: path0
    tr = s._trace
    if tr:
        n = len(tr)
        # fraction of sampled ticks where oldest-flight age exceeded rttmin+tau (delay gate would close)
        return res, s, tr
    return res, s, tr

print("#"*80)
print("# Q1: does lambda / lam_used / budget carry a nominal-cap (cap_fn(0)) prior?")
print("#"*80)
init_state(lambda: make_defs('edge'), 'EDGE')
init_state(lambda: make_defs('mid', local_mult=20.0), 'MID-drop')

print("\n" + "#"*80)
print("# Q2/Q4/Q5: single-seed instrumented runs")
print("#"*80)
res_e, se, tre = traced(lambda: make_defs('edge'), 'EDGE')
res_m, sm, trm = traced(lambda: make_defs('mid', local_mult=20.0), 'MID-drop')

# Q4: in MID, sample path0 trace: how often would delay-gate (fage>=budg) close?
def gate_frac(tr, s):
    dl = 0; tot = 0
    for r in tr:
        tot += 1
        # delay gate closes when oldest flight age (fage0 ms) >= rttmin+tau (budg0 ms)
        if r['fage0'] >= r['budg0'] and r['budg0'] > 0:
            dl += 1
    return dl, tot
dl, tot = gate_frac(trm, sm)
print(f"\n[MID path0] sampled ticks where oldest-flight-age >= (rttmin+tau): {dl}/{tot} = {100*dl/max(1,tot):.0f}%  <- delay-gate closure")
dle, tote = gate_frac(tre, se)
print(f"[EDGE path0] same: {dle}/{tote} = {100*dle/max(1,tote):.0f}%")

# print a few MID trace rows mid-run to see budget vs inflight vs down-backlog
print("\n[MID path0 trace @ t=3.0..4.0s]  dc0=downcap lam0 cwnd0 infl0 fage0(ms) budg0(ms) db0=downQ(frames) pool")
for r in trm:
    if 3.0 <= r['t'] <= 4.0 and abs((r['t']/0.05)-round(r['t']/0.05))<1e-6:
        print(f"  t={r['t']:.2f} dc0={r['dc0']:.0f} lam0={r['lam0']:.0f} cwnd0={r['cwnd0']:.1f} "
              f"infl0={r['infl0']} fage0={r['fage0']:.0f} budg0={r['budg0']:.0f} db0={r['db0']:.0f} pool={r['pool']}")

# Q3: applim frequency under MID load -- re-run counting applim ticks
class SimCount(Sim):
    def _c_update(s, now):
        super()._c_update(now)
for tag, dfn in (('EDGE', lambda: make_defs('edge')), ('MID', lambda: make_defs('mid', local_mult=20.0))):
    s = Sim(dfn(), lambda t: off2, 10.0, 0, sched='C')
    # count applim by wrapping: applim_t is set in run(); count ticks where (now-applim_t)<LAM_WIN
    applim_ticks = [0,0]; total_ticks=[0,0]
    # easier: instrument by post-run inspection is impossible; do a light patched run
    import ackclock_sim as A
    s._do_trace=False
    # patch _c_update to record applim state per path
    rec = {'ap':[0]*s.N, 'tot':0}
    orig = s._c_update
    def patched(now, s=s, rec=rec, orig=orig):
        orig(now)
        rec['tot']+=1
        for i in range(s.N):
            if (now - s.applim_t[i]) < s.LAM_WIN:
                rec['ap'][i]+=1
    s._c_update = patched
    s.run()
    print(f"\n[Q3 {tag}] app-limited fraction per path: "
          + ", ".join(f"p{i}={100*rec['ap'][i]/max(1,rec['tot']):.0f}%" for i in range(s.N))
          + f"  (applim=True freezes lam down-ratchet)")
