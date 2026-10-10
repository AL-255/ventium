#!/usr/bin/env python3
"""Build ordinary BIOS-bootable CoreMark disks, without modifying algorithms.

--qemu-smoke executes ten-iteration correctness diagnostics on pinned QEMU.
It never calls a QEMU timer reading an FPGA score or performs board access.
Use an external TMPDIR and a bounded service (512 MiB, 180 seconds suffices).
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

PORT = Path(__file__).resolve().parent
REPO = PORT.parents[2]
REFS = REPO/'ventium-refs/07-p5-emulation-harness'
SOURCE = REFS/'benchmarks/src/coremark-eembc'
ALGORITHMS = ['core_main.c','core_list_join.c','core_matrix.c','core_state.c','core_util.c']
FLAGS = ['-O2','-m32','-march=pentium','-mtune=pentium','-mno-mmx','-mno-sse',
         '-mfpmath=387','-fcf-protection=none','-fno-stack-protector','-fno-pie',
         '-ffreestanding','-fno-asynchronous-unwind-tables']
CRCS = {'performance':['e9f5','e714','1fd7','8e3a','fcaf'],
        'validation':['18f2','e3c1','0747','8d84','c64e']}


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream: json.dump(value,stream,indent=2)


def command(argv, log, seconds=30, allowed=(0,)):
    with log.open('x') as stream:
        process=subprocess.Popen([str(x) for x in argv],stdout=stream,stderr=subprocess.STDOUT,
                                 start_new_session=True)
        try: status=process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            import signal
            os.killpg(process.pid,signal.SIGTERM)
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGKILL);process.wait()
            raise
    if status not in allowed: raise RuntimeError(f'native exit {status}: {argv}; see {log}')
    return dict(argv=[str(x) for x in argv],native_exit=status,log=str(log))


def smoke(qemu, disk, seed, work):
    debug=work/'qemu-debug.log'
    result=command([qemu,'-machine','pc','-accel','tcg','-cpu','pentium','-m','16',
        '-drive',f'file={disk},format=raw,if=ide','-boot','c','-display','none',
        '-serial','none','-monitor','none','-no-reboot','-no-shutdown',
        '-debugcon',f'file:{debug}','-global','isa-debugcon.iobase=0xe9',
        '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],work/'qemu.log',allowed=(33,))
    text=debug.read_text()
    found=[]
    for field in ('seedcrc','crclist','crcmatrix','crcstate','crcfinal'):
        matches=re.findall(r'^(?:\[0\])?'+field+r'\s*:\s*0x([0-9a-f]{4})$',text,re.M)
        assert len(matches)==1, (field,matches)
        found.append(matches[0])
    assert found==CRCS[seed],(seed,found)
    assert re.findall(r'^Iterations\s*:\s*(\d+)$',text,re.M)==['10']
    assert re.findall(r'^CoreMark Size\s*:\s*(\d+)$',text,re.M)==['666']
    errors=re.findall(r'^ERROR!.*$',text,re.M)
    assert errors==['ERROR! Must execute for at least 10 secs for a valid result!'],errors
    assert text.count('PORT-END\n')==1 and text.count('Errors detected\n')==1
    fields=re.findall(r'^PORT-TSC start=([0-9a-f]{8}):([0-9a-f]{8}) stop=([0-9a-f]{8}):([0-9a-f]{8})$',text,re.M)
    delta=re.findall(r'^PORT-TSC delta=([0-9a-f]{8}):([0-9a-f]{8})$',text,re.M)
    assert len(fields)==len(delta)==1
    a,b,c,d=map(lambda s:int(s,16),fields[0]);hi,lo=map(lambda s:int(s,16),delta[0])
    elapsed=(((c<<32)|d)-((a<<32)|b)) & ((1<<64)-1)
    assert elapsed==((hi<<32)|lo) and 0<elapsed<400000000
    result.update(crcs=found,correctness_pass=True,score_eligible=False,
        duration_error_retained=True,qemu_tsc_not_processor_cycles=True,
        standard_suite=False,physical_board=False)
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--iterations',type=int,default=10)
    parser.add_argument('--qemu-smoke',action='store_true')
    parser.add_argument('--cc',type=Path,default=Path('/usr/bin/x86_64-linux-gnu-gcc-13'))
    args=parser.parse_args()
    assert __debug__ and 1<=args.iterations<=100000
    assert not args.qemu_smoke or args.iterations==10
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert scratch.stat().st_dev!=REPO.stat().st_dev
    assert Path(os.environ['TMPDIR']).resolve(strict=True).is_relative_to(scratch)
    out=args.out.resolve();assert out.is_relative_to(scratch) and out!=scratch and not out.exists()
    assert shutil.disk_usage(scratch).free>128*1024**2
    cc=args.cc.resolve(strict=True)
    inputs=[SOURCE/n for n in [*ALGORITHMS,'coremark.h','LICENSE.md']]
    inputs += [SOURCE/'barebones/ee_printf.c',*sorted(PORT.glob('*.S')),
               PORT/'link.ld',PORT/'core_portme.h',PORT/'core_portme.c',Path(__file__),cc]
    qemu=REFS/'build/qemu/build-sys/qemu-system-i386'
    if args.qemu_smoke: inputs += [qemu,REFS/'build/qemu/pc-bios/bios-256k.bin']
    pins={str(p.resolve()):sha(p) for p in inputs}
    out.mkdir();src=out/'source';src.mkdir()
    for name in [*ALGORITHMS,'coremark.h','LICENSE.md']: shutil.copyfile(SOURCE/name,src/name)
    for name in ['core_portme.h','core_portme.c']: shutil.copyfile(PORT/name,src/name)
    for name in ['boot.S','start.S','link.ld','build.py']: shutil.copyfile(PORT/name,src/name)
    printf=(SOURCE/'barebones/ee_printf.c').read_text()
    pattern=r'void\nuart_send_char\(char c\)\n\{.*?\n\}\n\nint\nee_printf'
    printf,count=re.subn(pattern,'void uart_send_char(char c);\n\nint\nee_printf',printf,flags=re.S)
    assert count==1
    (src/'ee_printf.c').write_text(printf)
    pins.update({str(p):sha(p) for p in src.iterdir()})
    save(out/'started.json',dict(pins=pins,flags=FLAGS,iterations=args.iterations,compiler=str(cc),
        compiler_version=subprocess.check_output([str(cc),'-dumpfullversion'],text=True).strip(),
        algorithms_unmodified=True,printf_change='replace port UART stub with external declaration only',
        memory='stack; flat CPL0, no paging, interrupts disabled',clock_calibration_hz=40000000,
        performance_qualified=False,physical_board=False,gameplay_ipc=None))
    records=[];error=None;start=time.monotonic()
    try:
        for seed in ('performance','validation'):
            work=out/seed;work.mkdir();commands=[];objects=[]
            defs=[f'-DITERATIONS={args.iterations}','-DTOTAL_DATA_SIZE=2000',
                  '-D'+seed.upper()+'_RUN=1','-DFLAGS_STR="'+' '.join(FLAGS)+'"']
            for name in [*ALGORITHMS,'core_portme.c','ee_printf.c']:
                obj=work/(Path(name).stem+'.o');objects.append(obj)
                commands.append(command([cc,*FLAGS,*defs,'-I'+str(src),'-c',src/name,'-o',obj],work/(name+'.log')))
            obj=work/'start.o';objects.insert(0,obj)
            commands.append(command([cc,'-m32','-c',PORT/'start.S','-o',obj],work/'start.log'))
            elf=work/'coremark.elf';payload=work/'coremark.bin'
            commands.append(command(['ld','-m','elf_i386','-T',PORT/'link.ld','-o',elf,*objects],work/'link.log'))
            commands.append(command(['objcopy','-O','binary',elf,payload],work/'objcopy.log'))
            count=(payload.stat().st_size+511)//512;assert 0<count<=127
            commands.append(command([cc,'-m32',f'-DPAYLOAD_SECTORS={count}','-c',PORT/'boot.S',
                                     '-o',work/'boot.o'],work/'boot-compile.log'))
            commands.append(command(['ld','-m','elf_i386','-Ttext','0x7c00','--oformat','binary',
                                     work/'boot.o','-o',work/'boot.bin'],work/'boot-link.log'))
            boot=(work/'boot.bin').read_bytes();assert len(boot)==512 and boot[510:]==b'\x55\xaa'
            disk=work/'coremark.img'
            with disk.open('xb') as stream:
                stream.write(boot);stream.write(payload.read_bytes());stream.truncate(8*1024**2)
            record=dict(seed=seed,payload_sectors=count,commands=commands,
                        disk_sha256=sha(disk),elf_sha256=sha(elf),compiled=True)
            records.append(record)
            if args.qemu_smoke: record['qemu']=smoke(qemu,disk,seed,work)
    except Exception as exc: error=repr(exc)
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=error is None and stable and len(records)==2,records=records,error=error,
        source_pins_unchanged=stable,seconds=time.monotonic()-start,
        score_eligible=False,standard_suite=False,physical_board=False,gameplay_ipc=None)
    save(out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='records'}))
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
