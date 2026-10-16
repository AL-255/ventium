"""Build two small ordinary BIOS disks for external-input integration tests."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]


def sha(path):
    with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args();scratch=Path('/home/yukidama/external/tmp').resolve(strict=True);out=a.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>4*1024**3
    assert out!=scratch and out.is_relative_to(scratch) and not out.exists()
    cc=Path('/usr/bin/x86_64-linux-gnu-gcc-13');ld=Path('/usr/bin/ld')
    source=HERE/'pc_input_probe.S';boot=REPO/'verif/bench/coremark_boot/boot.S'
    pins={str(p.resolve()):sha(p) for p in (source,boot,Path(__file__),cc,ld)}
    out.mkdir();shutil.copyfile(source,out/source.name);shutil.copyfile(boot,out/'boot.S')
    rows=[]
    for raw in (0,1):
        work=out/f'raw{raw}';work.mkdir();commands=[]
        def run(argv):
            log=work/(str(len(commands))+'.log')
            with log.open('x') as f:
                p=subprocess.run([str(x) for x in argv],stdout=f,stderr=subprocess.STDOUT,timeout=20)
            commands.append(dict(argv=list(map(str,argv)),native_exit=p.returncode,log=str(log),log_sha256=sha(log)))
            assert p.returncode==0,log
        run([cc,'-m32',f'-DRAW_MODE={raw}','-c',out/source.name,'-o',work/'payload.o'])
        run([ld,'-m','elf_i386','-Ttext','0x10000','--oformat','binary',work/'payload.o','-o',work/'payload.bin'])
        sectors=(work/'payload.bin').stat().st_size//512+bool((work/'payload.bin').stat().st_size%512)
        assert 0<sectors<=127
        run([cc,'-m32',f'-DPAYLOAD_SECTORS={sectors}','-c',out/'boot.S','-o',work/'boot.o'])
        run([ld,'-m','elf_i386','-Ttext','0x7c00','--oformat','binary',work/'boot.o','-o',work/'boot.bin'])
        data=(work/'boot.bin').read_bytes();assert len(data)==512 and data[-2:]==b'\x55\xaa'
        image=work/'input.img'
        with image.open('xb') as f:
            f.write(data);f.write((work/'payload.bin').read_bytes());f.truncate(8*1024**2)
        rows.append(dict(raw=raw,commands=commands,image=str(image),sha256=sha(image),payload_sectors=sectors))
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(built=True,pins=pins,pins_unchanged=True,rows=rows,executed=False,
        ordinary_bios_boot=True,guest_specific_patch=False,standard_suite=False,gameplay_ipc=None)
    with (out/'built.json').open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}))


if __name__=='__main__':main()
