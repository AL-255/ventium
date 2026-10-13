"""Cold-boot CS-extent architectural/cycle A/B; not whole-suite acceptance.

Run only under the shared heavy-work guard, with already built models. No RTL
build, golden normalization, state injection or fallback profile is allowed.
Request/held-owner qualification still needs a read-only internal observer;
the ordinary trace's default U label is intentionally not used as that proof.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import traceback

from prepare_pipe_mem_cs_fixtures import REPO, CASES, audit_image, sha

sys.path.insert(0, str(REPO/'verif/diff'))
import tracefmt


def grade_native(folder, stem, layout):
    want = layout['expected']
    text = '\n'.join((folder/(stem+suffix)).read_text()
                     for suffix in ('.stdout', '.stderr'))
    assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL', text)
    faults = re.findall(r'^\[FAULT\] vec=(\d+) err=([0-9a-f]+) pc=([0-9a-f]+)\b', text, re.M)
    assert faults == [('13', '00000000', f"{want['fault_pc']:08x}")], faults
    trace = tracefmt.read_trace(str(folder/(stem+'.vtrace')))
    rows = trace.records
    assert 50 < len(rows) < 3000
    assert [r['n'] for r in rows] == list(range(len(rows)))
    assert all(int(r['pc'], 0) != layout['symbols']['fail'] for r in rows)
    footer = re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) '
                        r'after (\d+) retired in (\d+) clocks$', text, re.M)
    assert len(footer) == 1 and int(footer[0][0]) == len(rows)
    if stem.endswith('cycle-func'):
        assert trace.hdr.get('sys') is True
        final = rows[-1]
        for field, value in dict(eax=0x42, ebp=want['memory'], edi=1,
                                 esi=want['fault_pc'], cs=8, ss=0x10).items():
            assert int(final[field], 0) == value, (field, final[field], value)
        assert int(final['edx'], 0) & 0xffff == 0xf4
        returns = [r for r in rows if int(r['pc'], 0) == layout['symbols']['case_return']]
        assert len(returns) == 1 and int(returns[0]['eax'], 0) == want['eax']
        for row in rows:
            assert all(key in row for key in tracefmt.SYS_CR)
    else:
        # Real V execution in the copied warmup, not a define-count claim.
        pairs = [r for r in rows if r.get('pipe') == 'V' and r.get('paired')
                 and 0x8000 <= int(r['pc'], 0) < 0x8020]
        assert pairs, 'UV warmup did not pair'
    extents = re.findall(r'^\[SEGCHK-X\] st=(\d+) eip=([0-9a-f]+) len=(\d+) '
                         r'cs_lim=([0-9a-f]+) cs_attr=([0-9a-f]+)$', text, re.M)
    return trace, dict(records=len(rows), clocks=int(footer[0][1]),
                       extent_observations=extents)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('fixtures', 'control', 'candidate', 'out'):
        ap.add_argument('--'+name, type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    out = args.out.resolve()
    assert out.is_relative_to(scratch) and out != scratch
    fixtures = args.fixtures.resolve(strict=True)
    prepared = json.loads((fixtures/'closed.json').read_text())
    started = json.loads((fixtures/'started.json').read_text())
    assert prepared['layout_passed'] and prepared['pins_unchanged']
    assert len(prepared['cases']) == 12
    models = {key: getattr(args, key).resolve(strict=True) for key in ('control', 'candidate')}
    pins = dict(started['pins'])
    profiles = {}
    for key, model in models.items():
        stamp = model.parent/'Vventium_top__verFiles.dat'
        commands = [x for x in stamp.read_text().splitlines() if x.startswith('C ')]
        assert len(commands) == 1 and ' --assert ' in commands[0]
        profile = set(re.findall(r'\+define\+(\w+)', commands[0]))
        assert {'VEN_SEG_ENFORCE', 'VEN_L1_AXI', 'VEN_SYS_FASTPATH',
                'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTLOAD_FLAT',
                'VEN_SYS_FASTSTORE_FLAT', 'VEN_FE_PIPE'} <= profile
        assert not {'VEN_UOPCACHE', 'VEN_SYS_FASTPATH_ALL', 'SYNTHESIS', 'VTM_NO_DPI'} & profile
        profiles[key] = sorted(profile)
        pins.update({str(p): sha(p) for p in (model, stamp)})
    assert profiles['control'] == profiles['candidate']
    for p in (Path(__file__), fixtures/'closed.json', fixtures/'started.json',
              REPO/'verif/diff/tracefmt.py'):
        pins[str(p)] = sha(p)
    cases = {}
    for row in prepared['cases']:
        case = tuple(row['expected'][k] for k in ('kind', 'length', 'over'))
        assert case not in cases
        image = Path(row['image']).resolve(strict=True)
        assert image.is_relative_to(fixtures) and sha(image) == row['image_sha256']
        assert audit_image(image.read_bytes(), row['symbols'], case) == row['expected']
        pins[str(image)] = sha(image)
        cases[case] = row
    assert set(cases) == set(CASES) and all(sha(p) == h for p, h in pins.items())
    out.mkdir()
    with (out/'started.json').open('x') as f:
        json.dump(dict(pins=pins, profiles=profiles, invocation=os.environ.get('INVOCATION_ID'),
                       affinity=sorted(os.sched_getaffinity(0))), f, indent=2)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VEN_', 'TB_', 'AXI_', 'QEMU_'))}
    begin = time.monotonic()
    result = dict(passed=False, cases=[], errors=[], fast_request_coverage_qualified=False,
                  standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    try:
        for case, layout in cases.items():
            leaf = out/f'k{case[0]}-n{case[1]}-over{case[2]}'
            leaf.mkdir()
            for latency in (0, 7):
                all_traces, measurements = {}, {}
                for name, model in models.items():
                    traces, measures = {}, {}
                    for mode in ('cycle-func', 'cycle'):
                        stem = f'{name}-l{latency}-{mode}'
                        command = ['timeout', '--signal=TERM', '--kill-after=3s', '60s', str(model),
                            '--system', '--cosim', '--'+mode, '--l1-axi', '--image', layout['image'],
                            '--out', str(leaf/(stem+'.vtrace')), '--max-insn', '3000',
                            '--max-cycles', '3000000', '--quiesce', '4096', '+ven_faultlog', '+ven_seglog']
                        with (leaf/(stem+'.command.json')).open('x') as f:
                            json.dump(dict(argv=command, AXI_RLAT=latency, AXI_WLAT=latency), f)
                        with (leaf/(stem+'.stdout')).open('x') as output, (leaf/(stem+'.stderr')).open('x') as error:
                            status = subprocess.run(command, env=dict(env, AXI_RLAT=str(latency),
                                AXI_WLAT=str(latency)), stdout=output, stderr=error).returncode
                        with (leaf/(stem+'.exit')).open('x') as f:
                            f.write(str(status)+'\n')
                        assert status == 133, (case, stem, status)
                        trace, measures[mode] = grade_native(leaf, stem, layout)
                        traces[mode] = trace.records
                    assert [r['pc'] for r in traces['cycle']] == [r['pc'] for r in traces['cycle-func']]
                    all_traces[name], measurements[name] = traces, measures
                assert all_traces['control'] == all_traces['candidate'], (case, latency, 'full A/B drift')
                assert measurements['control'] == measurements['candidate'], (case, latency, 'observation drift')
                result['cases'].append(dict(case=case, latency=latency, measurements=measurements))
        result['passed'] = len(result['cases']) == 24
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result['pins_unchanged'] = all(sha(p) == h for p, h in pins.items())
    result['passed'] &= result['pins_unchanged']
    result['seconds'] = time.monotonic()-begin
    with (out/'closed.json').open('x') as f:
        json.dump(result, f, indent=2)
    print(json.dumps({k: v for k, v in result.items() if k != 'cases'}), flush=True)
    raise SystemExit(0 if result['passed'] else 1)


if __name__ == '__main__':
    main()
