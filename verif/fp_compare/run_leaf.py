"""Native source-extracted compare/status equivalence, including negative controls."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import subprocess
import time

import prepare

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
MODEL='97b11f3b4ebc54524dfe3da08fa49e42ea829d90c68481c1e029b3a5d32fcc0e'
WRAPPER='''
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;
  import ventium_decode_pkg::*;
(
  input logic [79:0] st0_data, sti_data, cmd_mem,
  input logic [15:0] fstat_o,
  input logic [3:0] cmd_mem_bytes,
  input fxop_e cmd_op,
  output logic [15:0] cmp_status,
  output logic [79:0] cmp_b
);
  logic cmp_signaling;
  wire st0_empty=1'b0;
  logic [3:0] xam_codes;
'''


def sha(path):
    with Path(path).open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()


def load(path): return json.loads(path.read_text())


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args(); parent=args.parent.resolve(strict=True); root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3
    assert os.sched_getaffinity(0)==set(range(12,20))
    assert os.environ['VENTIUM_VERILATOR_BIN']=='/tools/verilator/v5.046/bin/verilator'
    assert Path('/proc/self/cgroup').read_text().strip().endswith('/ventium-ipc-parallel32.scope')
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True,timeout=10)
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    started,closed=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit']==0
    assert sha(parent/'obj/tb_ventium')==closed['binary_sha256']==MODEL
    source=parent/'candidate'
    inputs=sorted(p for p in source.rglob('*') if p.is_file())
    assert len(inputs)==195 and all(sha(p)==started['pins'][str(p)] for p in inputs)
    definitions=started['definitions']; assert len(set(definitions))==len(definitions)==152
    old=(source/'fp_shared/ven_fp_top.sv').read_text(); new=prepare.transform(old)
    variants={'positive':new,
        'lost-signaling-nan':new.replace('(|memory[22:0])','memory[22]'),
        'integer-nan':new.replace('FX_FICOM_M16, FX_FICOM_M32, FX_FTST:\n        return fx_is_nan(a);',
            'FX_FICOM_M16, FX_FICOM_M32, FX_FTST:\n        return fx_is_nan(a) || memory_nan;'),
        'quiet-nan-signals':new.replace('return fx_is_snan(a) || fx_is_snan(sti);',
                                      'return fx_is_nan(a) || fx_is_nan(sti);'),
        'lost-m80-default':new.replace('default: memory_nan = fx_is_nan(memory);',
                                      "default: memory_nan = 1'b0;")}
    assert len(set(variants.values()))==5
    pins={str(p):sha(p) for p in (*inputs,Path(__file__),Path(prepare.__file__).resolve(),
        HERE/'test_prepare.py',HERE/'tb_classifier.sv',parent/'build-started.json',
        parent/'build-closed.json',parent/'obj/tb_ventium',REPO/'tools/build_scope.sh',
        REPO/'tools/verilator_serial.sh',Path(os.environ['VENTIUM_VERILATOR_BIN']))}
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as stream: json.dump(value,stream,indent=2)
    (root/'proposal.sv').write_text(new);pins[str(root/'proposal.sv')]=sha(root/'proposal.sv')
    save('started.json',dict(pins=pins,definitions=definitions,invocation=os.environ['INVOCATION_ID'],
        parent=str(parent),affinity=sorted(os.sched_getaffinity(0)),whole_core=False))
    result=dict(passed=False,rows=[],error=None,whole_core=False,gameplay_ipc=None,
        timing_mhz=None,canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False)
    began=time.monotonic()
    try:
        for label,body in variants.items():
            assert shutil.disk_usage(scratch).free>4*1024**3+256*1024**2
            folder=root/label;folder.mkdir()
            function=body[body.index('  function automatic logic compare_invalid('):body.index(prepare.ANCHOR)]
            text='module old_compare'+WRAPPER+prepare.compare_block(old)+'endmodule\n'
            text+='module new_compare'+WRAPPER+function+prepare.compare_block(body)+'endmodule\n'
            (folder/'compare.sv').write_text(text)
            command=[REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-sv',
                '-j','32','--verilate-jobs','1','--output-split','10000','--output-split-cfuncs','500',
                '-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+v for v in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+'+v for v in definitions],'-f',source/'rtl_ven_core.f',folder/'compare.sv',
                HERE/'tb_classifier.sv','--top-module','tb_classifier','--Mdir',folder/'obj','-o','test']
            row=dict(name=label,command=list(map(str,command)));result['rows'].append(row)
            with (folder/'build.log').open('x') as stream:
                native=subprocess.run(command,cwd=source,stdout=stream,stderr=subprocess.STDOUT,
                    pass_fds=(9,),timeout=120)
            row['build_exit']=native.returncode;assert native.returncode==0
            cmd=['taskset','-c','12',str(folder/'obj/test')]
            with (folder/'run.log').open('x') as stream:
                child=subprocess.Popen(cmd,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
                limit=time.monotonic()+30;observed=False
                try:
                    while child.poll() is None:
                        if time.monotonic()>limit:raise subprocess.TimeoutExpired(cmd,30)
                        try:
                            if Path('/proc',str(child.pid),'exe').resolve(strict=True)==folder/'obj/test':
                                assert os.sched_getaffinity(child.pid)=={12};observed=True
                        except (FileNotFoundError,ProcessLookupError):pass
                        time.sleep(.001)
                    code=child.wait()
                except BaseException:
                    os.killpg(child.pid,signal.SIGKILL);child.wait();raise
            row.update(native_exit=code,actual_wait=True,affinity_observed=observed,
                       native_pid=child.pid,native_command=cmd)
            log=(folder/'run.log').read_text()
            if label=='positive':
                assert code==0 and observed and not re.search(r'%Error|%Fatal|MISMATCH|VACUOUS',log)
                match=re.search(r'FP-COMPARE-OK checks=(\d+) memory_nan=(\d+) quiet_nan=(\d+) finite_integer=(\d+)',log)
                assert match and int(match[1])==425984 and all(int(v)>0 for v in match.groups()[1:])
                row['coverage']=dict(zip(('checks','memory_nan','quiet_nan','finite_integer'),map(int,match.groups())))
            else:assert code in (1,134,-6) and 'FP-COMPARE-MISMATCH' in log
            row['artifacts']={str(p):sha(p) for p in (folder/'compare.sv',folder/'build.log',folder/'run.log',folder/'obj/test')}
            print(json.dumps({k:v for k,v in row.items() if k not in ('command','artifacts')}),flush=True)
        result['passed']=True
    except Exception as exc:result['error']=repr(exc)
    cg=Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().split('::',1)[1].strip().lstrip('/')
    events=dict(line.split() for line in (cg/'memory.events').read_text().splitlines())
    result.update(seconds=time.monotonic()-began,pins_unchanged=all(sha(p)==h for p,h in pins.items()),
        memory_events=events,memory_peak=int((cg/'memory.peak').read_text()),
        swap=int((cg/'memory.swap.current').read_text()))
    result['passed'] &= result['pins_unchanged'] and all(events[k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    return int(not result['passed'])


if __name__=='__main__':raise SystemExit(main())
