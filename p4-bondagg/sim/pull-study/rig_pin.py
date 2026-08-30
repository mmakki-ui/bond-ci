#!/usr/bin/env python3
# =============================================================================
# rig_pin.py -- LOAD THE PHYSICS AND THE ORACLE BY PATH, AND ASSERT WHICH FILE
#               IS LOADED.  (ROADMAP U35)
#
# WHY THIS FILE EXISTS
# --------------------
# The pull-study tree holds MORE THAN ONE COPY of two modules, and until this
# file existed the copy that ran was decided by `sys.path` -- i.e. by the
# caller's cwd and PYTHONPATH -- and nothing anywhere asserted the answer.
#
#   ackclock_sim.py   02-ackclock/           the later sched='C' revision
#                     03-reserved-composite/ the gated-oracle revision (different code)
#   nsched_model.py   p4-bondagg/sim/         the shipped model (U1's hold==0 guard)
#                     pull-study/variants/    the hedge/mirror fork
# (Deliberately no line/byte counts here: a frozen count in a comment rots exactly
#  as the frozen sha this file's README correction retires -- the copies' identity
#  is asserted at import, not described. What actually differs is enumerated below.)
#
# ADR-004 named `../02-ackclock/ackclock_sim.py` as the rig's oracle. That was
# WRONG -- under the gate's environment (cwd = 03-reserved-composite,
# PYTHONPATH = p4-bondagg/sim) the loaded copy is 03's -- and it stayed wrong in
# the record for a day (amended in `2c052b4`).  `.github/scripts/
# rig_paired_gate.py::preflight()` now checks this from OUTSIDE the rig.  An
# external checker is not enough: THE RIG SHOULD KNOW WHAT IT IS RUNNING.  Every
# entry point here loads its dependencies by explicit path and asserts
# `__file__`, so the wrong copy raises at import instead of quietly producing
# numbers attributed to the other file.
#
# =============================================================================
# THE CANONICAL DECISION (U35) -- BOTH COPIES ARE LIVE.  NEITHER IS DELETED.
# =============================================================================
# `02-ackclock/ackclock_sim.py`  is CANONICAL FOR THE 02-ACKCLOCK STUDY LINE.
# `03-reserved-composite/ackclock_sim.py` is CANONICAL FOR THE COMPOSITE STUDY,
#     for the ADR-004 gated oracle, and for `modes-r2-study/`.
#
# This is not a preference; it is what reproduces the committed outputs.
# MEASURED, both directions (2026-08-30, U35):
#
#  (a) The 03 copy is the one the composite line's published numbers were made
#      on.  Running the battery's own scheduler set -- `ackclock_sim.Sim` for
#      ewma / pull / oracle and `reserved_composite.SimD` for Dc -- over
#      {N2-het, N3-het, N5-het, N5-corr} x {0.65, 0.85, 0.95} x seeds 0-2, rig
#      = mid, T = 9.0 s, gives metrics that are IDENTICAL under both copies:
#      48 of 60 cells byte-for-byte equal (gp / loss / p50 / p95 / p99 / deliv /
#      tdrop / tshare / res_tx).  So the copy choice changes NO published
#      composite number -- see "does any published number change" below.
#
#  (b) The probe is not blind, and the two copies really are different code.
#      The other 12 of those 60 cells are exactly the ones run with
#      `sched='C'`, the 02 line's "unifying datapath law" scheduler -- e.g.
#      N3-het @0.85: loss 32.65% (03 copy) vs 25.94% (02 copy).
#
#  (c) The 02 copy is REQUIRED to reproduce the 02 line's committed output.
#      `02-ackclock/pred_iii_out.txt` row "C floor ON (probe=4)" at
#      ack_loss=15%, SEEDS=24, T=10.0, rig=mid reproduces DIGIT-FOR-DIGIT under
#      the 02 copy -- gp=75341 loss=17.1% p50=421 p95=596 p99=629 tdrop=630
#      qdrops=8642 late=1239 c_lost=3342 -- and does NOT reproduce under the 03
#      copy: gp=69449 loss=23.6% p50=400 p95=608 p99=651 tdrop=928 qdrops=1318
#      late=11696 c_lost=5950.
#
# WHAT EACH IS FOR (what the diff actually is)
# --------------------------------------------
# The 02 copy is the LATER revision of the `sched='C'` research line and carries
# machinery the 03 copy has never had:
#   * `c_mode` ('delay' | 'rate')            -- 02 only (`ackclock_sim.py:85,150,464`)
#   * `lam_used` / `lam_samp` / `LAM_MAX_WIN` -- 02 only (windowed-max BBR btlbw)
#   * `probe_frames` default 4 vs 1, and an UNCONDITIONAL min-window escape
#     hatch vs 03's probe-interval-gated one
#   * RTT sample subsampling (~5 ms) in `_reap_echoes`
#   * a dict-valued `_trace` row vs 03's tuple
#   * different `_c_budget` (fast-down lambda, no startup gain) and `_pace_rate`
#     (lambda_max vs lambda) derivations
# `02-ackclock/pred_iii.py:15` documents "floor ON = probe_frames=4 (default)",
# which is true of the 02 copy and false of the 03 copy -- the 02 line's own
# artifacts are written against the 02 copy.
#
# Everything those differences touch is reached ONLY under `sched == 'C'`, which
# is why (a) holds: the composite line never runs 'C'.
#
# DELETION -- WHAT WOULD BE LOST
# ------------------------------
# Deleting `02-ackclock/ackclock_sim.py` would make the whole 02 line
# unreproducible: `pred_c/pred_iii/pred_iv/pred_v/pred_vi`, `probe_*`, `sweep*`,
# `verify_passes.py`, `verify_repro.py`, `audit_*` and their committed `*_out.txt`
# are the evidence base for ADR-002's REJECTION of ack-clocking as a replacement
# for the statistical cap.  A rejected branch that cannot be re-run is a claim,
# not a result.  Deleting `03-reserved-composite/ackclock_sim.py` would delete the
# gated oracle itself.  NEITHER IS DELETED.
#
# `pull-study/variants/nsched_model.py` is likewise kept: it is a FORK, not a
# stale duplicate -- it carries the hedge / opportunistic-mirror machinery
# (`hedge`, `hedge_free`, `hedge_src/dst`, `mrng`, `hedge_arr`) that
# `variants/hedge_measure.py` needs and that the shipped model never had, and it
# predates U1's `hold == 0` guard.  145 changed lines, not one.  Deleting it
# would delete the ability to re-run the measurement that OVERTURNED ADR-002's
# opportunistic mirror.
# =============================================================================
import importlib.util
import os
import sys

#: directory name of each study line that owns its own `ackclock_sim.py`
LINES = ('02-ackclock', '03-reserved-composite')

#: the physics module every line shares, relative to `p4-bondagg/sim/`
PHYSICS_BASENAME = 'nsched_model.py'


class RigPinError(ImportError):
    """A module resolved to a file this rig does not claim to be running."""


def _real(p):
    """Comparison form only. NEVER hand this to the loader: `normcase` lowercases on
    Windows, and `ackclock_sim.__file__` is string-compared against a path built from
    the caller's cwd by `rig_paired_gate.py::preflight()`. Case must survive."""
    return os.path.normcase(os.path.realpath(os.path.abspath(p)))


def _asis(p):
    """Loader form: absolute, case preserved exactly as the caller spelled it."""
    return os.path.abspath(p)


def load_pinned(name, path, why=''):
    """Import `path` as module `name`, and REFUSE if `name` is already a different file.

    Returns the module.  Idempotent: a second call with the same path returns the
    module already in `sys.modules` rather than executing it twice (executing it
    twice would give two class objects with the same name and silently break
    `isinstance` across the study).
    """
    want = _real(path)
    if not os.path.isfile(want):
        raise RigPinError('%s: no such file (wanted for module %r)%s'
                          % (path, name, why and '\n  ' + why))
    got = sys.modules.get(name)
    if got is not None:
        have = _real(getattr(got, '__file__', '') or '')
        if have != want:
            raise RigPinError(
                'module %r is already loaded from\n    %s\nbut this rig requires\n    %s\n'
                '  The tree holds more than one copy of %s and which one runs was decided by\n'
                '  sys.path until U35. Fix the path or fix the claim -- do not run an oracle\n'
                '  you cannot name. See p4-bondagg/sim/pull-study/rig_pin.py.%s'
                % (name, have, want, os.path.basename(want), why and '\n  ' + why))
        return got
    spec = importlib.util.spec_from_file_location(name, _asis(path))
    mod = importlib.util.module_from_spec(spec)
    # register BEFORE exec so a self-referential import inside the module sees it
    sys.modules[name] = mod
    try:
        spec.loader.exec_module(mod)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    have = _real(getattr(mod, '__file__', '') or '')
    if have != want:
        sys.modules.pop(name, None)
        raise RigPinError('loaded %r from %s but asked for %s' % (name, have, want))
    return mod


def line_dir(caller_file):
    """The study-line directory holding `caller_file` (e.g. .../03-reserved-composite)."""
    return os.path.dirname(os.path.abspath(caller_file))


def sim_dir(caller_file):
    """`p4-bondagg/sim/` -- two levels above the study line, verified by content.

    Derived from the CALLER'S OWN `__file__`, never from cwd or sys.path, so a rig
    run from any directory resolves the same physics file.
    """
    d = os.path.abspath(os.path.join(line_dir(caller_file), os.pardir, os.pardir))
    if not os.path.isfile(os.path.join(d, PHYSICS_BASENAME)):
        raise RigPinError('expected %s two levels above %s, found none at %s'
                          % (PHYSICS_BASENAME, caller_file, d))
    return d


def pin_physics(caller_file):
    """Load `p4-bondagg/sim/nsched_model.py` BY PATH and assert it is that file.

    Not `pull-study/variants/nsched_model.py`, which is a fork (see the header).
    """
    return load_pinned('nsched_model', os.path.join(sim_dir(caller_file), PHYSICS_BASENAME),
                       why='physics: the SHIPPED model, not pull-study/variants/ (a hedge fork '
                           'that also predates U1\'s hold == 0 guard)')


def pin_oracle(caller_file, line):
    """Load the `ackclock_sim.py` belonging to study line `line`, BY PATH.

    `line` is asserted against the caller's own directory, so a file that is moved
    or copied into the wrong line fails loudly instead of silently swapping the
    two revisions of the oracle.
    """
    if line not in LINES:
        raise RigPinError('unknown study line %r (known: %s)' % (line, ', '.join(LINES)))
    here = os.path.basename(line_dir(caller_file))
    if here != line:
        raise RigPinError('%s claims study line %r but sits in %r -- the two ackclock_sim.py '
                          'revisions are materially different (U35); refusing to guess'
                          % (caller_file, line, here))
    return load_pinned('ackclock_sim', os.path.join(line_dir(caller_file), 'ackclock_sim.py'),
                       why='oracle: the copy belonging to study line %s' % line)


def claim(caller_file, line):
    """Assert the CALLER is the `ackclock_sim.py` of study line `line`.

    Called by each `ackclock_sim.py` on itself, so `import ackclock_sim` alone --
    with no `reserved_composite` in the picture -- still cannot load a copy that
    has been moved out of the directory whose published outputs it reproduces.
    """
    here = os.path.basename(line_dir(caller_file))
    if here != line:
        raise RigPinError('%s declares study line %r but sits in %r (U35: the 02 and 03 copies '
                          'of ackclock_sim.py are different code and reproduce different '
                          'published outputs)' % (caller_file, line, here))
    return line


def identity():
    """What is actually loaded right now, as file paths. For banners and self-checks."""
    out = {}
    for name in ('nsched_model', 'ackclock_sim', 'reserved_composite'):
        m = sys.modules.get(name)
        out[name] = os.path.abspath(getattr(m, '__file__', '')) if m is not None else None
    return out


def describe(prefix='  '):
    lines = []
    for k, v in sorted(identity().items()):
        lines.append('%s%-18s %s' % (prefix, k, v if v else '(not loaded)'))
    return '\n'.join(lines)


if __name__ == '__main__':
    print(__doc__ or '')
    print('rig_pin.py at %s' % os.path.abspath(__file__))
    print('study lines with their own ackclock_sim.py: %s' % ', '.join(LINES))
