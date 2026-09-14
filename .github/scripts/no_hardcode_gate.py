#!/usr/bin/env python3
"""Fail the build on hardcoded topology in SHIPPED code. U36b.

WHY THIS EXISTS
---------------
"N-generic: no privileged path, no 2-source assumption, in code OR prose" is this project's oldest
and most absolute rule. It is in the goal-post, in every agent brief, and in the review checklist.
It has been broken continuously anyway:

    p4-bondagg/daemon/main.go:55   env("AGG_PATHS", "eth1,usb0")     <- sets N itself
    p4-bondagg/daemon/main.go:300  env("AGG_PATHS", "eth1,usb0")
    p4-bondagg/daemon/main.go:70   env("AGG_W", "20000,15000")
    p4-bondagg/daemon/main.go:312  env("AGG_W", "20000,15000")

Those four survived U2, U6 (the N-generic aggregate), U19 (exhaustive to N=8), U36's own pass at
exactly this constant, and several reviews whose briefs quoted the rule. They surfaced only when a
third WAN source was added to the client and `eth1,usb0` stopped being a latent 2-shaped constant
and became a wrong description of the actual box.

The violation log already draws the lesson: a rule that only INFORMS gets broken; a rule that BLOCKS
gets followed. Every rule that stuck in this project became a gate. This is that gate.

WHAT IT FLAGS
-------------
1. INTERFACE NAME LITERAL - "eth1", "usb0", "wwan0", "wgclient1" used as a value in shipped code.
   An interface name in code is a claim about one box on one day.
2. N-SHAPED DEFAULT       - a comma-joined list of two or more values used as a fallback, e.g.
   "eth1,usb0" or "20000,15000". Worse than a lone constant, because it also encodes a COUNT.

WHAT IT DOES NOT FLAG, AND WHY
------------------------------
Test fixtures and simulator shims MUST name interfaces - that is the data the discovery logic is
tested against, and demanding they be generic would make them untestable. Those are allowlisted by
path, each with its reason. An allowlist entry is a claim that the file does not ship; if that stops
being true the entry is wrong. Keep the list short.

VALIDATE THE GATE ITSELF
------------------------
--selftest seeds each defect class into a scratch tree and asserts the gate reddens, and seeds the
same defect into an allowlisted path and asserts it stays silent. A gate that cannot fail is
theater, and four gates in this project have already passed while deliberately weakened.

    python .github/scripts/no_hardcode_gate.py            # scan; exit 1 on any finding
    python .github/scripts/no_hardcode_gate.py --selftest # prove it catches each class
"""
import os
import re
import sys

# Directories whose contents SHIP to a router. Everything here is held to the rule.
SHIPPED = [
    "p4-bondagg/daemon",
    "p4-bondagg/server",
    "deploy/p5",
]

# Path fragments that are NOT shipped, each with the reason it is exempt.
ALLOW = {
    "_test.go":     "Go tests -- a test must be able to name the interface it is testing.",
    "/test":        "test scaffolding.",
    "ecosim":       "the Layer-2 shim battery; its fixtures ARE interface names by construction.",
    "gl-discovery": "discovery fixtures: the table of boxes the discovery logic is tested against.",
    "/sim/":        "simulator and rig code, not shipped to a box.",
    "diagnostics":  "hand-run bench scripts, not part of the package.",
    "README":       "prose.",
    ".md":          "prose.",
}

EXT = (".go", ".sh", ".dag", ".py")

# an interface name used as a literal
IFACE = re.compile(r'"[^"\n]*\b((?:eth|usb|wwan|wlan|rmnet|ppp|wg[a-z]*)\d+)\b[^"\n]*"')
# a comma-joined list of two or more values standing in as a default
NSHAPE = re.compile(r'"\s*[A-Za-z0-9_.]+\s*(?:,\s*[A-Za-z0-9_.]+\s*){1,}"')
# a shell ${VAR:-default} carrying an interface name
SHDEF = re.compile(r'\$\{[A-Za-z_][A-Za-z0-9_]*:-\s*((?:eth|usb|wwan|wlan|rmnet|ppp|wg[a-z]*)\d+)')

# A finding is real only where the literal acts as a VALUE. These are how a default is actually
# spelled in this codebase; matching them keeps the gate specific rather than noisy.
VALUE_CTX = re.compile(r'\b(env|getenv|Getenv|default|DEFAULT)\b|:=|=|\$\{[A-Za-z_]')


def strip_trailing_comment(line):
    """Drop a trailing comment so a literal QUOTED IN PROSE is not read as a value.

    Earned immediately: bond-xctl:294 is
        _RTS=" $(_route_defaults)"      # " eth1=1 usb0=2 " -- one ip+awk, once
    where `eth1`/`usb0` appear only in a comment illustrating the FORMAT. Flagging that would teach
    people to delete explanatory comments to appease the gate, which is worse than the defect.
    A `#` inside a string is not a comment, so only an even number of quotes before it counts.
    """
    for mark in ("#", "//"):
        idx = 0
        while True:
            i = line.find(mark, idx)
            if i < 0:
                break
            head = line[:i]
            if head.count('"') % 2 == 0 and head.count("'") % 2 == 0:
                line = head
                break
            idx = i + len(mark)
    return line


def exempt(path):
    p = path.replace("\\", "/")
    for frag, why in ALLOW.items():
        if frag in p:
            return why
    return None


def scan(root):
    hits = []
    for base in SHIPPED:
        d = os.path.join(root, base)
        if not os.path.isdir(d):
            continue
        for dirpath, _dirnames, files in os.walk(d):
            for fn in files:
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, root).replace("\\", "/")
                # extensionless files ship too -- deploy/p5 artifacts have no suffix
                if not (fn.endswith(EXT) or "." not in fn):
                    continue
                if exempt(rel):
                    continue
                try:
                    with open(full, encoding="utf-8", errors="replace") as f:
                        lines = f.readlines()
                except OSError:
                    continue
                for i, line in enumerate(lines, 1):
                    s = line.strip()
                    if s.startswith(("#", "//", "*")):
                        continue                    # prose is judged by review, not here
                    line = strip_trailing_comment(line)
                    m = SHDEF.search(line)
                    if m:
                        hits.append((rel, i, "IFACE", m.group(1), s[:96]))
                        continue
                    if not VALUE_CTX.search(line):
                        continue
                    m = IFACE.search(line)
                    if m:
                        hits.append((rel, i, "IFACE", m.group(1), s[:96]))
                        continue
                    m = NSHAPE.search(line)
                    if m:
                        hits.append((rel, i, "N-SHAPED", m.group(0), s[:96]))
    return hits


def selftest():
    """Seed each class and assert the gate reddens; seed an exempt path and assert it does not."""
    import tempfile
    import shutil
    ok = True
    cases = [
        ("IFACE",    "p4-bondagg/daemon/x.go", '\tpaths := env("AGG_PATHS", "eth1,usb0")\n'),
        ("IFACE",    "deploy/p5/y.sh",         'WG=${WG_DEV:-wgclient1}\n'),
        ("N-SHAPED", "p4-bondagg/daemon/z.go", '\tw := env("AGG_W", "20000,15000")\n'),
    ]
    for want, relpath, line in cases:
        root = tempfile.mkdtemp(prefix="nhg-")
        try:
            full = os.path.join(root, relpath.replace("/", os.sep))
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8") as f:
                f.write(line)
            kinds = [h[2] for h in scan(root)]
            good = want in kinds
            print("  seed %-9s in %-26s -> %-14s %s"
                  % (want, relpath, ",".join(kinds) or "NOTHING", "ok" if good else "FAIL"))
            ok = ok and good
        finally:
            shutil.rmtree(root, ignore_errors=True)

    root = tempfile.mkdtemp(prefix="nhg-")
    try:
        full = os.path.join(root, "p4-bondagg", "daemon", "x_test.go")
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write('\tpaths := env("AGG_PATHS", "eth1,usb0")\n')
        good = not scan(root)
        print("  same defect in a _test.go            -> %-14s %s"
              % ("silent" if good else "FLAGGED", "ok" if good else "FAIL"))
        ok = ok and good
    finally:
        shutil.rmtree(root, ignore_errors=True)
    return 0 if ok else 1


def main():
    root = os.environ.get("BOND_ROOT") or os.getcwd()
    if "--selftest" in sys.argv:
        print("no-hardcode gate self-test:")
        rc = selftest()
        print("  self-test PASS" if rc == 0 else "  self-test FAIL")
        return rc

    hits = scan(root)
    if not hits:
        print("no-hardcode gate: clean -- no interface literal or N-shaped default in shipped code")
        return 0

    print("no-hardcode gate: %d finding(s)\n" % len(hits))
    for rel, ln, kind, what, ctx in hits:
        print("  %-44s :%-5d %-9s %s" % (rel, ln, kind, what))
        print("      %s" % ctx)
    print("""
An interface name in shipped code is a claim about one box on one day, and a comma-joined default
encodes a COUNT as well as a value. Both are exactly what the N-generic rule targets.

Fix by DISCOVERING the value. Not by picking a different literal, and not by refusing when unset --
"refuse when unset" is still a hardcoded decision about what the operator must already know.
deploy/p5/bond-xctl ordered_wans() and p4-bondagg/daemon/pullrun.go pullNoPrior are the two shapes
already solved here; follow one rather than inventing a third.

If a file genuinely does not ship, add it to ALLOW with its reason -- and keep that list short.""")
    return 1


if __name__ == "__main__":
    sys.exit(main())
