"""Run all canonical cycle kernels on the explicit ao486 single-fill model.

This is a diagnostic, not a substitute for canonical verification. Preserve
both zero-added-latency and default-latency results and all original bands.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'verif'))
import m5_metrics


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    out = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert os.sched_getaffinity(0) == set(range(8, 16))
    source = root / 'board-profile-r1.driver.py'
    assert sha(source) == 'aebb3c9a800b5c86acd3381b693265ef6207332cfcc2863ac83ee85b58546e25'
    parent = Path(json.loads((root / 'board-core-r1/build-started.json').read_text())['parent'])
    jobs_file = parent / 'generic-work/jobs.txt'
    jobs = [s.split('\t') for s in jobs_file.read_text().splitlines() if s.startswith('cycle\t')]
    names = tuple(job[1] for job in jobs)
    assert len(names) == len(set(names)) == 20
    assert {j[9] for j in jobs} == {'INT', 'FP', 'CACHE', 'DIV', 'MUL', 'PAIR', 'INFO'}
    substitutions = [
        ("NAMES=('mb_fpindep','mb_faddchain','mb_depadd','mb_indepadd','mb_dmiss','mb_imiss','mb_brloop','mb_brrandom')",
         'NAMES=' + repr(names)),
        ('for latency in (0,1,7):', 'for latency in (0,7):'),
        ('latencies=[0,1,7]', 'latencies=[0,7]'),
        # Some kernels serialize legitimately. Retain and verify their actual
        # V records; do not require every directed kernel to be pairable.
        ("pairs==sum(r['pipe']=='V' for r in records) and pairs>0",
         "pairs==sum(r['pipe']=='V' for r in records)"),
        ("assert profile and profile.groups()[5:]==('0','0','0','1')",
         "assert profile and profile.groups()[6:8]==('0','0')"),
        ("        assert avg\n        axi.update(zip(('avg_busy','first_r_hs','nontransfer','rvalid_low','rready_stall'),map(float,avg.groups())))",
         """        if axi['valid']:
            assert avg and axi['incomplete']==0
            axi.update(zip(('avg_busy','first_r_hs','nontransfer','rvalid_low','rready_stall'),map(float,avg.groups())))
        else:
            # The canonical INFO kernel ends at its instruction cap with a
            # read outstanding. Retain invalidity, not invented averages.
            assert name=='mb_agiloop' and len(records)==int(args[args.index('--max-insn')+1])
            assert 'stop: reached --max-insn ('+str(len(records))+')' in txt
            assert axi['incomplete']==1 and axi['ar']==axi['rlast']+1
            assert axi['rlast']*8 < axi['r'] < axi['requested']==axi['ar']*8
            assert avg is None and 'read averages INVALID' in txt
            axi['incomplete_reason']='instruction-capped INFO trace; averages unavailable'"""),
    ]
    text = source.read_text()
    for before, after in substitutions:
        assert text.count(before) == 1, before
        text = text.replace(before, after)
    driver = out.with_suffix('.driver.py')
    compile(text, str(driver), 'exec')
    with driver.open('x') as stream:
        stream.write(text)
    pins = {str(p): sha(p) for p in (Path(__file__), source, driver, jobs_file,
        REPO / 'verif/m5_metrics.py', REPO / 'verif/m4_metrics.py', REPO / 'verif/verify.sh')}
    command = [sys.executable, '-B', str(driver), '--out', str(out)]
    save(out.with_suffix('.driver.json'), dict(pins=pins, substitutions=substitutions,
        command=command, jobs=jobs, invocation=os.environ['INVOCATION_ID']))
    subprocess.run(command, check=True, timeout=180, stdout=subprocess.DEVNULL)
    closed = json.loads((out / 'closed.json').read_text())
    assert closed['diagnostic_completed'] and len(closed['rows']) == 40
    bands = []
    for latency in (0, 7):
        chain = next(r for r in closed['rows'] if r['name'] == 'mb_faddchain' and r['latency'] == latency)
        os.environ['M5_FADDCHAIN_CPI'] = str(chain['cpi'])
        for job in jobs:
            name = job[1]
            gold = (parent / 'generic-work' / (name + '.cycle.result')).read_text().split('|')[5]
            verdict, cpi, pair, extra, detail = m5_metrics.compute(
                name, str(out / (name + '-lat' + str(latency) + '.vtrace')), gold, 10.0)
            assert verdict in ('PASS', 'FAIL', 'INFO')
            bands.append(dict(name=name, latency=latency, classification=job[9], verdict=verdict,
                cpi=cpi, pair=pair, extra=extra, detail=detail, gated=job[9] != 'INFO'))
    assert all(sha(p) == h for p, h in pins.items())
    result = dict(diagnostic_completed=True, pins_unchanged=True, bands=bands,
        pins=pins, canonical_gate_passed=False, hardware_acceptance=False, gameplay_ipc=None,
        note='Unchanged M4/M5 bands; zero slave wait is a diagnostic, not physical DDR latency.')
    save(out / 'bands.json', result)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
