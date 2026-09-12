#!/usr/bin/env python3
# =============================================================================
# mutation_matrix.py -- WHICH DEFECT MAKES WHICH BAR GO RED.
# Task U14. Reads out/mut_*.txt, writes out/mutations.md.
#
# WHY: a gate that cannot fail is theatre, and this repo has already shipped two
# bars that passed while deliberately weakened (rig_paired_gate.py:preflight
# records both -- a 4x B2 dilution and a hardcoded SEEDS=2, each exit 0). Both
# were caught by review. So every bar here has to be DEMONSTRATED red on a
# known-bad tree, and the demonstration has to be re-run by the gate rather than
# quoted from a commit message.
#
# WHAT THIS STUDY DOES NOT ESTABLISH, and it took a FOURTH weakened-green gate to
# see it: a red demonstration proves a bar detects a GROSS defect. It says
# nothing about how much the bar could be WIDENED and still pass. The clean-vs-
# defect columns below are exactly that headroom -- SPD-3a 0.9993 clean against
# 0.5727 under hold-gran, HOLD-1d 24 against 8544 -- and four gated bars were
# diluted inside it to a green exit 0 with every row here still `-> ok`.
# Dilution is bounded by `latency_gate.py:MARGIN_PIN`, not by this file.
#
# The output splits the GATED bars into:
#   RED-DEMONSTRATED  a defect turns it from PASS to FAIL. Gate-worthy.
#   MUST-FAIL         it FAILS on the clean tree. Its protection runs the other
#                     way: the gate fails if it ever stops failing, which is what
#                     a diluted bar looks like.
#   NO RED DEMO       neither. Reported, deliberately NOT gated, with the reason.
#
# Run:  python mutation_matrix.py     (after out/RUNME.sh)
# =============================================================================
import glob
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')
CHECK = re.compile(r'^\s{2}(SPD-\d[a-z]|HOLD-\d[a-z])\s+(.*?)\s+(PASS|FAIL)\s')

# From out/geometry.md -- kept in one place so the two studies cannot drift.
GEOM = os.path.join(OUT, 'geometry.md')

# Why a bar has no defect that reddens it. Each is a MEASURED reason, not an
# excuse: if a bar cannot fail, the honest report is that it cannot fail.
WHY_NO_RED = {
    'SPD-1c': 'the +2*gran tolerance is 20 ms at the model\'s real granularity '
              '(DT=0.010), and the whole spread between "use every source" and '
              '"use the fastest one" at an offer that fits one source is 3 ms '
              '(p95 14 vs 11 under rank-hungriest). The bar is swamped by its own '
              'tolerance. It had teeth in the r1 table only because that table '
              'used TICK=1.0 ms, which contradicts the model.',
    'SPD-1d': 'at an offer the fastest source carries alone, every draw order '
              'delivers every frame: gp is 59926 for speed, for max and for the '
              'N=1 control alike. There is nothing for a draw-order defect to '
              'cost. The bar is true by the offer, not by the scheduler.',
    'HOLD-1a': 'r1 sec 4.1 measured it and this reproduces it: AT THE EDGE the hold '
               'length moves no percentile at all -- in-order frames release on '
               'arrival, so p50 is 12 ms under the ratchet, under a bare '
               'granularity hold, under a x3 pad and under fixed-343 alike. The '
               'hold is a LOSS knob at the edge. A latency bar there cannot fail.',
    'HOLD-1b': 'same as HOLD-1a: p95 is 242 ms under every hold policy injected.',
    'HOLD-3a': 'the warm-window p95 (12 ms edge) is compared against the OVERALL '
               'p95 (242 ms), which is set by the loaded steady state. Arming the '
               'ring at HoldMax instead of granularity -- the exact bug r1 sec 4.4 '
               'deletes -- moves the warm window to 12 ms at edge and 76 ms at mid, '
               'both still far under the overall p95. The bar as r1 states it is '
               'absorbed by its own reference. It needs a different reference '
               '(the same window under the other warm-up policy) to have teeth.',
    'HOLD-3b': 'same as HOLD-3a: warm 76 ms vs overall 422 ms under the injected '
               'warm-up-at-HoldMax defect.',
}


def read(path):
    v = {}
    for line in open(path, encoding='utf-8', errors='replace'):
        m = CHECK.match(line)
        if m:
            v.setdefault(m.group(1), []).append(m.group(3))
    return v


def gated_ids():
    txt = open(GEOM, encoding='utf-8').read()
    m = re.search(r"^GATED = \((.*?)\)$", txt, re.M)
    return [x.strip().strip("'") for x in m.group(1).split(',') if x.strip()]


def main():
    files = sorted(glob.glob(os.path.join(OUT, 'mut_*.txt')))
    runs = {os.path.basename(f)[4:-4]: read(f) for f in files}
    if 'none' not in runs:
        raise SystemExit('out/mut_none.txt missing -- the clean control run')
    clean = runs['none']
    gated = gated_ids()
    defects = [d for d in sorted(runs) if d != 'none']

    rows = []
    for bid in gated:
        clean_fail = 'FAIL' in clean.get(bid, [])
        reds = []
        for d in defects:
            if 'FAIL' in runs[d].get(bid, []) and not clean_fail:
                reds.append(d)
        if clean_fail:
            cls = 'MUST-FAIL'
        elif reds:
            cls = 'RED-DEMONSTRATED'
        else:
            cls = 'NO RED DEMO'
        rows.append((bid, cls, reds, clean_fail))

    lines = ['# Mutation matrix -- proving each OBJ-D latency bar can go RED (U14)', '',
             'GENERATED by `mutation_matrix.py` from `out/mut_*.txt`. Do not hand-edit.',
             '',
             'Every defect is a REAL design error from this project\'s own record, not a',
             'synthetic mutation. Run at SEEDS=2 (defects are gross; the point is the',
             'VERDICT flipping, not a margin), GEO=canonical.', '',
             '| defect | what it is |', '|---|---|']
    dd = {
        'rank-static': 'draw order = static latency rank (V1). REFUTED r1 sec 3.2, and it '
                       'reproduces CPF\'s documented pinning failure: -9.07% gp at S3@90k',
        'rank-hungriest': '`speed` silently degraded into `max` -- hungriest-first',
        'rank-mid-meter': 'the cap meter fed into the mid draw KEY (g2m). REFUTED r1 sec 5: '
                          'p95 456 vs 371 at mid 0.85',
        'hold-gran': 'the ratchet never learns -- a bare granularity hold',
        'hold-quantile': 'the REFUTED q=0.99/W=3s quantile hold (r1 sec 4.2). NOT in the '
                         'gate\'s matrix: `holdlib.dyn_release` re-sorts its sample window '
                         'per block and takes minutes per scenario. Its target bars '
                         '(HOLD-1d, HOLD-2b) are covered by `hold-gran`, which is fast',
        'warmup-max': 'the ring arms at HoldMax(343) instead of granularity -- the exact bug '
                      'r1 sec 4.4 deletes ("warm-up = HoldMax is backwards")',
        'ratchet-x3': 'granularity inflated 3x, so the floor becomes a pad again. This is '
                      "r1 sec 8's OWN pre-registered pass-by-artifact route (\"granularity "
                      'inflation -- gran becomes the new pad\"), and the guard it names '
                      'is exactly HOLD-4',
    }
    for d in defects:
        lines.append('| `%s` | %s |' % (d, dd.get(d, '?')))
    lines += ['', '| gated bar | class | reddened by |', '|---|---|---|']
    for bid, cls, reds, cf in rows:
        lines.append('| `%s` | %s | %s |'
                     % (bid, cls, ', '.join('`%s`' % r for r in reds) if reds
                        else ('fails on the clean tree' if cf else '**nothing**')))
    lines += ['', '## Bars with NO demonstrated failure mode', '',
              'Reported here and NOT gated. A bar that cannot fail is not a gate, and',
              'merging it green would be exactly the theatre this unit exists to avoid.', '']
    none_red = [b for b, c, _r, _f in rows if c == 'NO RED DEMO']
    if not none_red:
        lines.append('(none)')
    for b in none_red:
        lines.append('- **`%s`** -- %s' % (b, WHY_NO_RED.get(b, 'REASON NOT RECORDED')))
    lines += ['', '```python',
              'MUTATIONS = {']
    inv = {}
    for bid, cls, reds, _cf in rows:
        if cls == 'RED-DEMONSTRATED':
            for d in reds:
                inv.setdefault(d, []).append(bid)
    for d in sorted(inv):
        lines.append("    '%s': (%s)," % (d, ', '.join("'%s'" % b for b in sorted(inv[d]))))
    lines.append('}')
    lines.append('NO_RED_DEMO = (%s)' % ', '.join("'%s'" % b for b in none_red))
    lines.append('```')
    open(os.path.join(OUT, 'mutations.md'), 'w', encoding='utf-8',
         newline='\n').write('\n'.join(lines) + '\n')
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
