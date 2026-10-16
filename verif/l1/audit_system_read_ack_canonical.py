"""Prove full canonical RTL trace preservation without waiving its red verdict."""
import argparse
import json
from pathlib import Path
import run_system_read_ack_core as common
from audit_system_read_ack_core import owner


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,required=True)
    root=ap.parse_args().root.resolve(strict=True)
    assert root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    parent=root/'raw-prime-storage-core-r1'
    candidate=root/'system-read-ack-core-r1'
    replay=root/'system-read-ack-replay-r1'
    start,closed=[json.loads((replay/n).read_text()) for n in ('started.json','closed.json')]
    owner('ventium-system-read-ack-replay-oct16-r1.service',start['invocation'],0)
    assert closed['regression_check_passed'] and closed['pins_unchanged'] and not closed['errors']
    assert len(closed['rows'])==108 and not closed['masks_or_record_normalization']
    pins=dict(start['pins']); rows=[]
    for mode,expected in (('func',108),('cycle',20)):
        new=sorted((candidate/'generic-work').glob('*.'+mode+'_rtl.vtrace'))
        # Independent QEMU invocations have different initial ESP. Reuse the
        # candidate's actual image/initial stack in a real native parent run;
        # never mask ESP or normalize records to force equivalence.
        old=([replay/p.name.removesuffix('.func_rtl.vtrace')/'parent.vtrace' for p in new]
             if mode=='func' else sorted((parent/'generic-work').glob('*.cycle_rtl.vtrace')))
        assert len(old)==len(new)==expected
        for a,b in zip(old,new):
            for p in (a,b):pins[str(p)]=common.sha(p)
            before,after=[common.tracefmt.read_trace(str(p)) for p in (a,b)]
            assert before.records==after.records,(mode,b.name)
            rows.append(dict(mode=mode,name=b.name,records=len(after.records),same_records=True))
    for p in (Path(__file__),Path(common.__file__),Path(common.tracefmt.__file__),
              root/'system-read-ack-audit-r1.json',candidate/'verify-closed.json',parent/'verify-closed.json',
              replay/'started.json',replay/'closed.json'):
        pins[str(p.resolve())]=common.sha(p)
    verdict=json.loads((candidate/'verify-closed.json').read_text())
    assert verdict['canonical_gate_native_exit']==2 and not verdict['canonical_gate_passed']
    assert not verdict['masks_or_goldens_or_bands_changed']
    assert all(common.sha(p)==h for p,h in pins.items())
    result=dict(parent_identical=True,same_input_parent_replay=True,rows=rows,pins=pins,canonical_gate_passed=False,
        native_gate_exit=2,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    common.save(root/'system-read-ack-canonical-audit-r1.json',result)
    print(json.dumps({m:dict(traces=sum(r['mode']==m for r in rows),
        records=sum(r['records'] for r in rows if r['mode']==m)) for m in ('func','cycle')}))


if __name__=='__main__':main()
