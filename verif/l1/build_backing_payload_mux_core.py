"""Build the single-file payload-mux derivative with the retained native builder.

Require both the unfiltered four-state leaf and real-cache positive/negative
tests. Keep the exact 195-source parent, 152 definitions, private harness,
32-job guard and native build/header checks; no timing or acceptance claim.
"""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import subprocess

import prepare_backing_payload_mux as recipe

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]


def once(text,before,after):
    if text.count(before)!=1:raise ValueError('native builder anchor drift: '+before)
    return text.replace(before,after,1)


def core_driver():
    text=(HERE/'build_current_u_pair_core.py').read_text()
    text=once(text,'import prepare_current_u_pair as recipe','import prepare_backing_payload_mux as recipe')
    text=once(text,'REPO = Path(__file__).resolve().parents[2]',f'REPO = Path({str(REPO)!r})')
    begin=text.index("    leaf = DATA/'current-u-pair-leaf-r1'")
    end=text.index('    # This is the direct source/build closure',begin)
    text=text[:begin]+'''    leaf = DATA/'backing-payload-mux-leaf-r1'
    cache = DATA/'backing-payload-mux-cache-r2'
    checked = native.load(leaf/'closed.json')
    sequential = native.load(cache/'closed.json')
    assert checked['passed'] and checked['pins_unchanged'] and checked['unfiltered_all_outputs']
    assert len(checked['rows']) == 7 and sum(r['native_exit']==0 for r in checked['rows']) == 3
    assert sequential['passed'] and sequential['pins_unchanged'] and not sequential['errors']
    assert sequential['contract_filter'] is None and sequential['output_filter'] is None
    assert [(r['label'],r['native_exit']) for r in sequential['rows']] == [
        ('positive',0),('late-address-negative',1)]
    assert native.stable(checked['pins']) and native.stable(sequential['pins'])
    for label in ('leaf-oct15-r1','cache-oct15-r2'):
        unit='ventium-backing-payload-mux-'+label+'.service'
        props=dict(s.split('=',1) for s in subprocess.check_output([
            'systemctl','--user','show',unit,'-p','SubState','-p','MainPID','-p','ExecMainStatus'],text=True).splitlines())
        assert props == dict(SubState='exited',MainPID='0',ExecMainStatus='0')
''' + text[end:]
    text=once(text,"    pins = dict(checked['pins'])\n",'''    pins = dict(checked['pins'])
    pins.update(sequential['pins'])
    for row in checked['rows']: pins.update(row['files'])
    for row in sequential['native']:
        assert row['actual_wait'] and row['reaped'] and native.sha(row['log']) == row['sha256']
        pins[row['log']] = row['sha256']
    for path in (cache/'closed.json', cache/'started.json', leaf/'ven_l1d.sv',
                 REPO/'verif/l1/build_backing_payload_mux_core.py',
                 REPO/'verif/l1/build_current_u_pair_core.py'):
        pins[str(path.resolve())] = native.sha(path)
''')
    text=once(text,'    for name in recipe.PARENTS:',"    for name in ('rtl/mem/ven_l1d.sv',):")
    text=once(text,'recipe.transform((source/name).read_text(),name)',
                    'recipe.transform((source/name).read_text())')
    text=once(text,"leaf/'current-u/ven_l1d.sv'","leaf/'ven_l1d.sv'")
    text=once(text,'changes = sorted(recipe.PARENTS)',"changes = ['rtl/mem/ven_l1d.sv']")
    text=once(text,"'tb_current_u_pair_'","'tb_backing_payload_mux_'")
    text=once(text,'Reject standalone/no-current-U sideband requests only in the core current-U client',
                   'Separate backing payload mux from late control; every output remains equivalent, including idle hints')
    ast.parse(text)
    return text


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',required=True,type=Path)
    root=parser.parse_args().out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    text=core_driver();driver=root.with_suffix('.driver.py')
    with driver.open('x') as f:f.write(text)
    paths=(Path(__file__),Path(recipe.__file__),HERE/'prepare_backing_pair_payload.py',
           HERE/'build_current_u_pair_core.py',driver)
    sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
    pins={str(p.resolve()):sha(p) for p in paths}
    with root.with_suffix('.inputs.json').open('x') as f:json.dump(pins,f,indent=2)
    child=subprocess.run(['/usr/bin/python3','-B',str(driver),'--out',str(root)],
        env=dict(os.environ,PYTHONPATH=str(HERE)),pass_fds=(9,),timeout=660)
    assert all(sha(p)==h for p,h in pins.items())
    return child.returncode


if __name__=='__main__':raise SystemExit(main())
