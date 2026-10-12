"""Full P5 cache pair A/B plus explicit hint/intent arbitration microbenches."""
import argparse
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import time
import traceback

import prepare_pair_intent as recipe
import run_parallel_tag_pairs as pair
from run_parallel_tag_cache import archive_products, control_source, sha

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent


def fixture(flat):
    text = pair.fixture((HERE/'tb_l1d_pair_store.sv').read_text(), flat)
    # The control retains its old public interface. Both see identical
    # traffic until compare_parent becomes false for the new arbitration API.
    anchor = '  ven_l1d #(.L1_SETS(128)) dut ('
    text = recipe.replace(text, anchor, anchor+'\n      .c_pair_intent(c_pair_req || explicit_intent),')
    anchor = "  logic clk = 1'b0, rst_n = 1'b0;"
    text = recipe.replace(text, anchor, anchor+'''
  logic explicit_intent=0, next_hint=0, next_commit=0, compare_parent=1;
  logic [31:0] next_address=0;
''')
    assert text.count(".c_next_req(c_we), .c_next_commit(1'b1)") == 2
    text = text.replace(".c_next_req(c_we), .c_next_commit(1'b1)",
                        '.c_next_req(c_we || next_hint), .c_next_commit(next_commit)')
    assert text.count(".c_next_addr(c_addr ^ 32'h12345020)") == 2
    text = text.replace(".c_next_addr(c_addr ^ 32'h12345020)",
        ".c_next_addr(next_hint ? next_address : (c_addr ^ 32'h12345020))")
    # The parent's earlier backing-payload improvement only guarantees idle
    # payload identity when a transaction or blocked-pair hint is observable.
    # Both A/B instances here are already that exact parent: compare all ports.
    text = text.replace('if (dut.', 'if (compare_parent && dut.')
    text = recipe.replace(text, '    if (errors == 0) $display("L1D-PAIR-STORE-GATE-OK");',
        (HERE/'pair_intent_cases.svh').read_text()+'\n    if (errors == 0) $display("L1D-PAIR-STORE-GATE-OK");')
    text = recipe.replace(text, '    $finish;',
        '    if (errors != 0) $fatal(1,"PAIR-INTENT-GATE-FAIL");\n    $finish;')
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    parent, root = args.parent.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert root.is_relative_to(scratch) and not root.exists()
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(root.parent).free > 5*1024**3
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode == 1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    source = parent.read_text()
    changed = recipe.transform(source,'rtl/mem/ven_l1d.sv')
    root.mkdir()
    (root/'control_l1d.sv').write_text(control_source(source))
    (root/'ven_l1d.sv').write_text(changed)
    pins = {str(p):sha(p) for p in (parent,Path(__file__),Path(recipe.__file__),
        Path(pair.__file__),HERE/'run_parallel_tag_cache.py',HERE/'tb_l1d_pair_store.sv',
        HERE/'pair_intent_cases.svh',root/'control_l1d.sv',root/'ven_l1d.sv')}
    def save(name, data):
        with (root/name).open('x') as f: json.dump(data,f,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID']))
    begin = time.monotonic()
    result = dict(passed=False,rows=[],errors=[],whole_core=False,standard_suite=False,
                  hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    try:
        cases = [(f,w,False) for f in (False,True) for w in range(3)] + [(True,2,True)]
        for flat, windows, mutant in cases:
            assert shutil.disk_usage(root).free > 4*1024**3
            label = f'{"wrong" if mutant else "positive"}-lut{int(flat)}-windows{windows}'
            folder = root/label; folder.mkdir()
            actual = changed
            if mutant:
                assert actual.count('      !c_pair_intent &&') == 2
                actual = actual.replace('      !c_pair_intent &&', "      1'b1 &&")
            sv, tb = folder/'ven_l1d.sv',folder/'tb_l1d_pair_store.sv'
            sv.write_text(actual); tb.write_text(fixture(flat))
            pins.update({str(p):sha(p) for p in (sv,tb)})
            defs = pair.FLAGS + (['VEN_L1D_TAG_LUTRAM'] if flat else [])
            if windows: defs += ['VEN_L1D_WINDOW_REUSE','VEN_L1D_WINDOW_KEEP_STORE']
            if windows == 2: defs += ['VEN_L1D_TWO_WINDOW_REUSE','VEN_L1D_TWO_WINDOW_KEEP_STORE']
            command = [str(REPO/'tools/verilator_serial.sh'),'--binary','--timing','--assert','-sv',
                '--top-module','tb_l1d_pair_store','--Mdir',str(folder/'obj'),'-j','32',
                '--output-split','20000','--output-split-cfuncs','2000','-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+'+v for v in defs],str(root/'control_l1d.sv'),str(sv),str(tb)]
            row = dict(label=label,mutant=mutant,definitions=defs,command=command)
            result['rows'].append(row)
            with (folder/'build.log').open('x') as f:
                child = subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,
                    env=dict(os.environ,CCACHE_DISABLE='1'),pass_fds=(9,),timeout=180)
            row['build_exit'] = child.returncode
            assert child.returncode == 0, label
            binary = folder/'obj/Vtb_l1d_pair_store'
            with (folder/'run.log').open('x') as f:
                child = subprocess.run([binary],stdout=f,stderr=subprocess.STDOUT,timeout=30)
            log = (folder/'run.log').read_text()
            row.update(native_exit=child.returncode,binary_sha256=sha(binary),
                       build_log_sha256=sha(folder/'build.log'),log_sha256=sha(folder/'run.log'))
            if mutant:
                assert child.returncode != 0 and ('PAIR-READY-COFACTOR' in log or 'PAIR-INTENT' in log), log
            else:
                assert child.returncode == 0 and 'PAIR-INTENT-ARBITRATION-OK' in log, log
                assert 'L1D-PAIR-STORE-GATE-OK' in log and 'FAIL' not in log
                assert 'PARALLEL-PAIR-MITER checks=' in log
            row['compiler_archive'] = archive_products(folder,'tb_l1d_pair_store')
            save(label+'/closed.json',row)
            print(label,child.returncode,flush=True)
        result['passed'] = True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins=pins,
                  pins_unchanged=all(sha(p) == h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print({k:v for k,v in result.items() if k not in ('pins','rows')},flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
