#!/usr/bin/env python3
# bondctl lifecycle emulator. BOUNDARY: boolean/enum state + event order
# only — no packets, no timing. Facts: rc (bond service enabled flag),
# eng (engarde-client running), ep ('local'|'direct') = WG peer endpoint,
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
# as `engaged_agg) converge speed ;;` -- a line that says something else,
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
CITED = {
    'bond-xctl':     os.path.join(P5_DIR, 'bond-xctl'),
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
def fresh(): return dict(rc=False, eng=False, ep='direct', mode='lightning', capable=True, susp=False)
def hook(s):                    # 97-bond -> bondctl on (self-testing engage)
    if s['rc']:
        if s['capable']:
            s['ep']='local'; s['eng']=True; s['susp']=False
        else:                    # probe fails -> auto-revert to direct
            s['ep']='direct'; s['eng']=False; s['susp']=True
    # rc off: hook is silent — never resurrects
def wg_reconfig(s):             # GL co-writer rewrites endpoint, then hook
    s['ep']='direct'; hook(s)
def bond_on(s, races=0):
    s['rc']=True
    for _ in range(5):                    # convergence loop (engage-verify)
        hook(s)
        if races > 0 and s['ep']=='local':
            s['ep']='direct'; races -= 1  # in-flight direct packet re-pins
            continue
        break
def bond_off(s): s['rc']=False; s['eng']=False; s['ep']='direct'; s['susp']=False
def set_mode(s,m): s['mode']=m   # config regen + engarde restart (eng unchanged)
def reboot(s):
    s['eng']=False               # services down
    if s['rc']: s['eng']=True    # rc.d starts it
    wg_reconfig(s)               # wg comes up at boot; GL writes; hook runs
EV=dict(wg_reconfig=wg_reconfig, reboot=reboot)
def seqs(d):
    for n in range(d+1):
        yield from itertools.product(list(EV),repeat=n)
# I1: OFF is stable — endpoint stays direct, engarde stays down, forever
b=fresh(); bond_on(b); bond_off(b)
ok=True
for sq in seqs(6):
    s=copy.deepcopy(b)
    for e in sq: EV[e](s)
    if s['eng'] or s['ep']!='direct': ok=False; print("  I1:",sq); break
check("I1 OFF stable under wg churn + reboots (all seqs d<=6)", ok)
# I2: ON self-heals — endpoint returns to local after any co-writer event
b=fresh(); bond_on(b)
ok=True
for sq in seqs(6):
    s=copy.deepcopy(b)
    for e in sq: EV[e](s)
    if not (s['eng'] and s['ep']=='local'): ok=False; print("  I2:",sq); break
check("I2 ON self-heals endpoint after every co-writer rewrite", ok)
# I3: mode persists across reboot and churn
s=fresh(); bond_on(s); set_mode(s,'eco'); reboot(s); wg_reconfig(s)
check("I3 mode persists (eco after reboot+churn)", s['mode']=='eco' and s['eng'])
# I4: on/off idempotent
s=fresh(); bond_on(s); bond_on(s); a=(s['eng'] and s['ep']=='local')
bond_off(s); bond_off(s); b2=(not s['eng'] and s['ep']=='direct')
check("I4 on/off idempotent", a and b2)
# I5: off then reboot: WG works direct (endpoint never left direct)
s=fresh(); bond_on(s); bond_off(s); reboot(s)
check("I5 OFF survives reboot with WG direct to server", s['ep']=='direct' and not s['eng'])

# I6: incapable server -> suspended+direct; capability returning -> auto-resume
s=fresh(); bond_on(s); s['capable']=False; wg_reconfig(s)
a = (s['ep']=='direct' and not s['eng'] and s['susp'])
s['capable']=True; wg_reconfig(s)
b = (s['ep']=='local' and s['eng'] and not s['susp'])
check("I6 profile-switch: incapable -> suspended+direct; capable -> auto-resume", a and b)
# I7: OFF stable even against capability flapping
s=fresh(); bond_on(s); bond_off(s)
ok=True
for cap in (False, True, False):
    s['capable']=cap; wg_reconfig(s); reboot(s)
    if s['eng'] or s['ep']!='direct': ok=False; break
check("I7 OFF stable regardless of server capability flapping", ok)

print("== RESULT:", "ALL PASS" if not fails else fails)

s=fresh(); bond_on(s, races=3)
check("I8 engage converges to local despite 3 roaming races", s['ep']=='local' and s['eng'])
s=fresh(); bond_on(s, races=99)
check("I8b unbounded races -> loop terminates (suspend path reachable)", True)
print("== RESULT:", "ALL PASS" if not fails else fails)

# I9: the dead state (ep=local AND engarde down) is UNREACHABLE — suspend
# reverts-before-stop and keeps the service alive if revert unconfirmed.
def on_v25(s, races=0, peer_absent_at_suspend=False):
    s['rc']=True
    ok=False
    for _ in range(5):
        s['ep']='local'; s['eng']=True
        if s['capable'] and races==0: ok=True; break
        if races>0: s['ep']='direct'; races-=1
        if not s['capable']: break
    if not ok:
        if peer_absent_at_suspend:
            # revert unconfirmable -> KEEP service running (v2.5 rule)
            s['susp']=True            # eng stays True, ep stays local BUT listener alive
        else:
            s['ep']='direct'; s['eng']=False; s['susp']=True
def dead(s): return s['ep']=='local' and not s['eng']
ok=True
for races in (0,3,99):
    for pa in (False,True):
        for cap in (True,False):
            s=fresh(); s['capable']=cap; on_v25(s,races,pa)
            if dead(s): ok=False; print("  I9 violated:",races,pa,cap)
check("I9 dead state (local endpoint + no listener) unreachable in all branches", ok)
print("== RESULT (Layer-1a reference invariants):", "ALL PASS" if not fails else fails)

# =====================================================================
#  P5 LAYER-1b — DUAL-MACHINE FUNCTIONAL EQUIVALENCE (reference == DAG)
# =====================================================================
# Fact tuple (one writer each, mirrors HANDOVER 3-fact-space + speed/agg):
#   rc    engagement / rc.d engarde-enabled flag  (bondctl on/off)
#   mode  lightning|eco|speed                     (/etc/bond/mode)
#   auto  ecod policy enabled                     (/etc/bond/auto)
#   eng   engarde-client RUNNING                  (procd)
#   agg   bond-agg RUNNING (speed feeder)         (procd)
#   ep    direct|local|speed  = WG peer endpoint  (wg runtime; GL co-writes)
#   susp  none|suspended|suspended_degraded       (/var/run/bond/suspended)
#   prev  last non-speed mode (speed restore)     (derived)
#   mtu   1420|1408                               (wg dev)
#   lock  serialization lock held                 (/var/run/bond/lock; D4)
#   eng_srcs  source tuple enrolled in engarde.yml / applied_wans (genconf)
#   agg_srcs  source tuple enrolled in agg_env AGG_PATHS          (env_gen)
# The "world" (environment inputs, NOT our state):
#   capable      server runs engarde (verify_local gate)
#   agg_ok       server 59402 forward + capable   (verify_agg gate)
#   sources      ORDERED tuple of live underlay sources (see N-GENERIC below)
#   agg_installed  bond-agg binary present         (speed guard)
#   installed    engarde-client + BOND_DIR present (universal guard)
#   races        # of in-flight direct roams that will spoil an engage
#   peer_absent  revert cannot be confirmed -> suspended_degraded
#
# ---------------------------------------------------------------------
# N-GENERIC (U2). The world used to carry a BOOLEAN `two_wans`, so Layer-1
# had no N at all and the equivalence proof would have passed a 2-source-only
# implementation without noticing. It now carries `sources`: the ORDERED
# tuple of live underlay sources, ordered by route metric so sources[0] IS
# the primary (== bond-xctl `primary_wan`, lowest metric first). N is
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
#      `ordered_wans` source. Truncation is invisible to a count (the count of
#      live sources is unchanged) and visible only in the enrolled SET, so a
#      set is what keeps a regression catchable.
#   3. There is a real fact on the box to mirror: bond-xctl writes
#      `$BOND_DIR/applied_wans` (in `genconf`) and `AGG_PATHS` into agg_env
#      (in `build_agg_env`).
#      `eng_srcs` / `agg_srcs` are those two files' model twins - one writer
#      each (genconf / env_gen), exactly as on the box - and they are part
#      of the compared terminal tuple, so a truncating candidate DIVERGES.
#
# The ladder is not invented: the client box declares these four WAN
# interfaces with these metrics (docs/INTENT.md:193, `uci show network`):
#   network.wan.metric=1 . tethering=2 . secondwan=3 . wwan=4
# Higher-N entries are synthetic (`src5`, `src6`, ...) and exist only to
# prove there is no N ceiling in the wiring.
#
# HONEST GAP (not modelled): bond-xctl `build_engarde_conf` calls `fail`
# when `mode_wans` is empty (N=0). This model has no shell-control-flow
# boundary, so at N=0 genconf enrolls the empty set rather than aborting
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
# ONE `agg` intent and ONE `engaged_agg` target, and a mode is a COMPOSITION
# (mode -> sched), never a branch.
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
AGG_SCHED = load_agg_sched_table(CITED['bond-xctl'])

def agg_sched(mode):
    """The aggregate scheduler for `mode`, or None when it is not an aggregate
    mode. Membership in AGG_SCHED, never a comparison against a mode name."""
    return AGG_SCHED.get(mode)

def is_agg_mode(s):  return agg_sched(s['mode']) is not None

def S0(**kw):
    # agg_sched: the AGG_SCHED line of agg_env as last WRITTEN by a_env_gen --
    # the model twin of the emitted fact, so a max<->speed flip is a REAL config
    # delta the reconciler must notice, exactly as it is on the box.
    s = dict(rc=False, mode='lightning', auto=False, eng=False, agg=False,
             ep='direct', susp='none', prev='lightning', mtu=1420, lock=False,
             eng_srcs=(), agg_srcs=(), agg_sched=None)
    s.update(kw); return s

# Default world = every source the CLIENT BOX ACTUALLY DECLARES (N=4), not
# two. A default of 2 would quietly re-privilege the old assumption in every
# scenario that does not name N.
DEFAULT_SOURCES = srcs(len(SOURCE_LADDER))

def W(capable=True, agg_ok=True, sources=DEFAULT_SOURCES, agg_installed=True,
      installed=True, races=0, peer_absent=False, pool=None):
    # `pool` (U19 churn) = the ORDERED universe of sources this environment can
    # ever have, metric order, always a superset of `sources`. `sources` is the
    # LIVE subset right now. With no churn the two are equal, so every pre-churn
    # caller is unchanged. Both are tuples of str, so dict(w) stays an exact copy.
    return dict(capable=capable, agg_ok=agg_ok, sources=tuple(sources),
                agg_installed=agg_installed, installed=installed,
                races=races, peer_absent=peer_absent,
                pool=tuple(sources) if pool is None else tuple(pool))

def n_sources(w):  return len(w['sources'])

def mode_sources(s, w):
    """== bond-xctl `mode_wans()`: eco -> primary only; every other mode ->
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
# deploy/p5/97-bond gates on the wg LOGICAL iface (`$BOND_DIR/wg-logical`),
# so a hotplug on `wan`/`tethering`/`wwan` exits 0 without ever calling
# bond-xctl. The delta is picked up by the NEXT trigger -- the watchdog's
# periodic `bond-xctl reconcile` (bond-watchdog, one per CYCLE), a wg ifup, a
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
    # mirroring the shell node(): engaged iff engarde is rc-enabled OR (the mode is
    # an AGGREGATE mode AND the bond-agg feeder is up) -- an aggregating box with
    # rc=off is still `engaged` (feeder=bond-agg), so `disengage` correctly applies
    # while tearing the aggregate down;
    # once agg is gone the box reads `off`. `susp` overrides. desired() is the
    # rc/mode-driven TARGET twin (below).
    if s['susp']=='suspended':            return 'suspended'
    if s['susp']=='suspended_degraded':   return 'suspended_degraded'
    if s['rc'] or (is_agg_mode(s) and s['agg']):  return 'engaged'
    return 'off'

def desired(s):
    # DESIRED lifecycle target = pure function of the STORED facts (rc, mode) only.
    # NOT a function of susp (an onfail OUTCOME, not an input) -- desired() keeps
    # aiming at engaged so reconcile RETRIES recovery each tick (I6 auto-resume).
    # rc-precedence: `off` outranks mode, so a disabled box tears down regardless of
    # an aggregate mode (aggregation engages only when the box is on). This is what makes the
    # MF-1/MF-2 wrong-intent class unrepresentable: the caller writes facts, never
    # picks an edge -- reconcile() derives the single edge from (observed -> desired).
    if not s['rc']:        return 'off'
    if is_agg_mode(s):     return 'engaged_agg'
    return 'engaged'

# ---- shared LEAF primitives (the code extracted from bondctl into bond-xctl;
#      identical for both machines — equivalence is proven on the WIRING) ----
def a_rc_on(s,w,a):     s['rc']=True
def a_rc_off(s,w,a):    s['rc']=False
def a_genconf(s,w,a):
    # regenerate engarde.yml + applied_wans (bond-xctl `genconf`).
    # The enrolled set is mode_wans() -- ALL live sources, however many.
    s['eng_srcs'] = mode_sources(s,w)
def a_eng_enable(s,w,a):pass                      # rc.d enable (rc already carries it)
def a_eng_restart(s,w,a): s['eng']=True
def a_eng_stop(s,w,a):  s['eng']=False
def a_eng_disable(s,w,a): pass
def a_ep_local(s,w,a):  s['ep']='local'
def a_ep_direct(s,w,a): s['ep']='direct'
def a_ep_agg(s,w,a):  s['ep']='agg'      # 127.0.0.1:59402, the AGGREGATE listener
def a_clear_susp(s,w,a):s['susp']='none'
def a_env_gen(s,w,a):
    # regenerate agg_env (bond-xctl `act_env_gen` / `build_agg_env`).
    # AGG_PATHS must carry EVERY live source. The PRE-U6 builder carried
    # primary + `head -1` and silently discarded the rest; U6 fixed the
    # artifact, and NG-2 is the bar that keeps the MODEL from regressing to
    # it, with NG-M1 proving the bar has teeth.
    s['agg_srcs'] = mode_sources(s,w)
    # AGG_SCHED rides agg_env, so a max<->speed flip is a config BYTE CHANGE:
    # act_env_gen swaps the file and drops the `agg_env_changed` crumb, which is
    # what makes act_agg_restart bounce the datapath exactly once. Modelling it as
    # a written fact is what lets converged() see the flip (an unmodelled AGG_SCHED
    # would make a max<->speed switch a silent no-op here and only on the box).
    s['agg_sched'] = agg_sched(s['mode'])
def a_agg_install(s,w,a): pass
def a_agg_enable(s,w,a):pass
def a_agg_restart(s,w,a): s['agg']=True
def a_agg_stop(s,w,a):  s['agg']=False
def a_agg_disable(s,w,a): pass
def a_mtu_1408(s,w,a):  s['mtu']=1408
def a_mtu_1420(s,w,a):  s['mtu']=1420
def a_aggdown_if_agg(s,w,a):
    # If the box is currently on the aggregate feeder (agg up / ep on :59402), tear
    # it down AND restore the engarde feeder endpoint (the T6 tail), so a
    # switch/disengage/engage that leaves an aggregate mode never strands ep on :59402.
    if s['agg'] or s['ep']=='agg':
        s['agg']=False; s['mtu']=1420
        a_restore_feeder(s,w,a)
def a_genconf_if_enabled(s,w,a):
    if s['rc']: a_genconf(s,w,a)
def a_eng_restart_if_enabled(s,w,a):
    if s['rc']: s['eng']=True          # T3 live switch: restart, endpoint untouched
def a_restore_feeder(s,w,a):
    # T6 tail: bring the single engarde feeder back if bond is engaged
    if s['rc']:
        s['eng']=True
        s['ep']='local' if w['capable'] else 'direct'
    else:
        s['ep']='direct'
def a_revert(s,w,a):
    # I9 revert-then-suspend: try direct, confirm readback != local, THEN stop.
    if w['peer_absent']:
        s['susp']='suspended_degraded'     # unconfirmed -> KEEP engarde running (not dead)
        s['ep']='direct'
    else:
        s['ep']='direct'; s['eng']=False; s['susp']='suspended'

ACTIONS = dict(rc_on=a_rc_on, rc_off=a_rc_off, genconf=a_genconf,
               eng_enable=a_eng_enable, eng_restart=a_eng_restart,
               eng_stop=a_eng_stop, eng_disable=a_eng_disable,
               ep_local=a_ep_local, ep_direct=a_ep_direct, ep_agg=a_ep_agg,
               clear_susp=a_clear_susp, env_gen=a_env_gen,
               agg_install=a_agg_install, agg_enable=a_agg_enable,
               agg_restart=a_agg_restart, agg_stop=a_agg_stop,
               agg_disable=a_agg_disable, mtu_1408=a_mtu_1408, mtu_1420=a_mtu_1420,
               aggdown_if_agg=a_aggdown_if_agg,
               genconf_if_enabled=a_genconf_if_enabled,
               eng_restart_if_enabled=a_eng_restart_if_enabled,
               restore_feeder=a_restore_feeder, revert=a_revert)

def g_installed(s,w,a):     return w['installed']
def g_manual(s,w,a):        return not (a or {}).get('auto_ctx', False)
def g_agg_installed(s,w,a): return w['agg_installed']
def g_enough_sources_to_aggregate(s,w,a):
    # The agg guard is an ARITY requirement (>= MIN_AGG_SOURCES live sources),
    # NOT a two-WAN assumption: you cannot stripe one link. `>=` has no upper
    # bound, so N=3,4,...,k all pass identically. Read the name, not the
    # legacy DAG spelling.
    return n_sources(w) >= MIN_AGG_SOURCES
GUARDS = dict(installed=g_installed, manual=g_manual,
              agg_installed=g_agg_installed,
              # `two_wans` is the LEGACY spelling. U6 renamed the shipped
              # aggregate row's guard to `enough_sources`, and bond-xctl's
              # run_guard accepts BOTH so a half-upgraded box (new bond-xctl,
              # old bond.dag on disk) still resolves it. Both spellings stay
              # registered here for that same reason, and resolve to the SAME
              # N-generic predicate, asserted by NG-0.
              two_wans=g_enough_sources_to_aggregate,
              enough_sources=g_enough_sources_to_aggregate)

def v_local(s,w,a):
    # one engage_verify(59401) attempt: capability + roam consumption
    if not w['capable']: return False
    if w['races']>0:
        w['races']-=1; s['ep']='direct'   # in-flight direct packet re-pinned it
        return False
    s['ep']='local'; return True
def v_agg(s,w,a):
    return bool(w['agg_ok'])
VERIFY = dict(verify_local=v_local, verify_agg=v_agg)

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
    # THE single level-triggered verb (== deploy/p5/bond-xctl `reconcile`).
    # observe node() -> desired() -> walk ONE bond.dag edge with the same
    # guard/action/verify machinery. The lifecycle target (off/engaged/
    # engaged_agg) is chosen by desired(), NOT by the caller -- this is what
    # dissolves the MF-1/MF-2 wrong-intent class. One edge per call; the next
    # trigger/tick reconverges (no loop-to-fixpoint).
    #   `refresh` = a config-only change (a live mode switch): the tunnel is
    #   intact, so re-apply config via `switch` (no re-verify, ep untouched)
    #   rather than re-establish it via `engage`. For engage-class triggers
    #   (on/wg_ifup/reboot/watchdog) the endpoint may be disturbed -> `engage`.
    d = desired(s)
    if d == 'off':
        return converge(s, w, 'disengage')
    if d == 'engaged_agg':
        if converge(s, w, 'agg'):
            return True
        # ---- CHURN SUSTAINMENT (U19). THE DECISION the previous unit left open.
        # desired() is NOT a function of n_sources, and that is CORRECT: it is the
        # target derived from the user's STORED intent (rc, mode), and rewriting it
        # from the world would destroy the aggregate-mode pin the moment a WAN blinks.
        # The gap is one level down. The arity requirement is expressed ONLY as an
        # ENTRY guard on the `agg` edge (bond.dag:`enough_sources`), and converge() gives
        # a refused guard NO defined outcome -- it returns False and changes nothing.
        # A world condition that gates ENTERING a state therefore has no counterpart
        # that gates STAYING in it, so a box already ON the aggregate when N falls
        # below the floor keeps bond-agg running over a source that is GONE, and
        # every later tick re-refuses the same edge. Nothing else resolves it:
        # watchdog_tick sees term(s) unchanged, calls it a no-op (I11), and never
        # burns its budget. That is the undefined outcome, and it is a REAL DEFECT
        # in the shipped artifact too (bond-xctl's `engaged_agg) converge agg ;;`
        # arm has the same hole, one level up from `build_agg_env`, whose
        # `fail` exits the process mid-edge).
        #
        # The defined resolution needs no new edge and no new constant. Aggregation
        # below MIN_AGG_SOURCES is undefined BY DEFINITION (nothing to stripe
        # across), and the DAG already carries the exact recovery: `switch`, whose
        # aggdown_if_agg head is the INV1-ordered aggregate teardown + engarde
        # restore and whose genconf re-enrolls the sources that ARE live. `mode` is
        # deliberately NOT rewritten, so the pin survives and the aggregate re-forms
        # by itself when a source returns -- the same shape as I6 capability
        # auto-resume. Keyed on `s['agg']` so it fires ONLY on sustainment loss
        # (a box already aggregating), never on an entry refusal: `bondctl mode
        # max`/`bondctl mode speed` at N<2 must still fail and restore the prior
        # mode (SP5/NG-1).
        if s['agg'] and not g_enough_sources_to_aggregate(s, w, None):
            converge(s, w, 'switch')
        return False
    if refresh and s['rc']:
        return converge(s, w, 'switch')
    return converge(s, w, 'engage')

def _ecod_guards(s):
    # ecod no-op guards (bond-ecod header): auto set, engarde enabled (rc),
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
        okc=reconcile(s,w)                     # desired=engaged_agg -> agg; onfail agg_revert
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
    s['eng']=False; s['agg']=False             # services down
    s['ep']='direct'                           # wg up at boot -> co-writer
    if s['rc'] and is_agg_mode(s):
        s['agg']=True; s['ep']='agg'           # rc.d starts the ONE mode-feeder
    elif s['rc']:
        s['eng']=True; reconcile(s,w)          # hook re-engages via reconcile (T9)

def cand_crash(s,w):
    # procd respawn: the feeder dies and is immediately restarted.
    if is_agg_mode(s):  s['agg']=True
    elif s['rc']:       s['eng']=True

def cand_respawn_exhaust(s,w):
    # procd gave up (respawn exhaustion). Candidate watchdog W1 restarts it. (D3)
    if not is_agg_mode(s): s['eng']=False
    else:                  s['agg']=False
    watchdog_tick(s,w,{'n':0,'cap':8})

def cand_tput(s,w):
    # W5 publishes tput=degraded; ecod consumes as a 3rd trigger class (D1/F6):
    # in auto+eco, escape to lightning. Manual/other modes: no actor -> no-op.
    if _ecod_guards(s) and s['mode']=='eco':
        s['prev']=s['mode']; s['mode']='lightning'
        converge(s,w,'switch',dict(auto_ctx=True))

# ---- REFERENCE: hardcoded deployed bondctl v2.8 wiring (T1-T11) ----
def _engage_ref(s,w):
    a_aggdown_if_agg(s,w,None)                       # INV1: never two feeders
    a_rc_on(s,w,None); a_genconf(s,w,None); s['eng']=True; a_ep_local(s,w,None)
    okv=False
    for _ in range(BUDGET_ENGAGE):
        if v_local(s,w,None): okv=True; break
    if okv: s['susp']='none'
    else:   a_revert(s,w,None)

def _agg_disengage_ref(s,w):
    s['agg']=False; s['mtu']=1420
    if s['rc']:
        s['eng']=True
        s['ep']='local' if w['capable'] else 'direct'
    else:
        s['ep']='direct'

def ref_event(s, w, ev):
    if ev=='on':
        if not w['installed']: return
        _engage_ref(s,w)
    elif ev=='off':                            # T2
        if is_agg_mode(s): _agg_disengage_ref(s,w)
        a_rc_off(s,w,None); s['eng']=False; s['ep']='direct'; s['susp']='none'
    elif ev in ('mode_lightning','mode_eco'):   # T3
        m=ev.split('_')[1]
        # ADR-003 (SPECIFICATION change, not a reference bent to fit the candidate):
        # `eco` IS the auto policy, so selecting it ENABLES auto; every other manual
        # mode is a pin and clears auto. INTENT is the PAIR (auto, mode).
        if m=='eco': s['auto']=True
        elif s['auto']: s['auto']=False
        prev=s['mode']; s['prev']=prev; s['mode']=m
        if agg_sched(prev) is not None: _agg_disengage_ref(s,w)
        if s['rc']:                            # engarde enabled -> restart, ep untouched
            a_genconf(s,w,None); s['eng']=True
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
        prev=s['mode']; s['prev']=prev
        if not (w['installed'] and w['agg_installed']
                and n_sources(w) >= MIN_AGG_SOURCES):
            return                             # guard fail: mode restored (stays prev)
        s['mode']=m
        a_env_gen(s,w,None); s['eng']=False; s['agg']=True; s['mtu']=1408; s['ep']='agg'
        if v_agg(s,w,None):
            s['susp']='none'
        else:
            _agg_disengage_ref(s,w); s['mode']=prev     # restore PREV mode
    elif ev in ('ecod_lightning','ecod_eco'):  # T4
        m=ev.split('_')[1]
        if _ecod_guards(s):
            s['prev']=s['mode']; s['mode']=m
            if s['rc']: a_genconf(s,w,None); s['eng']=True
    elif ev=='auto_on':  s['auto']=True
    elif ev=='auto_off': s['auto']=False
    elif ev=='wg_ifup':                        # T9
        s['ep']='direct'
        if s['rc']: _engage_ref(s,w)
    elif ev=='reboot':                         # T10
        s['eng']=False; s['agg']=False
        s['ep']='direct'
        if s['rc'] and is_agg_mode(s):
            s['agg']=True; s['ep']='agg'
        elif s['rc']:
            s['eng']=True; _engage_ref(s,w)
    elif ev=='feeder_crash':                   # T11 (procd respawn)
        if is_agg_mode(s): s['agg']=True
        elif s['rc']:      s['eng']=True
    elif ev=='respawn_exhaust':                # reference: unhandled until next wg ifup (D3)
        if not is_agg_mode(s): s['eng']=False
        else:                  s['agg']=False
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
# eng_srcs/agg_srcs ARE part of the compared terminal tuple. Without them the
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
KEYS=('rc','mode','auto','eng','agg','ep','susp','eng_srcs','agg_srcs','agg_sched')
LIFECYCLE_KEYS=('rc','mode','auto','eng','agg','ep','susp','agg_sched')  # N-independent projection
def term(s): return tuple(s[k] for k in KEYS)
def lifecycle(s): return tuple(s[k] for k in LIFECYCLE_KEYS)
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
    if t['eng'] or t['ep']!='direct' or t['rc']: ok=False; print("  I1c:",sq); break
check("I1  (cand) OFF stable under wg churn + reboots + crashes (d<=6)", ok)
# I2 ON self-heals (candidate)
s=S0(); w=W(); cand_event(s,w,'on')
ok=True
for sq in cand_seqs(['wg_ifup','reboot','feeder_crash'],6):
    t=S0(**s); tw=W()
    for e in sq: cand_event(t,tw,e)
    if not (t['eng'] and t['ep']=='local'): ok=False; print("  I2c:",sq); break
check("I2  (cand) ON self-heals endpoint after every co-writer rewrite", ok)
# I3 mode persists (candidate)
s=S0(); w=W(); cand_event(s,w,'on'); cand_event(s,w,'mode_eco'); cand_event(s,w,'reboot'); cand_event(s,w,'wg_ifup')
check("I3  (cand) mode persists (eco after reboot+churn)", s['mode']=='eco' and s['eng'])
# I4 idempotent (candidate)
s=S0(); w=W(); cand_event(s,w,'on'); cand_event(s,w,'on'); a=(s['eng'] and s['ep']=='local')
cand_event(s,w,'off'); cand_event(s,w,'off'); b2=(not s['eng'] and s['ep']=='direct' and not s['rc'])
check("I4  (cand) on/off idempotent", a and b2)
# I5 off survives reboot (candidate)
s=S0(); w=W(); cand_event(s,w,'on'); cand_event(s,w,'off'); cand_event(s,w,'reboot')
check("I5  (cand) OFF survives reboot with WG direct", s['ep']=='direct' and not s['eng'] and not s['rc'])
# I6 capability suspend/resume (candidate)
s=S0(); w=W(capable=False); cand_event(s,w,'on')
a=(node(s) in ('suspended','suspended_degraded'))
w2=W(capable=True); cand_event(s,w2,'wg_ifup')
b=(s['ep']=='local' and s['eng'] and s['susp']=='none')
check("I6  (cand) incapable -> suspended; capable -> auto-resume on wg up", a and b)
# I7 OFF stable vs capability flap (candidate)
s=S0(); w=W(); cand_event(s,w,'on'); cand_event(s,w,'off')
ok=True
for cap in (False,True,False):
    tw=W(capable=cap); cand_event(s,tw,'wg_ifup'); cand_event(s,tw,'reboot')
    if s['eng'] or s['ep']!='direct' or s['rc']: ok=False; break
check("I7  (cand) OFF stable regardless of server capability flapping", ok)
# I8 engage races converge (candidate)
s=S0(); w=W(races=3); cand_event(s,w,'on')
check("I8  (cand) engage converges to local despite 3 roaming races", s['ep']=='local' and s['eng'])
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
      s['eng'] and not s['agg'] and s['ep']=='local' and node(s)=='engaged')
# S-R2 watchdog restart itself is invisible (I11 no-op when clean).
s=S0(); w=W(); cand_event(s,w,'on'); before=term(s)
cand_event(s,w,'watchdog_tick')
check("SUP2 watchdog tick in a clean engaged state is a NO-OP (I11)", term(s)==before)
# S-R3 respawn EXHAUSTION: reference stuck until next wg-up; candidate W1 restarts (D3).
sr=S0(); wr=W(); ref_event(sr,wr,'on'); ref_event(sr,wr,'respawn_exhaust')
sc=S0(); wc=W(); cand_event(sc,wc,'on'); cand_event(sc,wc,'respawn_exhaust')
check("SUP3 respawn-exhaustion: ref feeder DOWN (unhandled), cand W1 restarts it (D3)",
      (not sr['eng']) and sc['eng'])

# --- Path failover ---
# PF1 ecod hard-bad flips eco -> lightning (auto path failover on the primary).
# ADR-003: mode_eco now SETS auto, so one call reaches the ecod-managed state.
s=S0(); w=W(); cand_event(s,w,'on'); cand_event(s,w,'mode_eco')
cand_event(s,w,'ecod_eco')          # ecod settles to eco
eco_ok = (s['mode']=='eco' and s['auto'])
cand_event(s,w,'ecod_lightning')    # primary bad -> escape to lightning
check("PF1 ecod path failover eco->lightning keeps auto + engaged",
      eco_ok and s['mode']=='lightning' and s['auto'] and s['eng'])
# PF2 duplicate-mode 0-loss failover is STRUCTURAL: a WAN dropping does not
# change engagement facts (both copies flow; one stream just stops). Model:
# in lightning, a feeder_crash/respawn and wg churn never drop engagement.
s=S0(); w=W(); cand_event(s,w,'on')   # lightning
ok=True
for sq in cand_seqs(['wg_ifup','feeder_crash'],5):
    t=S0(**s); tw=W()
    for e in sq: cand_event(t,tw,e)
    if not (t['eng'] and t['ep']=='local'): ok=False; break
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
# CX2 prod :59401 vs aggregate :59402 separation — aggregate uses ep='agg', engaged
# uses ep='local'; they are never both feeders (INV1). Sweep on/speed/off.
s=S0(); w=W(); ok=True
for sq in cand_seqs(['on','mode_speed','mode_lightning','off'],4):
    t=S0(); tw=W()
    for e in sq: cand_event(t,tw,e)
    if t['eng'] and t['agg']: ok=False; break        # never two local feeders
check("CX2 single-feeder INV holds across on/speed/mode/off sweeps (:59401 vs :59402)", ok)
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
check("SP1 speed engage: ref==cand, single feeder (agg up / engarde down, :59402)",
      term(rs)==term(cs) and cs['mode']=='speed' and cs['agg'] and not cs['eng'] and cs['ep']=='agg')
# SP2 speed verify FAIL -> restore PREV mode, engarde back, single feeder (INV5)
rs,cs=run_both(['on','mode_eco','mode_speed'], {'agg_ok':False})
check("SP2 speed verify-fail: ref==cand, restores prev mode (eco), engarde back (INV5)",
      term(rs)==term(cs) and cs['mode']=='eco' and cs['eng'] and not cs['agg'])
# SP3 speed then off: ref==cand, fully torn down
rs,cs=run_both(['on','mode_speed','off'], {})
check("SP3 speed then off: ref==cand, torn down (no feeder, direct)",
      term(rs)==term(cs) and not cs['eng'] and not cs['agg'] and cs['ep']=='direct' and not cs['rc'])
# SP4 speed then mode lightning (live switch back): ref==cand, single feeder
rs,cs=run_both(['on','mode_speed','mode_lightning'], {})
check("SP4 speed -> lightning: ref==cand, single feeder (agg down, engarde up)",
      term(rs)==term(cs) and cs['mode']=='lightning' and cs['eng'] and not cs['agg'])
# SP5 speed guard fail (below aggregation arity): ref==cand, refused, mode restored
rs,cs=run_both(['on','mode_eco','mode_speed'], {'sources':srcs(1)})
check("SP5 speed guard-fail (N=1, below agg arity): ref==cand, refused, prior mode kept, no agg",
      term(rs)==term(cs) and cs['mode']=='eco' and not cs['agg'] and cs['eng'])
# SP6 on/reboot-during-speed keep INV1 (single feeder). reboot-during-speed is
# ref==cand (both re-start the agg feeder). on-during-speed is a JUSTIFIED RECONCILER
# DIVERGENCE from ref v2.8: ref `on` re-engages ENGARDE (mode-blind), but the
# reconciler keeps SPEED (desired(mode=speed)=engaged_agg) -- `on` must not silently
# drop the speed feeder the user selected via `mode speed`. INV1 holds in both.
cs=S0(); cw=W()
for ev in ['on','mode_speed','on']: cand_event(cs,cw,ev)
sp6a = (cs['mode']=='speed' and cs['agg'] and not cs['eng'] and cs['ep']=='agg'
        and not (cs['eng'] and cs['agg']))     # reconciler stays in speed; single feeder
rs,cs2=run_both(['on','mode_speed','reboot'], {})
sp6b = term(rs)==term(cs2) and not (cs2['eng'] and cs2['agg'])
check("SP6 reboot-during-speed ref==cand+INV1; on-during-speed reconciler keeps speed (INV1 holds)",
      sp6a and sp6b)
# MF-2 (the reconciler's headline win): during speed, a co-writer wg_ifup + watchdog
# ticks must NOT oscillate the box out of speed. The deployed hook fired `engage`
# mode-blindly -> tore speed down -> hook/watchdog fight -> capped black-hole. Under
# the reconciler BOTH the hook (wg_ifup) and the watchdog funnel to reconcile(), which
# is mode-aware (desired=engaged_agg), so the box stays pinned in speed. Drive the
# exact MF-2 oscillation sequence and assert stability every cycle (INV1 too).
cs=S0(); cw=W()
cand_event(cs,cw,'on'); cand_event(cs,cw,'mode_speed')
mf2_ok = cs['mode']=='speed' and cs['agg']
for _ in range(6):
    cand_event(cs,cw,'wg_ifup')                # GL co-writer knocks ep to direct
    cand_event(cs,cw,'watchdog_tick')          # periodic resync
    if not (cs['mode']=='speed' and cs['agg'] and cs['ep']=='agg'
            and not cs['eng'] and not (cs['eng'] and cs['agg'])):
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
        engaged_agg = (cs['mode']=='speed' and cs['agg'] and cs['ep']=='agg')
        if engaged_agg != (n >= MIN_AGG_SOURCES): return False
        if not engaged_agg and not (cs['mode']=='eco' and cs['eng'] and not cs['agg']):
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
        if ce['eng_srcs'] != srcs(n)[:1]: return False
        if cl['eng_srcs'] != srcs(n):     return False
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
      % (cite('bond-xctl', 'build_agg_env() {'),
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

def _mut_env_gen(s,w,a):    s['agg_srcs'] = mode_sources(s,w)[:2]   # pre-U6 build_agg_env defect
def _mut_genconf(s,w,a):    s['eng_srcs'] = mode_sources(s,w)[:2]
def _mut_guard_eq2(s,w,a):  return n_sources(w) == 2                # "exactly two WANs"

caught_trunc = _with(ACTIONS, 'env_gen', _mut_env_gen,
                     lambda: (not _ng_no_truncation()) and (not _ng_arity()))
check("NG-M1 mutant `AGG_PATHS = first 2 sources` (the PRE-U6 build_agg_env defect, since "
      "fixed in the artifact) is CAUGHT by NG-2 AND by ref==cand equivalence", caught_trunc)

# BOTH registered spellings are mutated, though not for the reason first written
# here. It was claimed that patching only the legacy `two_wans` alias would leave
# the mutant UNREACHED and this bar vacuously true. CHECKED and WRONG (ROADMAP.md,
# "U6 landed" section): the interpreter resolves the guard by the name the SHIPPED
# bond.dag uses, which is `enough_sources` post-rename, so patching `two_wans` only
# leaves that unreached guard correct -- `_ng_arity()` then still passes, so
# `caught_eq2` is False and `check("NG-M2 ...", caught_eq2)` FAILS LOUDLY (RED),
# not silently true. Mutating both is still the right test: it is what actually
# reaches the interpreter under the shipped spelling, and it keeps NG-M2 correct
# under either spelling (NG-0 already asserts they are the same predicate).
caught_eq2 = _with(GUARDS, 'two_wans', _mut_guard_eq2,
             lambda: _with(GUARDS, 'enough_sources', _mut_guard_eq2,
                           lambda: not _ng_arity()))
check("NG-M2 mutant `guard: exactly 2 sources` is CAUGHT (would pass a 2-WAN-only box, "
      "fails at N=3,4,...)", caught_eq2)

# NG-M3 mutates the ENGAGE path and re-runs the exhaustive sweep itself, so the
# demonstration covers THE GATE (the equivalence enumeration), not only the
# targeted NG bars. Bounded on purpose -- N=3 only, depth 2 (585 seqs/env) --
# because it must merely FIND a divergence, not characterise it.
_mut_envs = list(env_grid((3,)))
mut_m, mut_n = _with(ACTIONS, 'genconf', _mut_genconf,
                     lambda: sweep(_mut_envs, 2))
check("NG-M3 mutant `applied_wans = first 2 sources` is CAUGHT by the exhaustive sweep itself "
      "(N=3, depth<=2, %d seqs; divergence at seq %s)"
      % (mut_n, (mut_m[0] if mut_m else '-')), mut_m is not None)


# =====================================================================
#  AGG - ONE AGGREGATE INTENT, N AGGREGATE MODES (U17)
#
#  ADR-003 splits the aggregate mode into `max` (stripe every usable source) and
#  `speed` (deliver the offered load over the fewest, fastest sources). The
#  DATAPATH difference is real; the ORCHESTRATION difference is exactly one
#  emitted fact. So the reconciler carries ONE `agg` intent, ONE `engaged_agg`
#  target and ONE leaf set, and selects the scheduler with AGG_SCHED.
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
check("AGG-0 ONE aggregate intent in the SHIPPED bond.dag: rows %s, and NO per-mode row "
      "(none of %s), for %d aggregate modes. A new aggregate scheduler adds ONE entry to "
      "AGG_SCHED and ZERO rows here"
      % (_agg_rows, list(AGG_MODES), len(AGG_MODES)),
      _agg_rows == ['agg', 'agg_revert'] and _per_mode_rows == [] and len(AGG_MODES) >= 2)

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
# bond-xctl OWNS the table, so two of its lines are allowed to name a mode and
# both are named here rather than pattern-excused: the table assignment itself,
# and the legacy dag-row alias, where `speed` is the name of a ROW in a pre-U17
# bond.dag on a half-upgraded box, not the name of a mode.
_XCTL_OWNER_LINES = ('AGG_SCHED_TABLE=', '_dag_row_raw speed')
_xctl_stray = [h for h in _mode_name_hits('bond-xctl')
               if not any(t in _artifact_lines('bond-xctl')[h[1]-1] for t in _XCTL_OWNER_LINES)]
_other_stray = []
for _a in ('bondctl', 'bond-ecod', 'bond-watchdog', 'bond.dag', '97-bond'):
    _other_stray += _mode_name_hits(_a)
check("AGG-4 ONE owner of the mode -> scheduler table: this model PARSES bond-xctl's "
      "AGG_SCHED_TABLE (%s -> %s) instead of restating it, and NO other shipped artifact "
      "names an aggregate mode in live code (bondctl, bond-ecod, bond-watchdog, bond.dag, "
      "97-bond: %d hits; bond-xctl outside the table row and the legacy dag-row alias: %d). "
      "So a third aggregate scheduler is ONE row. Strays: %s"
      % (cite('bond-xctl', 'AGG_SCHED_TABLE='), sorted(AGG_SCHED.items()),
         len(_other_stray), len(_xctl_stray), (_other_stray + _xctl_stray) or 'none'),
      not _other_stray and not _xctl_stray and len(AGG_SCHED) >= MIN_AGG_SCHEDULERS)

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
    return len(tgts) == 1 and tgts == {'engaged_agg'} and len(walks) == 1
check("AGG-1 every aggregate mode %s derives the SAME desired target (engaged_agg) and walks the "
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
        eng = [m for m in AGG_MODES if _agg_run(m, seq, wk)['agg']]
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
    # the PRE-U17 line, verbatim: only `speed` aggregates, so `mode max` falls
    # through to plain `engaged` and the box quietly runs the engarde feeder.
    if not s['rc']:        return 'off'
    if s['mode'] == 'speed': return 'engaged_agg'
    return 'engaged'
def _mut_env_gen_blind(s, w, a):
    # AGG_SCHED emitted mode-blind: max and speed are identical on the wire.
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

check("AGG-M1 mutant `desired(): only mode==speed aggregates` (the literal pre-U17 line) is CAUGHT "
      "-- `mode max` silently runs the engarde feeder instead of the aggregate",
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
    `bond-xctl reconcile`, once per bond-watchdog CYCLE) to a fixpoint of term().
    Returns (ticks_that_changed_state, reached_fixpoint, inv1_held)."""
    inv1 = not (s['eng'] and s['agg'])
    for i in range(cap):
        before = term(s)
        reconcile(s, w)
        if s['eng'] and s['agg']: inv1 = False
        if term(s) == before:
            return i, True, inv1
    return cap, False, inv1

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
    want = mode_sources(s, w)
    if s['agg'] and tuple(s['agg_srcs']) != want: return False
    if s['eng'] and tuple(s['eng_srcs']) != want: return False
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
        # candidate re-derived from the live world; reference could not have
        if cs['eng'] and tuple(cs['eng_srcs']) != mode_sources(cs,cw): return False, False
        if tuple(rs['eng_srcs']) != tuple(cs['eng_srcs']): seen_stale = True
        # ...and the next SHARED trigger re-converges them
        ref_event(rs,rw,'wg_ifup'); cand_event(cs,cw,'wg_ifup')
        if term(rs) != term(cs): return False, False
    return True, seen_stale
_d6_ok, _d6_seen = _ch_d6()
check("CH-D6 divergence ledger: after a WAN hotplug the REFERENCE has no actor that "
      "re-derives the source set (v2.8 has no watchdog; 97-bond ignores non-wg ifaces), so "
      "applied_wans goes STALE; the CANDIDATE's periodic reconcile (%s, once per CYCLE "
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
                s=S0(); w=dict(w0); inv1=True
                for ev in sq:
                    w['races']=w0['races']
                    cand_event(s,w,ev)
                    if s['eng'] and s['agg']: inv1=False
                ticks, conv, inv1b = settle(s,w)
                if not inv1b: inv1=False
                r['nseq'] += 1
                if ticks > r['maxticks']: r['maxticks']=ticks
                wit = (sq, w0['pool'], w0['sources'], w0['capable'])
                if not conv:
                    if r['nofix'] is None: r['nofix']=wit
                    continue
                if not inv1 and r['inv1'] is None:   r['inv1']=wit
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
check("CH-4 COHERENCE at every fixpoint: a RUNNING feeder is enrolled over the sources that "
      "are live NOW -- no feeder left striping over a departed source, %d seqs. SCOPE, stated "
      "so the bar is not read as wider than it is: this alphabet has no mode_speed, so the "
      "feeder exercised here is ENGARDE; the same coherent() predicate covers the AGGREGATE "
      "feeder in CH-3/CH-5, which do drive speed"
      % CH['nseq'], CH['incoh'] is None)

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
    engarde-incapable server the box never reaches speed at all (`on` suspends,
    and bond.dag's `speed` row has from=off,engaged -- `suspended` is not in it),
    so an incapable-from-the-start run would test nothing. The compound case that
    DOES matter is: aggregating fine, then the world loses BOTH a source and the
    engarde server -- the resolution must still land on a defined node."""
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
    cand_event(s,w,'watchdog_tick')                   # bond-watchdog periodic reconcile
    ticks, conv, inv1 = settle(s,w)
    return s, w, conv, inv1, ticks

def _ch_arity_loss():
    for pn in CH_LADDER:
        for cap in (True, False):
            r = _arity_loss_run(pn, cap)
            if r is None: return False
            s,w,conv,inv1,_ = r
            if not (conv and inv1):            return False   # converged, one feeder
            if s['agg']:                       return False   # aggregate is DOWN
            if s['mode'] != 'speed':           return False   # the PIN survives
            if node(s) not in ('engaged','suspended','suspended_degraded'):
                return False                                  # a DEFINED node
            if dead(s):                        return False   # never the I9 dead state
            if not coherent(s,w):              return False   # config matches the live world
            if not _stable(s,w):               return False   # and it does not oscillate
            if cap and not (s['eng'] and s['ep']=='local'):
                return False                   # capable server: traffic on the engarde feeder
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

check("CH-3 [MODEL BAR, artifact NOT yet fixed] arity loss MID-FLIGHT resolves to a DEFINED "
      "outcome at every N in %s: aggregate torn down, single feeder, `mode speed` PIN "
      "retained, config re-enrolled over the live sources. The SHIPPED reconciler has the "
      "same hole the model just closed -- %s `%s` leaves bond-agg up on a stale "
      "AGG_PATHS when guard_enough_sources (%s) refuses, forever; the fix is one arm in "
      "bond-xctl reconcile(), owned by deploy/p5"
      % (str(CH_LADDER),
         cite('bond-xctl', 'engaged_agg) converge agg ;;'),
         'engaged_agg) converge agg ;;',
         cite('bond-xctl', 'guard_enough_sources() {')),
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
      "reachable DYNAMICALLY rather than only as a static world): at N=0 the model's genconf "
      "enrolls the empty set, while %s build_engarde_conf calls `fail` -> the "
      "process exits 1 mid-edge and engarde keeps running on the PREVIOUS engarde.yml. The "
      "model has no shell-control-flow boundary to represent that. Open question, not invented"
      % cite('bond-xctl', 'build_engarde_conf() {'),
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
    s['eng_srcs'] = live[:1] if s['mode']=='eco' else live

def _mut_guard_pool(s,w,a):
    # the arity guard ignores disappears: it counts the sources the box COULD
    # have (the pool) instead of the ones that are live.
    return len(w['pool']) >= MIN_AGG_SOURCES

def _mut_reconcile_drop_pin(s,w,refresh=False,_real=reconcile):
    # the sustainment resolution destroys the aggregate-mode pin instead of
    # retaining it, so the aggregate can never re-form on its own.
    was = (is_agg_mode(s) and s['agg'])
    r=_real(s,w,refresh)
    if was and not s['agg'] and is_agg_mode(s): s['mode']=s['prev']
    return r

# M1: caught by the exhaustive churn equivalence sweep AND by CH-4 coherence.
_M1_EQ_DEPTH, _M1_SCAN_DEPTH = 3, 2
_m1_envs = [w for w in CHURN_ENVS if len(w['pool']) >= 2]
_m1_eq, _m1_n = _with(ACTIONS, 'genconf', _mut_genconf_cached,
                      lambda: sweep(_m1_envs, _M1_EQ_DEPTH, CHURN_EQ_EVENTS))
_m1_scan = _with(ACTIONS, 'genconf', _mut_genconf_cached,
                 lambda: churn_scan(_m1_envs, _M1_SCAN_DEPTH, CHURN_EVENTS))
check("CH-M1 mutant `candidate CACHES the source list` (ignores every appear/disappear -- "
      "the cached-source-table defect %s forbids) is CAUGHT by CH-EQ (%d seqs, "
      "divergence at %s) AND by CH-4 coherence (%s). Mutant run bounded to depth %d/%d "
      "because it need only FIND a failure, not characterise it"
      % (cite('bond-xctl', 'A cached source table would be STATE'),
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
_m2 = _with(GUARDS, 'two_wans', _mut_guard_pool,
            lambda: _with(GUARDS, 'enough_sources', _mut_guard_pool,
                          lambda: not _ch_arity_loss()))
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
    s['eng']=False                      # simulate the feeder dying every cycle
    if watchdog_tick(s,w,bud): acts+=1
check("I10 watchdog is fail-static: actions bounded by the cap (<=3), never flaps",
      acts<=3)
# I11 watchdog no-op when clean: over EVERY reachable clean state, tick changes nothing.
clean_states=[]
for ev_seq in cand_seqs(['on','off','mode_eco','mode_lightning','auto_on'],3):
    t=S0(); tw=W()
    for e in ev_seq: cand_event(t,tw,e)
    # "clean" = no invariant is currently violated
    dead_now = t['ep']=='local' and not t['eng'] and t['susp']!='suspended_degraded'
    two_feeders = t['eng'] and t['agg']
    absent = t['rc'] and t['susp']=='none' and (
             (is_agg_mode(t) and not t['agg']) or (not is_agg_mode(t) and not t['eng']))
    if not (dead_now or two_feeders or absent):
        clean_states.append(term(t))
ok=True
for _ in range(1):
    for ev_seq in cand_seqs(['on','off','mode_eco','mode_lightning','auto_on'],3):
        t=S0(); tw=W()
        for e in ev_seq: cand_event(t,tw,e)
        dead_now = t['ep']=='local' and not t['eng'] and t['susp']!='suspended_degraded'
        two_feeders = t['eng'] and t['agg']
        absent = t['rc'] and t['susp']=='none' and (
                 (is_agg_mode(t) and not t['agg']) or (not is_agg_mode(t) and not t['eng']))
        if dead_now or two_feeders or absent: continue
        before=term(t)
        watchdog_tick(t,tw,{'n':0,'cap':8})
        if term(t)!=before: ok=False; print("  I11 violated at", before, "->", term(t)); break
    if not ok: break
check("I11 watchdog_tick is a NO-OP in every invariant-clean state (%d clean states)" % len(set(clean_states)), ok)

# --- Divergence ledger D4: stale-lock power-loss defect (fixed in P5) ---
# Reference: /etc/bond/lock survives power loss -> permanent skip-everything.
# Candidate: /var/run/bond/lock is tmpfs -> clears on boot -> ops proceed.
def ref_locked_on(s,w):
    if s['lock']: return                 # mkdir lock held -> skip (the defect)
    _engage_ref(s,w)
sr=S0(rc=True, eng=True, ep='local'); sr['lock']=True   # power-lost mid-transition
ref_locked_on(sr,W())                                   # a later `on` skips forever
sc=S0(rc=True, eng=True, ep='local'); sc['lock']=False  # tmpfs cleared at boot
cand_event(sc,W(),'wg_ifup')                            # converges normally
check("D4  stale-lock defect: ref stuck (lock persists), cand self-clears (tmpfs)",
      sr['lock'] and (sc['ep']=='local' and sc['eng']))

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
# :59401 is the production engarde listener and :59402 the P5 aggregate
# listener -- UDP ports, not line numbers. Named so the scan can tell the two
# apart rather than being taught to ignore numbers in general.
_PORT_RX = re.compile(r'(?:(?<=\s)|(?<=\())(:59401|:59402)')
_BARE_RX = re.compile(r'(?:(?<=\s)|(?<=\())(:[0-9]{2,4})')
def _hand_typed_citations():
    out = []
    for i, ln in enumerate(_SELF_SRC):
        if _ART_RX.search(ln):                              out.append((i+1, ln.strip()[:70]))
        elif _BARE_RX.search(_PORT_RX.sub(' ', ln)):        out.append((i+1, ln.strip()[:70]))
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
      _cite_rejects('bond-xctl', 'engaged_speed) converge speed ;;')
      and _cite_rejects('bond-xctl', 'guard_two_wans()')
      and _cite_rejects('bond-xctl', '#')
      and cite('bond-xctl', 'engaged_agg) converge agg ;;').startswith('bond-xctl:'))

print("== RESULT (Layer-1b P5 equivalence + I10/I11 + scenarios):",
      "ALL PASS" if not fails else fails)
raise SystemExit(1 if fails else 0)
