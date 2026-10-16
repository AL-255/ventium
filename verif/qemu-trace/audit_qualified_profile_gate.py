"""Recheck the closed Oct 16 profile run; explicitly retain the red gate.

The original controller mislabeled S_PIPE issue pairs as total V retirements.
Its exact source and unchanged receipt are retained. Recount native U/V totals,
and allow only that one historical source alias; no general drift waiver.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess

import run_qualified_profile_gate as gate
import qualified_profile as profile

ORIGINAL_RUNNER = 'dd471f4eedaf59b6bd10a970df34d1709785b3cebb9cd1e8745e6edce60799c9'


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--run',type=Path,required=True)
    ap.add_argument('--unit',required=True)
    args=ap.parse_args()
    root=args.run.resolve(strict=True)
    profile.require(root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True)),
                    'external run required')
    started=json.loads((root/'started.json').read_text())
    closed=json.loads((root/'closed.json').read_text())
    runner=str(Path(gate.__file__).resolve())
    historical=root/'run_qualified_profile_gate-observed.py'
    pins=started['pins']
    profile.require(pins[runner]==profile.sha(historical)==ORIGINAL_RUNNER,'historical runner mismatch')
    for name,digest in pins.items():
        profile.require(profile.sha(historical if name==runner else name)==digest,'input drift: '+name)
    profile.select(Path(started['environment']['VTM_QEMU_PROFILE_BUILD']))
    report=gate.analyze(root/'work',Path(started['core_build'])/'generic-work')
    profile.require(report['functional_passes']==len(report['functional'])==108,'functional failures/missing results')
    profile.require(report['functional_records']==80800,'functional trace count changed')
    profile.require(report['cycle_records_unchanged'] and report['cycle_argv_checked'],'cycle regression/mode changed')
    profile.require(closed['native_exit']==2 and closed['gate_passed'] is False
                    and closed['pins_unchanged'] is True and closed['errors']==[], 'unexpected native verdict')
    profile.require(closed['functional_v_retired']==report['functional_fast_issue_pairs'],
                    'original counter discrepancy is not the documented classification error')
    text=(root/'native.log').read_text()
    profile.require('func totals: 108 PASS / 0 FAIL / 108 total' in text,'missing functional summary')
    bands=dict(re.findall(r'^\s+(mb_\w+)\s+(?:INT|FP|CACHE|DIV|MUL|PAIR|INFO)\s+(PASS|FAIL|INFO)\s',text,re.M))
    profile.require(len(bands)==20 and list(bands.values()).count('FAIL')==9,'cycle-band summary changed')
    owner=subprocess.check_output(['systemctl','--user','show',args.unit,
        '-p','ActiveState','-p','MainPID','-p','Result','-p','ExecMainStatus','-p','InvocationID'],text=True)
    props=dict(line.split('=',1) for line in owner.splitlines())
    profile.require(props['MainPID']=='0' and props['ActiveState']=='failed'
        and props['Result']=='exit-code' and props['ExecMainStatus']=='1'
        and props['InvocationID']==started['invocation'],'owner is not the exact closed failed run')
    for row in closed['native_samples'].values():
        profile.require(set(row['affinity'])<=set(range(4)),'native affinity')
        cgroup=row['cgroup'].strip().split('::',1)[1]
        profile.require(not Path('/sys/fs/cgroup'+cgroup).exists(),'guarded scope not reaped')
    artifacts=[root/'started.json',root/'closed.json',root/'native.log',historical,
               Path(__file__).resolve(),Path(gate.__file__).resolve(),Path(profile.__file__).resolve()]
    artifacts.extend(p for p in (root/'work').iterdir() if p.is_file())
    artifacts.extend(p for p in (root/'cache').iterdir() if p.is_file())
    result=dict(audit_completed=True,gate_passed=False,native_exit=2,
        input_pins_checked=len(pins),historical_source_alias={runner:str(historical)},
        historical_source_sha256=ORIGINAL_RUNNER,
        artifacts={str(p):profile.sha(p) for p in artifacts},owner=props,cycle_bands=bands,
        corrected_counter_note='Original functional_v_retired counts only S_PIPE pairs; totals below use native pairedV.',
        **report,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    gate.dump(root/'audit.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in
        ('artifacts','functional','cycles','historical_source_alias','cycle_bands')}))


if __name__=='__main__':main()
