"""Independent closure/source/trace audit of the isolated SMSW first-stage gate."""
import argparse
import ast
import json
from pathlib import Path
import subprocess
import sys

from run_probe import REPO, sha
import prepare


def owner(unit, invocation):
    props = dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show',unit,'-p','MainPID','-p','SubState',
        '-p','ExecMainStatus','-p','Result','-p','InvocationID'],text=True).splitlines())
    assert props == dict(MainPID='0',SubState='exited',ExecMainStatus='0',
                         Result='success',InvocationID=invocation)
    return props


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('core','golden','checks','out'):
        parser.add_argument('--'+name,required=True,type=Path)
    args = parser.parse_args()
    core,golden,checks = [getattr(args,key).resolve(strict=True) for key in ('core','golden','checks')]
    built = json.loads((core/'build-closed.json').read_text())
    before = json.loads((core/'build-started.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(core/'obj/tb_ventium') == built['binary_sha256']
    assert all(sha(path) == value for path,value in before['pins'].items())
    assert len(before['definitions']) == 152
    parent = Path(before['parent'])/'candidate'
    for name in prepare.PARENTS:
        assert (core/'candidate/rtl/core'/name).read_text() == prepare.transform(
            (parent/'rtl/core'/name).read_text(),name)
    changed = [str(path.relative_to(parent)) for path in parent.rglob('*') if path.is_file()
               and sha(path) != sha(core/'candidate'/path.relative_to(parent))]
    assert sorted(changed) == sorted('rtl/core/'+name for name in prepare.PARENTS)
    # build_scope creates a separate native invocation; do not confuse its ID
    # with the retained controller's ID or accept a vanished scope as closure.
    owners = {'build':owner('ventium-smsw-core-oct13-r1.service',
                            'b142acdcc9c44e948ed767f4962bb171')}
    journal = [json.loads(line) for line in subprocess.check_output([
        'journalctl','--user','_SYSTEMD_INVOCATION_ID='+before['invocation'],
        '-o','json','--no-pager'],text=True).splitlines()]
    assert journal and all(row['_SYSTEMD_USER_UNIT'] == 'ventium-ipc-parallel32.scope'
                           for row in journal)
    native_receipts = [ast.literal_eval(row['MESSAGE']) for row in journal
                       if row['MESSAGE'].startswith("{'passed':")]
    assert native_receipts == [built]
    owners['build_native_invocation'] = before['invocation']
    pins = {str(path):sha(path) for path in (Path(__file__),Path(prepare.__file__),
        REPO/'verif/diff/compare.py',REPO/'verif/diff/tracefmt.py',
        core/'build-started.json',core/'build-closed.json',core/'obj/tb_ventium')}
    runs = {}
    for name,root,action in (('golden',golden,'golden'),('diff',checks,'check')):
        start,closed = [json.loads((root/file).read_text()) for file in ('started.json','closed.json')]
        assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
        assert closed['action'] == action and len(closed['rows']) == 88
        assert all(sha(path) == value for path,value in start['pins'].items())
        assert all(sha(path) == value for path,value in closed['artifacts'].items())
        owners[name] = owner('ventium-smsw-'+name+'-oct13-r1.service',start['invocation'])
        pins.update(closed['artifacts'])
        pins[str(root/'closed.json')] = sha(root/'closed.json')
        runs[name] = closed
    assert [r['name'] for r in runs['golden']['rows']] == [r['name'] for r in runs['diff']['rows']]
    total = 0
    for row in runs['diff']['rows']:
        name = row['name']
        assert row['native_exit'] == 133
        compared = subprocess.run(['taskset','-c','0,1',sys.executable,
            REPO/'verif/diff/compare.py','--mode','func',
            golden/(name+'.vtrace'),checks/(name+'.vtrace')],capture_output=True,text=True,timeout=10)
        assert compared.returncode == 0, (name,compared.stdout,compared.stderr)
        assert 'sys compared: True' in compared.stdout
        total += row['records']
    assert all(sha(path) == value for path,value in pins.items())
    result = dict(passed=True,owners=owners,model=built['binary_sha256'],
        changed_sources=sorted(changed),cases=88,architectural_records=total,
        full_trace_comparison=True,custom_masks=False,pins=pins,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,
        limits='Real and CPL0 only; paging off. CPL3/V86 and precise faults remain open.')
    with args.out.open('x') as stream:
        json.dump(result,stream,indent=2)
    print(json.dumps({key:value for key,value in result.items() if key != 'pins'}))


if __name__ == '__main__':
    main()
