#!/usr/bin/env python3
import sys
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
import reserved_cap0 as R

SEEDS = 24; T = 9.0
def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n//2] if n % 2 else (xs[n//2-1]+xs[n//2])/2.0

def runs(archs, rig, load, sched):
    defs = R.build_rig(archs, bottleneck=rig)
    nom = sum(a['base'] for a in archs)
    ofn = lambda t, _n=nom, _L=load: _L*_n
    return [R.SimD(defs, ofn, T, sd, sched=sched).run() for sd in range(SEEDS)]

MIXED = [
    ('N2 1cell+1eth', [R.cellA(R.DROPS_A), R.eth()]),
    ('N3 2cell+1eth', [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.eth()]),
]
print('CHECK 4 -- mid load 0.85: Dp duplicate arming  (24 seeds, medians)')
print('  scenario           rig   |  Dp armed  Dp gp   pull gp   Dp res_tx  |  D armed (ctx)')
for label, ar in MIXED:
    for rig in ('mid', 'edge'):
        dp = runs(ar, rig, 0.85, 'Dp')
        pl = runs(ar, rig, 0.85, 'pull')
        dd = runs(ar, rig, 0.85, 'D')
        print('  %-18s %-5s | %8.3f %6.0f %8.0f %10.0f  | %8.3f' % (
            label, rig, med([m['armed_frac'] for m in dp]),
            med([m['gp'] for m in dp]), med([m['gp'] for m in pl]),
            med([m['res_tx'] for m in dp]), med([m['armed_frac'] for m in dd])))
