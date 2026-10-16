"""Reconstruct six passing boundary/control executions and the failed CDC run.

The unchanged CDC fixture's stale read is a retained failure, not a pass. Its
separate edge-correct derivative must preserve data checks and all four clock
ratios. No processor, timing or hardware acceptance follows from this audit.
"""
import argparse
import json
from pathlib import Path

import audit_qualified_pair_credit as native
import run_qualified_pair_credit_corners as corners
import run_qualified_pair_credit_exclusions as exclusions
import run_qualified_pair_credit_cdc_edges as edges

RUNS = (
    ('corners', '464c1326c35c4094aedb240d8c315336'),
    ('default', '78c6de20bfc54d5eb2f621094c073a9a'),
    ('cdc-edges', 'ab11ef8a6426449188210d669ac1f030'),
)


def audit(root):
    root = root.resolve(strict=True)
    parent = root/'raw-prime-storage-fpga-r1'
    source = {n:(parent/'ventium/rtl/mem'/n).read_text() for n in native.recipe.PINS}
    changed = native.recipe.transform(source)
    hardware = json.loads((parent/'input-manifest.json').read_text())['hardware_defines']
    pins, owners, results = {}, {}, []
    for label, invocation in RUNS:
        folder = root/('qualified-pair-credit-'+label+'-r1')
        closed = json.loads((folder/'closed.json').read_text())
        assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
        assert len(closed['rows']) == 2
        assert not any(closed[k] for k in ('whole_core','standard_suite','hardware_acceptance'))
        owners[label] = native.owner(folder,'ventium-qualified-pair-'+label+'-oct16-r1.service','success',invocation)
        if label == 'corners':
            bench = corners.fixture()
            assert (folder/'qualified_pair_credit_corners.svh').read_text() == corners.leaf()
            definitions = [v for v in hardware if v!='SYNTHESIS']+['AXI_BFM_MON','VEN_AXI_RESP_FAULT_INJECT']
            coverage = 'PAIR-CREDIT-CORNERS-OK quad_release=1 split_release=1 deny_release=1 error_release=1 shutdown=1 U=10 V=4 AW=11'
        else:
            bench = exclusions.fixture('default') if label=='default' else edges.fixture('cdc')
            definitions = [] if label=='default' else ['VEN_AXI_CDC']
            coverage = ('L1AXI-GATE-OK (all checks pass)' if label=='default' else
                        'L1AXICDC-GATE-OK (CDC data-coherent across axi-fast/slow/equal/coprime)')
        assert (folder/'tb_qualified_pair_wrapper.sv').read_text() == bench
        for name in ('ven_axi_master.sv','ventium_l1_axi.sv'):
            assert (folder/name).read_text() == changed[name]
        for row in closed['rows']:
            command = row['command']; candidate = row['candidate']
            assert row['coverage'] == coverage
            extra = ['PAIR_CREDIT_CANDIDATE_OBSERVE'] if candidate and label!='corners' else []
            assert [v for v in command if v.startswith('+define+')] == ['+define+'+v for v in definitions+extra]
            assert '--assert' in command and all('-Werror-'+v in command for v in
                ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT'))
            for index, name in ((-3,'ven_axi_master.sv'),(-2,'ventium_l1_axi.sv')):
                assert Path(command[index]).read_text() == (changed if candidate else source)[name]
            if label == 'cdc-edges':
                for ratio in ('axi-fast 5:2','axi-slow 2:5','equal 4:4','coprime 5:3'):
                    assert row['log'].count('CDC-EDGE ['+ratio+'] accepted_stores=41 first_store=1') == 1
            pins.update(native.artifacts(row))
        pins.update(closed['pins']);pins[str(folder/'closed.json')] = native.sha(folder/'closed.json')
        results.append(dict(label=label,seconds=closed['seconds'],native_passes=2,coverage=coverage))

    failed = root/'qualified-pair-credit-cdc-r1'
    old = json.loads((failed/'closed.json').read_text())
    assert not old['passed'] and old['pins_unchanged'] and len(old['rows'])==1
    row = old['rows'][0]
    assert not row['candidate'] and row['build_exit']==row['native_exit']==0
    assert row['log'].count('read-after-write: got a5a51008 exp deadbeef')==4
    assert 'L1AXICDC-GATE-FAIL (4 errors)' in row['log'] and 'L1AXICDC-GATE-OK' not in row['log']
    assert (failed/'tb_qualified_pair_wrapper.sv').read_text()==exclusions.fixture('cdc')
    assert (failed/'parent/run.log').read_text()==row['log']
    pins.update(old['pins']);pins.update(row['artifacts'])
    pins[str(failed/'closed.json')] = native.sha(failed/'closed.json')
    owners['cdc-original-failed'] = native.owner(failed,'ventium-qualified-pair-cdc-oct16-r1.service',
        'exit-code','1343a8d50f4f4d39bcca0ffbeafa7856')
    for p in (Path(__file__).resolve(),Path(native.__file__).resolve(),Path(corners.__file__).resolve(),
              Path(exclusions.__file__).resolve(),Path(edges.__file__).resolve()):
        pins[str(p)] = native.sha(p)
    assert all(native.sha(p)==v for p,v in pins.items())
    return dict(audit_passed=True,native_passes=6,original_cdc_still_failed=True,
                native_failure_count=1,results=results,pins=pins,owners=owners,
                canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
                gameplay_ipc=None,fmax_mhz=None)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,required=True)
    args = ap.parse_args(); result = audit(args.root)
    output = args.root.resolve(strict=True)/'qualified-pair-credit-boundaries-audit-r1.json'
    assert output.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    with output.open('x') as f: json.dump(result,f,indent=2)
    print('PAIR-BOUNDARY-AUDIT-OK native=6 original_cdc_failed=1 pins='+str(len(result['pins'])))
