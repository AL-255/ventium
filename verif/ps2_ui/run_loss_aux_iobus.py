"""Bounded Icarus check of current AUX + loss/resync proposal on real iobus.

This is an isolated peripheral check, not a full-PC or physical-board pass.
No source in the running Vivado export is modified; no Verilator/CAD launched.
"""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import prepare_loss_aux as recipe

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
SOURCE = ROOT/'v-result-carry-posted-mouse-fpga-r1'
HERE = Path(__file__).resolve().parent


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.absolute()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    assert out.parent.resolve(strict=True) == ROOT and not out.exists()
    assert shutil.disk_usage(ROOT).free > 4*1024**3
    assert sorted(os.sched_getaffinity(0)) == [13]
    invocation = os.environ['INVOCATION_ID']
    group = Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0 < int((group/'memory.max').read_text()) <= 512*1024**2
    assert (group/'memory.swap.max').read_text().strip() == '0'
    assert 0 < int((group/'pids.max').read_text()) <= 32
    files = {
        'parent.v': SOURCE/'ventium/3rd-party/ao486_MiSTer/rtl/soc/ps2.v',
        'iobus.v': SOURCE/'ventium/3rd-party/ao486_MiSTer/rtl/soc/iobus.v',
        'simple_fifo.v': SOURCE/'ventium/3rd-party/ao486_MiSTer/rtl/common/simple_fifo.v',
        'tb_loss_aux_iobus.sv': HERE/'tb_loss_aux_iobus.sv',
        'prepare_loss_aux.py': Path(recipe.__file__).resolve(),
        'run_loss_aux_iobus.py': Path(__file__).resolve(),
        **{name: HERE/'proposals'/name for name in recipe.PATCHES},
    }
    assert sha(files['parent.v']) == recipe.PARENT
    assert sha(files['iobus.v']) == '59a36814438e730af6bb036e1906278a04bcfea7c4aaea4f4878ed341f82e92d'
    assert sha(files['simple_fifo.v']) == 'aff3ebc275191351eb582f2624cb056712d392331a951f1ed778360ca81f3bf4'
    tools = {name: Path(shutil.which(name)).resolve(strict=True) for name in ('iverilog','vvp')}
    pins = {str(path): sha(path) for path in list(files.values())+list(tools.values())}
    out.mkdir(); source = out/'source'; source.mkdir()
    for name,path in files.items():
        shutil.copyfile(path,source/name); assert sha(source/name) == pins[str(path)]
        pins[str(source/name)] = sha(source/name)
    candidate = recipe.transform((source/'parent.v').read_text())
    with (source/'candidate.v').open('x') as stream: stream.write(candidate)
    pins[str(source/'candidate.v')] = sha(source/'candidate.v')
    definitions = ['VEN_KBC_FAST','VEN_KBD_AUTOACK']
    hardware_defs = (SOURCE/'defines.txt').read_text().splitlines()
    assert all(d in hardware_defs for d in definitions)
    pins[str(SOURCE/'defines.txt')] = sha(SOURCE/'defines.txt')
    # These are all conditional options used by this exact controller.
    import re
    assert set(re.findall(r'^`ifdef (\w+)',candidate,re.M)) == set(definitions)
    cases = [(s,h,w,t) for s in range(3) for h in ((64,1667) if s==0 else (64,))
             for w,t in itertools.product((0,7),(0,1))]
    def save(name,data):
        with (out/name).open('x') as stream: json.dump(data,stream,indent=2)
    save('started.json',dict(pins=pins,invocation=invocation,affinity=[13],definitions=definitions,
         cases=cases,candidate_sha256=sha(source/'candidate.v'),time=time.time()))
    result=dict(passed=False,rows=[],builds=[],errors=[],pins_unchanged=False,
                full_pc=False,physical_board=False,standard_suite=False,gameplay_ipc=None)
    start=time.monotonic()
    try:
        for label in ('parent','candidate'):
            image=out/(label+'.vvp')
            command=[str(tools['iverilog']),'-g2012','-Wall','-s','tb_loss_aux_iobus',
                     *['-D'+d for d in definitions],'-o',str(image),str(source/(label+'.v')),
                     *[str(source/n) for n in ('simple_fifo.v','iobus.v','tb_loss_aux_iobus.sv')]]
            with (out/(label+'-compile.log')).open('x') as log:
                native=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=30)
            result['builds'].append(dict(command=command,native_exit=native.returncode))
            assert native.returncode==0, label+' compile failed'
            for number,(scenario,half,wait,translated) in enumerate(cases):
                assert time.monotonic()-start<240
                assert shutil.disk_usage(ROOT).free>4*1024**3
                command=[str(tools['vvp']),str(image),f'+scenario={scenario}',f'+half={half}',
                         f'+wait={wait}',f'+translate={translated}']
                logfile=out/f'{label}-{number:02d}.log'
                with logfile.open('x') as log:
                    native=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=12)
                text=logfile.read_text()
                expected='pass' if label=='candidate' else 'loss_witness'
                good=(native.returncode==0 and 'LOSS-AUX-IOBUS-OK ' in text) if label=='candidate' else (
                    native.returncode==1 and ('LOSS-AUX-BYTE got=fa' in text if scenario==0 else
                                             'LOSS-AUX-FULL-ACK-LOST' in text))
                if scenario==0: good=good and 'LOSS-AUX-COLLISION cycle=' in text
                row=dict(label=label,case=[scenario,half,wait,translated],command=command,
                         native_exit=native.returncode,expected=expected,passed=good,
                         log=str(logfile),sha256=sha(logfile))
                result['rows'].append(row)
                if not good: result['errors'].append(f'{label}-{number:02d}')
                print(json.dumps({k:v for k,v in row.items() if k not in ('command','log','sha256')}),flush=True)
        result['passed']=not result['errors'] and len(result['rows'])==32
    except Exception as exc:
        result['errors'].append(repr(exc))
    result['pins_unchanged']=all(sha(p)==h for p,h in pins.items())
    result['passed']=result['passed'] and result['pins_unchanged']
    result['seconds']=time.monotonic()-start
    result['memory_peak']=int((group/'memory.peak').read_text())
    result['memory_events']={k:int(v) for k,v in (s.split() for s in (group/'memory.events').read_text().splitlines())}
    result['passed']=result['passed'] and not any(result['memory_events'][k] for k in ('oom','oom_kill','oom_group_kill'))
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','builds')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
