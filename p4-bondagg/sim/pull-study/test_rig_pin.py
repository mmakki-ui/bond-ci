#!/usr/bin/env python3
# =============================================================================
# test_rig_pin.py -- self-tests for the U35 oracle/physics pin.
#
# Every check runs in a FRESH SUBPROCESS, because the thing under test is import
# resolution and a single interpreter can only answer it once.
#
# Each negative test is paired with a positive control that must PASS under the
# same machinery, so a test that "catches" something is distinguishable from a
# test that is simply broken.
#
#   python p4-bondagg/sim/pull-study/test_rig_pin.py
# =============================================================================
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.abspath(os.path.join(HERE, os.pardir))
RIG = os.path.join(HERE, '03-reserved-composite')
ACK02 = os.path.join(HERE, '02-ackclock', 'ackclock_sim.py')
ACK03 = os.path.join(RIG, 'ackclock_sim.py')
VARIANTS = os.path.join(HERE, 'variants', 'nsched_model.py')

PASS, FAIL = [], []


def run(code, cwd, env_extra=None, argv=()):
    env = dict(os.environ)
    env.pop('PYTHONPATH', None)
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    if env_extra:
        env.update(env_extra)
    return subprocess.run([sys.executable, '-c', code] + list(argv), cwd=cwd, env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def check(name, ok, detail=''):
    (PASS if ok else FAIL).append(name)
    print('  %-4s %s%s' % ('PASS' if ok else 'FAIL', name, ('\n       ' + detail.strip().replace('\n', '\n       ')) if (detail and not ok) else ''))


IDENT = ("import reserved_composite as RC, os;"
         "print('ORACLE=' + os.path.normcase(os.path.realpath(RC.ORACLE_FILE)));"
         "print('PHYSICS=' + os.path.normcase(os.path.realpath(RC.PHYSICS_FILE)))")


def norm(p):
    return os.path.normcase(os.path.realpath(p))


def ident_ok(out):
    want_o = 'ORACLE=' + norm(ACK03)
    want_p = 'PHYSICS=' + norm(os.path.join(SIM, 'nsched_model.py'))
    lines = [l.strip() for l in out.splitlines()]
    return want_o in lines and want_p in lines


print('rig_pin self-tests -- %s' % HERE)
print()
print('[1] the rig names its own oracle and physics, from any environment')

# T1 -- the gate's own environment: cwd = the rig dir, PYTHONPATH = p4-bondagg/sim
r = run(IDENT, cwd=RIG, env_extra={'PYTHONPATH': SIM})
check('T1 gate env (cwd=rig, PYTHONPATH=sim) resolves 03 oracle + shipped physics',
      r.returncode == 0 and ident_ok(r.stdout), r.stdout)

# T2 -- a FOREIGN cwd and NO PYTHONPATH: resolution must not depend on either.
# Before U35 this could not even import; now it resolves off the rig's own __file__.
r = run(IDENT, cwd=tempfile.gettempdir(), env_extra={'PYTHONPATH': RIG})
check('T2 foreign cwd, PYTHONPATH=rig only, resolves the same two files',
      r.returncode == 0 and ident_ok(r.stdout), r.stdout)

print()
print('[2] loading the WRONG copy now raises instead of running silently')

# T3 -- the exact historical failure: 02\'s oracle already imported under the plain
# name, then the rig imported on top of it. Positive control T1 above proves the
# same import path succeeds when the copies agree.
r = run("import importlib.util as u, sys;"
        "s = u.spec_from_file_location('ackclock_sim', sys.argv[1]);"
        "m = u.module_from_spec(s); sys.modules['ackclock_sim'] = m; s.loader.exec_module(m);"
        "import reserved_composite",
        cwd=RIG, env_extra={'PYTHONPATH': SIM}, argv=[ACK02])
check('T3 rig refuses when 02-ackclock/ackclock_sim.py is already loaded as `ackclock_sim`',
      r.returncode != 0 and 'RigPinError' in r.stdout and '02-ackclock' in r.stdout, r.stdout)

# T4 -- the forked physics (pull-study/variants/) pre-loaded under the plain name.
r = run("import importlib.util as u, sys;"
        "s = u.spec_from_file_location('nsched_model', sys.argv[1]);"
        "m = u.module_from_spec(s); sys.modules['nsched_model'] = m; s.loader.exec_module(m);"
        "import reserved_composite",
        cwd=RIG, env_extra={'PYTHONPATH': SIM}, argv=[VARIANTS])
check('T4 rig refuses the pull-study/variants/ physics fork',
      r.returncode != 0 and 'RigPinError' in r.stdout and 'variants' in r.stdout, r.stdout)

print()
print('[3] a copy MOVED into the other line fails -- with a positive control')

tmp = tempfile.mkdtemp(prefix='u35pin_')
try:
    tsim = os.path.join(tmp, 'sim')
    tps = os.path.join(tsim, 'pull-study')
    good = os.path.join(tps, '03-reserved-composite')
    os.makedirs(good)
    shutil.copy2(os.path.join(SIM, 'nsched_model.py'), os.path.join(tsim, 'nsched_model.py'))
    shutil.copy2(os.path.join(HERE, 'rig_pin.py'), os.path.join(tps, 'rig_pin.py'))
    shutil.copy2(ACK03, os.path.join(good, 'ackclock_sim.py'))

    # T5 POSITIVE CONTROL -- in a directory named for the line it declares, it loads.
    r = run("import ackclock_sim; print('LINE=' + ackclock_sim.STUDY_LINE)", cwd=good)
    check('T5 control: the 03 oracle loads in a tree whose line dir matches its claim',
          r.returncode == 0 and 'LINE=03-reserved-composite' in r.stdout, r.stdout)

    # T6 NEGATIVE -- same bytes, directory renamed to the other line: refused.
    bad = os.path.join(tps, '02-ackclock')
    os.rename(good, bad)
    r = run("import ackclock_sim", cwd=bad)
    check('T6 the same file in a 02-ackclock directory is refused (claim asserts its line)',
          r.returncode != 0 and 'RigPinError' in r.stdout, r.stdout)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print()
print('[4] both copies are still present -- U35 deletes neither')
for p in (ACK02, ACK03, VARIANTS):
    check('T7 present: %s' % os.path.relpath(p, SIM), os.path.isfile(p))

print()
print('%d passed, %d failed' % (len(PASS), len(FAIL)))
sys.exit(1 if FAIL else 0)
