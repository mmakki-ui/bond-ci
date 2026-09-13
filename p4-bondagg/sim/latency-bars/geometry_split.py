#!/usr/bin/env python3
# =============================================================================
# geometry_split.py -- DERIVE the gate/report split for the OBJ-D latency bars.
# Task U14. Reads out/geo_*.txt, writes out/geometry.md.
#
# THE QUESTION IT ANSWERS
# -----------------------------------------------------------------------------
# U33 measured that this rig's stall geometry is HAND-PLACED, that seeds vary
# jitter and not phase, and that even PAIRED quantities move about 0.9 pt when
# the phase is rotated -- so "24 seeds" is 24 jitter samples of ONE geometry, not
# a confidence interval (ROADMAP, "U33 -- the corrected phase result"). It drew
# the consequence for the U8 gate but nobody had applied it to a NEW gate.
#
# Applied here as the rule that decides what may be gated at all:
#
#     A bar is GATED only if its verdict is IDENTICAL across the geometry
#     sample. A bar whose verdict flips is REPORTED, never gated -- gating it
#     would be gating the stall phase, which is invented.
#
# This is a threshold DERIVED FROM MEASUREMENT, which is the only kind this
# project allows. It is also conservative in the right direction: sampling a
# subset of rotations can only SHRINK measured geometry spread (U33), so a bar
# that flips here would flip at least as often over the full rotation family.
#
# The sample is canonical + four `rig_checks.phase_drops` rotations. That is a
# SMALL sample and it is named as such: four rotations do not establish that a
# surviving bar is stable, only that it did not flip on four draws. Widening it
# is one more run of the loop in out/RUNME.sh.
#
# Run:  python geometry_split.py           (after out/RUNME.sh)
# =============================================================================
import ast
import glob
import os
import re

# =============================================================================
# U14c -- THIS SCRIPT IS A GATE NOW, NOT A REPORT.
#
# The hole it closes: `latency_gate.py` carries GATED/REPORTED as hand-copied
# tuples, and the CI job that uses them runs GEO=canonical ONLY. The study that
# DERIVED the split was run by hand, out of band, and nothing ever checked that
# the tuples in the gate still equal what the study says. Two ways that rots:
#
#   * somebody edits GATED in `latency_gate.py` and the study never moves --
#     a geometry-UNSTABLE bar becomes gated, i.e. the gate starts gating the
#     invented stall phase, which is the exact thing U33 measured against;
#   * a `out/geo_*.txt` goes missing and the sample silently SHRINKS -- fewer
#     draws means fewer flips means MORE bars look stable, so the split widens
#     on its own and every widened bar is unearned.
#
# Both are now hard exits. `ROTATIONS` pins the sample so it cannot shrink, and
# `check_gate()` re-derives the gate's own tuples from the study and refuses to
# exit 0 if they disagree. The derivation is mechanical and is the rule
# `out/RUNME.sh` states in prose ("GATED <- out/geometry.md minus
# out/mutations.md's NO RED DEMO"):
#
#     latency_gate.GATED    == sorted(geometry-stable ids) - NO_RED_DEMO
#     latency_gate.REPORTED == sorted(geometry-unstable ids | NO_RED_DEMO)
#
# Verified on this branch: 21 stable ids - 6 NO_RED_DEMO = the 15 GATED, and
# 7 unstable | 6 NO_RED_DEMO = the 13 REPORTED.
# =============================================================================

# The rotation sample the split is entitled to be derived from. `canonical` is
# the hand-placed DROPS_*; the integers select `rig_checks.phase_drops`
# rotations (U33's count- and duration-preserving randomiser). Widening the
# sample is adding an integer HERE and to `out/RUNME.sh` in the same commit --
# never to one of them alone.
ROTATIONS = ('canonical', '3', '7', '11', '19')


HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')
GATE_PY = os.path.normpath(os.path.join(
    HERE, '..', '..', '..', '.github', 'scripts', 'latency_gate.py'))
CHECK = re.compile(r'^\s{2}(SPD-\d[a-z]|HOLD-\d[a-z])\s+(.*?)\s+(PASS|FAIL)\s')


def read(path):
    v = {}
    for line in open(path, encoding='utf-8', errors='replace'):
        m = CHECK.match(line)
        if m:
            v[(m.group(1), ' '.join(m.group(2).split()))] = m.group(3)
    return v


def gate_consts():
    """Read GATED / REPORTED / NO_RED_DEMO out of latency_gate.py WITHOUT
    importing it -- importing would drag in latency_battery and the whole rig,
    and this has to work from a bare checkout with no rig deps. ast.literal_eval
    over the module's top-level assignments is exact and cannot execute
    anything."""
    want = ('GATED', 'REPORTED', 'NO_RED_DEMO')
    src = open(GATE_PY, encoding='utf-8').read()
    got = {}
    for node in ast.parse(src).body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            t = node.targets[0]
            if isinstance(t, ast.Name) and t.id in want:
                got[t.id] = tuple(ast.literal_eval(node.value))
    missing = [k for k in want if k not in got]
    if missing:
        raise SystemExit('latency_gate.py has no top-level %s -- this checker '
                         'reads the split from there and cannot be silently '
                         'skipped' % ', '.join(missing))
    return got


def check_gate(gated, reported, names):
    """Re-derive latency_gate.py's split from the study just computed and exit 1
    on any disagreement. Returns nothing; it either passes or kills the run."""
    bad = []

    if tuple(names) != tuple(sorted(ROTATIONS,
                                    key=lambda x: (x != 'canonical', x))):
        bad.append('the rotation sample is %s but ROTATIONS pins %s. A MISSING '
                   'geometry makes bars look stable that are not -- fewer draws, '
                   'fewer flips, a wider GATED set that nothing measured. Restore '
                   'the out/geo_*.txt, or widen ROTATIONS and out/RUNME.sh in the '
                   'same commit.' % (list(names), list(ROTATIONS)))

    c = gate_consts()
    no_demo = set(c['NO_RED_DEMO'])
    want_gated = tuple(sorted(set(gated) - no_demo))
    want_reported = tuple(sorted(set(reported) | no_demo))
    if tuple(c['GATED']) != want_gated:
        bad.append('latency_gate.GATED is\n    %s\nbut this study derives\n    %s'
                   % (list(c['GATED']), list(want_gated)))
    if tuple(c['REPORTED']) != want_reported:
        bad.append('latency_gate.REPORTED is\n    %s\nbut this study derives\n    %s'
                   % (list(c['REPORTED']), list(want_reported)))
    unstable_but_gated = sorted(set(c['GATED']) & set(reported))
    if unstable_but_gated:
        bad.append('GATED bars whose verdict FLIPS across the geometry sample: %s. '
                   'Gating one gates the stall phase, which is hand-placed and '
                   'invented (U33).' % unstable_but_gated)

    if bad:
        print('')
        print('=' * 78)
        print('GEOMETRY SPLIT CHECK FAILED (U14c) -- %s' % GATE_PY)
        for b in bad:
            print('  * %s' % b)
        print('')
        print('  The split is DERIVED, never hand-held. Re-run out/RUNME.sh, then')
        print('  copy out/geometry.md\'s result into latency_gate.py, minus the')
        print('  NO_RED_DEMO ids -- and say in the commit which bar moved and why.')
        print('=' * 78)
        raise SystemExit(1)
    print('geometry split check: latency_gate.py GATED(%d)/REPORTED(%d) EQUAL the'
          % (len(c['GATED']), len(c['REPORTED'])))
    print('split just derived from %d geometries (%s), NO_RED_DEMO(%d) applied.'
          % (len(names), ', '.join(names), len(no_demo)))


def main():
    files = sorted(glob.glob(os.path.join(OUT, 'geo_*.txt')))
    if not files:
        raise SystemExit('no out/geo_*.txt -- run out/RUNME.sh first')
    geos = {}
    for f in files:
        g = os.path.basename(f)[4:-4]
        geos[g] = read(f)
    names = sorted(geos, key=lambda x: (x != 'canonical', x))
    keys = sorted(set().union(*[set(v) for v in geos.values()]))

    rows = []
    for k in keys:
        verds = [geos[g].get(k, '-') for g in names]
        stable = len(set(verds)) == 1 and '-' not in verds
        rows.append((k, verds, stable))

    by_id = {}
    for (bid, subj), verds, stable in rows:
        by_id.setdefault(bid, []).append(stable)
    gated = sorted(b for b, ss in by_id.items() if all(ss))
    reported = sorted(b for b, ss in by_id.items() if not all(ss))

    lines = []
    lines.append('# Geometry study -- which OBJ-D latency bars may be gated (U14)')
    lines.append('')
    lines.append('GENERATED by `geometry_split.py` from `out/geo_*.txt`. Do not hand-edit.')
    lines.append('')
    lines.append('Geometries scored: ' + ', '.join(names) +
                 '  (integers = `rig_checks.phase_drops(name, GEO, T)`, U33\'s corrected')
    lines.append('count- and duration-preserving rotation; no interval over t=0).')
    lines.append('Seeds, offers, rigs, hold policy and bar arithmetic identical in all runs;')
    lines.append('the ONLY thing that varies is the stall phase of the spotty archetypes.')
    lines.append('')
    lines.append('| bar | subject | ' + ' | '.join(names) + ' | geometry-stable |')
    lines.append('|---|---|' + '---|' * (len(names) + 1))
    for (bid, subj), verds, stable in rows:
        lines.append('| `%s` | %s | %s | %s |'
                     % (bid, subj, ' | '.join(verds), 'YES' if stable else '**NO**'))
    lines.append('')
    lines.append('## Result')
    lines.append('')
    lines.append('```python')
    lines.append('GATED = (' + ', '.join("'%s'" % b for b in gated) + ')')
    lines.append('REPORTED = (' + ', '.join("'%s'" % b for b in reported) + ')')
    lines.append('```')
    lines.append('')
    lines.append('A bar id is GATED only when EVERY one of its checks kept the same verdict')
    lines.append('on every geometry. One flip anywhere in the id demotes the whole id: the')
    lines.append('gate classifies by id, so a mixed id would gate a coin flip under another')
    lines.append('check\'s name.')
    lines.append('')
    lines.append('**Named non-coverage.** %d rotations is a small sample. It does not show a'
                 % (len(names) - 1))
    lines.append('surviving bar is stable -- only that it did not flip on these draws. U33\'s')
    lines.append('own conclusion applies unchanged: the geometry axis is sampled by PHASE')
    lines.append('ONLY; stall COUNT and DURATION remain the hand-placed canonical values, so')
    lines.append('this is a lower bound on the true spread.')
    open(os.path.join(OUT, 'geometry.md'), 'w', encoding='utf-8', newline='\n').write(
        '\n'.join(lines) + '\n')
    print('\n'.join(lines[-12:]))
    print('\nwrote out/geometry.md  (%d checks, %d geometries)' % (len(rows), len(names)))
    check_gate(gated, reported, names)


if __name__ == '__main__':
    main()
