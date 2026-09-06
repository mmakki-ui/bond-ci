#!/usr/bin/env python3
# =============================================================================
# eq1_citecheck.py -- U9 / EQ-1.  THE CITATION GATE.
#
# WHY THIS EXISTS.  U9's first round shipped 18 `file:line` citations into files
# it does not own.  Ten of them were WRONG on `dev` -- the tree that merges --
# because U35 landed a 52-line import-pin header on reserved_composite.py the
# same day, shifting every line below it by exactly +52.  Nothing detected that:
# a line number is a claim about a file that some other unit is free to edit, and
# no gate ever read it.  Fixing the ten numbers would have fixed the symptom and
# left the mechanism intact -- the eleventh citation would rot on the next merge.
#
# THE FIX IS TO STOP CITING LINE NUMBERS.  A citation in U9's files is an ANCHOR:
#
#     reserved_composite.py@'while len(s.fifo) * PKT_KB > s.maxq_kb'
#
# the exact source text that establishes the claim.  An anchor survives any edit
# above it, and it carries its own evidence -- a reader sees the code, not a
# coordinate.  This script resolves every anchor against the tree and fails if
# one does not appear, and it BANS bare FILE-COLON-LINE citations in the files U9
# owns so the old form cannot come back.
#
#   python eq1_citecheck.py                # resolve against the working tree
#   python eq1_citecheck.py --git-ref dev  # resolve against another tree
#   python eq1_citecheck.py --selftest     # prove the gate has teeth
#
# --git-ref is the point: `--git-ref dev` is the exact check that would have
# caught round 1, and it is what the merge runs.
# =============================================================================
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))

# STRICT -- U9 owns these.  Every citation must be an anchor; a bare file:line is
# a failure.
STRICT = [
    'p4-bondagg/sim/eq1/eq1_record.py',
    'p4-bondagg/sim/eq1/eq1_selfcheck.py',
    'p4-bondagg/sim/eq1/eq1_citecheck.py',
    'p4-bondagg/sim/eq1/README.md',
    'p4-bondagg/daemon/eq1_replay_test.go',
    'p4-bondagg/daemon/eq1_free_test.go',
]

# ANCHORS-ONLY -- shared files.  Any anchor found here is resolved; bare
# file:line citations belong to whichever unit wrote them and are not U9's to
# rewrite, so they are counted and reported, not failed.
SHARED = [
    'docs/ROADMAP.md',
    '.github/workflows/emulator-gate.yml',
]

# NAME@<quoted anchor text>, where NAME is a basename or enough of a path
CITE = re.compile(r"([A-Za-z0-9_][A-Za-z0-9_./-]*\.(?:py|go|sh|yml))@'([^']+)'")
# the banned form, and its relative continuation -- an open paren, a colon, a digit
BARE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*\.(?:py|go)(:\d)")
BARE_REL = re.compile(r"\(:\d")

SKIP_DIRS = {'.git', '.claude', 'node_modules', '__pycache__', 'traces'}


def index_tree():
    """basename -> [repo-relative paths].  Built once, from the working tree."""
    idx = {}
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if not fn.endswith(('.py', '.go', '.sh', '.yml')):
                continue
            rel = os.path.relpath(os.path.join(dirpath, fn), ROOT).replace('\\', '/')
            idx.setdefault(fn, []).append(rel)
    return idx


def resolve(name, idx):
    """A citation names a file by basename, or by enough of a path to be unique."""
    if '/' in name:
        hits = [p for p in sum(idx.values(), []) if p.endswith(name)]
    else:
        hits = idx.get(name, [])
    return sorted(set(hits))


class Tree(object):
    """The tree citations are resolved against: the working copy, or a git ref."""

    def __init__(self, ref=None):
        self.ref = ref
        self.cache = {}

    def read(self, rel):
        if rel in self.cache:
            return self.cache[rel]
        if self.ref:
            p = subprocess.run(['git', '-C', ROOT, 'show', '%s:%s' % (self.ref, rel)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            txt = None if p.returncode else p.stdout.decode('utf-8', 'replace')
        else:
            full = os.path.join(ROOT, rel)
            txt = None
            if os.path.exists(full):
                with open(full, 'r', encoding='utf-8', errors='replace') as fh:
                    txt = fh.read()
        self.cache[rel] = txt
        return txt


def scan_text(text, path, strict, idx, tree, out):
    """Returns (n_citations, [violations])."""
    bad = []
    n = 0
    for lineno, line in enumerate(text.splitlines(), 1):
        if strict:
            m = BARE.search(line)
            if m:
                bad.append('%s:%d BARE LINE CITATION %r -- use file@\'anchor text\''
                           % (path, lineno, line.strip()[:96]))
            if BARE_REL.search(line):
                bad.append('%s:%d RELATIVE LINE CITATION %r -- use file@\'anchor text\''
                           % (path, lineno, line.strip()[:96]))
        for name, anchor in CITE.findall(line):
            n += 1
            hits = resolve(name, idx)
            if not hits:
                bad.append('%s:%d cites %s -- no such file in the tree' % (path, lineno, name))
                continue
            if len(hits) > 1:
                bad.append('%s:%d cites %s -- AMBIGUOUS, resolves to %s; write enough '
                           'of the path to disambiguate' % (path, lineno, name, hits))
                continue
            rel = hits[0]
            body = tree.read(rel)
            if body is None:
                bad.append('%s:%d cites %s -- not present in the tree under check'
                           % (path, lineno, rel))
                continue
            at = [i for i, l in enumerate(body.splitlines(), 1) if anchor in l]
            if not at:
                bad.append('%s:%d ANCHOR NOT FOUND in %s: %r'
                           % (path, lineno, rel, anchor))
                continue
            out.append('  %-46s -> %s:%s' % ('%s:%d' % (os.path.basename(path), lineno),
                                             rel, ','.join(str(x) for x in at[:3])))
    return n, bad


def selftest():
    """The gate's own negative control: both rules must FIRE on a planted defect."""
    idx = index_tree()
    tree = Tree()
    out = []
    rc = 0

    # Built by concatenation so this file does not contain the banned form it
    # bans -- the gate is not exempt from itself.
    planted = 'cited at reserved_composite.py' + ':240-241, the banned form'
    _, bad = scan_text(planted, '<selftest-bare>', True, idx, tree, out)
    if not any('BARE LINE CITATION' in b for b in bad):
        print('SELFTEST FAIL: a bare file:line citation was NOT reported')
        rc = 1
    else:
        print('selftest ok  bare file:line citation is reported')

    q = chr(39)
    planted = ('cited at reserved_composite.py@' + q +
               'this text is not in that file at all' + q)
    _, bad = scan_text(planted, '<selftest-anchor>', True, idx, tree, out)
    if not any('ANCHOR NOT FOUND' in b for b in bad):
        print('SELFTEST FAIL: an unresolvable anchor was NOT reported')
        rc = 1
    else:
        print('selftest ok  an unresolvable anchor is reported')

    planted = ('cited at reserved_composite.py@' + q +
               'while len(s.fifo) * PKT_KB > s.maxq_kb' + q)
    n, bad = scan_text(planted, '<selftest-good>', True, idx, tree, out)
    if n != 1 or bad:
        print('SELFTEST FAIL: a good anchor was reported: %s' % bad)
        rc = 1
    else:
        print('selftest ok  a resolvable anchor passes')
    return rc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--git-ref', default=None,
                    help='resolve citations against this git ref instead of the '
                         'working tree (e.g. --git-ref dev -- the merge target)')
    ap.add_argument('--selftest', action='store_true')
    ap.add_argument('-v', '--verbose', action='store_true')
    a = ap.parse_args()

    if a.selftest:
        return selftest()

    idx = index_tree()
    tree = Tree(a.git_ref)
    where = a.git_ref or 'working tree'
    out = []
    bad = []
    total = 0
    for rel, strict in [(p, True) for p in STRICT] + [(p, False) for p in SHARED]:
        full = os.path.join(ROOT, rel)
        if not os.path.exists(full):
            if strict:
                bad.append('%s: missing from the working tree' % rel)
            else:
                # The public CI mirror publishes no docs/ (the DDNS host and the
                # server WAN IP live there), so a shared file can be legitimately
                # absent. Said out loud rather than skipped in silence.
                print('SKIP %s -- not present in this tree' % rel)
            continue
        with open(full, 'r', encoding='utf-8', errors='replace') as fh:
            text = fh.read()
        n, b = scan_text(text, rel, strict, idx, tree, out)
        total += n
        bad.extend(b)

    if a.verbose:
        print('\n'.join(out))
    print('EQ1 CITECHECK: %d anchor citations resolved against %s' % (total, where))
    if bad:
        print('FAIL -- %d violation(s):' % len(bad))
        for b in bad:
            print('  ' + b)
        return 1
    print('OK -- every anchor resolves; no bare line citations in the files U9 owns')
    return 0


if __name__ == '__main__':
    sys.exit(main())
