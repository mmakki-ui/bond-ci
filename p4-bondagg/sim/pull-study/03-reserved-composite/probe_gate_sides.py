#!/usr/bin/env python3
# =============================================================================
# probe_gate_sides.py -- ARCHITECTURE-REVIEW MECHANISM PROBE (read-only physics).
# Question under review: the "one per-link gate on delivered-vs-sent, read from
# two sides" proposal.  OPEN side (delivered>=sent) is claimed to mark a valid
# copy landing spot; SHUT side is the cap AND the lightning trigger.
# This probe measures, on the EXISTING Dpp rig (reserved_meter, physics
# UNMODIFIED, subclass-only instrumentation):
#   (1) per path, the duty cycle of each gate side:
#         local-side shut  : local_ms >= target        (pull's own edge signal)
#         far-side shut    : inflight/lagged_deliv >= target  (the delivered<sent latch)
#   (2) on the STEADY host (the landing spot): which clause actually sheds
#       duplicate admission (_meter_ok attribution) -- is the far side ever
#       the operative check, or is it inert (edge-limited => never shuts)?
#   (3) on the SPOTTY source: the latch DETECTION DELAY per stall window
#       (first far-shut sample after stall onset) -- the reactive-trigger gap.
# =============================================================================
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
import reserved_meter as RM

TARGET = 40.0

class Probe(RM.SimD):
    def __init__(s, *a, **kw):
        super().__init__(*a, **kw)
        N = s.N
        s.pb_ticks   = [0]*N   # per-path sampled ticks (one per tick via _lagged_deliv)
        s.pb_lshut   = [0]*N   # local side shut  (local_ms >= target)
        s.pb_fshut   = [0]*N   # far side shut    (inflight-time >= target)
        s.pb_fmax    = [0.0]*N # max far inflight-time ratio seen (ms)
        s.pb_mo_call = [0]*N   # _meter_ok calls (landing-check attribution)
        s.pb_mo_lrej = [0]*N   # rejected by LOCAL clause
        s.pb_mo_frej = [0]*N   # rejected by FAR clause (local passed)
        s.pb_now     = 0.0
        s.pb_first_fshut = {}  # stall onset -> first far-shut time on that path

    def _lagged_deliv(s, i, now):
        # one call per path per tick under Dpp (meter feed) -- sample gate sides
        s.pb_now = now
        lm = s._local_ms(i)
        est = max(1.0, s.push_est[i])   # pre-refresh estimate (1-tick stale, fine)
        infl = s.local[i].backlog_kb + s.down[i].backlog_kb
        fms = infl / est * 1000.0
        s.pb_ticks[i] += 1
        if lm >= s.target_ms: s.pb_lshut[i] += 1
        if fms >= s.target_ms:
            s.pb_fshut[i] += 1
            if s.spotty[i]:
                for (a, b) in RM.DROPS_A:
                    if a <= now <= b + 1.0 and a not in s.pb_first_fshut:
                        s.pb_first_fshut[a] = now
        if fms > s.pb_fmax[i]: s.pb_fmax[i] = fms
        return super()._lagged_deliv(i, now)

    def _meter_ok(s, i):
        s.pb_mo_call[i] += 1
        if s._local_ms(i) >= s.target_ms:
            s.pb_mo_lrej[i] += 1
            return False
        est = max(1.0, s.push_est[i])
        infl = s.local[i].backlog_kb + s.down[i].backlog_kb
        if infl / est * 1000.0 >= s.target_ms:
            s.pb_mo_frej[i] += 1
            return False
        return True


def run_rig(tag, bottleneck, loads, seeds=8, T=9.0):
    archs = [RM.cellA(RM.DROPS_A), RM.eth()]
    defs = RM.build_rig(archs, bottleneck=bottleneck)
    nom = sum(a['base'] for a in archs)
    drops = RM.DROPS_A
    print("=" * 78)
    print("RIG %s  (bottleneck=%s)  nominal_agg=%d  T=%.1f seeds=%d  target=%.0fms"
          % (tag, bottleneck, nom, T, seeds, TARGET))
    print("  paths: 0=cellA(spotty, dropouts %s)  1=eth(steady)" %
          (", ".join("%.1f-%.1f" % ab for ab in drops)))
    print("=" * 78)
    for load in loads:
        of = lambda t, _n=nom, _L=load: _L * _n
        agg = None
        det = {a: [] for (a, b) in drops}   # per stall onset: detection delays (s)
        nodet = {a: 0 for (a, b) in drops}
        gp = []; loss = []; rtx = []
        for sd in range(seeds):
            p = Probe(defs, of, T, sd, sched='Dpp', target_ms=TARGET)
            m = p.run()
            gp.append(m['gp']); loss.append(m['loss']); rtx.append(m['res_tx'])
            if agg is None:
                agg = dict(t=[0]*p.N, l=[0]*p.N, f=[0]*p.N, fm=[0.0]*p.N,
                           mc=[0]*p.N, ml=[0]*p.N, mf=[0]*p.N)
            for i in range(p.N):
                agg['t'][i] += p.pb_ticks[i]; agg['l'][i] += p.pb_lshut[i]
                agg['f'][i] += p.pb_fshut[i]
                agg['fm'][i] = max(agg['fm'][i], p.pb_fmax[i])
                agg['mc'][i] += p.pb_mo_call[i]; agg['ml'][i] += p.pb_mo_lrej[i]
                agg['mf'][i] += p.pb_mo_frej[i]
            for (a, b) in drops:
                if a in p.pb_first_fshut:
                    det[a].append(p.pb_first_fshut[a] - a)
                else:
                    nodet[a] += 1
        med = RM.med if hasattr(RM, 'med') else (lambda xs: sorted(xs)[len(xs)//2])
        print("load=%.2f   Dpp med gp=%.0f loss=%.2f%% res_tx=%.0f" %
              (load, med(gp), med(loss), med(rtx)))
        print("  %-28s %10s %10s %12s" % ("gate-side duty (all ticks)",
                                          "local-shut", "far-shut", "far max(ms)"))
        names = ['cellA(spotty)', 'eth(steady)']
        for i in range(2):
            print("  path%d %-22s %9.1f%% %9.1f%% %11.1f" %
                  (i, names[i], 100.0*agg['l'][i]/max(1, agg['t'][i]),
                   100.0*agg['f'][i]/max(1, agg['t'][i]), agg['fm'][i]))
        print("  %-28s %10s %10s %10s" % ("landing-check (_meter_ok)",
                                          "calls", "LOCAL-rej", "FAR-rej"))
        for i in range(2):
            print("  path%d %-22s %10d %10d %10d" %
                  (i, names[i], agg['mc'][i], agg['ml'][i], agg['mf'][i]))
        print("  source-latch detection delay after stall onset (far side, cellA):")
        for (a, b) in drops:
            ds = sorted(det[a])
            if ds:
                print("    stall %.1f-%.1fs: median delay %4.0f ms  (min %3.0f max %4.0f, "
                      "detected %d/%d seeds, missed %d)" %
                      (a, b, 1000*ds[len(ds)//2], 1000*ds[0], 1000*ds[-1],
                       len(ds), seeds, nodet[a]))
            else:
                print("    stall %.1f-%.1fs: NEVER detected (all %d seeds)" % (a, b, seeds))
        print()

t0 = time.time()
run_rig("N2 MID (hidden downstream)", 'mid', [0.65, 0.85])
run_rig("N2 EDGE (local bottleneck)", 'edge', [0.65, 0.85])
print("elapsed %.1fs" % (time.time() - t0))
