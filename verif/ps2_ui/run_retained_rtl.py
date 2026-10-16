"""Exercise the retained host observer on actual frozen controller RTL."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


def sha(path):
    with Path(path).open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()


def once(text,old,new):
    assert text.count(old)==1,old
    return text.replace(old,new)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    out=parser.parse_args().out.absolute()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    assert out.parent.resolve(strict=True)==ROOT and not out.exists()
    assert sorted(os.sched_getaffinity(0))==[12,13]
    assert shutil.disk_usage(ROOT).free>4*1024**3
    group=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0<int((group/'memory.max').read_text())<=2*1024**3
    assert (group/'memory.swap.max').read_text().strip()=='0'
    assert 0<int((group/'pids.max').read_text())<=160
    inputs={n:HERE/n for n in ('ui_input_host.h','ui_ps2_probe.sv','test_ui_ps2.cpp','retained_native_body.inc')}
    inputs.update({n:ROOT/'ps2-loss-aux-extended-r2/source'/n for n in ('candidate.v','simple_fifo.v')})
    assert sha(inputs['candidate.v'])=='9c9d62149a25a5e3f97683ca269b77d01dcf4034517c02a225a5bce0bd2dc405'
    assert sha(inputs['simple_fifo.v'])=='aff3ebc275191351eb582f2624cb056712d392331a951f1ed778360ca81f3bf4'
    out.mkdir(); source=out/'source'; source.mkdir()
    pins={str(p):sha(p) for p in [*inputs.values(),Path(__file__).resolve(),REPO/'tools/verilator_serial.sh',REPO/'tools/build_scope.sh']}
    for name,path in inputs.items():
        shutil.copyfile(path,source/name); assert sha(source/name)==pins[str(path)]
        pins[str(source/name)]=sha(source/name)
    probe=(source/'ui_ps2_probe.sv').read_text()
    probe=once(probe,'    output wire synced_clock,',
        '    output wire rx_pending, scan_commit,\n    output wire [7:0] pending_value,\n    output wire synced_clock,')
    probe=once(probe,'    assign controller_state = dut.keyb_state;',
        '    assign rx_pending = dut.kb_rx_pending;\n    assign pending_value = dut.kb_rx_pending_data;\n'
        '    assign scan_commit = dut.kb_scan_commit;\n    assign controller_state = dut.keyb_state;')
    code=(source/'test_ui_ps2.cpp').read_text().split('static void ordinary_stream_tests() {')[0]
    assert code.count('class Harness {')==1 and code.rstrip().endswith('};')
    code=once(code,'        p.old_write_index=d.write_index;',
        '        p.retained_contract=true; p.scan_commit=d.scan_commit;\n'
        '        p.pending_before=d.rx_pending; p.pending_value_before=d.pending_value;\n'
        '        p.old_write_index=d.write_index;')
    code=once(code,'        p.escape_after=d.escape_state;',
        '        p.pending_after=d.rx_pending; p.pending_value_after=d.pending_value;\n'
        '        p.escape_after=d.escape_state;')
    code+=(source/'retained_native_body.inc').read_text()
    host=source/('retained_native_'+hashlib.sha256(code.encode()).hexdigest()[:12]+'.cpp')
    for path,text in ((source/'retained_probe.sv',probe),(host,code)):
        with path.open('x') as stream: stream.write(text)
        pins[str(path)]=sha(path)
    obj=out/'obj'; model=obj/'retained_native'
    command=[str(REPO/'tools/verilator_serial.sh'),'--cc','--exe','--build','-j','2','--assert',
        '-Wno-fatal','-Wno-UNUSED',*['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
        '--top-module','ui_ps2_probe','--Mdir',str(obj),'-o',model.name,
        '+define+VEN_KBC_FAST','+define+VEN_KBD_AUTOACK','-CFLAGS','-std=c++17 -O1',
        str(source/'candidate.v'),str(source/'simple_fifo.v'),str(source/'retained_probe.sv'),str(host)]
    def save(name,value):
        with (out/name).open('x') as stream: json.dump(value,stream,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],command=command,
        affinity=[12,13],full_pc=False,physical_fpga=False))
    started=time.monotonic(); result=dict(passed=False,errors=[],full_pc=False,physical_fpga=False,gameplay_ipc=None)
    try:
        with (out/'build.log').open('x') as stream:
            built=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,timeout=240)
        result['build_exit']=built.returncode; assert built.returncode==0,'build failed'
        local_obj=obj/(host.stem+'.o'); dep=obj/(host.stem+'.d')
        assert local_obj.is_file() and dep.is_file() and 'Vui_ps2_probe.h' in dep.read_text()
        assert str(host) in dep.read_text() and (obj/'Vui_ps2_probe.h').is_file()
        result['private_harness_object']=str(local_obj); result['binary_sha256']=sha(model)
        with (out/'native.log').open('x') as stream:
            child=subprocess.Popen([str(model)],stdout=stream,stderr=subprocess.STDOUT)
            assert sorted(os.sched_getaffinity(child.pid))==[12,13]
            try: code=child.wait(timeout=60)
            except BaseException:
                child.kill(); child.wait(); raise
        result['native_exit']=code
        assert code==0 and 'UI-RETAINED-RTL-OK ordinary=8 retained=4 collisions=2 flush_refusals=4 full_pc=0' in (out/'native.log').read_text()
        result['passed']=True
    except Exception as exc: result['errors'].append(repr(exc))
    result['pins_unchanged']=all(sha(p)==h for p,h in pins.items())
    result['memory_events']={k:int(v) for k,v in (s.split() for s in (group/'memory.events').read_text().splitlines())}
    result['passed']=result['passed'] and result['pins_unchanged'] and not any(result['memory_events'][k] for k in ('oom','oom_kill','oom_group_kill'))
    result['seconds']=time.monotonic()-started
    result['memory_peak']=int((group/'memory.peak').read_text())
    result['artifacts']={str(p):sha(p) for p in out.iterdir() if p.is_file() and p.suffix=='.log'}
    save('closed.json',result); print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
