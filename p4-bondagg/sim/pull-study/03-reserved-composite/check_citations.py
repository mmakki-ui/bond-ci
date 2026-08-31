#!/usr/bin/env python3
"""check_citations.py -- U10.  Make a rotting citation a MECHANICAL failure.

WHY THIS EXISTS.  Three separate `file:line` citations shipped by U10's own probes
pointed at the wrong line on the branch that merges.  One was broken by the very
commit that wrote it: the commit inserted 14 lines above `PAIRED` in
`.github/scripts/rig_paired_gate.py` and three places in the same commit still cited
the pre-insertion number -- one of them a `print()`, so every future run reproduced
the wrong number into the artifact.  A second cited `docs/HANDOFF.md:294`, correct
only on this branch and 7 lines off on `dev`.  A third cited a BLANK line.

None of that is catchable by reading and all of it is catchable by a program.  The
cause is not carelessness: a bare line number is a claim about a MOVING tree, and
nothing was checking it.  So:

  RULE 1  A bare `path:line` citation is valid only if the cited line is NON-BLANK
          and BYTE-IDENTICAL on the working tree and on the merge target (default
          `dev`).  A line that means two different things on two trees is not a
          citation, it is a coincidence.
  RULE 2  A citation into a file that moves should carry no line number at all.
          The anchored form `grep -n 'RE' path` is checked instead: the pattern must
          match, and match the SAME NUMBER of times, on both trees.

WHAT THIS CANNOT DO, MEASURED RATHER THAN ASSUMED.  It checks that a citation
RESOLVES.  It cannot check that the line it resolves to MEASURES the claim -- that is
a human read.  The sharp case, demonstrated by injecting both defects into a U10 row
and re-running: an anchor that no longer matches (`^PAIRED_NOPE`) is CAUGHT, while an
off-by-one onto a neighbouring line that happens to be non-blank and identical on both
trees (`reserved_composite.py:518` -> `:519`) is NOT.  Rule 1 can only see a citation
that stopped resolving, never one that resolves to the wrong thing.  That is the whole
reason Rule 2 exists, and why a citation into a file anyone is still editing should
carry no line number.  Bare line numbers are left in place here only for the pinned
rig files (`reserved_composite.py`, `ackclock_sim.py`, `nsched_model.py`), which U35's
`rig_pin` exists to hold still, and Rule 1 fires the moment one of them diverges from
the merge target.

USAGE   python check_citations.py [--ref=dev] [--verbose]
        exit 0 = every citation resolves;  exit 1 = at least one does not.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))

#: files whose citations are checked: the two U10 probes, the artifacts they print,
#: and the ROADMAP sections that restate them.
SCANNED = [
    '.github/scripts/rig_paired_gate.py',
    'p4-bondagg/sim/pull-study/03-reserved-composite/rig_geometry.py',
    'p4-bondagg/sim/pull-study/03-reserved-composite/rig_geometry.txt',
    'p4-bondagg/sim/pull-study/03-reserved-composite/rig_constants.py',
    'p4-bondagg/sim/pull-study/03-reserved-composite/rig_constants.txt',
    'docs/ROADMAP.md',
]

#: repo-relative prefixes a bare basename citation may resolve under, most specific
#: first.  A citation that resolves nowhere is a failure, not a skip.
SEARCH = [
    'p4-bondagg/sim/pull-study/03-reserved-composite',
    'p4-bondagg/sim/pull-study/02-ackclock',
    'p4-bondagg/sim',
    'p4-bondagg/daemon',
    'p4-bondagg/server',
    'docs/knowledge/design/research',
    'docs/knowledge/design',
    'docs/knowledge/decisions',
    'docs',
    '.github/scripts',
    '',
]

#: OWNERSHIP.  U10 is answerable for its own citations, not for the whole repo's.
#: A failure inside a U10-owned region is FATAL; one outside is printed as
#: PRE-EXISTING and counted, never silently dropped -- see U10d in ROADMAP.
#: In ROADMAP.md, owned = inside a `## U10 ...` section, or a table row whose
#: first cell names U10.
def owned(src, line, heading):
    if src != 'docs/ROADMAP.md':
        return True
    if heading.startswith('U10'):
        return True
    return bool(re.match(r'\|\s*\**U10', line))

#: `path:line` or `path:line-line`.  Path may be bare (`ackclock_sim.py`) or
#: repo-relative (`.github/scripts/rig_paired_gate.py`).
CITE = re.compile(r'(?<![\w./-])((?:[\w.-]+/)*[\w.-]+\.(?:py|md|go|sh|txt|yml))'
                  r':(\d+)(?:-(\d+))?(?![\w.])')

#: the anchored form: grep -n 'RE' path   (either quote style, so a pattern may
#: itself contain a quote -- `grep -n "m2\['sshare'\]" highn_battery.py`).
ANCHOR = re.compile(r"""grep -n (?:'([^']+)'|"([^"]+)") """
                    r"""((?:[\w.-]+/)*[\w.-]+\.(?:py|md|go|sh|txt|yml))""")

#: this file's own docstring quotes the defects it was written to catch.
IGNORE_FILES = ('check_citations.py',)


def sh(args):
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True,
                          encoding='utf-8', errors='replace')


def worktree_lines(path):
    p = os.path.join(ROOT, path)
    if not os.path.isfile(p):
        return None
    with open(p, 'r', encoding='utf-8', errors='replace') as f:
        return f.read().split('\n')


def ref_lines(ref, path):
    r = sh(['git', 'show', '%s:%s' % (ref, path)])
    if r.returncode != 0:
        return None
    return r.stdout.split('\n')


def resolve(cited, present):
    """Map a cited path onto a real repo path.  `present` = set of tracked paths."""
    cited = cited.replace('\\', '/')
    if cited in present:
        return cited
    for pre in SEARCH:
        cand = ('%s/%s' % (pre, cited)) if pre else cited
        if cand in present:
            return cand
    base = cited.rsplit('/', 1)[-1]
    hits = [p for p in present if p.rsplit('/', 1)[-1] == base]
    return hits[0] if len(hits) == 1 else None


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass
    ref, verbose = 'dev', False
    for a in sys.argv[1:]:
        if a.startswith('--ref'):
            ref = a.split('=', 1)[1] if '=' in a else 'dev'
        elif a in ('-v', '--verbose'):
            verbose = True

    r = sh(['git', 'ls-tree', '-r', '--name-only', 'HEAD'])
    if r.returncode != 0:
        print('FATAL: not a git tree at %s' % ROOT)
        return 2
    present = set(r.stdout.split('\n'))

    print('citation check -- working tree vs merge target `%s` (%s)'
          % (ref, sh(['git', 'rev-parse', '--short', ref]).stdout.strip()))
    print('  RULE 1  path:line must be NON-BLANK and IDENTICAL on both trees')
    print('          (a path:a-b RANGE must be identical over the range and not all blank)')
    print('  RULE 2  anchored `grep -n RE path` must match equally on both trees')
    print('  U10-owned failures are FATAL.  Failures elsewhere in ROADMAP.md predate this')
    print('  unit; they are listed, counted and owned by U10d, not silently dropped.')
    print()

    wcache, rcache = {}, {}
    own_f, pre_f, checked = [], [], 0

    def load(path):
        if path not in wcache:
            wcache[path] = worktree_lines(path)
            rcache[path] = ref_lines(ref, path)
        return wcache[path], rcache[path]

    for src in SCANNED:
        text = worktree_lines(src)
        if text is None:
            own_f.append((src, 0, 'scanned file does not exist'))
            continue
        heading = ''
        for ln0, line in enumerate(text, 1):
            if src == 'docs/ROADMAP.md' and line.startswith('## '):
                heading = line[3:].strip().lstrip('*').strip()
            bucket = own_f if owned(src, line, heading) else pre_f

            def bad(why):
                bucket.append((src, ln0, why))

            for m in CITE.finditer(line):
                cited, a, b = m.group(1), int(m.group(2)), m.group(3)
                if cited.rsplit('/', 1)[-1] in IGNORE_FILES:
                    continue
                path = resolve(cited, present)
                if path is None:
                    bad('cites %s:%s -- resolves to no unique file in the tree'
                        % (cited, a))
                    continue
                W, R = load(path)
                hi = int(b) if b else a
                checked += 1
                if R is None:
                    bad('%s does not exist on %s' % (cited, ref))
                    continue
                if not W or hi > len(W):
                    bad('%s:%s is past end of file on the working tree'
                        % (cited, b or a))
                    continue
                if hi > len(R):
                    bad('%s:%s is past end of file on %s' % (cited, b or a, ref))
                    continue
                seg_w = [W[n - 1] for n in range(a, hi + 1)]
                seg_r = [R[n - 1] for n in range(a, hi + 1)]
                if not any(x.strip() for x in seg_w):
                    bad('%s:%s is %s' % (cited, b or a,
                                         'a BLANK line' if not b else 'entirely blank'))
                    continue
                diff = [n for n, (x, y) in enumerate(zip(seg_w, seg_r), a)
                        if x.rstrip() != y.rstrip()]
                if diff:
                    n = diff[0]
                    bad('%s:%d DIFFERS between the trees'
                        '\n        here : %s\n        %-5s: %s'
                        % (cited, n, W[n - 1].strip()[:76], ref, R[n - 1].strip()[:76]))
                elif verbose:
                    print('  ok   %s:%s  %s' % (cited, b or a, seg_w[0].strip()[:64]))

            for m in ANCHOR.finditer(line):
                pat, cited = (m.group(1) or m.group(2)), m.group(3)
                path = resolve(cited, present)
                if path is None:
                    bad('anchored grep on %s -- no such file' % cited)
                    continue
                W, R = load(path)
                try:
                    rx = re.compile(pat)
                except re.error as e:
                    bad('anchor %r is not a regex: %s' % (pat, e))
                    continue
                checked += 1
                nw = sum(1 for L in (W or []) if rx.search(L))
                nr = sum(1 for L in (R or []) if rx.search(L))
                if nw == 0:
                    bad('anchor %r matches NOTHING in %s here' % (pat, cited))
                elif R is None:
                    bad('%s does not exist on %s' % (cited, ref))
                elif nw != nr:
                    bad('anchor %r matches %d here and %d on %s in %s'
                        % (pat, nw, nr, ref, cited))
                elif verbose:
                    print('  ok   grep %r %s -> %d line(s) on both trees'
                          % (pat, cited, nw))

    print('  %d citations checked across %d files' % (checked, len(SCANNED)))
    if pre_f:
        print()
        print('  PRE-EXISTING, NOT U10-owned (%d) -- ROADMAP rows belonging to other units.'
              % len(pre_f))
        print('  Reported, not fixed here, and not fatal.  Owner: U10d.')
        for (src, ln0, why) in pre_f:
            print('    %s:%d  %s' % (src, ln0, why.split('\n')[0]))
    print()
    if not own_f:
        print('  EVERY U10-OWNED CITATION RESOLVES.  (Resolution only -- whether a line')
        print('  MEASURES its claim is a human read and is NOT checked here.)')
        return 0
    for (src, ln0, why) in own_f:
        print('  FAIL  %s:%d' % (src, ln0))
        print('        %s' % why)
    print()
    print('  %d U10-owned citation(s) do not resolve.' % len(own_f))
    return 1


if __name__ == '__main__':
    sys.exit(main())
