"""Recheck every original AUX microcase before transferring its one-line fix.

Read-only. Native failures are required old-controller/mutant witnesses, not
controller passes. This does not establish full-PC, Win95, or board acceptance.
"""
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess

import run_aux_status as gate
import prepare_aux_status as recipe

CLOSED = 'c20586f06a84633b1d4bdec25b7be45f9e76e027ec4124528bb0f211bd1ae042'
CANDIDATE = '2ee3b64fc24875b3aaca0e6296a2514161f19cef5e6f79aa90923ca06f1846da'
UNIT = 'ventium-ps2-aux-oct14-r2.service'
INVOCATION = '527a4a8260594a0884b515c30fd3f329'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def expected_cases():
    rows = []
    for case in gate.matrix():
        for variant in (0, 1):
            expected = 'parent_bug' if variant == 0 and case[0] in (2, 4, 5) else 'pass'
            rows.append((variant, case, expected))
    for variant, scenario in ((2, 1), (3, 0)):
        for sources in (0, 3):
            rows.append((variant, (scenario, sources, 64, 31, 1, 1), 'constant_aux_mutant'))
    assert len(rows) == 996
    return rows


def grade(row, text, expected):
    """Do not accept a relabelled expected failure or a false zero exit."""
    assert row['expected'] == expected and row['affinity'] == [13]
    if expected == 'pass':
        assert row['exit'] == 0 and 'PS2-AUX-OK ' in text
        assert 'PS2-AUX-ORIGIN-MISMATCH' not in text
    else:
        assert row['exit'] in (-6, 1, 134) and 'PS2-AUX-ORIGIN-MISMATCH' in text
        assert 'PS2-AUX-OK ' not in text


def audit(proof):
    proof = proof.resolve(strict=True)
    assert sha(proof/'closed.json') == CLOSED
    start = json.loads((proof/'started.json').read_text())
    closed = json.loads((proof/'closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert not closed['full_pc'] and not closed['standard_suite'] and not closed['fpga_acceptance']
    assert start['pins'] == closed['input_pins']
    pins = dict(start['pins'])
    assert all(sha(p) == h for p, h in pins.items())
    assert sha(proof/'ps2.v') == start['candidate_sha256'] == CANDIDATE
    source = (gate.REPO/(gate.REL+'soc/ps2.v')).read_text()
    assert (proof/'ps2.v').read_text() == recipe.transform(source)
    for name in ('parent', 'fixed', 'zero', 'one'):
        assert (proof/('ps2_aux_'+name+'.sv')).read_text() == recipe.variant(source, name)
    events = dict(line.split() for line in closed['memory_events'].splitlines())
    assert all(events[k] == '0' for k in ('oom', 'oom_kill', 'oom_group_kill'))
    keys = ('ActiveState', 'SubState', 'MainPID', 'Result', 'ExecMainStatus', 'InvocationID')
    owner = dict(s.split('=', 1) for s in subprocess.check_output([
        'systemctl', '--user', 'show', UNIT, *['-p'+k for k in keys]], text=True).splitlines())
    assert owner == dict(ActiveState='active', SubState='exited', MainPID='0',
                         Result='success', ExecMainStatus='0', InvocationID=INVOCATION)
    assert len(closed['builds']) == 4 and len(closed['rows']) == 3984
    counts = Counter()
    for profile, definitions in enumerate(gate.PROFILES):
        folder = proof/('profile-'+str(profile))
        build = closed['builds'][profile]
        assert build['exit'] == 0 and sha(folder/'build.log') == build['log_sha256']
        assert sha(folder/'obj/test') == build['model_sha256']
        assert [s[8:] for s in build['command'] if s.startswith('+define+')] == list(definitions)
        for warning in ('IMPLICIT', 'PINMISSING', 'UNDRIVEN', 'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT'):
            assert '-Werror-'+warning in build['command']
        for index, (variant, case, expected) in enumerate(expected_cases()):
            row = closed['rows'][profile*996+index]
            log = folder/f'case-{index:04d}.log'
            command = [str(folder/'obj/test'), '+variant='+str(variant)] + [
                '+'+k+'='+str(v) for k, v in zip(
                    ('scenario', 'sources', 'half', 'wait', 'translate', 'interrupts'), case)]
            assert row['command'] == command and row['log'] == str(log)
            assert sha(log) == row['log_sha256']
            grade(row, log.read_text(), expected)
            counts[expected] += 1
            pins[str(log)] = sha(log)
        for p in (folder/'build.log', folder/'obj/test'):
            pins[str(p)] = sha(p)
    assert dict(counts) == closed['counts'] == {'pass': 3008, 'parent_bug': 960, 'constant_aux_mutant': 16}
    for p in (Path(__file__), Path(gate.__file__), Path(recipe.__file__),
              proof/'started.json', proof/'closed.json'):
        pins[str(p)] = sha(p)
    assert all(sha(p) == h for p, h in pins.items())
    return dict(passed=True, counts=dict(counts), pins=pins, retained_owner=owner,
                candidate_sha256=CANDIDATE, executions=3984,
                full_pc=False, standard_suite=False, physical_board=False, gameplay_ipc=None)
