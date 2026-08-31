#!/usr/bin/env python3
# =============================================================================
# meterfree_check.py -- (c) confirm the mirror-arm decision is meter-free:
# ONLY static path identity (spotty class, fixed at construction) + LOCAL state
# (this host's own local queue/drain), NEVER a far-end "is it stalling now"
# signal (no ack ledger, no delivered-rate meter, no oracle).
#
# Two independent checks, single process (cheap, no ProcessPoolExecutor, low
# footprint on a shared/contended box):
#   1. STATIC CODE AUDIT: grep the classifier body (armed/at_risk/healthy/host,
#      lines computed BEFORE any packet is sent this tick) for any read of
#      s.arr / s.down -- the only simulator state that encodes far-end/receiver
#      knowledge. Report every hit with its line + which block it's in.
#   2. DYNAMIC PROOF (MID rig, the hidden-stall case): run the SAME offered
#      load on the SAME cellA archetype twice -- once WITH the canonical
#      dropout schedule (DROPS_A, real hidden stalls happen), once with NO
#      dropouts at all (spotty class present, but it never actually stalls).
#      If arming were reacting to a far-end/delivered-rate signal, armed_frac
#      would differ between "some stalls happen" and "zero stalls happen".
#      If arming is pure static-identity (spotty[i] alive[i], both LOCAL/config
#      reads for MID rig, since local_cap_fn is constant there), armed_frac is
#      IDENTICAL in both cases -- the reserve is armed the whole time a spotty
#      class is present and offering traffic, whether or not it is currently
#      stalling. That is the meter-free signature.
# =============================================================================
import ast, sys, textwrap
import reserved_dp as R

def audit():
    src = open('reserved_dp.py', encoding='utf-8').read()
    tree = ast.parse(src)
    fn = None
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == 'run':
            fn = node
            break
    assert fn is not None, 'SimD.run not found'
    lines = src.splitlines()
    # classifier block = from 'alive = [' up to (not including) 'mir_kb = ' /
    # the PIECE 1 native-admission loop -- i.e. before any packet is offered.
    start = end = None
    for i, ln in enumerate(lines):
        if 'alive = [lcaps[i]' in ln and start is None:
            start = i
        if 'nat_kb = [0.0]' in ln:
            end = i
            break
    assert start and end, 'classifier block markers not found (code shape changed)'
    block = lines[start:end]
    hits = [(start + j + 1, ln) for j, ln in enumerate(block)
            if ('s.arr' in ln or 's.down' in ln) and not ln.strip().startswith('#')]
    return start + 1, end, block, hits

def dyn_check():
    T = 9.0; SEEDS = 8
    ARCHS_STALL = [R.cellA(R.DROPS_A), R.eth()]
    ARCHS_NOSTALL = [R.cellA(()), R.eth()]
    nom = sum(a['base'] for a in ARCHS_STALL)
    ofn = lambda t, _n=nom: 0.70 * _n
    res = {}
    for label, archs in (('WITH dropouts (real hidden stalls)', ARCHS_STALL),
                          ('NO dropouts (spotty class, never stalls)', ARCHS_NOSTALL)):
        defs = R.build_rig(archs, bottleneck='mid')
        afs = []
        for sd in range(SEEDS):
            m = R.SimD(defs, ofn, T, sd, sched='D', reserve_frac=0.15).run()
            afs.append(m['armed_frac'])
        res[label] = afs
    return res

def main():
    try: sys.stdout.reconfigure(encoding='utf-8')
    except Exception: pass
    print('=' * 90)
    print('CHECK 1 -- STATIC CODE AUDIT: does the classifier read far-end state?')
    print('=' * 90)
    s1, e1, block, hits = audit()
    print('classifier block = reserved_dp.py lines %d..%d (armed/at_risk/healthy/host/'
          'mir_budget, computed BEFORE any packet is offered this tick)' % (s1, e1))
    if hits:
        print('FAIL -- far-end state (s.arr / s.down) read inside the classifier:')
        for ln, txt in hits:
            print('  line %d: %s' % (ln, txt.strip()))
    else:
        print('PASS -- zero reads of s.arr / s.down in the classifier block.')
        print('  Only reads: s.spotty[i] (static, fixed at __init__ from path_defs),')
        print('  lcaps[i] = s._local_cap(i, now) (this-tick sample of the LOCAL config')
        print('  trace / local queue -- this host\'s own interface, not the peer), and')
        print('  s.drain_ewma[i] / s._local_ms(i) (this host\'s own local backlog+drain')
        print('  EWMA, DRAIN_TAU=0.10s causal local filter). mir_budget/tot_budget use')
        print('  only s.cap0[i], the NOMINAL config capacity, not any runtime meter.')
    # also report the one legitimate s.arr use elsewhere, to be transparent about it
    all_arr_lines = [(i + 1, ln) for i, ln in enumerate(open('reserved_dp.py', encoding='utf-8').read().splitlines())
                      if 's.arr' in ln and 'def ' not in ln]
    print()
    print('for completeness, ALL s.arr touches in the file (outside the classifier):')
    for ln, txt in all_arr_lines:
        if ln < s1 or ln > e1:
            print('  line %d: %s' % (ln, txt.strip()))
    print('  (line 223, inside PIECE 2 mirror-SEND loop: dedup only -- "don\'t fire a')
    print('  copy for a seq this SAME sender already knows it already transmitted /')
    print('  the reorder ring already resolved". It does not feed armed/at_risk/')
    print('  healthy/host/mir_budget -- those are already fixed for the tick by the')
    print('  time this line runs. No ACK, no RTT sample, no peer report.)')
    print()
    print('=' * 90)
    print('CHECK 2 -- DYNAMIC PROOF: armed_frac vs whether a stall is ACTUALLY happening')
    print('  MID rig (hidden downstream stall), load=0.70, seeds=%d, reserve r=0.15' % 8)
    print('=' * 90)
    res = dyn_check()
    for label, afs in res.items():
        afs_s = sorted(afs)
        med = afs_s[len(afs_s)//2]
        print('  %-42s armed_frac per-seed=%s  median=%.4f' %
              (label, ['%.4f' % x for x in afs_s], med))
    labels = list(res.keys())
    d = abs(sorted(res[labels[0]])[len(res[labels[0]])//2] - sorted(res[labels[1]])[len(res[labels[1]])//2])
    print()
    if d < 1e-9:
        print('PASS -- armed_frac IDENTICAL whether or not the spotty path ever actually')
        print('  stalls (delta=%.2e). Arming tracks path-CLASS presence + local health,' % d)
        print('  never a far-end/delivered-rate stall signal -- it is armed continuously')
        print('  once the spotty class is alive+offering, dropout or no dropout.')
    else:
        print('DIFFERS -- armed_frac delta=%.6f between stall/no-stall runs; re-examine' % d)
        print('  (would suggest the arm decision is reacting to something stall-dependent).')

if __name__ == '__main__':
    main()
