#!/usr/bin/env python3
"""Qualify a private QEMU preexit observer without changing the trace producer.

Compare complete prefix records against both the pinned oracle and a matched
rebuild. The only added record must come from a real gdb register read. The
separate raw-RSP witness also checks the unmodified native exit after resume.
"""
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import argparse
import hashlib
import itertools
import json
import os
import socket
import subprocess
import sys
import time

import gen_trace
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'diff'))
import tracefmt


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def port():
    with socket.socket() as server:
        server.bind(('127.0.0.1', 0))
        return server.getsockname()[1]


def dump(path, value):
    with Path(path).open('x') as stream:
        json.dump(value, stream, indent=2); stream.write('\n')


def set_mode(mode):
    os.environ['QEMU_CPU'] = 'pentium'
    if mode is None:
        os.environ.pop('VTM_QEMU_GDB_PREEXIT', None)
    else:
        os.environ['VTM_QEMU_GDB_PREEXIT'] = mode


def raw_witness(binary, elf, symbols, code, out):
    set_mode('1')
    address = port()
    command = [binary, '-g', str(address), '-one-insn-per-tb', str(elf)]
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    rsp = None
    try:
        rsp = gen_trace.RSPClient(port=address, timeout=10.0, verbose=False)
        rsp.handshake()
        layout = rsp.discover_layout()
        raw = rsp.read_g(); layout.anchor_tail(len(raw))
        for count in range(64):
            pc = gen_trace.regs_to_fields(layout, raw)[0]
            if pc == symbols['terminal']:
                break
            reply = gen_trace.StopReply(rsp.step())
            assert reply.kind not in ('exit','term'), (pc, reply.kind)
            raw = rsp.read_g()
        else:
            raise AssertionError('did not reach actual terminal instruction')
        before = raw
        reply_bytes = rsp.step()
        reply = gen_trace.StopReply(reply_bytes)
        assert reply.kind == 'stop' and reply.signal == 5, vars(reply)
        after = rsp.read_g()
        state = gen_trace.regs_to_fields(layout, after)
        assert state[0] == symbols['after_terminal'], hex(state[0])
        # Do not construct the post-state. Check the entire actual g-packet:
        # normal linux-user exit leaves everything except actual EIP unchanged.
        eip_offset = layout.offset['eip']
        assert before[:eip_offset] == after[:eip_offset]
        assert before[eip_offset+4:] == after[eip_offset+4:]
        exit_bytes = rsp.step()
        exit_reply = gen_trace.StopReply(exit_bytes)
        assert exit_reply.kind == 'exit' and exit_reply.exit_code == code
        stdout, stderr = proc.communicate(timeout=10)
        assert proc.returncode == code and stdout == b'PREEXIT\n' and not stderr
        result = dict(command=command, terminal_pc=symbols['terminal'],
            after_pc=state[0], before_raw=before.hex(), after_raw=after.hex(),
            eip_offset=eip_offset, stop_reply=reply_bytes.decode(),
            exit_reply=exit_bytes.decode(), native_exit=proc.returncode,
            stdout=stdout.decode(), full_non_eip_state_unchanged=True)
        dump(out, result)
        return result
    finally:
        if rsp is not None: rsp.close()
        gen_trace._terminate(proc)


def case(job):
    nr, code, fp, flags, options = job
    name = f'exit{nr}-code{code}-fp{fp}-flags{flags}'
    out = Path(options['out'])/name; out.mkdir()
    row = dict(name=name, passed=False, errors=[])
    try:
        obj = out/'fixture.o'; elf = out/'fixture.elf'
        assemble = ['as','--32','--defsym',f'EXIT_NR={nr}', '--defsym',f'EXIT_CODE={code}',
                    '--defsym',f'FP_VARIANT={fp}', '--defsym',f'FLAGS_VARIANT={flags}',
                    '-o',str(obj),options['fixture']]
        subprocess.run(assemble, check=True, capture_output=True, timeout=20)
        link = ['ld','-m','elf_i386','-Ttext=0x08048000','-o',str(elf),str(obj)]
        subprocess.run(link, check=True, capture_output=True, timeout=20)
        symbols = {line.split()[2]:int(line.split()[0],16) for line in
                   subprocess.check_output(['nm',str(elf)]).decode().splitlines()}
        traces = {}
        profiles = (('pinned',options['pinned'],None), ('control',options['control'],None),
                    ('observer_off',options['observer'],None),
                    ('observer_invalid',options['observer'],'yes'),
                    ('observer_on',options['observer'],'1'))
        for label, binary, mode in profiles:
            set_mode(mode)
            path = out/(label+'.vtrace')
            count, ending = gen_trace.generate(binary,str(elf),str(path),64,port(),[],
                                              True,None,True,False)
            assert ending is not None and ending.kind == 'exit' and ending.exit_code == code
            traces[label] = tracefmt.read_trace(str(path)).records
            assert len(traces[label]) == count
        reference = traces['pinned']
        for label in ('control','observer_off','observer_invalid'):
            assert traces[label] == reference, f'{label}: prefix/state differs from pinned oracle'
        observed = traces['observer_on']
        assert len(observed) == len(reference)+1
        assert observed[:-1] == reference, 'observer changed an earlier architectural record'
        final = observed[-1]
        assert int(final['pc'],16) == symbols['terminal'] and final['bytes'].startswith('cd80')
        for key, value in dict(eax=nr,ebx=code,ecx=0x12345678,edx=0x23456789,
                               esi=0x3456789a,edi=0x456789ab,ebp=0x56789abc,
                               esp=symbols['stack_top']).items():
            assert int(final[key],16) == value, (key, final[key], value)
        assert (int(final['eflags'],16) & 0x401) == (0x401 if flags else 0)
        # A count-limited run ending before exit must not gain a terminal record.
        capped = []
        for label,binary,mode in (profiles[0], profiles[-1]):
            set_mode(mode); path = out/(label+'-limited.vtrace')
            count, ending = gen_trace.generate(binary,str(elf),str(path),8,port(),[],
                                               True,None,True,False)
            assert count == 8 and ending is None
            capped.append(tracefmt.read_trace(str(path)).records)
        assert capped[0] == capped[1]
        native = []
        for label,binary,mode in (profiles[0], profiles[2], profiles[-1]):
            set_mode(mode)
            child = subprocess.run([binary,str(elf)],capture_output=True,timeout=10)
            assert child.returncode == code and child.stdout == b'PREEXIT\n' and not child.stderr
            native.append(dict(label=label,exit=child.returncode,stdout=child.stdout.decode()))
        witness = raw_witness(options['observer'],elf,symbols,code,out/'raw-rsp.json')
        row.update(passed=True,assemble=assemble,link=link,elf_sha256=sha(elf),
            counts={key:len(value) for key,value in traces.items()},native=native,
            real_exit_state_observed=True, native_exit=witness['native_exit'])
    except Exception as error:
        row['errors'].append(repr(error))
    dump(out/'closed.json', row)
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('pinned','control','observer','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=24)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 24: parser.error('jobs must be 1..24')
    args.out.mkdir()
    fixture = Path(__file__).with_name('preexit_fixture.S')
    pins = {str(p.resolve()):sha(p) for p in (args.pinned,args.control,args.observer,
             Path(__file__),fixture,Path(gen_trace.__file__),Path(tracefmt.__file__))}
    options = {key:str(getattr(args,key).resolve()) for key in ('pinned','control','observer','out')}
    options['fixture'] = str(fixture.resolve())
    dump(args.out/'started.json',dict(pins=pins,options=options,jobs=args.jobs,started=time.time()))
    jobs = [(*values,options) for values in itertools.product((1,252),(0,7,255),(0,1),(0,1))]
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        rows = list(pool.map(case,jobs))
    stable = all(sha(p)==value for p,value in pins.items())
    result = dict(passed=stable and all(row['passed'] for row in rows),pins_stable=stable,
                  rows=rows,finished=time.time(),architectural_comparator_changed=False)
    dump(args.out/'closed.json',result)
    print(json.dumps(dict(passed=result['passed'],cases=len(rows),
                          failures=[row for row in rows if not row['passed']]),indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__': sys.exit(main())
