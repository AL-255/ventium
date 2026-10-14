"""Native next-line lookup equations, arbitrary writable two-way tag arrays.

Not a cache-FSM test or FPGA qualification. The common stimulus is source
pinned; next-line addresses include 32-bit wrap and set/tag boundaries.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import prepare_parallel_next_tag as recipe
import run_parallel_tag_lookup as fixture

REPO = Path(__file__).resolve().parents[2]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    source, out = args.source.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert os.sched_getaffinity(0) == {12}
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    unit = os.environ['VENTIUM_BUILD_SCOPE_UNIT']+'.scope'
    subprocess.run(['systemctl', '--user', 'set-property', '--runtime', unit,
                    'MemoryMax=2G', 'MemorySwapMax=0'], check=True)
    old = source.read_text()
    new = recipe.transform(old)
    wrapper = fixture.WRAPPER.replace('set_c', 'set_n').replace('tag_c', 'tag_n')
    wrapper = wrapper.replace('wire hit0,hit1,hit,hit_way;',
                              'wire [31:0] addr_n;\n  wire hit_n0,hit_n1,hit_n,hit_way_n;')
    wrapper = wrapper.replace('{hit_way,hit,hit1,hit0}', '{hit_way_n,hit_n,hit_n1,hit_n0}')
    tb = fixture.TB.replace('c_addr=a; c_next_addr=b;',
                            "c_addr=a-32'd32; c_next_addr=b-32'd32;")
    anchor = '      put(integer\'(a[5+:IDXW]),0,'
    assert tb.count(anchor) == 1
    tb = tb.replace(anchor, "      if ((k&7)==3) a=32'h00000000;\n"
                    "      if ((k&7)==4) a=32'(L1_SETS)<<5;\n"+anchor)
    assert 'c_addr=a;' not in tb and 'wire hit0' not in wrapper
    variants = {'positive': new,
        'reversed-owner': new.replace('mc_lookup_next ? tag_prime_next_hit[0] : tag_current_next_hit[0]',
                                      'mc_lookup_next ? tag_current_next_hit[0] : tag_prime_next_hit[0]'),
        'wrong-way': new.replace('mc_lookup_next ? tag_prime_next_hit[1] : tag_current_next_hit[1]',
                                'mc_lookup_next ? tag_prime_next_hit[0] : tag_current_next_hit[1]'),
        'wrong-stride': new.replace("tag_current_next_addr = c_addr + 32'd32;",
                                   "tag_current_next_addr = c_addr + 32'd16;")}
    assert len(set(variants.values())) == len(variants)
    out.mkdir()
    pins = {str(p.resolve()): fixture.sha(p) for p in (source, Path(__file__), Path(recipe.__file__),
        Path(fixture.__file__), Path(__file__).with_name('test_parallel_next_tag.py'),
        REPO/'tools/build_scope.sh', Path('/usr/bin/iverilog').resolve(), Path('/usr/bin/vvp').resolve())}
    def save(name, value):
        with (out/name).open('x') as stream:
            json.dump(value, stream, indent=2)
    (out/'proposal.sv').write_text(new)
    pins[str(out/'proposal.sv')] = fixture.sha(out/'proposal.sv')
    for label, content in variants.items():
        text = ''.join('module '+name+wrapper+recipe.lookup_block(body)+'endmodule\n'
                       for name, body in (('old_lookup',old),('new_lookup',content)))+tb
        path = out/(label+'.sv')
        path.write_text(text)
        pins[str(path)] = fixture.sha(path)
    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        scope=unit, controller_affinity=[12], whole_cache=False, gameplay_ipc=None))
    begin = time.monotonic()
    result = dict(passed=False, rows=[], error=None, whole_cache=False, timing_mhz=None,
                  gameplay_ipc=None, standard_suite=False, hardware_acceptance=False)
    try:
        for label in variants:
            for sets in (2,64,128,256) if label=='positive' else (128,):
                for flat in (False,True):
                    for chain in (False,True) if label=='positive' else (True,):
                        name=f'{label}-s{sets}-lut{int(flat)}-chain{int(chain)}'
                        binary=out/(name+'.vvp')
                        cmd=['/usr/bin/iverilog','-g2012','-s','tb',f'-DTEST_SETS={sets}',
                             *(['-DVEN_L1D_TAG_LUTRAM'] if flat else []),
                             *(['-DVEN_PIPE_MEM_CHAIN'] if chain else []),
                             '-o',str(binary),str(out/(label+'.sv'))]
                        save(name+'.command.json',cmd)
                        row=dict(name=name)
                        result['rows'].append(row)
                        for phase, command in (('build',cmd),('run',['/usr/bin/vvp',str(binary)])):
                            log=out/(name+'-'+phase+'.log')
                            with log.open('x') as stream:
                                run=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,timeout=20)
                            row[phase+'_exit']=run.returncode
                            pins[str(log)]=fixture.sha(log)
                            assert run.returncode == (1 if label!='positive' and phase=='run' else 0), row
                            if phase=='run':
                                expected='PARALLEL-TAG-LOOKUP-OK samples=16384 ' if label=='positive' else 'TAG_LOOKUP_MISMATCH'
                                assert expected in log.read_text(),row
                        pins[str(binary)]=fixture.sha(binary)
        result['passed']=True
    except Exception as exc:
        result['error']=repr(exc)
    result.update(seconds=time.monotonic()-begin,pins=pins,
                  pins_unchanged=all(fixture.sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
