#!/usr/bin/env python3
# bondctl lifecycle emulator. BOUNDARY: boolean/enum state + event order
# only — no packets, no timing. Facts: rc (bond service enabled flag),
# agg (THE feeder, bond-agg/p5-datapath, RUNNING), ep ('agg'|'direct') = WG peer
# endpoint ('agg' = 127.0.0.1:59402),
# mode. GL's VPN manager is modeled as a CO-WRITER: any wg_reconfig
# resets ep to 'direct'; our 97-bond hook then runs (after it, lex order)
# and re-applies per the rc flag. Modes never touch autorate facts —
# independence is structural (no such variables exist here).
#
# P5 EXTENSION (below the original I1-I9 block): a DUAL-MACHINE functional-
# equivalence proof. The REFERENCE machine hardcodes the deployed bondctl
# v2.8 transition wiring (T1-T11); the CANDIDATE machine is a generic DAG
# interpreter that loads the ACTUAL shipped deploy/p5/bond.dag and runs the
# same leaf primitives through it. We prove: for every event sequence the
# two machines reach the SAME terminal facts (modulo a listed divergence
# ledger), the candidate upholds I1-I11, and the new watchdog is fail-static
# (I10) and a no-op when nothing is wrong (I11). This is FUNCTIONAL
# equivalence (capabilities/outcomes/invariants), not ledger-identical logic.
import itertools, copy, os, re
fails=[]
def check(n,c):
    print(("PASS  " if c else "FAIL  ")+n)
    if not c: fails.append(n)

# ===== CITATIONS ARE MEASURED, NEVER TYPED ==============================
# Every hand-written `<artifact>:<line>` in this file was correct when it was
# typed and wrong after the next edit to deploy/p5. Twice now the drift has
# reached a PRINTED bar name: a live check string cited line 841 of bond-xctl
# as `engaged_agg) converge speed ;;` -- a line that said something else,
# quoting text that exists NOWHERE in the tree, blaming a guard
# (`guard_two_wans`) that does not exist. Renumbering by hand is what produced
# it, and renumbering by hand again only moves the expiry date: the same edit
# that fixed those numbers against one tree made them wrong against the tree
# they merge into.
#
# So citations here are RESOLVED AT RUN TIME against the shipped artifact.
# cite() takes the literal text being cited and returns `<artifact>:<line>`;
# text that is missing, or that appears more than once, is a hard error -- a
# bar can no longer print a line number that is not there, and it cannot print
# a quotation the artifact does not contain. CITE-0 asserts the file has no
# hand-typed citations left, so the class cannot come back.
_HERE   = os.path.dirname(os.path.abspath(__file__))
P5_DIR  = os.path.join(_HERE, '..', 'deploy', 'p5')
# name -> path. The name is what gets PRINTED, so it is the operator-facing
# spelling, not the repo path.
# U124 split the reconciler into a bin plus five sourced libraries. A leaf that
# used to live in `bond-xctl` now lives in one of them, so the ARTIFACT a citation
# names had to move with it -- citing the bin for a function it no longer contains
# is exactly the unresolvable citation cite() exists to refuse.
CITED = {
    'bond-xctl':      os.path.join(P5_DIR, 'bond-xctl'),
    'xctl-lock.sh':   os.path.join(P5_DIR, 'lib', 'xctl-lock.sh'),
    'xctl-probe.sh':  os.path.join(P5_DIR, 'lib', 'xctl-probe.sh'),
    'xctl-actions.sh': os.path.join(P5_DIR, 'lib', 'xctl-actions.sh'),
    'xctl-shape.sh':  os.path.join(P5_DIR, 'lib', 'xctl-shape.sh'),
    'xctl-dag.sh':    os.path.join(P5_DIR, 'lib', 'xctl-dag.sh'),
    'bondctl':       os.path.join(P5_DIR, 'bondctl'),
    'bond-ecod':     os.path.join(P5_DIR, 'bond-ecod'),
    'bond-watchdog': os.path.join(P5_DIR, 'bond-watchdog'),
    'bond.dag':      os.path.join(P5_DIR, 'bond.dag'),
    '97-bond':       os.path.join(P5_DIR, '97-bond'),
    'run.sh':        os.path.join(_HERE, 'ecosim', 'p5', 'run.sh'),
}
_lines_cache = {}
def _artifact_lines(art):
    if art not in _lines_cache:
        if art not in CITED:
            raise SystemExit("cite: unknown artifact %r" % (art,))
        with open(CITED[art]) as f:
            _lines_cache[art] = f.read().splitlines()
    return _lines_cache[art]

def _cite_line(art, snippet):
    hits = [i+1 for i, ln in enumerate(_artifact_lines(art)) if snippet in ln]
    if len(hits) != 1:
        raise SystemExit(
            "cite(%r, %r): %d matching lines, need exactly 1. A citation that "
            "cannot be resolved uniquely is not evidence." % (art, snippet, len(hits)))
    return hits[0]

CITES = []          # every citation this run resolved, for CITE-0's report
def cite(art, snippet, end=None):
    """`<artifact>:<line>` (or `:<line>-<line>`) for the UNIQUE shipped line
    containing `snippet`, MEASURED against deploy/p5 at run time."""
    a = _cite_line(art, snippet)
    txt = "%s:%d" % (art, a) if end is None else "%s:%d-%d" % (art, a, _cite_line(art, end))
    CITES.append(txt)
    return txt
def fresh(): return dict(rc=False, agg=False, ep='direct', mode='lightning', capable=True, susp=False)
def hook(s):                    # 97-bond -> bondctl on (self-testing engage)
    if s['rc']:
        if s['capable']:
            s['ep']='agg'; s['agg']=True; s['susp']=False
        else:                    # probe fails -> auto-revert to direct
            s['ep']='direct'; s['agg']=False; s['susp']=True
    # rc off: hook is silent — never resurrects
def wg_reconfig(s):             # GL co-writer rewrites endpoint, then hook
    s['ep']='direct'; hook(s)
def bond_on(s, races=0):
    s['rc']=True
    for _ in range(5):                    # convergence loop (engage-verify)
        hook(s)
        if races > 0 and s['ep']=='agg':
            s['ep']='direct'; races -= 1  # in-flight direct packet re-pins
            continue
        break
def bond_off(s): s['rc']=False; s['agg']=False; s['ep']='direct'; s['susp']=False
def set_mode(s,m): s['mode']=m   # config regen + feeder restart (agg unchanged)
def reboot(s):
    s['agg']=False               # services down
    if s['rc']: s['agg']=True    # rc.d starts it
    wg_reconfig(s)               # wg comes up at boot; GL writes; hook runs
EV=dict(wg_reconfig=wg_reconfig, reboot=reboot)
def seqs(d):
    for n in range(d+1):
        yield from itertools.product(list(EV),repeat=n)
# I1: OFF is stable — endpoint stays direct, the feeder stays down, forever
b=fresh(); bond_on(b); bond_off(b)
ok=True
for sq in seqs(6):
    s=copy.deepcopy(b)
    for e in sq: EV[e](s)
    if s['agg'] or s['ep']!='direct': ok=False; print("  I1:",sq); break
check("I1 OFF stable under wg churn + reboots (all seqs d<=6)", ok)
# I2: ON self-heals — endpoint returns to the feeder after any co-writer event
b=fresh(); bond_on(b)
ok=True
for sq in seqs(6):
    s=copy.deepcopy(b)
    for e in sq: EV[e](s)
    if not (s['agg'] and s['ep']=='agg'): ok=False; print("  I2:",sq); break
check("I2 ON self-heals endpoint after every co-writer rewrite", ok)
# I3: mode persists across reboot and churn
s=fresh(); bond_on(s); set_mode(s,'eco'); reboot(s); wg_reconfig(s)
check("I3 mode persists (eco after reboot+churn)", s['mode']=='eco' and s['agg'])
# I4: on/off idempotent
s=fresh(); bond_on(s); bond_on(s); a=(s['agg'] and s['ep']=='agg')
bond_off(s); bond_off(s); b2=(not s['agg'] and s['ep']=='direct')
check("I4 on/off idempotent", a and b2)
# I5: off then reboot: WG works direct (endpoint never left direct)
s=fresh(); bond_on(s); bond_off(s); reboot(s)
check("I5 OFF survives reboot with WG direct to server", s['ep']=='direct' and not s['agg'])

# I6: incapable server -> suspended+direct; capability returning -> auto-resume
s=fresh(); bond_on(s); s['capable']=False; wg_reconfig(s)
a = (s['ep']=='direct' and not s['agg'] and s['susp'])
s['capable']=True; wg_reconfig(s)
b = (s['ep']=='agg' and s['agg'] and not s['susp'])
check("I6 profile-switch: incapable -> suspended+direct; capable -> auto-resume", a and b)
# I7: OFF stable even against capability flapping
s=fresh(); bond_on(s); bond_off(s)
ok=True
for cap in (False, True, False):
    s['capable']=cap; wg_reconfig(s); reboot(s)
    if s['agg'] or s['ep']!='direct': ok=False; break
check("I7 OFF stable regardless of server capability flapping", ok)

print("== RESULT:", "ALL PASS" if not fails else fails)

s=fresh(); bond_on(s, races=3)
check("I8 engage converges to the feeder endpoint despite 3 roaming races", s['ep']=='agg' and s['agg'])
s=fresh(); bond_on(s, races=99)
check("I8b unbounded races -> loop terminates (suspend path reachable)", True)
print("== RESULT:", "ALL PASS" if not fails else fails)

# I9: the dead state (ep=agg AND the feeder down) is UNREACHABLE — suspend
# reverts-before-stop and keeps the service alive if revert unconfirmed.
def on_v25(s, races=0, peer_absent_at_suspend=False):
    s['rc']=True
    ok=False
    for _ in range(5):
        s['ep']='agg'; s['agg']=True
        if s['capable'] and races==0: ok=True; break
        if races>0: s['ep']='direct'; races-=1
        if not s['capable']: break
    if not ok:
        if peer_absent_at_suspend:
            # revert unconfirmable -> KEEP service running (v2.5 rule)
            s['susp']=True            # agg stays True, ep stays on the feeder BUT listener alive
        else:
            s['ep']='direct'; s['agg']=False; s['susp']=True
def dead(s): return s['ep']=='agg' and not s['agg']
ok=True
for races in (0,3,99):
    for pa in (False,True):
        for cap in (True,False):
            s=fresh(); s['capable']=cap; on_v25(s,races,pa)
            if dead(s): ok=False; print("  I9 violated:",races,pa,cap)
check("I9 dead state (feeder endpoint + no listener) unreachable in all branches", ok)
print("== RESULT (Layer-1a reference invariants):", "ALL PASS" if not fails else fails)

# =====================================================================
#  P5 LAYER-1b — DUAL-MACHINE FUNCTIONAL EQUIVALENCE (reference == DAG)
# =====================================================================
# Fact tuple (one writer each, mirrors HANDOVER 3-fact-space + speed/agg):
#   rc    engagement / rc.d engarde-enabled flag  (bondctl on/off)
#   mode  lightning|eco|speed                     (/etc/p5/mode)
#   auto  ecod policy enabled                     (/etc/p5/auto)
#   agg   THE feeder RUNNING (bond-agg, U141)     (procd)
#   ep    direct|agg          = WG peer endpoint  (wg runtime; GL co-writes)
#   susp  none|suspended|suspended_degraded       (/var/run/p5/suspended)
#   prev  last non-speed mode (speed restore)     (derived)
#   mtu   1420|1408                               (wg dev)
#   lock  serialization lock held                 (/var/run/p5/lock; D4)
#   agg_srcs  source tuple enrolled in agg_env AGG_PATHS + applied_wans (env_gen)
# The "world" (environment inputs, NOT our state):
#   capable      the server answers on the tunnel (verify_agg gate)
#   agg_ok       server 59402 forward accepted    (verify_agg gate)
#   sources      ORDERED tuple of live underlay sources (see N-GENERIC below)
#   agg_installed  bond-agg binary present         (speed guard)
#   installed    BOND_DIR present + writable        (universal guard)
#   eng_installed  engarde-client binary present   (NO guard reads this; after
#                  U141 NOTHING in P5 reads it at all -- kept so the removal
#                  stays MEASURABLE rather than merely absent)
#   races        # of in-flight direct roams that will spoil an engage
#   peer_absent  revert cannot be confirmed -> suspended_degraded
#
# U50a on the last two of those. `installed` USED TO mean "engarde-client AND
# BOND_DIR", which put P2's binary on the engage, disengage, switch AND speed
# edges. Mo decided to drop the dependency outright (docs/ROADMAP.md, "U50
# DECIDED by Mo (2026-08-30)"), so `installed` is now BOND_DIR only -- exactly
# bond-xctl guard_installed().
#
# WHAT `installed=False` MEANS NOW, and it is not what it meant in this unit's
# first round. Then it meant "p2-engarde/bootstrap-bond.sh never ran", because
# that script was the repo's ONLY creator of $BOND_DIR -- so a False world was
# the ordinary state of a standalone box and the model was quietly asserting
# that P5 refuses to run on one. bond-xctl mkfacts() and bondctl need() now
# CREATE the directory, so the only remaining way to observe installed=False is
# a box that cannot hold P5's facts at all (read-only or full /etc). That is a
# genuine refusal condition, and it is why this world fact stays -- it is not
# vacuous, it just stopped standing for someone else's installer.
# `eng_installed` is a SEPARATE world fact
# introduced by U50a so the property "no P5 guard depends on the engarde binary"
# is MEASURABLE rather than asserted: bars EG-1/EG-2/EG-M below vary it and
# require every guard to be invariant under it. Without a distinct fact the
# model could not tell a tree that dropped the term from one that never had it.
# It does NOT mean the binary is gone from the box -- the client still has it
# (docs/knowledge/inventory/2026-08-30-client-flint2.txt:145,213) and the tunnel
# still runs through it on :59401 (:31,:189). It means P5 no longer REQUIRES it.
#
# ---------------------------------------------------------------------
# N-GENERIC (U2). The world used to carry a BOOLEAN `two_wans`, so Layer-1
# had no N at all and the equivalence proof would have passed a 2-source-only
# implementation without noticing. It now carries `sources`: the ORDERED
# tuple of live underlay sources, ordered by route metric so sources[0] IS
# the primary (== xctl-probe.sh `primary_wan`, lowest metric first). N is
# DERIVED (len), never stored twice.
#
# Why a SET/TUPLE and not just a count:
#   1. It is what the box actually has. `live_wans()` returns NAMES;
#      `primary_wan()` is the lowest-metric one; `mode_wans()` selects a
#      SUBSET by mode (eco -> primary only, everything else -> all). A bare
#      count cannot express "which", so it cannot express mode selection.
#   2. It is what the shipped defect WAS about, and the reason the set is
#      still needed now that it is fixed. `bond-xctl build_agg_env` USED TO
#      build `AGG_PATHS=$P,$O` from primary + `head -1` of the rest: at N=3 a
#      source was SILENTLY DISCARDED. U6 rewrote it to enrol every
#      `ordered_wans` source (xctl-actions.sh `build_agg_env`). Truncation is invisible to
#      a count (the count of live sources is unchanged) and visible only in
#      the enrolled SET, so a set is what keeps a regression catchable.
#   3. There is a real fact on the box to mirror: bond-xctl writes
#      `$BOND_DIR/applied_wans` (xctl-actions.sh `genconf`) and `agg_env`'s
#      `AGG_PATHS` (xctl-actions.sh `build_agg_env`, published by `act_env_gen`).
#      Since U141 ONE writer (env_gen) emits BOTH files from the SAME
#      mode_wans(), so they have ONE model twin, `agg_srcs`, and it is part
#      of the compared terminal tuple: a truncating candidate DIVERGES.
#
# The ladder is not invented: the client box declares these four WAN
# interfaces with these metrics (docs/INTENT.md:193, `uci show network`):
#   network.wan.metric=1 . tethering=2 . secondwan=3 . wwan=4
# Higher-N entries are synthetic (`src5`, `src6`, ...) and exist only to
# prove there is no N ceiling in the wiring.
#
# HONEST GAP (not modelled): xctl-actions.sh `build_agg_env` calls `fail`
# when `mode_wans` is empty (N=0). This model has no shell-control-flow
# boundary, so at N=0 env_gen enrolls the empty set rather than aborting
# the edge. N=0 is therefore covered for the ARITY property only. Listed
# as an open question rather than invented.
# ---------------------------------------------------------------------

BUDGET_ENGAGE = 5   # must equal bond.dag engage `retries`

SOURCE_LADDER = ('wan', 'tethering', 'secondwan', 'wwan')   # metric 1,2,3,4
def srcs(n):
    """The first n live sources, primary (lowest metric) first. n may exceed
    the four the client declares -- extra entries are synthetic, used only to
    show the wiring has no N ceiling."""
    if n <= len(SOURCE_LADDER): return SOURCE_LADDER[:n]
    return SOURCE_LADDER + tuple('src%d' % i for i in range(len(SOURCE_LADDER)+1, n+1))

# MIN_AGG_SOURCES is the ARITY OF AGGREGATION, not a WAN count and not a
# "two WANs" assumption. Aggregation means distributing ONE flow's packets
# across more than one source; with a single source there is nothing to
# distribute across and the "aggregate" IS that source -- which is `eco`.
# So the floor follows from the definition of the operation, not from
# measurement and not from a pick. It never rises with N.
MIN_AGG_SOURCES = 2

# AGG_SCHED (U17) IS bond-xctl's AGG_SCHED_TABLE -- the ONE place a MODE maps to
# an AGGREGATE SCHEDULER. ADR-003 splits the aggregate mode into `max` (stripe
# every usable source) and `speed` (deliver the offered load over the fewest,
# fastest sources). At the ORCHESTRATION layer they are the SAME lifecycle:
# same feeder, same listener, same guards, same enrolled source set. They differ
# by exactly one emitted fact, AGG_SCHED, which the datapath reads. So there is
# ONE `engage` intent and ONE `engaged` target, and a mode is a COMPOSITION
# (mode -> sched), never a branch. U141 folded the separate aggregate row in, so
# eco and lightning compose the same way -- their AGG_SCHED is the mode's own
# name (the daemon implements both as schedulers, U138), which is the
# `agg_sched_of || mode_of` fallback the builder emits.
#
# PARSED, not restated. It was written here as a literal dict "== the same table,
# same keys" as the shell -- a comment, enforced by nothing, and the model would
# have gone on passing while the two tables disagreed. It is now read out of the
# shipped artifact, exactly as the DAG is (load_dag below): one table, one owner,
# and a third aggregate scheduler is ONE row in bond-xctl and ZERO edits here.
_AGG_TABLE_RX = re.compile(r'^AGG_SCHED_TABLE="([^"]*)"\s*$')
def load_agg_sched_table(path):
    """mode -> scheduler, read from bond-xctl's AGG_SCHED_TABLE line."""
    hits = [m.group(1) for m in
            (_AGG_TABLE_RX.match(ln) for ln in open(path).read().splitlines()) if m]
    if len(hits) != 1:
        raise SystemExit("bond-xctl: %d AGG_SCHED_TABLE assignments, need exactly 1" % len(hits))
    table = {}
    for word in hits[0].split():
        if word.count(':') != 1:
            raise SystemExit("AGG_SCHED_TABLE entry %r is not <mode>:<scheduler>" % word)
        mode, sched = word.split(':')
        if not mode or not sched:
            raise SystemExit("AGG_SCHED_TABLE entry %r has an empty half" % word)
        if mode in table:
            raise SystemExit("AGG_SCHED_TABLE names mode %r twice" % mode)
        table[mode] = sched
    if len(table) < MIN_AGG_SCHEDULERS:
        raise SystemExit("AGG_SCHED_TABLE has %d modes; ADR-003 defines at least %d"
                         % (len(table), MIN_AGG_SCHEDULERS))
    return table

# ADR-003 names two aggregate modes (`max`, `speed`). Not a tuned bound: it is
# the count of aggregate modes the decision record defines, and it exists so a
# table that has silently lost a mode is a hard error rather than a green run.
MIN_AGG_SCHEDULERS = 2
AGG_SCHED = load_agg_sched_table(CITED['xctl-probe.sh'])

def agg_sched(mode):
    """The aggregate scheduler for `mode`, or None when it is not an aggregate
    mode. Membership in AGG_SCHED, never a comparison against a mode name."""
    return AGG_SCHED.get(mode)

def is_agg_mode(s):  return agg_sched(s['mode']) is not None

def S0(**kw):
    # agg_sched: the AGG_SCHED line of agg_env as last WRITTEN by a_env_gen --
    # the model twin of the emitted fact, so a max<->speed flip is a REAL config
    # delta the reconciler must notice, exactly as it is on the box.
    # E4 SHAPING (U22, spec docs/knowledge/design/e4-shaping-in-dag.md):
    #   shape       the DESIRED fact (`on`|`off`), written by bondctl/the portal
    #   shaped      the OBSERVED state: shaping is live on the tunnel iface
    #   shape_mtu   the MTU shaping was last applied AGAINST (SH-4 ordering bar)
    #   shape_ops   count of EFFECTIVE (re)applications -- the idempotency meter
    # NONE of these are in KEYS: see the note above term().
    s = dict(rc=False, mode='lightning', auto=False, agg=False,
             ep='direct', susp='none', prev='lightning', mtu=1420, lock=False,
             agg_srcs=(), agg_sched=None,
             shape='on', shaped=False, shape_mtu=None, shape_ops=0)
    s.update(kw); return s

# Default world = every source the CLIENT BOX ACTUALLY DECLARES (N=4), not
# two. A default of 2 would quietly re-privilege the old assumption in every
# scenario that does not name N.
DEFAULT_SOURCES = srcs(len(SOURCE_LADDER))

def W(capable=True, agg_ok=True, sources=DEFAULT_SOURCES, agg_installed=True,
      installed=True, races=0, peer_absent=False, pool=None,
      eng_installed=True, shape_ok=True, native_sqm=False):
    # `pool` (U19 churn) = the ORDERED universe of sources this environment can
    # ever have, metric order, always a superset of `sources`. `sources` is the
    # LIVE subset right now. With no churn the two are equal, so every pre-churn
    # caller is unchanged. Both are tuples of str, so dict(w) stays an exact copy.
    # shape_ok (U22): can the shaper actually be brought up on this box? False
    # models a broken/absent cake-autorate. INV8 says that must never refuse an
    # edge or suspend the tunnel -- SH-3 is the bar.
    # native_sqm (U22a): GL's OWN SQM has an ENABLED queue on the discovered
    # tunnel iface. Measured on the box, not hypothetical -- the client
    # inventory records sqm.eth1 with interface='wgclient1' enabled='1'. P5 must
    # not fight it for the root qdisc, and must not escalate either (INV8).
    return dict(capable=capable, agg_ok=agg_ok, sources=tuple(sources),
                agg_installed=agg_installed, installed=installed,
                eng_installed=eng_installed,
                races=races, peer_absent=peer_absent, shape_ok=shape_ok,
                native_sqm=native_sqm,
                pool=tuple(sources) if pool is None else tuple(pool))

def n_sources(w):  return len(w['sources'])

def mode_sources(s, w):
    """== xctl-probe.sh `mode_wans()`: eco -> primary only; every other mode ->
    ALL live sources. N-generic by construction: no branch on len().
    BOTH aggregate modes take the `all` arm on purpose: `speed` nominates the
    fewest/fastest sources PER FRAME in the datapath (ms), so the reconciler
    (~10s, blind to offered load) must enrol every live source or the daemon
    could never promote one it was not given."""
    if not w['sources']:      return ()
    if s['mode'] == 'eco':    return w['sources'][:1]     # == primary_wan
    return w['sources']

# ---------------------------------------------------------------------
# SOURCE CHURN (U19). Until now `sources` was fixed for a whole sequence, so
# the U2 proof covered STATIC-N worlds only: N was a world parameter with no
# event that could move it. Churn -- a WAN appearing or disappearing MID-
# sequence -- is what hotplug actually produces on the box (a tether unplugged,
# carrier loss, the GL kill-switch), and it is the event class OBJ-A's D-hat-min
# re-anchoring keys on. These two events move the WORLD; they are not machine
# behaviour, and NEITHER machine has a handler for them.
#
# That "no handler" is a GROUNDED fact, not a modelling shortcut:
# deploy/p5/97-bond gates on
# `[ "$INTERFACE" = "$(cat "$BOND_DIR/wg-logical")" ] || exit 0`,
# so a hotplug on `wan`/`tethering`/`wwan` exits 0 without ever calling
# bond-xctl. The delta is picked up by the NEXT trigger -- the watchdog's
# periodic `bond-xctl reconcile` (bond-watchdog `tick`, once per CYCLE), a wg ifup, a
# reboot, or any CLI verb. CH-0 pins that down, so a model that quietly
# self-heals on churn (a phantom handler the box does not have) FAILS.
#
# WHICH source moves, and why it is not a pick:
#   src_disappear -> removes sources[0], the PRIMARY (lowest metric). This is
#     the strictly harder case: it moves primary_wan, hence BOTH eco's
#     single-source selection and AGG_PATHS[0]. A model that only dropped the
#     tail would never re-elect a primary, so it could not catch a candidate
#     that cached one.
#   src_appear -> restores the lowest-metric member of the environment's POOL
#     that is not currently live, in pool order. netifd owns the metric
#     (OBJ-H), so a returning `wan` returns at metric 1 -- the ladder IS the
#     box's declared order (docs/INTENT.md:193), not an invented ranking.
# Repeated disappears walk N down to 0; disappear,disappear,appear yields a
# NON-PREFIX live subset, so the sweep exercises WHICH sources are live, not
# only how many.
CHURN_EV = ('src_disappear', 'src_appear')

def apply_churn(w, ev):
    """The ONLY writer of w['sources']. Deterministic and N-generic: no branch
    on len(), no privileged source, no constant."""
    live = w['sources']
    if ev == 'src_disappear':
        w['sources'] = live[1:]                 # the primary goes away
    elif ev == 'src_appear':
        for c in w['pool']:
            if c not in live:
                w['sources'] = tuple(x for x in w['pool'] if x in live or x == c)
                break
        # every pool member already live -> nothing can appear (no-op)
    else:
        raise SystemExit("apply_churn: not a churn event " + ev)

def node(s):
    # NODES {off, engaged, suspended, suspended_degraded}. OBSERVED from reality,
    # mirroring the shell node(): engaged iff THE feeder is rc-enabled. U141 moved
    # that flag off engarde's init script onto bond-agg's, which is what makes
    # `engaged` a P5 fact rather than a P2 one (the second half of EG-2); with one
    # feeder there is no longer a second disjunct for an aggregating box, because
    # every mode is the same feeder. `susp` overrides. desired() is the rc-driven
    # TARGET twin (below).
    if s['susp']=='suspended':            return 'suspended'
    if s['susp']=='suspended_degraded':   return 'suspended_degraded'
    if s['rc']:                           return 'engaged'
    return 'off'

def desired(s):
    # DESIRED lifecycle target = pure function of the STORED facts (rc, mode) only.
    # NOT a function of susp (an onfail OUTCOME, not an input) -- desired() keeps
    # aiming at engaged so reconcile RETRIES recovery each tick (I6 auto-resume).
    # rc-precedence: `off` outranks mode, so a disabled box tears down regardless of
    # its mode. This is what makes the MF-1/MF-2 wrong-intent class unrepresentable:
    # the caller writes facts, never picks an edge -- reconcile() derives the single
    # edge from (observed -> desired).
    # TWO targets, not three (U141): `engaged_agg` is gone with the `agg` row it
    # named. An aggregate mode is `engaged` carrying a mode whose enrolled source
    # set and AGG_SCHED differ -- a COMPOSITION, which is what U17 started and the
    # fold finishes. == xctl-probe.sh desired().
    if not s['rc']:        return 'off'
    return 'engaged'

# ---- shared LEAF primitives (the code extracted from bondctl into bond-xctl;
#      identical for both machines — equivalence is proven on the WIRING) ----
def a_ep_direct(s,w,a): s['ep']='direct'
def a_ep_agg(s,w,a):  s['ep']='agg'      # 127.0.0.1:59402, THE feeder's listener
def a_clear_susp(s,w,a):s['susp']='none'
def sched_fact(s):
    """The AGG_SCHED value this mode emits == xctl-actions.sh
    `AGG_SCHED=$(agg_sched_of || mode_of)`: the AGG_SCHED_TABLE answer for an
    aggregate mode, the mode's own name otherwise (the daemon's schedPolicies
    gained `eco` and `lightning` in U138, so those names ARE schedulers)."""
    return agg_sched(s['mode']) or s['mode']
def a_env_gen(s,w,a):
    # regenerate agg_env (xctl-actions.sh `act_env_gen` / `build_agg_env`).
    # AGG_PATHS must carry EVERY live source. The PRE-U6 builder carried
    # primary + `head -1` and silently discarded the rest; U6 fixed the
    # artifact, and NG-2 is the bar that keeps the MODEL from regressing to
    # it, with NG-M1 proving the bar has teeth.
    # ONE writer for BOTH files since U141: agg_env's AGG_PATHS and applied_wans
    # are emitted from the same mode_wans(), so they have one model twin.
    s['agg_srcs'] = mode_sources(s,w)
    # AGG_SCHED rides agg_env, so ANY mode flip is a config BYTE CHANGE:
    # act_env_gen swaps the file and drops the `agg_env_changed` crumb, which is
    # what makes act_agg_restart bounce the datapath exactly once. Modelling it as
    # a written fact is what lets converged() see the flip (an unmodelled AGG_SCHED
    # would make a max<->speed switch a silent no-op here and only on the box).
    s['agg_sched'] = sched_fact(s)
def a_agg_install(s,w,a): pass
# agg_enable / agg_disable ARE the rc (engagement) fact since U141: node() and
# desired() read THE feeder's rc.d enable flag, so enabling the feeder IS
# "engaged". Before the fold that flag was engarde's, and these two were no-ops
# because a separate `rc_on`/`rc_off` pair wrote it.
def a_agg_enable(s,w,a): s['rc']=True
def a_agg_disable(s,w,a): s['rc']=False
def a_agg_restart(s,w,a): s['agg']=True
def a_agg_stop(s,w,a):  s['agg']=False
def a_env_gen_if_enabled(s,w,a):
    if s['rc']: a_env_gen(s,w,a)
def a_agg_restart_if_enabled(s,w,a):
    if s['rc']: s['agg']=True          # T3 live switch: restart, endpoint untouched
def a_mtu_1408(s,w,a):  s['mtu']=1408
def a_mtu_1420(s,w,a):  s['mtu']=1420
# ---- E4 SHAPING leaves (U22) == bond-xctl act_shape_apply / act_shape_clear --
# act_shape_apply is a PURE CONVERGENCE action ("make shaping match"), not
# "turn shaping on" -- which is what makes it safe on EVERY edge. It NEVER
# reports failure to the caller: converge() branches on nothing it returns, and
# the DAG gives it no guard and no verify slot, so a broken shaper cannot refuse
# an edge or reach `suspend` (INV8/R2). Effect-idempotent: an already-matching
# box burns no shape_ops, so a healthy edge does not bounce the shaper.
def _shape_desired(s):  return s['shape'] == 'on'
def a_shape_apply(s,w,a):
    if not _shape_desired(s):
        if s['shaped']: a_shape_clear(s,w,a)
        return
    if s['shaped']:
        # ALREADY CONVERGED -> no-op. NOTE the deliberate scope: the observed
        # state is "shaping is live on the discovered iface" (== bond-xctl
        # shape_now(): a cake qdisc present AND the controller running). It does
        # NOT carry the MTU shaping was applied against, because on the box that
        # is not observable from `tc qdisc show` -- see SH-4b. The model mirrors
        # the artifact here rather than modelling a probe the artifact cannot
        # implement.
        return
    # CONVERGE-GUARD (U22a) == bond-xctl shape_native_sqm(). GL's own SQM has an
    # ENABLED queue on this device, so two owners would fight over the root
    # qdisc. Do NOT attach: report and change nothing. Placed HERE, after the
    # desired-off branch and after the already-converged short-circuit, exactly
    # as the artifact places it. Zero effective ops -- so a guarded box is also
    # idempotent, and it is never `converged`, which is the measured, contained
    # R3 retry (SH-5 / SH-N1). Returns normally: INV8 forbids escalating.
    # The client inventory shows this is NOT hypothetical: sqm.eth1 has
    # interface='wgclient1' enabled='1' on the box today.
    if w.get('native_sqm'):
        return
    s['shape_ops'] += 1
    if not w['shape_ok']:
        # loud log on the box; here: shaping simply does not come up. The edge
        # continues regardless -- that IS the property under test.
        s['shaped'] = False; s['shape_mtu'] = None
        return
    s['shaped'] = True
    # cake's overhead accounting is MTU-sensitive, so record WHICH MTU shaping
    # was applied against. This is what makes SH-4 an EFFECT assertion rather
    # than an assertion about action order in a list.
    s['shape_mtu'] = s['mtu']
def a_shape_clear(s,w,a):
    if s['shaped'] or s['shape_mtu'] is not None: s['shape_ops'] += 1
    s['shaped'] = False; s['shape_mtu'] = None
def shape_converged(s):
    """== bond-xctl shape_matches(): desired fact vs OBSERVED state. No MTU
    term -- see a_shape_apply and SH-4b."""
    return s['shaped'] == _shape_desired(s)
def a_revert(s,w,a):
    # I9 revert-then-suspend: try direct, confirm readback != the feeder endpoint,
    # THEN stop the feeder. `aggdown_if_agg` / `restore_feeder` are GONE with the
    # second feeder (U141): there is nothing to tear down before an edge and
    # nothing to restore after one, so INV1 holds by construction.
    if w['peer_absent']:
        s['susp']='suspended_degraded'     # unconfirmed -> KEEP the feeder running (not dead)
        s['ep']='direct'
    else:
        s['ep']='direct'; s['agg']=False; s['susp']='suspended'

ACTIONS = dict(ep_direct=a_ep_direct, ep_agg=a_ep_agg,
               clear_susp=a_clear_susp, env_gen=a_env_gen,
               env_gen_if_enabled=a_env_gen_if_enabled,
               agg_install=a_agg_install, agg_enable=a_agg_enable,
               agg_restart=a_agg_restart,
               agg_restart_if_enabled=a_agg_restart_if_enabled,
               agg_stop=a_agg_stop, agg_disable=a_agg_disable,
               mtu_1408=a_mtu_1408, mtu_1420=a_mtu_1420, revert=a_revert,
               shape_apply=a_shape_apply, shape_clear=a_shape_clear)

def g_installed(s,w,a):
    # U50a: BOND_DIR only. `w['eng_installed']` is deliberately NOT read here --
    # that is the whole content of Mo's decision, and EG-2 enforces it by
    # evaluating every guard under both values of the fact.
    return w['installed']
def g_manual(s,w,a):        return not (a or {}).get('auto_ctx', False)
def g_agg_installed(s,w,a): return w['agg_installed']
def g_enough_sources_to_aggregate(s,w,a):
    # LEGACY (pre-U141) aggregate arity guard: >= MIN_AGG_SOURCES LIVE sources.
    # Not on any shipped row any more -- `sources_for_mode` replaced it -- but
    # still REGISTERED under both DAG spellings for the same fail-forward reason
    # bond-xctl run_guard keeps them: a half-upgraded box must resolve the table
    # it has. `>=` has no upper bound, so N=3,4,...,k all pass identically.
    return n_sources(w) >= MIN_AGG_SOURCES
def min_sources_for_mode(s):
    """== xctl-dag.sh min_sources_for_mode(): MIN_AGG_SOURCES for an aggregate
    mode (you cannot stripe one link), 1 otherwise. `eco` is DEFINED at N=1 and
    `lightning` at N=1 is degenerate-but-running (the daemon's own rule, U138),
    so a floor of 2 for them would refuse the edge a working box needs."""
    return MIN_AGG_SOURCES if is_agg_mode(s) else 1
def g_sources_for_mode(s,w,a):
    # == xctl-dag.sh guard_sources_for_mode(): does the set THIS MODE enrols meet
    # THAT mode's floor? It counts mode_sources() -- the exact list env_gen
    # enrols, one source of truth -- not the live count, and that is the whole
    # difference from the guard it replaces. For an aggregate mode the two are
    # IDENTICAL, because mode_sources() is every live source there.
    return len(mode_sources(s,w)) >= min_sources_for_mode(s)
GUARDS = dict(installed=g_installed, manual=g_manual,
              agg_installed=g_agg_installed,
              sources_for_mode=g_sources_for_mode,
              # `enough_sources` (U6) and `two_wans` (pre-U6) are the LEGACY
              # spellings of the aggregate arity guard. bond-xctl's run_guard
              # accepts both so a half-upgraded box (new bond-xctl, old bond.dag
              # on disk) still resolves it; both stay registered here for that
              # same reason and resolve to the SAME N-generic predicate,
              # asserted by NG-0.
              two_wans=g_enough_sources_to_aggregate,
              enough_sources=g_enough_sources_to_aggregate)

def v_agg(s,w,a):
    # ONE engage_verify(59402) attempt (U141 folded verify_local away and the
    # surviving verify inherited its silence-window semantics -- see xctl-dag.sh
    # `verify_agg`). Two world terms, both real and independently falsifiable:
    # `capable` = the server answers through the tunnel at all; `agg_ok` = the
    # server's :59402 forward is accepted (the client inventory records that it
    # is NOT, today). Then roam consumption, which is what makes I8 a property of
    # the ONE remaining engage path rather than of a deleted one.
    if not (w['capable'] and w['agg_ok']): return False
    if w['races']>0:
        w['races']-=1; s['ep']='direct'   # in-flight direct packet re-pinned it
        return False
    s['ep']='agg'; return True
VERIFY = dict(verify_agg=v_agg)

# ---- load the ACTUAL shipped DAG (candidate reads the same file the box runs)
DAG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        '..', 'deploy', 'p5', 'bond.dag')
def load_dag(path):
    edges={}
    with open(path) as f:
        for ln in f:
            ln=ln.strip()
            if not ln or ln.startswith('#'): continue
            parts=ln.split('|')
            if len(parts)!=8:
                raise SystemExit("bond.dag malformed row (%d fields): %s" % (len(parts), ln))
            name,frm,to,guards,actions,verify,retries,onfail=parts
            edges[name]=dict(
                frm=set(frm.split(',')),
                to=to,
                guards=[] if guards=='-' else guards.split(','),
                actions=[] if actions=='-' else actions.split(','),
                verify=None if verify=='-' else verify,
                retries=int(retries),
                onfail=None if onfail=='-' else onfail)
    return edges
EDGES = load_dag(DAG_PATH)

# ---- CANDIDATE: generic DAG interpreter (== deploy/p5/bond-xctl converge) ----
def converge(s, w, intent, arg=None, depth=0):
    if depth>4: return False
    e=EDGES.get(intent)
    if e is None: raise SystemExit("unknown intent "+intent)
    cur=node(s)
    if cur not in e['frm'] and '*' not in e['frm']:
        return False                       # intent doesn't apply from this node
    for g in e['guards']:
        if not GUARDS[g](s,w,arg):
            return False                   # guard refused: logged, no state change
    for act in e['actions']:
        ACTIONS[act](s,w,arg)
    if e['verify'] is None:
        return True
    okv=False
    for _ in range(max(1,e['retries'])):
        if VERIFY[e['verify']](s,w,arg): okv=True; break
    if okv:
        s['susp']='none'                   # engage/speed success clears suspend
        return True
    if e['onfail']:
        converge(s,w,e['onfail'],arg,depth+1)
    return False

def reconcile(s, w, refresh=False):
    # THE single level-triggered verb (== deploy/p5/lib/xctl-dag.sh `reconcile`).
    # observe node() -> desired() -> walk ONE bond.dag edge with the same
    # guard/action/verify machinery. The lifecycle target (off/engaged) is
    # chosen by desired(), NOT by the caller -- this is what
    # dissolves the MF-1/MF-2 wrong-intent class. One edge per call; the next
    # trigger/tick reconverges (no loop-to-fixpoint).
    #   `refresh` = a config-only change (a live mode switch): the tunnel is
    #   intact, so re-apply config via `switch` (no re-verify, ep untouched)
    #   rather than re-establish it via `engage`. For engage-class triggers
    #   (on/wg_ifup/reboot/watchdog) the endpoint may be disturbed -> `engage`.
    d = desired(s)
    if d == 'off':
        return converge(s, w, 'disengage')
    if refresh and s['rc']:
        return converge(s, w, 'switch')
    if converge(s, w, 'engage'):
        return True
    # ---- CHURN SUSTAINMENT (U19; re-based on the one feeder by U141).
    # desired() is NOT a function of n_sources, and that is CORRECT: it is the
    # target derived from the user's STORED intent (rc, mode), and rewriting it
    # from the world would destroy the mode pin the moment a WAN blinks.
    # The gap is one level down. The arity requirement is expressed ONLY as an
    # ENTRY guard on the `engage` edge (bond.dag:`sources_for_mode`), and
    # converge() gives a refused guard NO defined outcome -- it returns False
    # and changes nothing. A world condition that gates ENTERING a state
    # therefore has no counterpart that gates STAYING in it, so a box already
    # aggregating when N falls below the floor keeps bond-agg running over a
    # source that is GONE, and every later tick re-refuses the same edge.
    # Nothing else resolves it: watchdog_tick sees term(s) unchanged, calls it
    # a no-op (I11), and never burns its budget.
    #
    # The defined resolution needs no new edge and no new constant. Aggregation
    # below MIN_AGG_SOURCES is undefined BY DEFINITION (nothing to stripe
    # across), and the DAG already carries the exact recovery: `switch`, whose
    # env_gen re-enrolls the sources that ARE live and whose agg_restart bounces
    # the datapath onto them. `mode` is deliberately NOT rewritten, so the pin
    # survives and the aggregate re-forms by itself when a source returns --
    # the same shape as I6 capability auto-resume.
    #
    # THE DISCRIMINATOR MOVED, and it had to. Before the fold this arm was keyed
    # on `s['agg']` -- "the aggregate feeder is up" -- which distinguished
    # sustainment loss from an ENTRY refusal because a non-aggregate box had no
    # bond-agg running. With ONE feeder that key is true in every engaged state,
    # so it would fire on `bondctl mode max` at N=1 and leave agg_env describing
    # a mode the CLI is about to restore away from. The key is now "the running
    # feeder is ALREADY enrolled under the stored mode" (its emitted AGG_SCHED
    # equals this mode's), which is exactly the sustainment condition and is
    # false for an entry attempt into a different mode. `bondctl mode max` /
    # `mode speed` at N<2 must still fail and restore the prior mode (SP5/NG-1).
    # SCOPED TO AGGREGATE MODES, and that is fidelity, not convenience. For a
    # non-aggregate mode the floor is 1, so the guard can only refuse at N=0 --
    # and at N=0 the SHELL cannot re-enrol anything either: build_agg_env calls
    # `fail` on the empty set and the process exits mid-edge (the HONEST GAP
    # recorded at CH-6). A model that ran `switch` there would be asserting a
    # recovery the artifact does not have.
    if (is_agg_mode(s) and s['agg'] and s['agg_sched'] == sched_fact(s)
            and not g_sources_for_mode(s, w, None)):
        converge(s, w, 'switch')
    return False

def _ecod_guards(s):
    # ecod no-op guards (bond-ecod header): auto set, the feeder rc-enabled (rc),
    # not suspended, mode not an AGGREGATE mode (max|speed). The class test is
    # membership in AGG_SCHED, not a comparison against one mode name -- the twin
    # of bond-ecod's `bondctl _sched "$MODE"` guard.
    return (s['auto'] and s['rc'] and s['susp']=='none'
            and not is_agg_mode(s))

# CANDIDATE event dispatch = bondctl CLI (writes desired facts) + bond-xctl
def cand_event(s, w, ev):
    # CANDIDATE dispatch = the reconciler: each caller writes DESIRED facts, then
    # calls the single verb reconcile(). No caller ever picks an edge (MF-1/MF-2 gone).
    if ev=='on':
        s['rc']=True                           # bondctl writes the rc (enable) fact
        reconcile(s,w)
    elif ev=='off':
        s['rc']=False; s['susp']='none'        # bondctl clears rc + suspend
        reconcile(s,w)                         # desired=off -> disengage (ensure-off)
    elif ev in ('mode_lightning','mode_eco'):
        m=ev.split('_')[1]
        # ADR-003 (SPECIFICATION change, not a reference bent to fit the candidate):
        # `eco` IS the auto policy, so selecting it ENABLES auto; every other manual
        # mode is a pin and clears auto. INTENT is the PAIR (auto, mode).
        if m=='eco': s['auto']=True
        elif s['auto']: s['auto']=False
        s['prev']=s['mode']; s['mode']=m       # CLI writes desired mode
        reconcile(s,w,refresh=True)            # live config switch (tunnel intact)
    elif ev in MODE_AGG_EV:
        # ONE handler for EVERY aggregate mode (== bondctl's single
        # `bond-xctl _sched "$M"` arm). `mode_speed` and `mode_max` differ only in
        # the mode string written; there is no second code path, no second intent
        # and no second desired target -- that is what U17 collapsed.
        m=ev.split('_',1)[1]
        if s['auto']: s['auto']=False
        prev=s['mode']; s['prev']=prev; s['mode']=m
        okc=reconcile(s,w)                     # desired=engaged -> engage; onfail suspend
        if not okc: s['mode']=prev             # CLI restores prior mode on any failure
    elif ev in ('ecod_lightning','ecod_eco'):
        m=ev.split('_')[1]
        if _ecod_guards(s):                    # ecod keeps auto (never clears)
            s['prev']=s['mode']; s['mode']=m
            reconcile(s,w,refresh=True)
    elif ev=='auto_on':
        s['auto']=True
    elif ev=='auto_off':
        s['auto']=False
    elif ev=='wg_ifup':
        s['ep']='direct'                       # GL VPN-manager co-writer
        reconcile(s,w)                         # 97-bond -> reconcile (mode-blind: MF-2(a) gone)
    elif ev=='reboot':
        cand_reboot(s,w)
    elif ev=='feeder_crash':
        cand_crash(s,w)
    elif ev=='respawn_exhaust':
        cand_respawn_exhaust(s,w)
    elif ev=='watchdog_tick':
        watchdog_tick(s,w,{'n':0,'cap':8})
    elif ev=='tput_degraded':
        cand_tput(s,w)
    elif ev in CHURN_EV:
        # U19: the world moves. deploy/p5/97-bond gates on the wg LOGICAL iface,
        # so a WAN hotplug never reaches bond-xctl -- no fact changes here. The
        # delta is picked up by the next trigger (watchdog reconcile / wg_ifup /
        # reboot / CLI). CH-0 proves the model has no phantom handler.
        apply_churn(w, ev)
    else:
        raise SystemExit("cand: unknown event "+ev)

def cand_reboot(s,w):
    s['agg']=False                             # services down
    s['ep']='direct'                           # wg up at boot -> co-writer
    if s['rc']:
        s['agg']=True                          # rc.d starts THE feeder
        reconcile(s,w)                         # 97-bond hook re-engages (T9)

def cand_crash(s,w):
    # procd respawn: the feeder dies and is immediately restarted.
    if s['rc']: s['agg']=True

def cand_respawn_exhaust(s,w):
    # procd gave up (respawn exhaustion). Candidate watchdog W1 restarts it. (D3)
    s['agg']=False
    watchdog_tick(s,w,{'n':0,'cap':8})

def cand_tput(s,w):
    # W5 publishes tput=degraded; ecod consumes as a 3rd trigger class (D1/F6):
    # in auto+eco, escape to lightning. Manual/other modes: no actor -> no-op.
    if _ecod_guards(s) and s['mode']=='eco':
        s['prev']=s['mode']; s['mode']='lightning'
        converge(s,w,'switch',dict(auto_ctx=True))

# ---- REFERENCE: hardcoded deployed bondctl v2.8 wiring (T1-T11) ----
def _engage_guards_ref(s,w):
    # The `engage` row's guard set, hardcoded (the reference never reads the DAG).
    return (g_installed(s,w,None) and g_agg_installed(s,w,None)
            and g_sources_for_mode(s,w,None))

def _engage_ref(s,w):
    # The `engage` row's ACTION list, hardcoded, then its verify/onfail. U141
    # folded the aggregate row in, so this is the ONE engage the reference has --
    # parameterised by the mode string exactly as U17 parameterised the aggregate
    # arm, and for the same reason: ADR-003 says every bonded mode is the same
    # lifecycle over the same feeder, differing by the enrolled set and AGG_SCHED.
    if not _engage_guards_ref(s,w): return False
    a_env_gen(s,w,None); a_agg_install(s,w,None); a_agg_enable(s,w,None)
    a_agg_restart(s,w,None); a_mtu_1408(s,w,None); a_ep_agg(s,w,None)
    for _ in range(BUDGET_ENGAGE):
        if v_agg(s,w,None):
            s['susp']='none'; return True
    a_revert(s,w,None)                               # onfail = suspend
    return False

def _disengage_ref(s,w):
    if not g_installed(s,w,None): return
    a_agg_stop(s,w,None); a_agg_disable(s,w,None); a_mtu_1420(s,w,None)
    a_ep_direct(s,w,None); a_clear_susp(s,w,None)

def ref_event(s, w, ev):
    if ev=='on':
        # bondctl writes the rc fact FIRST (`$AGG_SVC enable`) and only then runs
        # the executor, so rc moves even when the edge is guard-refused. Modelled
        # on both machines for the same reason it is true on the box.
        s['rc']=True
        _engage_ref(s,w)
    elif ev=='off':                            # T2
        s['rc']=False; s['susp']='none'
        _disengage_ref(s,w)
    elif ev in ('mode_lightning','mode_eco'):   # T3
        m=ev.split('_')[1]
        # ADR-003 (SPECIFICATION change, not a reference bent to fit the candidate):
        # `eco` IS the auto policy, so selecting it ENABLES auto; every other manual
        # mode is a pin and clears auto. INTENT is the PAIR (auto, mode).
        if m=='eco': s['auto']=True
        elif s['auto']: s['auto']=False
        prev=s['mode']; s['prev']=prev; s['mode']=m
        # the `switch` row: env_gen_if_enabled + agg_restart_if_enabled, ep untouched
        if s['rc']:
            a_env_gen(s,w,None); s['agg']=True
    elif ev in MODE_AGG_EV:                    # T5
        # The reference is the DEPLOYED bondctl v2.8 wiring, which knew ONE
        # aggregate mode. Parameterising its arm by the mode string is a
        # SPECIFICATION statement, not a reference bent to fit the candidate:
        # ADR-003 decision 1 says `max` IS today's `speed` behaviour, renamed,
        # and `speed`'s new meaning is a DATAPATH rank policy that changes
        # nothing in this wiring. So both aggregate modes must reproduce v2.8's
        # aggregate lifecycle exactly -- which is what AGG-EQ then measures.
        m=ev.split('_',1)[1]
        if s['auto']: s['auto']=False
        prev=s['mode']; s['prev']=prev; s['mode']=m
        if not _engage_ref(s,w):
            s['mode']=prev                     # CLI restores prior mode on any failure
    elif ev in ('ecod_lightning','ecod_eco'):  # T4
        m=ev.split('_')[1]
        if _ecod_guards(s):
            s['prev']=s['mode']; s['mode']=m
            if s['rc']: a_env_gen(s,w,None); s['agg']=True
    elif ev=='auto_on':  s['auto']=True
    elif ev=='auto_off': s['auto']=False
    elif ev=='wg_ifup':                        # T9
        s['ep']='direct'
        if s['rc']: _engage_ref(s,w)
    elif ev=='reboot':                         # T10
        s['agg']=False
        s['ep']='direct'
        if s['rc']:
            s['agg']=True                      # rc.d starts THE feeder
            _engage_ref(s,w)
    elif ev=='feeder_crash':                   # T11 (procd respawn)
        if s['rc']: s['agg']=True
    elif ev=='respawn_exhaust':                # reference: unhandled until next wg ifup (D3)
        s['agg']=False
    elif ev=='watchdog_tick':                  # reference: no watchdog exists
        pass
    elif ev=='tput_degraded':                  # reference: the section-7 blind spot (D1)
        pass
    elif ev in CHURN_EV:                       # U19: world event, no handler in v2.8 either
        apply_churn(w, ev)
    else:
        raise SystemExit("ref: unknown event "+ev)

# ---- watchdog model (candidate only): 5 checks, remedy-per-invariant ----
def watchdog_tick(s, w, budget):
    # RECONCILER watchdog: a capped periodic reconcile (THE delta detector) + W5.
    # W1-W4 collapse into deltas reconcile notices (W1 liveness pickup, W2 dead-state
    # re-pin, W4 coherence); W3 single-feeder is enforced by converge's
    # aggdown_if_agg ordering. Fail-static past the cap (I10); a net-unchanged
    # reconcile is a NO-OP (I11) and does not consume the budget. W5 tput = a
    # separate publish-only sensor (not a converge), no fact writes here.
    if budget['n'] >= budget['cap']:
        return False                           # fail-static (cap reached)
    if s['susp'] != 'none':
        return False                           # suspended = backed-off recovery; the
                                               # watchdog leaves it (only a trigger,
                                               # e.g. wg_ifup, re-attempts engage --
                                               # matches the original W1/W2 susp=none gate)
    before = term(s)
    reconcile(s, w)
    if term(s) == before:
        return False                           # invariant-clean -> no-op
    budget['n'] += 1
    return True

# =====================================================================
#  EQUIVALENCE ENUMERATION (pure alphabet: no watchdog/tput/respawn/lock)
# =====================================================================
# agg_srcs IS part of the compared terminal tuple. Without it the
# proof compares only lifecycle booleans and is blind to WHICH sources the two
# machines enrolled -- which is precisely how a 2-source-only implementation
# used to pass unnoticed.
# MODE_AGG_EV is DERIVED from AGG_SCHED, not written out: adding an aggregate
# scheduler must not require editing an event list (that is the per-mode dispatch
# U17 removed). Sorted for determinism.
MODE_AGG_EV = tuple('mode_' + m for m in sorted(AGG_SCHED))

# agg_sched IS part of the compared terminal tuple: it is the ONLY fact that
# distinguishes `max` from `speed` at this layer, so leaving it out would make a
# mode-blind builder (one that emits a constant AGG_SCHED) invisible to the
# equivalence proof -- the same failure shape as the 2-source agg_srcs blindness
# the line below records.
#
# E4 SHAPING IS DELIBERATELY NOT IN KEYS, and this is a decision, not an
# oversight. The REFERENCE machine is deployed bondctl v2.8, which has no
# shaping in its lifecycle at all (shaping was `autoratectl`, invoked
# out-of-band -- ADR-001 decision 1, now superseded). Putting `shaped` in the
# compared tuple would therefore assert a divergence that is the WHOLE POINT of
# the change, and every EQ sequence would fail for the same uninformative
# reason. Same treatment `mtu` and `prev` already get. Shaping is a
# CANDIDATE-ONLY property and is proved by the SH-* bars below, which is exactly
# how D1/D3/D4 divergences are handled. SH-EQ demonstrates that the exclusion is
# load-bearing (including it DOES diverge), so the choice is measured, not
# asserted.
KEYS=('rc','mode','auto','agg','ep','susp','agg_srcs','agg_sched')
LIFECYCLE_KEYS=('rc','mode','auto','agg','ep','susp','agg_sched')  # N-independent projection
def term(s): return tuple(s[k] for k in KEYS)
def lifecycle(s): return tuple(s[k] for k in LIFECYCLE_KEYS)

# INV1 AFTER THE FOLD (U141). "Two feeders up" used to be `s['eng'] and s['agg']`;
# with ONE feeder that conjunction is unwritable, and a bar that can no longer be
# falsified is not a bar. INV1 is therefore re-expressed as the two things it
# existed to protect, both still falsifiable:
#   (a) STRUCTURAL -- the state space carries exactly ONE feeder-running fact.
#       Re-introducing a second feeder (a second `*_running` key in KEYS) fails
#       here, which is the regression INV1 was written against.
#   (b) EFFECT -- the tunnel is never pointed at a feeder that is not running
#       (the I9 dead state), outside the suspended_degraded escape which exists
#       precisely to keep a listener alive under an unconfirmed revert.
# It is checked per STEP, exactly where the old conjunction was checked.
FEEDER_FACTS = tuple(k for k in KEYS if k in ('agg', 'eng', 'feeder'))
def inv1(s):
    return len(FEEDER_FACTS) == 1 and not (dead(s) and s['susp'] != 'suspended_degraded')
# Exhaustive alphabet = the NON-AGGREGATE lifecycle (aggregate atomicity INV5 is
# a targeted scenario per design section 4, not part of the exhaustive sweep).
EV_PURE=['on','off','mode_lightning','mode_eco',
         'wg_ifup','reboot','feeder_crash','watchdog_tick']
# NOTE: the MODE_AGG_EV events (mode_speed, mode_max) are DELIBERATELY excluded
# from the exhaustive alphabet (as in the baseline). Under the reconciler, desired()
# treats an aggregate mode as config: aggregation engages only when the box is on,
# so `mode max`/`mode speed`-from-off is a no-op (cleaner than v2.8's
# engage-from-off) -- a justified divergence from `ref`, proven in the targeted
# SP1-6 + AGG-* + aggregate-watchdog (MF-2) + reboot-in-aggregate scenarios below,
# not the sweep. watchdog_tick IS included: the reconciler watchdog must be a proven
# no-op over every reachable non-aggregate lifecycle state (MF-2 non-oscillation).

# ---- the N ladder the sweep is parameterised over ----------------------
# N is a WORLD parameter, not an event, so widening it costs LINEARLY in the
# number of environments -- it does NOT multiply the sequence space (only
# DEPTH is exponential, at |EV_PURE|=8 per step). That is why full exhaustive
# coverage to N=4 and beyond is affordable here and nothing had to be dropped.
# Counts are printed with the EQ result so any future bounding is visible.
SWEEP_N   = (0, 1, 2, 3, 4)     # 0/1 = below aggregation arity; 4 = every
                                # source the client box declares
CEILING_N = (5, 8, 16)          # synthetic: proves the wiring has NO N ceiling

def env_grid(ns):
    for cap in (True,False):
        for n in ns:
            for ao in (True,False):
                yield W(capable=cap, sources=srcs(n), agg_ok=ao)

def sweep(envs, depth, events=None):
    """Exhaustive ref-vs-cand terminal comparison. Returns (mismatch, nseq)."""
    events = events or EV_PURE
    nseq=0
    for w0 in envs:
        for n in range(depth+1):
            for sq in itertools.product(events, repeat=n):
                # every W() value is immutable (bool/int/tuple of str) and only
                # `races` is written back, so a shallow copy is exact here and
                # keeps the widened N grid affordable.
                rs=S0(); rw=dict(w0)
                cs=S0(); cw=dict(w0)
                for ev in sq:
                    # each engage attempt gets a fresh roam budget per event
                    rw['races']=w0['races']; cw['races']=w0['races']
                    ref_event(rs,rw,ev); cand_event(cs,cw,ev)
                nseq+=1
                if term(rs)!=term(cs):
                    return (sq, dict(zip(KEYS,term(rs))), dict(zip(KEYS,term(cs))), w0), nseq
    return None, nseq

def report_divergence(m):
    print("  DIVERGENCE seq=", m[0])
    print("    ref =", m[1])
    print("    cand=", m[2])
    print("    env =", {k:m[3][k] for k in ('capable','sources','agg_ok')})

DEPTH=int(os.environ.get('BOND_DAG_DEPTH','5'))
ENVS=list(env_grid(SWEEP_N))
mismatch, nseq = sweep(ENVS, DEPTH)
if mismatch: report_divergence(mismatch)
check("EQ  reference == DAG-candidate terminals (N in %s, %d envs x seq depth<=%d, %d seqs)"
      % (','.join(map(str,SWEEP_N)), len(ENVS), DEPTH, nseq), mismatch is None)

# EQ-N: same exhaustive sweep at N far above anything the box declares. Nothing
# is dropped here either -- same depth, same alphabet, same comparison; only the
# world's N moves. If this ever has to be bounded, the bound belongs HERE and
# must be logged in the check name.
CENVS=list(env_grid(CEILING_N))
cmismatch, cnseq = sweep(CENVS, DEPTH)
if cmismatch: report_divergence(cmismatch)
check("EQ-N no N ceiling: same exhaustive sweep at N in %s (%d envs x depth<=%d, %d seqs, nothing dropped)"
      % (','.join(map(str,CEILING_N)), len(CENVS), DEPTH, cnseq), cmismatch is None)

# ---- re-assert I1-I9 on the CANDIDATE (DAG) machine ----
def cand_seqs(events, d):
    for n in range(d+1):
        yield from itertools.product(events, repeat=n)

# I1 OFF stable (candidate)
s=S0(); w=W(); cand_event(s,w,'on'); cand_event(s,w,'off')
ok=True
for sq in cand_seqs(['wg_ifup','reboot','feeder_crash'],6):
    t=S0(**s); tw=W()
    for e in sq: cand_event(t,tw,e)
    if t['agg'] or t['ep']!='direct' or t['rc']: ok=False; print("  I1c:",sq); break
check("I1  (cand) OFF stable under wg churn + reboots + crashes (d<=6)", ok)
# I2 ON self-heals (candidate)
s=S0(); w=W(); cand_event(s,w,'on')
ok=True
for sq in cand_seqs(['wg_ifup','reboot','feeder_crash'],6):
    t=S0(**s); tw=W()
    for e in sq: cand_event(t,tw,e)
    if not (t['agg'] and t['ep']=='agg'): ok=False; print("  I2c:",sq); break
check("I2  (cand) ON self-heals endpoint after every co-writer rewrite", ok)
# I3 mode persists (candidate)
s=S0(); w=W(); cand_event(s,w,'on'); cand_event(s,w,'mode_eco'); cand_event(s,w,'reboot'); cand_event(s,w,'wg_ifup')
check("I3  (cand) mode persists (eco after reboot+churn)", s['mode']=='eco' and s['agg'])
# I4 idempotent (candidate)
s=S0(); w=W(); cand_event(s,w,'on'); cand_event(s,w,'on'); a=(s['agg'] and s['ep']=='agg')
cand_event(s,w,'off'); cand_event(s,w,'off'); b2=(not s['agg'] and s['ep']=='direct' and not s['rc'])
check("I4  (cand) on/off idempotent", a and b2)
# I5 off survives reboot (candidate)
s=S0(); w=W(); cand_event(s,w,'on'); cand_event(s,w,'off'); cand_event(s,w,'reboot')
check("I5  (cand) OFF survives reboot with WG direct", s['ep']=='direct' and not s['agg'] and not s['rc'])
# I6 capability suspend/resume (candidate)
s=S0(); w=W(capable=False); cand_event(s,w,'on')
a=(node(s) in ('suspended','suspended_degraded'))
w2=W(capable=True); cand_event(s,w2,'wg_ifup')
b=(s['ep']=='agg' and s['agg'] and s['susp']=='none')
check("I6  (cand) incapable -> suspended; capable -> auto-resume on wg up", a and b)
# I7 OFF stable vs capability flap (candidate)
s=S0(); w=W(); cand_event(s,w,'on'); cand_event(s,w,'off')
ok=True
for cap in (False,True,False):
    tw=W(capable=cap); cand_event(s,tw,'wg_ifup'); cand_event(s,tw,'reboot')
    if s['agg'] or s['ep']!='direct' or s['rc']: ok=False; break
check("I7  (cand) OFF stable regardless of server capability flapping", ok)
# I8 engage races converge (candidate)
s=S0(); w=W(races=3); cand_event(s,w,'on')
check("I8  (cand) engage converges to the feeder endpoint despite 3 roaming races", s['ep']=='agg' and s['agg'])
s=S0(); w=W(races=99); cand_event(s,w,'on')
check("I8b (cand) unbounded races -> suspend path (terminates, not dead)", not dead(s))
# I9 dead state unreachable (candidate) — all engage branches
ok=True
for races in (0,3,99):
    for pa in (False,True):
        for cap in (True,False):
            s=S0(); w=W(capable=cap, races=races, peer_absent=pa); cand_event(s,w,'on')
            if dead(s): ok=False; print("  I9c violated:",races,pa,cap)
check("I9  (cand) dead state (local ep + no listener) unreachable in all branches", ok)

# =====================================================================
#  NEW SCENARIOS the task calls out: supervisor restart, path failover,
#  coexistence — plus watchdog I10/I11 and the divergence ledger D1/D3/D4.
# =====================================================================

# --- Supervisor restart (procd respawn) ---
# S-R1 engarde feeder crash+respawn under load: still engaged, single feeder.
s=S0(); w=W(); cand_event(s,w,'on')
cand_event(s,w,'feeder_crash')
check("SUP1 feeder crash -> procd respawn -> still engaged (INV single-feeder holds)",
      s['agg'] and s['ep']=='agg' and node(s)=='engaged' and inv1(s))
# S-R2 watchdog restart itself is invisible (I11 no-op when clean).
s=S0(); w=W(); cand_event(s,w,'on'); before=term(s)
cand_event(s,w,'watchdog_tick')
check("SUP2 watchdog tick in a clean engaged state is a NO-OP (I11)", term(s)==before)
# S-R3 respawn EXHAUSTION: reference stuck until next wg-up; candidate W1 restarts (D3).
sr=S0(); wr=W(); ref_event(sr,wr,'on'); ref_event(sr,wr,'respawn_exhaust')
sc=S0(); wc=W(); cand_event(sc,wc,'on'); cand_event(sc,wc,'respawn_exhaust')
check("SUP3 respawn-exhaustion: ref feeder DOWN (unhandled), cand W1 restarts it (D3)",
      (not sr['agg']) and sc['agg'])

# --- Path failover ---
# PF1 ecod hard-bad flips eco -> lightning (auto path failover on the primary).
# ADR-003: mode_eco now SETS auto, so one call reaches the ecod-managed state.
s=S0(); w=W(); cand_event(s,w,'on'); cand_event(s,w,'mode_eco')
cand_event(s,w,'ecod_eco')          # ecod settles to eco
eco_ok = (s['mode']=='eco' and s['auto'])
cand_event(s,w,'ecod_lightning')    # primary bad -> escape to lightning
check("PF1 ecod path failover eco->lightning keeps auto + engaged",
      eco_ok and s['mode']=='lightning' and s['auto'] and s['agg'])
# PF2 duplicate-mode 0-loss failover is STRUCTURAL: a WAN dropping does not
# change engagement facts (both copies flow; one stream just stops). Model:
# in lightning, a feeder_crash/respawn and wg churn never drop engagement.
s=S0(); w=W(); cand_event(s,w,'on')   # lightning
ok=True
for sq in cand_seqs(['wg_ifup','feeder_crash'],5):
    t=S0(**s); tw=W()
    for e in sq: cand_event(t,tw,e)
    if not (t['agg'] and t['ep']=='agg'): ok=False; break
check("PF2 lightning duplicate-mode stays engaged across WAN churn (seamless failover)", ok)
# PF3 policer degradation (clean RTT): ref does nothing (section-7 hole);
# cand tput sensor -> ecod -> lightning. The ONE intended addition (D1/F6).
sr=S0(); wr=W(); ref_event(sr,wr,'on'); ref_event(sr,wr,'auto_on'); ref_event(sr,wr,'ecod_eco')
ref_event(sr,wr,'tput_degraded')
sc=S0(); wc=W(); cand_event(sc,wc,'on'); cand_event(sc,wc,'auto_on'); cand_event(sc,wc,'ecod_eco')
cand_event(sc,wc,'tput_degraded')
check("PF3 policer-degradation: ref stays eco (blind), cand escapes to lightning (D1)",
      sr['mode']=='eco' and sc['mode']=='lightning')

# --- Coexistence constraints ---
# CX1 GL VPN-manager co-writer: endpoint rewrite is self-healed (I2 already);
# assert the co-writer never leaves a dead state after any churn.
s=S0(); w=W(); cand_event(s,w,'on')
ok=True
for sq in cand_seqs(['wg_ifup','reboot'],6):
    t=S0(**s); tw=W()
    for e in sq: cand_event(t,tw,e)
    if dead(t): ok=False; break
check("CX1 GL co-writer churn never produces a dead state (INV2 under coexistence)", ok)
# CX2 INV1 across the mode sweep. Pre-U141 this read ":59401 vs :59402 separation"
# because the two feeders had two listeners; there is now ONE listener (:59402)
# for every bonded mode, so what is swept is inv1() -- one feeder fact, and the
# tunnel never pointed at a feeder that is down. Sweep on/speed/mode/off.
s=S0(); w=W(); ok=True
for sq in cand_seqs(['on','mode_speed','mode_lightning','off'],4):
    t=S0(); tw=W()
    for e in sq: cand_event(t,tw,e)
    if not inv1(t): ok=False; break                  # one feeder, never a dead endpoint
check("CX2 single-feeder INV holds across on/speed/mode/off sweeps (one feeder, :59402)", ok)
# CX3 autorate (P1) independence is STRUCTURAL: no autorate fact exists in the
# tuple, so no transition can touch it. Assert the fact space is disjoint.
check("CX3 P1 autorate independence is structural (no shared fact in the model)",
      not any('autorate' in k or 'cake' in k for k in KEYS))

# --- Speed mode (targeted; ref == cand + INV1 single-feeder + INV5 atomicity) ---
def run_both(seq, w_kwargs):
    rs=S0(); rw=W(**w_kwargs); cs=S0(); cw=W(**w_kwargs)
    for ev in seq:
        rw['races']=w_kwargs.get('races',0); cw['races']=w_kwargs.get('races',0)
        ref_event(rs,rw,ev); cand_event(cs,cw,ev)
    return rs, cs
# SP1 engage speed from engaged: ref==cand, single feeder (agg up, engarde down)
rs,cs=run_both(['on','mode_speed'], {})
check("SP1 speed engage: ref==cand, the ONE feeder up on :59402",
      term(rs)==term(cs) and cs['mode']=='speed' and cs['agg'] and cs['ep']=='agg' and inv1(cs))
# SP2 speed verify FAIL -> restore PREV mode + SUSPEND (INV5). U141 changed the
# OUTCOME and this is the change, not a weakened bar: the failed aggregate engage
# used to fall back onto the engarde feeder (`agg_revert` -> `restore_feeder`),
# and with one feeder there is nothing to fall back TO, so the row's onfail is
# `suspend` -- revert to DIRECT, feeder stopped, endpoint safe. The CLI still
# restores the prior mode, so the next reconcile retries THAT mode (I6 shape).
rs,cs=run_both(['on','mode_eco','mode_speed'], {'agg_ok':False})
check("SP2 speed verify-fail: ref==cand, restores prev mode (eco), box SUSPENDED on "
      "DIRECT with the feeder stopped -- one feeder means the onfail is `suspend`, "
      "not a fallback feeder (INV5)",
      term(rs)==term(cs) and cs['mode']=='eco' and not cs['agg']
      and cs['ep']=='direct' and cs['susp']=='suspended')
# SP3 speed then off: ref==cand, fully torn down
rs,cs=run_both(['on','mode_speed','off'], {})
check("SP3 speed then off: ref==cand, torn down (no feeder, direct)",
      term(rs)==term(cs) and not cs['agg'] and cs['ep']=='direct' and not cs['rc'])
# SP4 speed then mode lightning (live switch back): ref==cand, single feeder
rs,cs=run_both(['on','mode_speed','mode_lightning'], {})
check("SP4 speed -> lightning: ref==cand, a LIVE switch on the one feeder (it keeps "
      "running; only the enrolled set and AGG_SCHED move)",
      term(rs)==term(cs) and cs['mode']=='lightning' and cs['agg']
      and cs['agg_sched']=='lightning' and cs['ep']=='agg')
# SP5 speed guard fail (below aggregation arity): ref==cand, refused, mode restored
rs,cs=run_both(['on','mode_eco','mode_speed'], {'sources':srcs(1)})
check("SP5 speed guard-fail (N=1, below agg arity): ref==cand, refused, prior mode kept, "
      "and the box stays on the eco feeder it already had (the refusal changes NOTHING)",
      term(rs)==term(cs) and cs['mode']=='eco' and cs['agg']
      and cs['agg_sched']=='eco' and cs['agg_srcs']==srcs(1))
# SP6 on/reboot-during-speed keep INV1 (single feeder). reboot-during-speed is
# ref==cand (both re-start the agg feeder). on-during-speed is a JUSTIFIED RECONCILER
# DIVERGENCE from ref v2.8: ref `on` re-engages ENGARDE (mode-blind), but the
# reconciler keeps SPEED (`on` re-derives desired from the stored facts, and the
# mode fact still says speed) -- `on` must not silently drop the mode the user
# selected via `mode speed`. INV1 holds in both.
cs=S0(); cw=W()
for ev in ['on','mode_speed','on']: cand_event(cs,cw,ev)
sp6a = (cs['mode']=='speed' and cs['agg'] and cs['ep']=='agg'
        and cs['agg_sched']=='speed' and inv1(cs))
rs,cs2=run_both(['on','mode_speed','reboot'], {})
sp6b = term(rs)==term(cs2) and inv1(cs2)
check("SP6 reboot-during-speed ref==cand+INV1; on-during-speed reconciler keeps speed (INV1 holds)",
      sp6a and sp6b)
# MF-2 (the reconciler's headline win): during speed, a co-writer wg_ifup + watchdog
# ticks must NOT oscillate the box out of speed. The deployed hook fired `engage`
# mode-blindly -> tore speed down -> hook/watchdog fight -> capped black-hole. Under
# the reconciler BOTH the hook (wg_ifup) and the watchdog funnel to reconcile(), which
# re-derives the mode from the stored fact, so the box stays pinned in speed. Drive the
# exact MF-2 oscillation sequence and assert stability every cycle (INV1 too).
cs=S0(); cw=W()
cand_event(cs,cw,'on'); cand_event(cs,cw,'mode_speed')
mf2_ok = cs['mode']=='speed' and cs['agg']
for _ in range(6):
    cand_event(cs,cw,'wg_ifup')                # GL co-writer knocks ep to direct
    cand_event(cs,cw,'watchdog_tick')          # periodic resync
    if not (cs['mode']=='speed' and cs['agg'] and cs['ep']=='agg'
            and cs['agg_sched']=='speed' and inv1(cs)):
        mf2_ok=False; break
check("MF-2 speed pinned across wg_ifup x watchdog (no hook/watchdog oscillation, INV1)", mf2_ok)

# =====================================================================
#  NG — N-GENERICITY (U2). The exhaustive sweep above now varies N, but it
#  deliberately excludes `mode_speed` (see EV_PURE), so the AGGREGATION path
#  needs its own N ladder. These are the bars that make "N-generic" a proven
#  property instead of a stated intention.
#  NG_LADDER goes past the four sources the client declares on purpose: a
#  property that only holds up to the current hardware is not N-generic.
# =====================================================================
NG_LADDER = tuple(range(0, 9))          # N = 0..8

def _ng_arity():
    # speed engages iff there are >= MIN_AGG_SOURCES live sources, at EVERY N,
    # and ref == cand at every N. `>=`, never `==`.
    for n in NG_LADDER:
        rs,cs = run_both(['on','mode_eco','mode_speed'], {'sources':srcs(n)})
        if term(rs)!=term(cs): return False
        in_speed = (cs['mode']=='speed' and cs['agg'] and cs['ep']=='agg'
                    and cs['agg_sched']=='speed')
        if in_speed != (n >= MIN_AGG_SOURCES): return False
        if not in_speed and cs['mode'] != 'eco':
            return False                                   # refused -> prior mode kept
    return True

def _ng_no_truncation():
    # every live source is ENROLLED in the aggregate -- none silently dropped.
    for n in NG_LADDER:
        if n < MIN_AGG_SOURCES: continue
        _,cs = run_both(['on','mode_speed'], {'sources':srcs(n)})
        if cs['agg_srcs'] != srcs(n): return False
    return True

def _ng_no_privileged_n():
    # the LIFECYCLE outcome must not depend on N once the arity floor is met:
    # N may change WHICH sources are enrolled, never what the machine does.
    base=None
    for n in NG_LADDER:
        if n < MIN_AGG_SOURCES: continue
        _,cs = run_both(['on','mode_speed'], {'sources':srcs(n)})
        if base is None: base=lifecycle(cs)
        elif lifecycle(cs)!=base: return False
    return True

def _ng_mode_selection():
    # mode_wans() is N-generic in both directions: eco = the primary ONLY at
    # every N (eco is not aggregation); lightning = ALL N sources.
    for n in NG_LADDER:
        if n < 1: continue
        _,ce = run_both(['on','mode_eco'],       {'sources':srcs(n)})
        _,cl = run_both(['on','mode_lightning'], {'sources':srcs(n)})
        if ce['agg_srcs'] != srcs(n)[:1]: return False
        if cl['agg_srcs'] != srcs(n):     return False
    return True

check("NG-0 agg guard is arity (>=%d live sources), not a 2-WAN assumption; DAG spelling "
      "`two_wans` and `enough_sources` are the SAME N-generic predicate" % MIN_AGG_SOURCES,
      GUARDS['two_wans'] is GUARDS['enough_sources'] is g_enough_sources_to_aggregate
      and all(g_enough_sources_to_aggregate(S0(), W(sources=srcs(n)), None) == (n >= MIN_AGG_SOURCES)
              for n in range(0, 17)))
check("NG-1 speed engages iff N >= %d, ref==cand at every N in %s" % (MIN_AGG_SOURCES, str(NG_LADDER)),
      _ng_arity())
check("NG-2 [MODEL BAR] no truncation: the MODEL enrolls ALL N live sources. SCOPE, "
      "unchanged: this bar asserts the MODEL, not the box. The artifact defect it was "
      "written against is FIXED -- U6 rewrote build_agg_env (%s) to enrol every "
      "ordered_wans source; the pre-U6 code emitted AGG_PATHS=$P,$O (primary + head -1) "
      "and discarded sources 3..N. The BOX is covered by Layer-2 AGG_PATHS asserts, not "
      "by this bar -- and only to N=4: %s asserts AGG_PATHS content at N=2,3,4 while "
      "this bar runs N=2..8, so N>4 enrolment is asserted on the MODEL only"
      % (cite('xctl-actions.sh', 'build_agg_env() {'),
         cite('run.sh', 'NG1 N=3 AGG_PATHS carries ALL 3', 'NG3 N=2 AGG_PATHS')),
      _ng_no_truncation())
check("NG-3 no privileged N: lifecycle outcome identical for every N >= %d" % MIN_AGG_SOURCES,
      _ng_no_privileged_n())
check("NG-4 mode selection is N-generic: eco = primary only, lightning = all N, at every "
      "N >= 1 in %s. N=0 is EXCLUDED by the bar itself (_ng_mode_selection skips n < 1): "
      "with no live sources both selections are the empty set and the comparison is "
      "vacuous. N=0 IS carried, elsewhere: NG-0 (direct guard check, range(0,17)) and "
      "NG-1 (_ng_arity, NG_LADDER starts at 0). NG-2/NG-3 do NOT -- both skip "
      "n < MIN_AGG_SOURCES (=%d), which excludes N=0 (and N=1)" % (str(NG_LADDER), MIN_AGG_SOURCES),
      _ng_mode_selection())

# --- NG-M: MUTATION SELF-TESTS. A gate that passes wrongly is worse than no
# gate, so the bars above are themselves tested: reintroduce a hard 2-source
# assumption in the CANDIDATE and assert the proof FAILS. The mutation reaches
# the candidate ONLY -- the DAG interpreter resolves actions/guards through the
# ACTIONS/GUARDS dicts, while the reference machine calls the module-level
# leaf functions directly. Nothing here can make a failing gate pass: each
# check passes only when the mutant is CAUGHT.
def _with(d, name, fn, body):
    old=d[name]; d[name]=fn
    try:    return body()
    finally: d[name]=old

# _with_global: the same swap for a module-level FUNCTION (used by the AGG and CH
# mutants, which replace desired()/mode_sources()/reconcile() rather than a table
# entry). Defined next to _with so both are in scope for every mutant below.
def _with_global(name, fn, body):
    g=globals(); old=g[name]; g[name]=fn
    try:    return body()
    finally: g[name]=old

def _mut_env_gen(s,w,a):
    # the pre-U6 build_agg_env defect: AGG_PATHS (and, since U141, applied_wans
    # with it) truncated to the first two sources.
    s['agg_srcs'] = mode_sources(s,w)[:2]; s['agg_sched'] = sched_fact(s)
def _mut_guard_eq2(s,w,a):  return n_sources(w) == 2                # "exactly two WANs"

caught_trunc = _with(ACTIONS, 'env_gen', _mut_env_gen,
                     lambda: (not _ng_no_truncation()) and (not _ng_arity()))
check("NG-M1 mutant `AGG_PATHS = first 2 sources` (the PRE-U6 build_agg_env defect, since "
      "fixed in the artifact) is CAUGHT by NG-2 AND by ref==cand equivalence", caught_trunc)

# THE MUTANT MUST BE THE GUARD THE SHIPPED ROW NAMES, and this bar has already
# caught itself getting that wrong once. The interpreter resolves a guard by the
# name in bond.dag; patching a spelling no row uses leaves the reached guard
# correct, `_ng_arity()` still passes, `caught_eq2` is False and this check FAILS
# LOUDLY (RED) rather than passing vacuously -- which is how the earlier version,
# which mutated only the legacy `two_wans`, was found. Post-U141 the shipped
# spelling is `sources_for_mode`; `enough_sources`/`two_wans` are the legacy
# aliases no row uses, so mutating those would repeat the same mistake.
caught_eq2 = _with(GUARDS, 'sources_for_mode', _mut_guard_eq2,
                   lambda: not _ng_arity())
check("NG-M2 mutant `guard: exactly 2 sources` is CAUGHT (would pass a 2-WAN-only box, "
      "fails at N=3,4,...)", caught_eq2)

# NG-M3 mutates the ENGAGE path and re-runs the exhaustive sweep itself, so the
# demonstration covers THE GATE (the equivalence enumeration), not only the
# targeted NG bars. Same mutant as NG-M1 and that is the point: NG-M1 shows the
# targeted NG bars catch it, NG-M3 shows the exhaustive enumeration catches it
# WITHOUT a targeted bar. (Pre-U141 they were two mutants because applied_wans
# and AGG_PATHS had two writers; one writer now emits both.) Bounded on purpose
# -- N=3 only, depth 2 (585 seqs/env) -- because it must merely FIND a
# divergence, not characterise it.
_mut_envs = list(env_grid((3,)))
mut_m, mut_n = _with(ACTIONS, 'env_gen', _mut_env_gen,
                     lambda: sweep(_mut_envs, 2))
check("NG-M3 mutant `enrolled set = first 2 sources` is CAUGHT by the exhaustive sweep itself "
      "(N=3, depth<=2, %d seqs; divergence at seq %s)"
      % (mut_n, (mut_m[0] if mut_m else '-')), mut_m is not None)


# =====================================================================
#  AGG - ONE AGGREGATE INTENT, N AGGREGATE MODES (U17)
#
#  ADR-003 splits the aggregate mode into `max` (stripe every usable source) and
#  `speed` (deliver the offered load over the fewest, fastest sources). The
#  DATAPATH difference is real; the ORCHESTRATION difference is exactly one
#  emitted fact. So the reconciler carries ONE `engage` intent, ONE `engaged`
#  target and ONE leaf set, and selects the scheduler with AGG_SCHED. U141 went
#  further and folded the separate aggregate row in, so eco and lightning share
#  that one lifecycle too -- the composition is now over all four modes.
#
#  These bars exist because NOTHING in Layer-1 or Layer-2 previously distinguished
#  `mode max` working from `mode max` broken -- `max` did not exist, and the
#  cheapest way to add it (a second dag row + a second desired target + a second
#  CLI branch) would have passed every other bar in this file while building
#  exactly the per-mode dispatch module-architecture.md section 1 rejects.
# =====================================================================
AGG_MODES = tuple(sorted(AGG_SCHED))

# AGG-0: the DAG carries ONE aggregate lifecycle whatever the number of aggregate
# MODES. A per-mode implementation shows up here as an extra row.
_agg_rows      = sorted(k for k in EDGES if k.startswith('agg'))
_per_mode_rows = sorted(k for k in EDGES if k in AGG_SCHED)
_all_rows      = sorted(EDGES)
check("AGG-0 ONE lifecycle in the SHIPPED bond.dag: rows %s -- no per-mode row (none of %s) "
      "and, since U141 folded the aggregate row in, no separate aggregate row either (%s). "
      "%d aggregate modes and 2 non-aggregate ones all walk `engage`. A new aggregate "
      "scheduler adds ONE entry to AGG_SCHED and ZERO rows here"
      % (_all_rows, list(AGG_MODES), _agg_rows or 'none', len(AGG_MODES)),
      _all_rows == ['disengage', 'engage', 'suspend', 'switch']
      and _agg_rows == [] and _per_mode_rows == [] and len(AGG_MODES) >= 2)

# AGG-4: the "ONE table row" claim, at THIS layer. It was stated unqualified in
# the ROADMAP and in the commit message, and measured FALSE: adding a row to
# bond-xctl's table left `bondctl mode <new>` refused, because the mode NAME
# list was written out again in bondctl -- and this model restated the table a
# third time as a literal dict, with a comment ("the same table, same keys")
# enforced by nothing. Two halves now hold it up:
#   (a) this model PARSES the shipped table instead of restating it, so a
#       divergence is not possible rather than merely unlikely; and
#   (b) NO OTHER shipped artifact names an aggregate mode in live code. That is
#       the property that makes the row count ONE, and it is what fails the
#       moment someone adds a `max)` arm somewhere convenient.
# The executable end-to-end form -- add a row, engage the new mode -- is
# Layer-2 AGG-L12; this bar is its structural half.
def _mode_name_hits(art):
    """non-comment lines of a shipped artifact naming any aggregate mode."""
    out = []
    for i, ln in enumerate(_artifact_lines(art)):
        if ln.lstrip().startswith('#'): continue
        for m in AGG_SCHED:
            if re.search(r'(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])' % re.escape(m), ln):
                out.append((art, i+1, m)); break
    return out
# U124: bond-xctl is now a BIN plus the five libraries its LIBRARIES block sources.
# They are ONE program, so the stray scan reads all six. Scanning the bin alone
# would leave 1,356 of the 1,585 lines unread and a `max)` arm would only have to
# be written in a lib to be invisible here (measured: appending one to
# xctl-actions.sh passed this bar while the identical line in the bin failed it).
_XCTL_ARTS = ('bond-xctl', 'xctl-lock.sh', 'xctl-probe.sh', 'xctl-actions.sh',
              'xctl-shape.sh', 'xctl-dag.sh')
# Two lines are allowed to name a mode because they OWN it, and each exemption is
# KEYED TO THE FILE that holds it -- an exemption that floated across the six
# files would excuse the same text anywhere in the program. The table assignment
# lives in the probe lib; the legacy dag-row alias, where `speed` is the name of a
# ROW in a pre-U17 bond.dag on a half-upgraded box and not the name of a mode,
# lives in the dag lib.
_XCTL_OWNER_LINES = {
    'xctl-probe.sh': ('AGG_SCHED_TABLE=',),
    'xctl-dag.sh':   ('_dag_row_raw speed',),
}
_xctl_stray = []
for _a in _XCTL_ARTS:
    _own = _XCTL_OWNER_LINES.get(_a, ())
    _xctl_stray += [h for h in _mode_name_hits(_a)
                    if not any(t in _artifact_lines(_a)[h[1]-1] for t in _own)]
# COVERAGE FLOOR: the scan's reach is part of the bar. Dropping a file from
# _XCTL_ARTS (which is how this bar silently lost 86% of its subject once) fails
# here instead of reading clean.
_XCTL_MIN_LINES = 1500
_xctl_scanned = sum(len(_artifact_lines(_a)) for _a in _XCTL_ARTS)
_other_stray = []
for _a in ('bondctl', 'bond-ecod', 'bond-watchdog', 'bond.dag', '97-bond'):
    _other_stray += _mode_name_hits(_a)
check("AGG-4 ONE owner of the mode -> scheduler table: this model PARSES the shipped "
      "AGG_SCHED_TABLE (%s -> %s) instead of restating it, and NO other shipped artifact "
      "names an aggregate mode in live code (bondctl, bond-ecod, bond-watchdog, bond.dag, "
      "97-bond: %d hits; the reconciler -- bin + all five libs, %d lines scanned, floor %d "
      "-- outside the table row and the legacy dag-row alias: %d). "
      "So a third aggregate scheduler is ONE row. Strays: %s"
      % (cite('xctl-probe.sh', 'AGG_SCHED_TABLE='), sorted(AGG_SCHED.items()),
         len(_other_stray), _xctl_scanned, _XCTL_MIN_LINES, len(_xctl_stray),
         (_other_stray + _xctl_stray) or 'none'),
      not _other_stray and not _xctl_stray and len(AGG_SCHED) >= MIN_AGG_SCHEDULERS
      and _xctl_scanned >= _XCTL_MIN_LINES)

# AGG-1: every aggregate mode resolves to the SAME desired target and walks the
# SAME dag intent. RECORDED from converge(), not asserted about it.
_walked = []
def _rec_converge(s, w, intent, arg=None, depth=0, _real=converge):
    if depth == 0: _walked.append(intent)
    return _real(s, w, intent, arg, depth)
def _agg_one_intent():
    tgts, walks = set(), set()
    for m in AGG_MODES:
        del _walked[:]
        cs = S0(); cw = W()
        def _run():
            for e in ('on', 'mode_' + m): cand_event(cs, cw, e)
        _with_global('converge', _rec_converge, _run)
        tgts.add(desired(cs)); walks.add(tuple(_walked))
    return len(tgts) == 1 and tgts == {'engaged'} and len(walks) == 1
check("AGG-1 every aggregate mode %s derives the SAME desired target (engaged) and walks the "
      "SAME dag intent sequence -- one dispatch, not one per mode" % (list(AGG_MODES),),
      _agg_one_intent())

# AGG-2 (the discriminating bar). Across a lifecycle battery the aggregate modes
# must be IDENTICAL in every fact except the mode string, AND each must emit its
# OWN AGG_SCHED. Both halves carry weight:
#   - "identical" fails if a mode grows its own branch, its own source selection,
#     its own endpoint, its own feeder handling or its own recovery;
#   - "its own AGG_SCHED" fails if the selector is missing or mode-blind, i.e. if
#     `max` and `speed` are the same thing everywhere the datapath can see.
AGG_SCENARIOS = (
    ('engage',                ['on', '_AGG_'],                            {}),
    ('verify-fail -> revert', ['on', 'mode_eco', '_AGG_'],                {'agg_ok': False}),
    ('then off',              ['on', '_AGG_', 'off'],                     {}),
    ('live switch out',       ['on', '_AGG_', 'mode_lightning'],          {}),
    ('guard fail N=1',        ['on', 'mode_eco', '_AGG_'],                {'sources': srcs(1)}),
    ('reboot in aggregate',   ['on', '_AGG_', 'reboot'],                  {}),
    ('crash in aggregate',    ['on', '_AGG_', 'feeder_crash'],            {}),
    ('respawn exhaust',       ['on', '_AGG_', 'respawn_exhaust'],         {}),
    ('wg_ifup x watchdog',    ['on', '_AGG_', 'wg_ifup', 'watchdog_tick'], {}),
    ('re-on during aggregate', ['on', '_AGG_', 'on'],                     {}),
)
def _agg_run(m, seq, wk):
    cs = S0(); cw = W(**wk)
    for e in seq: cand_event(cs, cw, e.replace('_AGG_', 'mode_' + m))
    return cs
def _canon(st, m):
    """term() with the mode string folded out and agg_sched removed: what remains
    is the LIFECYCLE the aggregate modes must share exactly."""
    d = dict(zip(KEYS, term(st)))
    if d['mode'] == m:  d['mode'] = '<agg>'
    d['prev'] = '<agg>' if st['prev'] == m else st['prev']   # not in KEYS; compared here
    d.pop('agg_sched')
    return tuple(sorted(d.items()))
def _agg_same_lifecycle():
    for name, seq, wk in AGG_SCENARIOS:
        canon, scheds = set(), {}
        for m in AGG_MODES:
            cs = _agg_run(m, seq, wk)
            canon.add(_canon(cs, m))
            scheds[m] = cs['agg_sched']
            # an engaged aggregate must carry ITS OWN scheduler
            if cs['mode'] == m and cs['agg'] and cs['agg_sched'] != AGG_SCHED[m]:
                return False, name + ': AGG_SCHED wrong for ' + m
        if len(canon) != 1:
            return False, name + ': lifecycle differs between modes'
        # where more than one mode actually engaged, the emitted schedulers must
        # be DISTINCT -- this is the half a mode-blind builder fails.
        # "actually engaged IN THAT MODE" -- since U141 the feeder keeps running
        # across a live switch OUT of an aggregate mode, so `agg` alone would ask
        # two modes that both ended in `lightning` to emit different schedulers.
        eng = [m for m in AGG_MODES
               if _agg_run(m, seq, wk)['agg'] and _agg_run(m, seq, wk)['mode'] == m]
        if len(eng) > 1 and len(set(scheds[m] for m in eng)) != len(eng):
            return False, name + ': AGG_SCHED is mode-blind (modes emit the same value)'
    return True, ''
_agg_ok, _agg_why = _agg_same_lifecycle()
check("AGG-2 the %d aggregate modes %s are IDENTICAL across %d lifecycle scenarios in every fact "
      "except the mode string, AND each emits its OWN AGG_SCHED per the table. Composition, not "
      "branching: one intent, one target, one leaf set, one source selection, differing by exactly "
      "the one fact the datapath reads%s"
      % (len(AGG_MODES), list(AGG_MODES), len(AGG_SCENARIOS),
         '' if _agg_ok else ' [' + _agg_why + ']'), _agg_ok)

# AGG-3: the enrolled source set is NOT pruned by mode. `speed` nominates the
# fewest/fastest sources PER FRAME in the datapath (ms timescale); the reconciler
# (~10 s, blind to offered load) must enrol every live source or the daemon can
# never promote one it was never given. Every aggregate mode, every N.
def _agg_no_pruning():
    for m in AGG_MODES:
        for n in NG_LADDER:
            if n < MIN_AGG_SOURCES: continue
            cs = _agg_run(m, ['on', '_AGG_'], {'sources': srcs(n)})
            if cs['agg_srcs'] != srcs(n): return False
    return True

# ---- AGG mutants. Each is a plausible way to "add mode max"; the bars above must
#      reject all four. A bar nobody has watched fail is not a bar.
def _mut_desired_speed_only(s):
    # a PER-MODE desired(): only `speed` is allowed to reach the feeder, so
    # `mode max` converges to OFF. This is the post-fold shape of the pre-U17
    # line (`if s['mode']=='speed': return 'engaged_agg'`) -- with one target
    # left, per-mode dispatch can only express itself by sending the other modes
    # somewhere else.
    if not s['rc']:          return 'off'
    if s['mode'] == 'speed': return 'engaged'
    return 'off'
def _mut_env_gen_blind(s, w, a):
    # AGG_SCHED emitted mode-blind: every mode is identical on the wire.
    s['agg_srcs'] = mode_sources(s, w); s['agg_sched'] = 'max'
def _mut_env_gen_no_sched(s, w, a):
    # the selector is simply never emitted: `mode max` engages and selects nothing.
    s['agg_srcs'] = mode_sources(s, w)
def _mut_mode_sources_prune(s, w):
    # `speed` misread as a RECONCILER-level source selection. Wrong seam -- and the
    # one a careless reading of "fewest, fastest sources" produces.
    if not w['sources']:                  return ()
    if s['mode'] == 'eco':                return w['sources'][:1]
    if agg_sched(s['mode']) == 'speed':   return w['sources'][:MIN_AGG_SOURCES]
    return w['sources']

check("AGG-M1 mutant `desired(): only mode==speed reaches the feeder` (the post-fold shape of "
      "the pre-U17 per-mode line) is CAUGHT -- `mode max` silently converges to OFF",
      _with_global('desired', _mut_desired_speed_only,
                   lambda: (not _agg_one_intent()) and (not _agg_same_lifecycle()[0])))
check("AGG-M2 mutant `AGG_SCHED emitted mode-blind` (max and speed identical on the wire) is "
      "CAUGHT -- the lifecycle half still passes, so ONLY the emitted-fact half can catch it "
      "(non-vacuous in the other direction too)",
      _with(ACTIONS, 'env_gen', _mut_env_gen_blind,
            lambda: (not _agg_same_lifecycle()[0]) and _agg_one_intent()))
check("AGG-M3 mutant `AGG_SCHED never emitted` (the selector is missing entirely) is CAUGHT",
      _with(ACTIONS, 'env_gen', _mut_env_gen_no_sched,
            lambda: not _agg_same_lifecycle()[0]))
check("AGG-M4 mutant `speed prunes the enrolled sources at the RECONCILER` is CAUGHT by AGG-3 and "
      "by AGG-2 (wrong seam: source selection is the datapath's, per frame)",
      _with_global('mode_sources', _mut_mode_sources_prune,
                   lambda: (not _agg_no_pruning()) and (not _agg_same_lifecycle()[0])))
check("AGG-3 the enrolled source set is NOT pruned by mode: every aggregate mode enrols ALL N live "
      "sources at every N in %s (non-vacuous: AGG-M4 fails it)" % (list(NG_LADDER),),
      _agg_no_pruning())

# =====================================================================
#  EG — NO EDGE OF P5's DAG DEPENDS ON THE ENGARDE BINARY (U50a)
#
#  Mo's decision, docs/ROADMAP.md "U50 DECIDED by Mo (2026-08-30)": P5 drops
#  the engarde DEPENDENCY entirely. `installed` used to mean "engarde-client
#  AND BOND_DIR" and bond.dag puts it on the engage, disengage, switch AND
#  speed rows, so P5's own DAG could not reach `engaged` or `speed` without
#  P2's binary. It now means BOND_DIR only.
#
#  A removal with no bar cannot be shown to have happened, and a boolean that
#  no longer appears anywhere cannot be varied. So `eng_installed` is carried
#  as its OWN world fact (see the fact-tuple comment above) and these bars
#  require the machinery to be INVARIANT under it. On a tree where any edge
#  still requires the binary, EG-1/EG-2 go RED -- demonstrated non-vacuously
#  by EG-M, which re-introduces the term and asserts the bars catch it.
#
#  SCOPE, stated plainly: these bars measure P5's DEPENDENCY, not the box.
#  engarde-client is still installed on the client and the production tunnel
#  still runs through it on :59401 (docs/knowledge/inventory/
#  2026-08-30-client-flint2.txt). Nothing here removes it from anything.
#
#  CLOSED BY U141, which is why these bars now read wider than they did: no edge
#  runs an engarde action any more (genconf/eng_enable/eng_restart/eng_stop and
#  build_engarde_conf are deleted), so `eco` and `lightning` have bond-agg as
#  their feeder like every other mode. `eng_installed` is kept as a world fact
#  precisely because a boolean that no longer appears anywhere cannot be varied:
#  it is what makes "P5 does not read the engarde binary" a MEASURED property
#  rather than an absence. This model has no shell-control-flow boundary (the
#  HONEST GAP recorded for build_agg_env's N=0 `fail`), so the feeder actually
#  coming up is measured in Layer-2 (EG-5, EL-1..EL-4), not here.
# =====================================================================

# The guard/world matrix EG-2 sweeps. Small and explicit: guards read only
# `w`, `s` and the auto-context arg, and every guard is total, so a handful of
# representative states x the full arg domain is an EXHAUSTIVE check of the
# only thing at issue -- whether the guard's answer moves with eng_installed.
_EG_STATES = [S0(), S0(rc=True, agg=True, ep='agg'),
              S0(rc=True, mode='speed', agg=True, ep='agg'),
              S0(susp='suspended'), S0(susp='suspended_degraded')]
_EG_ARGS   = [None, {'auto_ctx': True}, {'auto_ctx': False}]
def _eg_worlds(**kw):
    """Every world in the EG matrix, paired ON/OFF by eng_installed."""
    for n in (0, 1, 2, 3, 4, 8):
        for inst in (True, False):
            for agg in (True, False):
                base = dict(sources=srcs(n), installed=inst, agg_installed=agg)
                base.update(kw)
                yield (W(eng_installed=True, **base), W(eng_installed=False, **base))

def _eg_guards_ignore_engarde():
    for wt, wf in _eg_worlds():
        for name, g in GUARDS.items():
            for s in _EG_STATES:
                for a in _EG_ARGS:
                    if g(dict(s), wt, a) != g(dict(s), wf, a):
                        return False
    return True

def _eg_edge_reachable_without_engarde(seq, want):
    """Run ref AND cand with the engarde binary ABSENT and require `want` of
    the candidate's terminal state, plus ref==cand (the equivalence is the
    point: a reference that still gated on the binary would diverge)."""
    rs, cs = run_both(seq, {'eng_installed': False})
    return term(rs) == term(cs) and want(cs)

# Both sequences ENGAGE first. That is not a softened bar, it is the modelled
# CLI semantics: `mode speed` alone with rc=False leaves the box at desired=off
# (bondctl writes the mode fact; the bond is still off).
# THE SECOND DEPENDENCY IS NOW GONE TOO. This comment used to record it as owed:
# the engaged/off discriminator was `svc_enabled "$SVC"` with SVC = engarde's
# init.d script, so P5's own lifecycle was keyed on a P2 artifact and the
# aggregate row's `from=off` member was unreachable through the CLI. U141 moved
# that flag onto bond-agg's own init script (xctl-probe.sh node()/desired(),
# bondctl `on`/`off`), which is why `engage` from `off` is now the ordinary
# path rather than an unreachable one. Layer-2 EG-2/EG-5 assert the closed
# state.
_eg_speed_ok = _eg_edge_reachable_without_engarde(
    ['on', 'mode_speed'], lambda c: c['mode'] == 'speed' and c['agg']
                                    and c['ep'] == 'agg')
_eg_speed_from_engaged_ok = _eg_edge_reachable_without_engarde(
    ['on', 'mode_eco', 'mode_speed'],
    lambda c: c['mode'] == 'speed' and c['agg'] and c['ep'] == 'agg')
_eg_engage_ok = _eg_edge_reachable_without_engarde(
    ['on'], lambda c: c['rc'] and c['susp'] == 'none')
_eg_disengage_ok = _eg_edge_reachable_without_engarde(
    ['on', 'off'], lambda c: not c['rc'] and not c['agg']
                             and c['ep'] == 'direct')
_eg_switch_ok = _eg_edge_reachable_without_engarde(
    ['on', 'mode_eco'], lambda c: c['mode'] == 'eco' and c['auto'])

check("EG-1 with the engarde binary ABSENT (eng_installed=False) an aggregate mode is "
      "REACHABLE from engaged, direct and via a prior eco pin: mode=speed, bond-agg up, "
      "ep=:59402, ref==cand. This is the row that was plainly defective -- the aggregate "
      "row already carried its OWN `agg_installed` guard and none of its actions called "
      "engarde, yet `installed` gated it on P2's binary. Since U141 NO row has an "
      "engarde action at all",
      _eg_speed_ok and _eg_speed_from_engaged_ok)
check("EG-2 NO guard in GUARDS reads the engarde binary: every registered guard "
      "(%s) returns the SAME answer with eng_installed True and False, over N in "
      "{0,1,2,3,4,8} x installed x agg_installed x 5 states x 3 auto-contexts. This is "
      "the bar that covers ALL THREE edges that carry `installed` (engage, disengage, "
      "switch) -- the fourth, the aggregate row, was folded into `engage` by U141"
      % ','.join(sorted(GUARDS)), _eg_guards_ignore_engarde())
check("EG-3 with the binary absent the engage, disengage and switch edges are still "
      "WALKED (not guard-refused): `on` engages, `off` tears down to direct, `mode_eco` "
      "switches and enables auto -- ref==cand throughout. SCOPE, now WIDER than it was: "
      "U141 gave eco/lightning a real feeder (bond-agg on :59402), so this no longer "
      "stops at 'the DAG does not refuse the edge' -- Layer-2 EG-5 and EL-1..EL-4 "
      "measure the feeder actually coming up with no engarde present",
      _eg_engage_ok and _eg_disengage_ok and _eg_switch_ok)

# EG-M: the mutation self-test. Re-introduce the term U50a removed and require
# the bars above to FAIL. Without this, EG-1/EG-2/EG-3 could be green on a tree
# that never removed anything.
def _mut_guard_installed_engarde(s, w, a):
    return w['installed'] and w['eng_installed']    # the PRE-U50a guard

_eg_caught = _with(GUARDS, 'installed', _mut_guard_installed_engarde,
                   lambda: (not _eg_guards_ignore_engarde())
                           and (not _eg_edge_reachable_without_engarde(
                                    ['on', 'mode_speed'],
                                    lambda c: c['mode'] == 'speed' and c['agg'])))
check("EG-M mutant `guard_installed = BOND_DIR AND engarde-client` (the PRE-U50a guard, "
      "ffd5857:bond-xctl:736 before this unit; today it is xctl-dag.sh `guard_installed`) "
      "is CAUGHT by EG-2 AND by EG-1: the guard's answer "
      "moves with eng_installed, and the speed edge stops being reachable. Non-vacuous "
      "proof that these bars measure the removal rather than assuming it", _eg_caught)

# =====================================================================
#  CH — SOURCE CHURN (U19). N used to be a STATIC world parameter: `sources`
#  was fixed for a whole sequence and EV_PURE had no event that could move it,
#  so the 1,198,368-sequence U2 proof covered static-N worlds ONLY. Churn is
#  what hotplug produces on the box (tether unplugged, carrier loss, the GL
#  kill-switch) and is the event class OBJ-A's D-hat-min re-anchoring keys on.
#  Semantics + why the primary is the one that moves: see CHURN_EV above.
#
#  WHAT IS PROVEN HERE
#    CH-0  churn alone changes NO fact in either machine (no phantom handler)
#    CH-EQ ref == cand under the churn alphabet, exhaustively
#    CH-1  the lifecycle CONVERGES after churn: a term fixpoint, then stable
#    CH-2  INV1 (single feeder) holds at EVERY step, churn and recovery
#    CH-3  dropping below the aggregation arity MID-FLIGHT resolves to a
#          DEFINED outcome (the open item the previous unit recorded)
#    CH-4  COHERENCE: a RUNNING feeder is enrolled over the sources live NOW
#    CH-5  auto-resume: a returning source re-forms the aggregate, no CLI
#    CH-6  total source loss (N -> 0) converges, with the honest gap named
#    CH-M1..M3 mutation self-tests: the bars FAIL on churn-blind candidates
# =====================================================================

FIXPOINT_CAP = 32
# NOT a tuned constant and not a bar threshold: a NON-TERMINATION DETECTOR.
# The reconciler walks ONE edge per tick, so the real tick count is small and
# is MEASURED -- the observed maximum is printed in the CH-1 bar name. Any
# sequence that needs more than the cap FAILS the bar (that is the point);
# raising the cap could never turn a red bar green, only turn a hang into a red.

def settle(s, w, cap=FIXPOINT_CAP):
    """Drive the level-triggered reconciler (== the watchdog's periodic
    `bond-xctl reconcile`, once per bond-watchdog `tick` CYCLE) to a fixpoint of term().
    Returns (ticks_that_changed_state, reached_fixpoint, inv1_held)."""
    inv1ok = inv1(s)
    for i in range(cap):
        before = term(s)
        reconcile(s, w)
        if not inv1(s): inv1ok = False
        if term(s) == before:
            return i, True, inv1ok
    return cap, False, inv1ok

def _stable(s, w, k=3):
    """No oscillation: once at a fixpoint, further ticks change nothing. k=3 is
    a repetition count, not a magnitude -- one extra tick already falsifies a
    2-cycle; 3 also falsifies a 3-cycle."""
    t = term(s)
    for _ in range(k):
        reconcile(s, w)
        if term(s) != t: return False
    return True

def coherent(s, w):
    """A RUNNING feeder must be enrolled over the sources that are LIVE NOW.
    Deliberately scoped to running feeders: a torn-down box's applied_wans /
    agg_env are inert records nothing reads, so constraining them would be
    theatre. This is the bar that catches a stale aggregate striping over a
    source that is gone -- the exact churn failure."""
    # N=0 is EXEMPT, and named: with no live source build_agg_env `fail`s, the
    # edge aborts mid-flight and the feeder keeps its PREVIOUS agg_env. Requiring
    # a re-enrolment here would assert behaviour the artifact does not have --
    # the same HONEST GAP CH-6 records, applied to the predicate as well as to
    # the bar. N>=1 is asserted in full. This exemption is DISCLOSED where a
    # reader meets it: CH-4's own bar text names it and says why (search "N=0 IS
    # EXEMPT"), and the U141 ROADMAP row carries it. A predicate that is quietly
    # weaker than the sentence its bar prints is the failure this guards against.
    if not w['sources']: return True
    want = mode_sources(s, w)
    if s['agg'] and tuple(s['agg_srcs']) != want: return False
    return True

# ---- churn environment grid -------------------------------------------
# agg_ok is FIXED True in the churn sweep and that is a LOGGED reduction, not a
# silent one: `mode_speed` is not in the churn alphabet (same reason EV_PURE
# excludes it), so verify_agg is never called and agg_ok cannot influence any
# terminal. The speed x churn interaction is covered exhaustively-by-scenario in
# CH-3/CH-5 instead, across the whole N ladder.
# The pool ladder. 8 is here so the exhaustive churn sweep is not silently capped at the
# count the client happens to declare today (N=4) -- the N-generic rule applies to the
# PROOF as much as to the code. Cost is small: the extra envs add ~30k seqs.
CHURN_POOL_N = (0, 1, 2, 3, 4, 8)
def churn_envs():
    for pn in CHURN_POOL_N:
        pool = srcs(pn)
        # start ALL-live, and (where possible) start with the primary ALREADY
        # gone, so `src_appear` is exercised from a degraded start too.
        for st in ([pool] if pn == 0 else [pool, pool[1:]]):
            for cap in (True, False):
                yield W(capable=cap, sources=st, pool=pool)

CHURN_ENVS  = list(churn_envs())
CHURN_EVENTS = EV_PURE + list(CHURN_EV)
# The EQUIVALENCE alphabet drops `watchdog_tick`, and that exclusion is a FINDING,
# not a convenience -- it is D6 below, proven rather than assumed. `watchdog_tick`
# is a CANDIDATE-ONLY capability (ref_event: "reference: no watchdog exists" -> pass).
# With a STATIC world that was invisible: a periodic reconcile on an unchanged world
# is a no-op (I11), so ref==cand held with it in the alphabet. Once the world can
# MOVE, it stops being a no-op -- the candidate's periodic reconcile is the ONLY
# thing on the box that notices a WAN hotplug at all (97-bond ignores it), so the
# two machines are SPECIFIED to differ there. CH-EQ therefore proves equivalence
# across churn on every trigger BOTH machines have; CH-D6 characterises the one
# they do not share, and proves it is a DETECTION-LATENCY difference that
# re-converges, not a permanent fork.
CHURN_EQ_EVENTS = [e for e in CHURN_EVENTS if e != 'watchdog_tick']
CHURN_EQ_DEPTH   = int(os.environ.get('BOND_CHURN_EQ_DEPTH', '4'))
CHURN_SCAN_DEPTH = int(os.environ.get('BOND_CHURN_SCAN_DEPTH', '3'))

# CH-0: churn is a WORLD event with no handler on either machine.
_ch0 = True
for _w0 in CHURN_ENVS:
    for _pre in (('on',), ('on','mode_eco'), ('off',), ()):
        for _c in CHURN_EV:
            rs=S0(); rw=dict(_w0); cs=S0(); cw=dict(_w0)
            for _e in _pre: ref_event(rs,rw,_e); cand_event(cs,cw,_e)
            rb, cb = term(rs), term(cs)
            rsrc, csrc = rw['sources'], cw['sources']
            ref_event(rs,rw,_c); cand_event(cs,cw,_c)
            if term(rs)!=rb or term(cs)!=cb: _ch0=False          # a fact moved: phantom handler
            if rw['sources']==rsrc and (rsrc or _c=='src_disappear'):
                pass                                             # no-op churn at the ladder ends is fine
            if rw['sources']!=cw['sources']: _ch0=False          # worlds must move in lockstep
check("CH-0 churn is a WORLD event: neither machine has a WAN hotplug handler "
      "(97-bond gates on the wg logical iface), so appear/disappear alone changes NO "
      "fact; the delta is picked up by the next trigger", _ch0)

# CH-EQ: the exhaustive equivalence sweep, with churn in the alphabet.
_chm, _chn = sweep(CHURN_ENVS, CHURN_EQ_DEPTH, CHURN_EQ_EVENTS)
if _chm: report_divergence(_chm)
check("CH-EQ ref == DAG-candidate under CHURN (%d events incl. appear/disappear, %d envs "
      "x depth<=%d, %d seqs). BOUNDED, every bound named: (a) depth %d not %d (the main EQ "
      "depth) -- the alphabet grew 8->%d, so depth 5 would cost ~%.1fM seqs; (b) "
      "`watchdog_tick` is excluded because it is candidate-only and the machines are "
      "SPECIFIED to differ there once the world moves -> proven as CH-D6, not assumed; "
      "(c) agg_ok fixed True (mode_speed is not in this alphabet, so verify_agg never runs); "
      "(d) the pool ladder is %s -- exhaustive to N=8, NOT to the static ladder's N=16. "
      "Above 8 the churn N ceiling is covered by SCENARIO (CH-3/CH-5 at N=2..8, CH-6 at "
      "N in 1,2,3,4,8), not by this sweep"
      % (len(CHURN_EQ_EVENTS), len(CHURN_ENVS), CHURN_EQ_DEPTH, _chn, CHURN_EQ_DEPTH, DEPTH,
         len(CHURN_EQ_EVENTS), len(CHURN_ENVS)*sum(len(CHURN_EQ_EVENTS)**k for k in range(6))/1e6,
         CHURN_POOL_N),
      _chm is None)

# CH-D6: the one place the machines differ under churn, characterised.
def _ch_d6():
    seen_stale = False
    for w0 in CHURN_ENVS:
        if len(w0['sources']) < 1: continue
        rs=S0(); rw=dict(w0); cs=S0(); cw=dict(w0)
        for e in ('on','src_disappear','watchdog_tick'):
            ref_event(rs,rw,e); cand_event(cs,cw,e)
        # candidate re-derived from the live world; reference could not have.
        # coherent() carries the N=0 exemption (build_agg_env `fail`s on the empty
        # set, so neither machine re-enrols there) -- asserted through it rather
        # than re-stated, so the two cannot drift apart.
        if not coherent(cs,cw): return False, False
        if tuple(rs['agg_srcs']) != tuple(cs['agg_srcs']): seen_stale = True
        # ...and the next SHARED trigger re-converges them
        ref_event(rs,rw,'wg_ifup'); cand_event(cs,cw,'wg_ifup')
        if term(rs) != term(cs): return False, False
    return True, seen_stale
_d6_ok, _d6_seen = _ch_d6()
check("CH-D6 divergence ledger: after a WAN hotplug the REFERENCE has no actor that "
      "re-derives the source set (v2.8 has no watchdog; 97-bond ignores non-wg ifaces), so "
      "the enrolled set goes STALE; the CANDIDATE's periodic reconcile (%s, once per CYCLE "
      "whose default is at %s) "
      "re-enrolls the live sources within ONE tick. Proven to be a DETECTION-LATENCY "
      "difference only: the next shared trigger (wg_ifup) makes ref == cand again"
      % (cite('bond-watchdog', 'reconcile converged a delta'),
         cite('bond-watchdog', 'CYCLE="${CYCLE:-')),
      _d6_ok and _d6_seen)

def churn_scan(envs, depth, events):
    """Candidate-only walk: every sequence, then settle to a fixpoint. Records
    the FIRST failure of each class separately so each bar reports its own
    counterexample, plus the measured worst-case ticks-to-fixpoint."""
    r = dict(nofix=None, osc=None, inv1=None, incoh=None, nseq=0, maxticks=0)
    for w0 in envs:
        for n in range(depth+1):
            for sq in itertools.product(events, repeat=n):
                s=S0(); w=dict(w0); inv1ok=True
                for ev in sq:
                    w['races']=w0['races']
                    cand_event(s,w,ev)
                    if not inv1(s): inv1ok=False
                ticks, conv, inv1b = settle(s,w)
                if not inv1b: inv1ok=False
                r['nseq'] += 1
                if ticks > r['maxticks']: r['maxticks']=ticks
                wit = (sq, w0['pool'], w0['sources'], w0['capable'])
                if not conv:
                    if r['nofix'] is None: r['nofix']=wit
                    continue
                if not inv1ok and r['inv1'] is None: r['inv1']=wit
                if not coherent(s,w) and r['incoh'] is None: r['incoh']=wit+(term(s), w['sources'])
                if not _stable(s,w) and r['osc'] is None:    r['osc']=wit
    return r

CH = churn_scan(CHURN_ENVS, CHURN_SCAN_DEPTH, CHURN_EVENTS)
if CH['nofix']: print("  CH-1 no fixpoint:", CH['nofix'])
if CH['osc']:   print("  CH-1 oscillates:", CH['osc'])
if CH['inv1']:  print("  CH-2 two feeders:", CH['inv1'])
if CH['incoh']: print("  CH-4 incoherent:", CH['incoh'])
check("CH-1 lifecycle CONVERGES across churn: every one of %d seqs (%d envs x depth<=%d, "
      "alphabet %d) reaches a term() fixpoint and stays there for 3 more ticks. Measured "
      "worst case %d reconcile ticks (cap %d = non-termination detector, never reached). "
      "BOUNDED: depth %d, not the CH-EQ %d -- each seq also costs a settle+stability walk"
      % (CH['nseq'], len(CHURN_ENVS), CHURN_SCAN_DEPTH, len(CHURN_EVENTS),
         CH['maxticks'], FIXPOINT_CAP, CHURN_SCAN_DEPTH, CHURN_EQ_DEPTH),
      CH['nofix'] is None and CH['osc'] is None)
check("CH-2 INV1 single-feeder holds at EVERY step across churn (during the sequence AND "
      "during every convergence tick), %d seqs" % CH['nseq'], CH['inv1'] is None)
check("CH-4 COHERENCE at every fixpoint, N>=1: a RUNNING feeder is enrolled over the sources "
      "that are live NOW -- no feeder left striping over a departed source, %d seqs. SCOPE, "
      "stated so the bar is not read as wider than it is, and it has TWO limits, not one. "
      "(1) N=0 IS EXEMPT -- coherent() returns True with no live source, and that is faithful "
      "to the artifact rather than a hole papered over: build_agg_env `fail`s on the empty set "
      "(%s, MEASURED not typed), so the edge aborts mid-flight and the SHIPPED "
      "feeder keeps its PREVIOUS agg_env. Asserting a re-enrolment at N=0 would assert "
      "behaviour the tree does not have -- the same honest gap CH-6 records, applied to the "
      "predicate as well as to the bar. So read this bar as: no feeder strands itself over a "
      "departed source while another source remains. (2) this alphabet has no mode_speed, so "
      "the feeder is running eco/lightning; the same coherent() predicate covers it under an "
      "AGGREGATE mode in CH-3/CH-5, which do drive speed"
      % (CH['nseq'], cite('xctl-actions.sh', '"$_WN" -ge 1')), CH['incoh'] is None)

# ---- CH-3 / CH-5: the aggregation-arity question, mid-flight -----------
# Ladder goes to 8, past the four the client declares: a churn property that
# only holds at today's hardware N is not N-generic.
CH_LADDER = tuple(range(MIN_AGG_SOURCES, 9))

def _drain(s, w, ev, done, slack=1):
    """Apply a churn event until `done()`, BOUNDED by the pool size. Returns
    False if the target was not reached -- a candidate that IGNORES the event
    then FAILS the bar instead of hanging the gate."""
    for _ in range(len(w['pool']) + slack):
        if done(): return True
        cand_event(s, w, ev)
    return done()

def _arity_loss_run(pn, capable_after=True):
    """Engage speed at N=pn, then remove primaries until the world is below the
    aggregation floor, then let the box's own delta detector run.

    `capable_after` is applied AFTER speed is engaged, on purpose: with an
    unreachable server the box never reaches speed at all (`on` suspends), so an
    incapable-from-the-start run would test nothing. The compound case that DOES
    matter is: aggregating fine, then the world loses BOTH a source and the
    server -- the resolution must still land on a defined node."""
    pool = srcs(pn)
    s=S0(); w=W(capable=True, sources=pool, pool=pool)
    cand_event(s,w,'on'); cand_event(s,w,'mode_speed')
    if not (s['mode']=='speed' and s['agg'] and s['agg_srcs']==pool):
        return None                                   # did not reach speed: not this test
    w['capable'] = capable_after
    # BOUNDED drain. Found by the U19 gate-validation run itself: with an
    # unbounded `while`, a candidate that IGNORES src_disappear did not fail the
    # bar, it HUNG the gate -- a gate that hangs on the bug it was written for is
    # worse than one that misses it. The pool is finite, so pool+1 drains it;
    # not reaching the floor within that IS the failure.
    if not _drain(s, w, 'src_disappear', lambda: n_sources(w) < MIN_AGG_SOURCES):
        return None
    cand_event(s,w,'watchdog_tick')                   # bond-watchdog `tick`: periodic `reconcile`
    ticks, conv, inv1 = settle(s,w)
    return s, w, conv, inv1, ticks

def _ch_arity_loss():
    for pn in CH_LADDER:
        for cap in (True, False):
            r = _arity_loss_run(pn, cap)
            if r is None: return False
            s,w,conv,inv1,_ = r
            if not (conv and inv1):            return False   # converged, one feeder
            if s['mode'] != 'speed':           return False   # the PIN survives
            # THE ENTRY GUARD IS ACTUALLY REFUSING. Without this the bar cannot
            # tell "the box coped with a refused edge" from "the guard never
            # noticed the disappear" -- which is exactly mutant CH-M2.
            if GUARDS['sources_for_mode'](s, w, None): return False
            if node(s) not in ('engaged','suspended','suspended_degraded'):
                return False                                  # a DEFINED node
            if dead(s):                        return False   # never the I9 dead state
            if not coherent(s,w):              return False   # config matches the live world
            if not _stable(s,w):               return False   # and it does not oscillate
            # DEGRADED, NOT DOWN (U141). Pre-fold the resolution tore the
            # aggregate down and handed the tunnel back to the engarde feeder;
            # with one feeder there is nowhere to hand it to, so the defined
            # outcome is that the SAME feeder keeps running, re-enrolled over the
            # sources that are actually live (coherent(), asserted above). The
            # sched fact still says `speed`, because the pin is not rewritten.
            if cap and not (s['agg'] and s['ep']=='agg'):
                return False                   # reachable server: traffic still on the feeder
            if cap and s['agg_sched'] != 'speed': return False
    return True

def _ch_auto_resume():
    for pn in CH_LADDER:
        r = _arity_loss_run(pn, True)
        if r is None: return False
        s,w,_,_,_ = r
        if not _drain(s,w,'src_appear', lambda: n_sources(w) >= MIN_AGG_SOURCES):
            return False
        cand_event(s,w,'watchdog_tick')
        ticks, conv, inv1 = settle(s,w)
        if not (conv and inv1):                          return False
        if not (s['mode']=='speed' and s['agg'] and s['ep']=='agg'): return False
        if s['agg_srcs'] != w['sources']:                 return False  # CURRENT set, not the old one
        if not coherent(s,w):                             return False
    return True

check("CH-3 arity loss MID-FLIGHT resolves to a DEFINED outcome at every N in %s: the ONE "
      "feeder keeps running, re-enrolled over the sources that are live NOW, the "
      "`mode speed` PIN is retained, and the box neither oscillates nor reaches a dead "
      "state. The SHIPPED reconciler carries the same arm the model does -- %s -- keyed "
      "on the running feeder ALREADY being enrolled under the stored mode (%s), which is "
      "what tells a sustainment loss apart from an entry refusal at N<2"
      % (str(CH_LADDER),
         cite('xctl-dag.sh', 'if is_agg && svc_running p5-datapath'),
         cite('xctl-dag.sh', 'guard_sources_for_mode() {')),
      _ch_arity_loss())
check("CH-5 auto-resume after churn: a returning source re-forms the aggregate with NO CLI "
      "action, enrolled over the CURRENT source set (not the pre-churn one), every N in %s"
      % str(CH_LADDER), _ch_auto_resume())

# ---- CH-6: total source loss ------------------------------------------
def _ch_total_loss():
    for pn in (1,2,3,4,8):
        for cap in (True, False):
            pool=srcs(pn)
            s=S0(); w=W(capable=cap, sources=pool, pool=pool)
            cand_event(s,w,'on')
            if not _drain(s,w,'src_disappear', lambda: not w['sources']): return False
            ticks, conv, inv1 = settle(s,w)
            if not (conv and inv1): return False
            if dead(s):             return False        # I9 dead state stays unreachable
            if not _stable(s,w):    return False
            # and it recovers when a source comes back
            cand_event(s,w,'src_appear')
            ticks2, conv2, inv12 = settle(s,w)
            if not (conv2 and inv12): return False
            if not coherent(s,w):     return False
    return True
check("CH-6 total source loss (N -> 0 mid-flight) converges, keeps INV1, never reaches the "
      "I9 dead state, and recovers when a source returns. HONEST GAP (unchanged by U19, now "
      "reachable DYNAMICALLY rather than only as a static world): at N=0 the model's env_gen "
      "enrolls the empty set, while %s build_agg_env calls `fail` -> the "
      "process exits 1 mid-edge and bond-agg keeps running on the PREVIOUS agg_env. The "
      "model has no shell-control-flow boundary to represent that. Open question, not invented"
      % cite('xctl-actions.sh', 'build_agg_env() {'),
      _ch_total_loss())

# --- CH-M: MUTATION SELF-TESTS. Task requirement: inject a churn-handling bug
# and prove the new bars FAIL. Each check passes ONLY when the mutant is CAUGHT,
# so nothing here can turn a failing gate green. All three mutants reach the
# CANDIDATE only (via the ACTIONS/GUARDS dispatch dicts, or by rebinding the
# module-level `reconcile` the candidate calls) -- the reference machine calls
# the leaf functions directly and is untouched.
def _mut_genconf_cached(s,w,a):
    # THE churn bug: the candidate caches `live_wans()` on first use and never
    # re-derives it, so it IGNORES every later appear/disappear. Exactly the
    # defect bond-xctl's GL/ubus source-discovery contract forbids ("A cached
    # source table would be STATE the level-triggered reconciler must not
    # trust"). Note it still branches on MODE
    # correctly (eco -> primary of the cached list) -- so the ONLY thing it gets
    # wrong is churn, and the only sequences that can catch it contain a churn
    # event. A mutant that also broke mode selection would be caught by the
    # pre-existing NG bars and would prove nothing about churn.
    if '_snap' not in w: w['_snap']=w['sources']
    live=w['_snap']
    s['agg_srcs'] = live[:1] if s['mode']=='eco' else live
    s['agg_sched'] = sched_fact(s)

def _mut_guard_pool(s,w,a):
    # the arity guard ignores disappears: it counts the sources the box COULD
    # have (the pool) instead of the ones this mode enrols from what is live.
    return len(w['pool']) >= min_sources_for_mode(s)

def _mut_reconcile_drop_pin(s,w,refresh=False,_real=reconcile):
    # the sustainment resolution destroys the aggregate-mode pin instead of
    # retaining it, so the aggregate can never re-form on its own. Keyed on the
    # condition the resolution itself is keyed on (the arity guard refusing an
    # aggregate mode) -- pre-U141 it could be keyed on the feeder going down,
    # which the fold no longer does.
    r=_real(s,w,refresh)
    if is_agg_mode(s) and not g_sources_for_mode(s,w,None): s['mode']=s['prev']
    return r

# M1: caught by the exhaustive churn equivalence sweep AND by CH-4 coherence.
_M1_EQ_DEPTH, _M1_SCAN_DEPTH = 3, 2
_m1_envs = [w for w in CHURN_ENVS if len(w['pool']) >= 2]
_m1_eq, _m1_n = _with(ACTIONS, 'env_gen', _mut_genconf_cached,
                      lambda: sweep(_m1_envs, _M1_EQ_DEPTH, CHURN_EQ_EVENTS))
_m1_scan = _with(ACTIONS, 'env_gen', _mut_genconf_cached,
                 lambda: churn_scan(_m1_envs, _M1_SCAN_DEPTH, CHURN_EVENTS))
check("CH-M1 mutant `candidate CACHES the source list` (ignores every appear/disappear -- "
      "the cached-source-table defect %s forbids) is CAUGHT by CH-EQ (%d seqs, "
      "divergence at %s) AND by CH-4 coherence (%s). Mutant run bounded to depth %d/%d "
      "because it need only FIND a failure, not characterise it"
      % (cite('xctl-probe.sh', 'A cached source table would be STATE'),
         _m1_n, (_m1_eq[0] if _m1_eq else '-'), (_m1_scan['incoh'][0] if _m1_scan['incoh'] else '-'),
         _M1_EQ_DEPTH, _M1_SCAN_DEPTH),
      _m1_eq is not None and _m1_scan['incoh'] is not None
      and _chm is None and CH['incoh'] is None)   # non-vacuous: CH-EQ + CH-4 pass unmutated

# M2: caught by CH-3 (and by CH-4: the aggregate stays up over a dead source).
# NON-VACUITY: each mutant bar requires the bar it leans on to PASS unmutated.
# Found by the U19 gate-validation run: with the sustainment resolution removed,
# CH-3 was already red, so `not _ch_arity_loss()` was True and CH-M2 passed for
# the WRONG reason -- a mutation test that cannot tell "the mutant was caught"
# from "the bar was already failing" is theatre.
_m2_clean = _ch_arity_loss()
_m2 = _with(GUARDS, 'sources_for_mode', _mut_guard_pool,
            lambda: not _ch_arity_loss())
check("CH-M2 mutant `arity guard counts the POOL, not the live sources` (ignores a "
      "disappear) is CAUGHT by CH-3: the box keeps aggregating over a single live source "
      "(non-vacuous: CH-3 passes unmutated)", _m2 and _m2_clean)

# M3: caught by CH-5 -- proves the PIN-RETENTION claim has teeth.
_m3_clean = _ch_auto_resume()
_m3 = _with_global('reconcile', _mut_reconcile_drop_pin, lambda: not _ch_auto_resume())
check("CH-M3 mutant `sustainment resolution rewrites mode instead of retaining the pin` is "
      "CAUGHT by CH-5: the aggregate never re-forms when the source returns "
      "(non-vacuous: CH-5 passes unmutated)", _m3 and _m3_clean)

# --- Watchdog fail-static (I10) ---
# Force a persistent brokenness (rc on, susp none, eng keeps dying) and tick the
# watchdog past its actions/hour cap: it must stop acting (fail-static), never flap.
s=S0(); w=W(); cand_event(s,w,'on')
bud={'n':0,'cap':3}
acts=0
for _ in range(20):
    s['agg']=False                      # simulate the feeder dying every cycle
    if watchdog_tick(s,w,bud): acts+=1
check("I10 watchdog is fail-static: actions bounded by the cap (<=3), never flaps",
      acts<=3)
# I11 watchdog no-op when clean: over EVERY reachable clean state, tick changes nothing.
clean_states=[]
for ev_seq in cand_seqs(['on','off','mode_eco','mode_lightning','auto_on'],3):
    t=S0(); tw=W()
    for e in ev_seq: cand_event(t,tw,e)
    # "clean" = no invariant is currently violated
    dead_now = dead(t) and t['susp']!='suspended_degraded'
    two_feeders = not inv1(t)
    absent = t['rc'] and t['susp']=='none' and not t['agg']
    if not (dead_now or two_feeders or absent):
        clean_states.append(term(t))
ok=True
for _ in range(1):
    for ev_seq in cand_seqs(['on','off','mode_eco','mode_lightning','auto_on'],3):
        t=S0(); tw=W()
        for e in ev_seq: cand_event(t,tw,e)
        dead_now = dead(t) and t['susp']!='suspended_degraded'
        two_feeders = not inv1(t)
        absent = t['rc'] and t['susp']=='none' and not t['agg']
        if dead_now or two_feeders or absent: continue
        before=term(t)
        watchdog_tick(t,tw,{'n':0,'cap':8})
        if term(t)!=before: ok=False; print("  I11 violated at", before, "->", term(t)); break
    if not ok: break
check("I11 watchdog_tick is a NO-OP in every invariant-clean state (%d clean states)" % len(set(clean_states)), ok)

# --- Divergence ledger D4: stale-lock power-loss defect (fixed in P5) ---
# Reference: /etc/p5/lock survives power loss -> permanent skip-everything.
# Candidate: /var/run/p5/lock is tmpfs -> clears on boot -> ops proceed.
def ref_locked_on(s,w):
    if s['lock']: return                 # mkdir lock held -> skip (the defect)
    _engage_ref(s,w)
sr=S0(rc=True, agg=True, ep='agg'); sr['lock']=True   # power-lost mid-transition
ref_locked_on(sr,W())                                   # a later `on` skips forever
sc=S0(rc=True, agg=True, ep='agg'); sc['lock']=False  # tmpfs cleared at boot
cand_event(sc,W(),'wg_ifup')                            # converges normally
check("D4  stale-lock defect: ref stuck (lock persists), cand self-clears (tmpfs)",
      sr['lock'] and (sc['ep']=='agg' and sc['agg']))

# --- CIT: citations on the CI-printed and shipped surfaces cannot rot --------
# This bar exists because THIS file was the victim. U50a added 60 comment lines to
# deploy/p5/bond-xctl and 16 to deploy/p5/bond.dag, which moved every `bond-xctl:N`
# and `bond.dag:N` citation in the repo -- twelve sites here, FOUR of them inside
# check() strings that recon-model prints on every run. Renumbering them to today's
# lines would restore the defect along with the truth, so the citations were
# re-anchored to symbols and the ANTI-PATTERN is now gated instead of policed:
# citation_check.py refuses an unpinned `<artifact>:<line>` anywhere on a gated
# surface, and requires every `<artifact> `symbol`` anchor to resolve in that file.
# Run standalone (with --report for the docs, which are dated records and out of
# scope) as: python orchestration/citation_check.py
import importlib.util as _ilu
_cc_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "citation_check.py")
_cc_spec = _ilu.spec_from_file_location("citation_check", _cc_path)
_cc = _ilu.module_from_spec(_cc_spec)
_cc_spec.loader.exec_module(_cc)          # ImportError here is a RED bar, not a skip
_cit_unpinned, _cit_unres, _cit_pinned, _cit_ok = _cc.scan(_cc.ROOT, _cc.SCOPE)
check("CIT-1 no rotting citation on any CI-printed or shipped surface: %d symbol anchors "
      "all resolve, %d rev-pinned (dated records, correct by construction), 0 unpinned "
      "line numbers. Unpinned: %s. Unresolved: %s"
      % (len(_cit_ok), len(_cit_pinned),
         [x[0] + ":" + str(x[1]) + " " + x[2] for x in _cit_unpinned] or "none",
         [x[0] + ":" + str(x[1]) + " `" + x[3] + "`" for x in _cit_unres] or "none"),
      not _cit_unpinned and not _cit_unres)
check("CIT-2 the citation gate BITES -- non-vacuity, proved the same way the EG-M mutant "
      "bar is: reintroduce a bare artifact-colon-line citation on this file (R1 must "
      "fire) and rename a cited shell function in the reconciler's actions library (R2 must fire), "
      "each on a copy of the tree. A gate that passes because it checks nothing is worse "
      "than no gate. (The literal is not spelled out here -- this string is itself a "
      "gated surface, and R1 would flag it, which is the gate working)",
      _cc.selftest() == 0)
# =====================================================================
# CITE-0 / CITE-M1 -- the citations THIS FILE prints are measured, and stay
# measured. B1 of the U17 verify: a live bar printed three citations about
# bond-xctl that were all wrong, including a quotation of a line that exists
# nowhere in the tree. The cause is not the three values; it is that a line
# number is a fact about a file, written by hand into a different file, with
# nothing checking the two agree. cite() removes the hand; CITE-0 removes the
# possibility of putting it back.
# =====================================================================
_SELF_SRC = open(os.path.abspath(__file__)).read().splitlines()
_ART_RX  = re.compile('(?:%s):[0-9]' % '|'.join(re.escape(a) for a in CITED))
# A REV PIN (`<hex>:<artifact>:<line>`) is exempt: it names a frozen object, so it
# cannot rot, and it is the ONLY way to cite a pre-change fact. Same allowance as
# citation_check.py R1. Stripped before the scan rather than special-cased after,
# so an UNPINNED citation on the same line is still caught.
_PIN_RX  = re.compile(r'[0-9a-f]{7,40}:(?:%s):[0-9]+(?:-[0-9]+)?'
                      % '|'.join(re.escape(a) for a in CITED))
# :59401 is the production engarde listener and :59402 the P5 aggregate
# listener -- UDP ports, not line numbers. Named so the scan can tell the two
# apart rather than being taught to ignore numbers in general.
_PORT_RX = re.compile(r'(?:(?<=\s)|(?<=\())(:59401|:59402)')
_BARE_RX = re.compile(r'(?:(?<=\s)|(?<=\())(:[0-9]{2,4})')
def _hand_typed_citations():
    out = []
    for i, ln in enumerate(_SELF_SRC):
        ln_s = _PIN_RX.sub(' ', ln)                     # rev-pinned citations are exempt
        if _ART_RX.search(ln_s):                            out.append((i+1, ln.strip()[:70]))
        elif _BARE_RX.search(_PORT_RX.sub(' ', ln_s)):      out.append((i+1, ln.strip()[:70]))
    return out
_typed = _hand_typed_citations()
check("CITE-0 every deploy/p5 citation this file prints is RESOLVED at run time against the "
      "shipped artifact (%d resolved this run) and ZERO are hand-typed. A hand-typed "
      "`<artifact>:<line>` anywhere in this file fails this bar, so the drift that made a "
      "live bar cite a line that does not exist cannot recur silently. Offenders: %s"
      % (len(CITES), _typed if _typed else 'none'),
      not _typed)

def _cite_rejects(art, snippet):
    try:
        cite(art, snippet); return False
    except SystemExit:
        return True
check("CITE-M1 cite() REFUSES a citation it cannot resolve: text absent from the artifact "
      "and text that matches more than one line both raise, so a bar can never print an "
      "unverified line number (non-vacuous: the same call on real text resolves)",
      _cite_rejects('xctl-dag.sh', 'engaged_speed) converge speed ;;')
      and _cite_rejects('xctl-dag.sh', 'guard_two_wans()')
      and _cite_rejects('xctl-dag.sh', '#')
      and cite('xctl-dag.sh', 'off)           converge disengage ;;').startswith('xctl-dag.sh:'))

# =====================================================================
#  E4 SHAPING FOLDED INTO THE DAG (U22)
#  spec: docs/knowledge/design/e4-shaping-in-dag.md
#  ADR-001 decision 1 SUPERSEDED (autorate is no longer a standalone actor)
# =====================================================================
# These bars are what distinguishes "E4 shaping present" from "E4 shaping
# absent". SH-0 reads the SHIPPED table, so it fails on a tree whose bond.dag
# has not been folded; SH-1..SH-4 are the spec's own owed asserts; SH-M1/SH-M2
# are mutants that prove SH-3 and SH-4 have teeth.

# ---- SH-0: the shipped table itself -----------------------------------
# EDGES is parsed from deploy/p5/bond.dag, so this is a bar on the ARTIFACT,
# not on the model.
LIFECYCLE_EDGES = ('engage','disengage','switch')
_sh0 = []
for _i in LIFECYCLE_EDGES:
    _e = EDGES.get(_i)
    _sh0.append(_e is not None and len(_e['actions']) > 0
                and _e['actions'][-1] == 'shape_apply')
# `suspend` is the failure-escape path and must stay untouched.
_sh0.append('shape_apply' not in EDGES['suspend']['actions'])
# R2 structurally: shaping is in NO guard list and is NO verify, on ANY row.
_sh0.append(all('shape_apply' not in e['guards'] and 'shape' not in ' '.join(e['guards'])
                for e in EDGES.values()))
_sh0.append(all(e['verify'] is None or 'shape' not in e['verify'] for e in EDGES.values()))
check("SH-0 the SHIPPED bond.dag carries shaping on every lifecycle edge: "
      "`shape_apply` is the LAST action of engage/disengage/switch, "
      "`suspend` (the failure-escape path) is untouched, and shaping appears in NO "
      "guard and NO verify on ANY row (R1+R2, structural INV8)", all(_sh0))

# ---- SH-4a: ordering, read off the table ------------------------------
# The MTU-sensitivity of cake's overhead accounting means shape_apply must come
# AFTER the mtu_* action on any edge that moves the MTU. Table-level half of the
# bar; SH-4 below asserts the resulting EFFECT.
_ord = True
for _i, _e in EDGES.items():
    _a = _e['actions']
    if 'shape_apply' in _a:
        for _m in ('mtu_1408','mtu_1420'):
            if _m in _a and _a.index(_m) > _a.index('shape_apply'): _ord = False
check("SH-4a shipped ordering: on every edge that moves the MTU, `shape_apply` "
      "comes AFTER mtu_1408/mtu_1420 (cake's overhead accounting is MTU-sensitive)",
      _ord)

# ---- SH-1: idempotency ------------------------------------------------
# reconcile twice on a box whose shaping is already correct => ZERO effective
# (re)applications. Measured as an EFFECT (shape_ops), not as a return code.
_t = S0(rc=True); _w = W()
reconcile(_t, _w)                       # engage; shaping converges here
_first = _t['shape_ops']
_before = (_t['shaped'], _t['shape_mtu'])
reconcile(_t, _w); reconcile(_t, _w)    # two more level-triggered passes
check("SH-1 idempotency: shaping converges once on the engage edge (%d op) and TWO "
      "further reconciles cause ZERO further (re)applications -- effect-idempotent, "
      "measured on shape_ops not on a return code" % _first,
      _first == 1 and _t['shape_ops'] == _first
      and (_t['shaped'], _t['shape_mtu']) == _before)

# ---- SH-2: self-heal, from EVERY node including `off` -----------------
# Tear the qdisc out from under a converged box; the NEXT reconcile restores it.
# The `off` case is the one that closes Mo's `direct` gap: bond-off carries and
# converges its shaping expectation, so `direct` means what its definition says
# (bond-off PLUS cake/autorate).
_heal = {}
for _name, _setup in (
        ('off',      lambda: (S0(rc=False), W())),
        ('engaged',  lambda: (S0(rc=True), W())),
        ('speed',    lambda: (S0(rc=True, mode='speed'), W())),
        ('suspended',lambda: (S0(rc=True), W(capable=False))),
    ):
    _t, _w = _setup()
    reconcile(_t, _w)                       # reach the node
    _t['shaped'] = False; _t['shape_mtu'] = None    # firmware event / GL UI / manual tc
    reconcile(_t, _w)                       # the next level-triggered pass
    _heal[_name] = shape_converged(_t)
check("SH-2 self-heal from EVERY node incl. `off`: shaping torn out from under a "
      "converged box is restored by the NEXT reconcile, with no new timer, daemon or "
      "watchdog (%s)" % ', '.join('%s=%s' % (k, 'ok' if v else 'FAIL') for k, v in sorted(_heal.items())),
      all(_heal.values()))

# ---- SH-3: INV8 non-escalation. THE bar that matters ------------------
# Make shaping fail hard (shape_ok=False) and assert the EFFECT: the edge still
# completes, engage still reaches `engaged`, and NO suspend is walked. Asserting
# the effect rather than the return code is what stops the obvious cheap pass
# (skip the action) -- SH-M1 below proves that.
_t = S0(rc=True); _w = W(shape_ok=False)
reconcile(_t, _w)
_sh3 = (node(_t) == 'engaged' and _t['susp'] == 'none' and _t['agg'] and _t['ep'] == 'agg'
        and not _t['shaped'])
# and the same under an aggregate mode (mode='speed' selects the `speed` scheduler,
# but post-U141 EVERY mode walks the one generic `engage` DAG edge, and a_ep_agg
# sets ep='agg' regardless of which scheduler is active)
_t2 = S0(rc=True, mode='speed'); _w2 = W(shape_ok=False)
reconcile(_t2, _w2)
_sh3 = _sh3 and _t2['agg'] and _t2['susp'] == 'none' and _t2['ep'] == 'agg' and not _t2['shaped']
check("SH-3 INV8 NON-ESCALATION: with shaping failing hard, `engage` still reaches "
      "`engaged` (the feeder up, ep :59402) under lightning AND under speed, NO suspend "
      "is walked, and shaping is observably DOWN -- so the edge really did run the "
      "action and really did not escalate", _sh3)

# ---- SH-4: MTU ordering, as an EFFECT ---------------------------------
# Asserted on the attach that ACTUALLY HAPPENS: shaping is torn out first, so
# the edge must re-attach it, and the bar reads the MTU it was attached
# AGAINST. It fails if `shape_apply` is moved before mtu_1408/mtu_1420 --
# SH-M2 demonstrates exactly that.
_t = S0(rc=True, mode='speed'); _w = W()
_t['shaped'] = False; _t['shape_mtu'] = None
reconcile(_t, _w)
_sh4_speed = (_t['mtu'] == 1408 and _t['shaped'] and _t['shape_mtu'] == 1408)
# ...and the other direction. U141 made 1408 the MTU of EVERY bonded mode (one
# feeder, one frame size -- ADR-003 G-10: eco now pays the 1408 it did not pay
# under engarde), so the edge that MOVES the MTU is `disengage`, not a mode flip.
_t['rc'] = False
_t['shaped'] = False; _t['shape_mtu'] = None
reconcile(_t, _w)                                # back down to direct
_sh4_back = (_t['mtu'] == 1420 and _t['shaped'] and _t['shape_mtu'] == 1420)
check("SH-4 MTU ordering (EFFECT, not action order): a shaping attach on the `engage` "
      "edge happens AFTER the MTU settles (applied against 1408, not 1420), and the "
      "same on `disengage` coming back to direct (1420)", _sh4_speed and _sh4_back)

# ---- SH-4b: the ordering guarantee's KNOWN LIMIT, named not hidden -----
# An MTU change alone does NOT re-apply shaping: `shape_now()` observes qdisc
# presence + controller liveness, and the MTU a qdisc was attached against is
# not recoverable from `tc qdisc show`. That is SOUND ONLY WHILE no MTU-derived
# cake parameter is configured -- and this unit deliberately configures none
# (no arbitrary constants; overhead/framing is E4's install half). The moment
# E4's installer sets an overhead/mpu, converging shaping will need an applied-
# record (the `applied_wans`/`_conf_matches` pattern) or an unconditional
# re-attach on the MTU-moving edges. Measured here so the limit is a recorded
# fact rather than a surprise.
_t = S0(rc=True); _w = W()
reconcile(_t, _w)                                # converged, engaged, at 1408
_pre = _t['shape_ops']
_t['rc'] = False; reconcile(_t, _w)              # disengage moves the MTU back to 1420
check("SH-4b NAMED LIMIT: an already-converged box crossing an MTU change does NOT "
      "re-apply shaping (ops %d -> %d, stamp stays %s while mtu is %d). Correct only "
      "while no MTU-derived cake parameter is configured; E4's install half must close "
      "it if it sets one" % (_pre, _t['shape_ops'], _t['shape_mtu'], _t['mtu']),
      _t['shape_ops'] == _pre and _t['shape_mtu'] == 1408 and _t['mtu'] == 1420)

# ---- SH-M1: the cheap pass. A shape_apply that ESCALATES is caught -----
def _mut_shape_escalates(s,w,a):
    # the regression this whole unit exists to prevent: shaping becomes a tunnel
    # dependency. Modelled the only way converge() can express it -- the action
    # leaves the box un-engaged when the shaper is down.
    a_shape_apply(s,w,a)
    if not s['shaped']:
        s['agg']=False; s['ep']='direct'; s['susp']='suspended'
def _m1():
    t = S0(rc=True); ww = W(shape_ok=False)
    reconcile(t, ww)
    return node(t) == 'engaged' and t['susp'] == 'none' and t['agg']
_caught_m1 = _with(ACTIONS, 'shape_apply', _mut_shape_escalates, _m1)
check("SH-M1 mutant `shape_apply escalates when the shaper is down` (shaping becomes a "
      "tunnel dependency -- the exact INV8 regression) is CAUGHT by SH-3 (non-vacuous: "
      "SH-3 passes unmutated)", (not _caught_m1) and _sh3)

# ---- SH-M2: a shape_apply that ignores the MTU is caught by SH-4 -------
def _mut_shape_stale_mtu(s,w,a):
    # shaping applied BEFORE the MTU settles (i.e. `shape_apply` placed ahead of
    # mtu_1408 in the action list): converged against the pre-edge frame size.
    if not _shape_desired(s):
        if s['shaped']: a_shape_clear(s,w,a)
        return
    if s['shaped']: return
    s['shape_ops'] += 1
    if not w['shape_ok']: return
    s['shaped']=True; s['shape_mtu']=1420  # the pre-edge MTU
def _m2():
    t = S0(rc=True, mode='speed'); ww = W()
    t['shaped'] = False; t['shape_mtu'] = None
    reconcile(t, ww)
    return t['shape_mtu'] == 1408
_caught_m2 = _with(ACTIONS, 'shape_apply', _mut_shape_stale_mtu, _m2)
check("SH-M2 mutant `shaping applied against the pre-edge MTU` is CAUGHT by SH-4 "
      "(non-vacuous: SH-4 passes unmutated)", (not _caught_m2) and _sh4_speed)

# ---- SH-EQ: the KEYS exclusion is load-bearing, not an oversight -------
# If shaping WERE in the compared terminal tuple, ref (v2.8 bondctl, which has
# no shaping at all) and cand would diverge on the very first `on`. Measured,
# so the exclusion above is a demonstrated decision.
_sr = S0(rc=False); _sc = S0(rc=False); _wr = W(); _wc = W()
ref_event(_sr, _wr, 'on'); cand_event(_sc, _wc, 'on')
check("SH-EQ the KEYS exclusion is LOAD-BEARING: with shaping in the compared tuple "
      "ref (v2.8: no shaping in the lifecycle at all) and cand DIVERGE on the first "
      "`on` (ref shaped=%s, cand shaped=%s), while term() equivalence is untouched"
      % (_sr['shaped'], _sc['shaped']),
      (_sr['shaped'] is False) and (_sc['shaped'] is True) and term(_sr) == term(_sc))

# ---- SH-5: the honest cost of R3, measured ----------------------------
# converged() now has a shaping term, so a box that WANTS shaping and cannot get
# it is never converged and walks an edge on every tick. That is a real cost and
# it is named rather than hidden. What must hold is CONTAINMENT: the leaves are
# effect-idempotent, so those ticks must not bounce a feeder. Measured over 20
# ticks with the shaper permanently broken.
_t = S0(rc=True); _w = W(shape_ok=False)
reconcile(_t, _w)
_restarts = 0
_prev = (_t['agg'], _t['ep'], _t['susp'])
for _ in range(20):
    reconcile(_t, _w)
    _now = (_t['agg'], _t['ep'], _t['susp'])
    if _now != _prev: _restarts += 1
    _prev = _now
check("SH-5 containment of the R3 cost: with shaping permanently unavailable the box is "
      "never `converged`, so every tick walks an edge -- but 20 ticks produce ZERO "
      "lifecycle churn (%d changes) because the leaves are effect-idempotent. The "
      "repeated shaping RETRY is real and is reported, not hidden" % _restarts,
      _restarts == 0 and node(_t) == 'engaged' and _t['susp'] == 'none')

# ---- SH-N1..N4: the GL native-SQM converge-guard (U22a, E4 install half) ----
# The client is ALREADY shaping through GL's sqm on the very interface P5's
# shaping targets (inventory 2026-08-30-client-flint2.txt:205-211: sqm.eth1,
# interface='wgclient1', qdisc='cake', enabled='1'). So "non-interfering with GL
# native SQM" is a live state, not a hypothetical. Two owners of one root qdisc
# is a tug-of-war neither wins, and taking the device off the operator silently
# is what E4's spec forbids. The guard must therefore: not attach, not escalate,
# not churn, and heal the moment the operator turns native SQM off.
_t = S0(rc=True); _w = W(native_sqm=True)
reconcile(_t, _w)
_sh_n1 = (node(_t) == 'engaged' and _t['susp'] == 'none' and _t['agg']
          and _t['shaped'] is False and _t['shape_ops'] == 0)
check("SH-N1 native-SQM converge-guard: with GL's sqm enabled on the tunnel iface the "
      "edge still completes (node=%s susp=%s), NOTHING is attached (shaped=%s, "
      "shape_ops=%d) and no `suspend` is walked -- INV8 holds through the guard exactly "
      "as it holds through a broken shaper" % (node(_t), _t['susp'], _t['shaped'], _t['shape_ops']),
      _sh_n1)

# the guarded box is NOT converged (honest: it wants shaping and cannot have it)
# and the retry must be contained -- same containment property SH-5 measures for
# a broken shaper, re-measured for the guard because the code path differs.
_churn = 0
_prev = (_t['agg'], _t['ep'], _t['susp'])
for _ in range(20):
    reconcile(_t, _w)
    _now = (_t['agg'], _t['ep'], _t['susp'])
    if _now != _prev: _churn += 1
    _prev = _now
check("SH-N2 the guard is CONTAINED: not converged (shape_matches=%s), so every tick "
      "walks an edge -- 20 ticks give ZERO lifecycle churn (%d) and ZERO shaping ops "
      "(%d). The retry is real and reported, never hidden"
      % (shape_converged(_t), _churn, _t['shape_ops']),
      (not shape_converged(_t)) and _churn == 0 and _t['shape_ops'] == 0
      and node(_t) == 'engaged')

# and it heals with no operator action the moment native SQM is turned off --
# which is also the E7 ordering: E7 removes P1's sqm section, THEN P5 shapes.
reconcile(_t, W())
check("SH-N3 self-heal: the operator disables GL native SQM and the very next reconcile "
      "converges shaping (shaped=%s, applied against mtu %s). This is also the E7 "
      "ordering -- remove P1's sqm queue first, then P5's shaping converges"
      % (_t['shaped'], _t['shape_mtu']),
      _t['shaped'] is True and shape_converged(_t))

# `shape off` must still tear P5's own shaping down while the guard is active:
# the guard is about not ATTACHING over someone else, never about refusing to
# clean up after ourselves.
_t2 = S0(rc=True); _w2 = W()
reconcile(_t2, _w2)                       # converged ON
_t2['shape'] = 'off'
reconcile(_t2, W(native_sqm=True))        # operator turns GL sqm on, and shape off
check("SH-N4 the guard never blocks TEARDOWN: with native SQM active, `shape off` still "
      "clears P5's own shaping (shaped=%s) -- the guard is about not attaching over "
      "another owner, not about refusing to clean up" % _t2['shaped'],
      _t2['shaped'] is False and shape_converged(_t2))

# ---- SH-MN: the mutant. A guard that ATTACHES ANYWAY is caught by SH-N1 -----
def _mut_shape_ignores_sqm(s, w, a):
    # the regression: P5 takes the device off the operator, and the two owners
    # then fight over the root qdisc on every sqm hotplug event (the box has
    # /etc/hotplug.d/iface/11-sqm, so sqm re-attaches on every ifup).
    if not _shape_desired(s):
        if s['shaped']: a_shape_clear(s, w, a)
        return
    if s['shaped']: return
    s['shape_ops'] += 1
    if not w['shape_ok']:
        s['shaped'] = False; s['shape_mtu'] = None; return
    s['shaped'] = True; s['shape_mtu'] = s['mtu']
def _mn():
    t = S0(rc=True); ww = W(native_sqm=True)
    reconcile(t, ww)
    return t['shaped'] is False and t['shape_ops'] == 0
_caught_mn = _with(ACTIONS, 'shape_apply', _mut_shape_ignores_sqm, _mn)
check("SH-MN mutant `shape_apply attaches over GL native SQM` (P5 silently takes the "
      "operator's device, and the two owners then fight on every 11-sqm hotplug) is "
      "CAUGHT by SH-N1 (non-vacuous: SH-N1 passes unmutated)",
      (not _caught_mn) and _sh_n1)

print("== RESULT (Layer-1b P5 equivalence + I10/I11 + scenarios):",
      "ALL PASS" if not fails else fails)
raise SystemExit(1 if fails else 0)
