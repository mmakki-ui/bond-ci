#!/usr/bin/env python3
"""citation_check.py -- the gate that makes a ROTTING citation unrepresentable. U50a.

WHY THIS EXISTS, measured. U50a inserted 60 comment lines into `deploy/p5/bond-xctl`
and 16 header lines into `deploy/p5/bond.dag`. Every pre-existing `bond-xctl:N` /
`bond.dag:N` citation in the repo then pointed at the wrong line -- twelve sites in
`orchestration/bond_model.py`, FOUR of them inside `check()` strings that the CI-gated
`recon-model` job PRINTS on every run. Nothing noticed, including the unit that caused
it. That is the U48 defect class (a fact recorded in one place, drifted in another)
applied to line numbers.

WHY NOT "RENUMBER AND MOVE ON". Renumbering restores today's truth and restores the
defect with it: the next comment inserted above the target breaks it again, silently,
and the next unit is the one that gets blamed. A line number into a file under active
edit is not a citation, it is a countdown. So this gate does not check that line
numbers are CURRENT -- it refuses to let an unpinned one exist on a surface that is
printed by CI or shipped to a box.

THE TWO RULES

  R1  NO UNPINNED LINE NUMBERS on a gated surface.
      `bond-xctl:796`                      -> FAIL
      `bond-xctl `guard_installed``        -> the fix (a symbol survives insertion)
      `ffd5857:bond-xctl:736`              -> allowed: a REV-PINNED citation is a dated
                                              record of a file as it was, it cannot rot
                                              by construction, and it is how a
                                              pre-change fact stays citable.

  R2  A SYMBOL ANCHOR MUST RESOLVE. `<artifact> `symbol`` -- an artifact name followed
      by a backticked token -- asserts that token occurs in that artifact. Rename the
      function and the citation goes red, which is the property a line number never had.
      Without R2, R1 alone would trade a rotting number for a rotting name.

WHAT THIS DOES NOT CHECK, said plainly rather than left to be discovered:
  * Only the FIRST backticked token after an artifact name is treated as the anchor.
    A second symbol in the same parenthesis is prose to this gate.
  * It proves the anchor EXISTS in the file, never that the anchored text SUPPORTS the
    claim around it. No mechanical check can do the second.
  * SCOPE is deliberately narrow: the files a CI job prints or a box executes. Dated
    review artifacts under docs/ are correct AT THEIR VINTAGE and rewriting them would
    falsify the record, so docs are scanned only in the non-gating `--report` mode.
  * A rev-pinned citation is not verified against that rev (no git call here); pinning
    is trusted, and it is trustworthy because a pin is a claim about a frozen object.
  * This file is NOT in SCOPE and must not be added to it: the examples above are the
    anti-pattern written out on purpose, and a gate that fails on its own error messages
    teaches the next reader to widen the stoplist instead of fixing the citation.

SELF-TEST (`--selftest`) proves teeth against BOTH failure modes rather than asserting
them: it re-introduces a bare `bond-xctl:123` (R1 must fire) and renames a cited shell
function (R2 must fire), each on a copy of the tree, and requires the clean tree green.

USAGE
  python orchestration/citation_check.py            # gate: SCOPE only, exit 1 on any hit
  python orchestration/citation_check.py --report   # + docs/, informational
  python orchestration/citation_check.py --selftest # prove the gate bites
"""
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# The artifacts whose internals get cited, each with the directory its bare name
# resolves under. `main.go` was added in round 3 (the U50a review): two gated
# surfaces cited it by line number and BOTH had already rotted -- `main.go:66,308`
# for the AGG_W default (actual: 70, 312, inside `runClient`/`runServer`) and
# `main.go:540` for parseW (actual: 544) -- moved by U7/U36a landing in that file.
# The same defect class this gate was built for, one directory over.
# U124: bond-xctl became a bin plus five sourced libraries, and every symbol
# anchor that named a leaf moved with the leaf. The libraries have to be
# ARTIFACTS or those ELEVEN anchors would stop being checked by this gate the
# moment they were re-pointed -- coverage silently dropping from 16 to 5 while
# the bar stayed green. 16 -> 5 is MEASURED, not estimated: revert this file to
# 949472a and the model gate prints "5 symbol anchors". The first cut of this
# comment guessed 7 and a review guessed 6; both were wrong, and the row was
# corrected while this line was not.
# They are also in SCOPE below: they ship to a box, so a stale citation inside
# one is a false statement made by a running program.
ARTIFACTS = {
    "bond-xctl":     "deploy/p5",
    "xctl-lock.sh":    "deploy/p5/lib",
    "xctl-probe.sh":   "deploy/p5/lib",
    "xctl-actions.sh": "deploy/p5/lib",
    "xctl-shape.sh":   "deploy/p5/lib",
    "xctl-dag.sh":     "deploy/p5/lib",
    "bondctl":       "deploy/p5",
    "bond.dag":      "deploy/p5",
    "bond-ecod":     "deploy/p5",
    "bond-watchdog": "deploy/p5",
    "97-bond":       "deploy/p5",
    "main.go":       "p4-bondagg/daemon",
}
ART_DIR = "deploy/p5"

# SCOPE = surfaces where a stale citation is a false statement made by a RUNNING program
# (a CI job prints it) or shipped to a box. Not documentation.
SCOPE = [
    "orchestration/bond_model.py",       # recon-model prints these strings
    "orchestration/ecosim/p5/run.sh",    # recon-ecosim prints these strings
    "deploy/p5/bond-xctl",
    "deploy/p5/lib/xctl-lock.sh",
    "deploy/p5/lib/xctl-probe.sh",
    "deploy/p5/lib/xctl-actions.sh",
    "deploy/p5/lib/xctl-shape.sh",
    "deploy/p5/lib/xctl-dag.sh",
    "deploy/p5/bondctl",
    "deploy/p5/bond.dag",
    "deploy/p5/bond-ecod",
    "deploy/p5/bond-watchdog",
    "deploy/p5/97-bond",
]

REPORT_ONLY = [
    "docs/HANDOFF.md", "docs/ROADMAP.md", "docs/INTENT.md",
    "docs/GROUNDING.md", "docs/GOAL.md", "docs/deploy-p5-runbook.md",
    "docs/knowledge/settled-results.md",
]

_NAMES = "|".join(re.escape(a) for a in ARTIFACTS)
# The lookbehind keeps a name from matching inside a longer word ("domain.go" must
# not match as "main.go"); '/' (a dir prefix) and ':' (a rev pin) still precede.
_LB = r'(?<![A-Za-z0-9_-])'
# R1: `[<dir>/]<artifact>:<digits>`. A leading `<hex>:` is a REV PIN and is allowed, so
# the character immediately before the path is inspected rather than matched away.
CIT = re.compile(r'(?P<dir>[A-Za-z0-9_./-]*/)?' + _LB + r'(?P<name>' + _NAMES + r'):(?P<a>\d+)')
# R2: an artifact name, then (across comment leaders, quotes and line breaks) a
# backticked token. The gap class is what lets an anchor wrap a Python string join.
ANCHOR = re.compile(_LB + r'(?P<name>' + _NAMES + r')(?P<gap>[\s#"\'\\]{0,40})`(?P<sym>[A-Za-z_][A-Za-z0-9_]*)`')
IDENT_OK = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')


def _read(path):
    with open(path, encoding='utf-8', errors='replace') as fh:
        return fh.read()


def _lineno(text, pos):
    return text.count('\n', 0, pos) + 1


def scan(root, files):
    """(unpinned, unresolved, pinned, resolved) findings for `files` under `root`."""
    cache = {}

    def artifact(rel_dir, name):
        key = (rel_dir or ARTIFACTS[name]).rstrip('/') + '/' + name
        if key not in cache:
            p = os.path.join(root, key)
            cache[key] = _read(p) if os.path.exists(p) else None
        return cache[key], key

    unpinned, unresolved, pinned, resolved = [], [], [], []
    for rel in files:
        p = os.path.join(root, rel)
        if not os.path.exists(p):
            continue
        text = _read(p)

        for m in CIT.finditer(text):
            start = m.start('dir') if m.group('dir') else m.start('name')
            if start > 0 and text[start - 1] == ':':
                pinned.append((rel, _lineno(text, m.start()), m.group(0)))
            else:
                unpinned.append((rel, _lineno(text, m.start()),
                                 "%s:%s" % (m.group('name'), m.group('a'))))

        for m in ANCHOR.finditer(text):
            body, key = artifact(None, m.group('name'))
            if body is None:
                continue
            sym = m.group('sym')
            if re.search(r'(?<![A-Za-z0-9_])' + re.escape(sym) + r'(?![A-Za-z0-9_])', body):
                resolved.append((rel, _lineno(text, m.start()), key, sym))
            else:
                unresolved.append((rel, _lineno(text, m.start()), key, sym))
    return unpinned, unresolved, pinned, resolved


def report(root, files, label, gating):
    unpinned, unresolved, pinned, resolved = scan(root, files)
    print("--- %s: %d symbol anchors resolved, %d rev-pinned, "
          "%d UNPINNED line numbers, %d UNRESOLVED anchors"
          % (label, len(resolved), len(pinned), len(unpinned), len(unresolved)))
    for rel, ln, cit in unpinned:
        print("UNPINNED   %s:%d cites `%s` -- re-anchor to a symbol "
              "(`%s `funcname``) or pin the rev (`<sha>:%s`)"
              % (rel, ln, cit, cit.split(':')[0], cit))
    for rel, ln, key, sym in unresolved:
        print("UNRESOLVED %s:%d anchors on `%s` in %s, which does not contain it"
              % (rel, ln, sym, key))
    return (unpinned + unresolved) if gating else []


def _copy_tree(dst):
    for rel in set(SCOPE) | {d + "/" + a for a, d in ARTIFACTS.items()}:
        src = os.path.join(ROOT, rel)
        if not os.path.exists(src):
            continue
        out = os.path.join(dst, rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        shutil.copyfile(src, out)


def selftest():
    """Two mutations, one per rule. Both must be caught; the clean tree must be green."""
    u0, r0, _p, ok0 = scan(ROOT, SCOPE)
    print("SELFTEST clean tree: %d anchors resolved, %d unpinned, %d unresolved"
          % (len(ok0), len(u0), len(r0)))
    if u0 or r0:
        print("SELFTEST INCONCLUSIVE: the real tree is already red")
        return 1
    rc = 0
    tmp = tempfile.mkdtemp(prefix="citcheck")
    try:
        # R1 -- someone reintroduces a bare line number on a CI-printed surface.
        _copy_tree(tmp)
        victim = os.path.join(tmp, "orchestration/bond_model.py")
        with open(victim, encoding='utf-8') as fh:
            body = fh.read()
        with open(victim, "w", encoding='utf-8', newline='\n') as fh:
            fh.write("# reintroduced: bond-xctl:123\n" + body)
        u1, _r1, _p1, _o1 = scan(tmp, SCOPE)
        print("SELFTEST R1 (bare `bond-xctl:123` reintroduced): %d unpinned" % len(u1))
        if len(u1) < 1:
            print("SELFTEST FAIL: R1 did not bite"); rc = 1

        # R2 -- someone renames a cited shell function and forgets the citations.
        shutil.rmtree(tmp, ignore_errors=True)
        _copy_tree(tmp)
        # U124: `build_agg_env` lives in the actions library now. Mutating the bin
        # would rename ZERO occurrences and R2 would report "did not bite" -- a
        # selftest that passes because it mutated nothing is the failure this
        # selftest exists to catch, one level up.
        victim = os.path.join(tmp, ART_DIR + "/lib/xctl-actions.sh")
        with open(victim, encoding='utf-8') as fh:
            body = fh.read()
        n = body.count("build_agg_env")
        with open(victim, "w", encoding='utf-8', newline='\n') as fh:
            fh.write(body.replace("build_agg_env", "build_sources_env"))
        _u2, r2, _p2, _o2 = scan(tmp, SCOPE)
        print("SELFTEST R2 (`build_agg_env` renamed, %d occurrences): %d unresolved anchors"
              % (n, len(r2)))
        if len(r2) < 1:
            print("SELFTEST FAIL: R2 did not bite"); rc = 1

        if rc == 0:
            print("SELFTEST PASS: both rules bite, clean tree green")
        return rc
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    args = sys.argv[1:]
    if "--selftest" in args:
        return selftest()
    root = args[args.index("--root") + 1] if "--root" in args else ROOT
    bad = report(root, SCOPE, "GATED (CI-printed and shipped surfaces)", gating=True)
    if "--report" in args:
        report(root, REPORT_ONLY,
               "REPORT ONLY (docs; dated records are correct at their vintage)", gating=False)
    if bad:
        print("FAIL: %d rotting citation(s) on a gated surface" % len(bad))
        return 1
    print("PASS: no rotting citations on a gated surface")
    return 0


if __name__ == "__main__":
    sys.exit(main())
