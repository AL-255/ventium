"""Bounded native SoftFloat A/B and exact-rounding tests; no guest/oracle change."""
import argparse
from fractions import Fraction
import hashlib
import json
from math import isqrt
import os
import random
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
import traceback

import prepare_round_increment as recipe

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'fp_shared/tb'))
from check_remaining_c1 import store_c1


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def exact_value(high,low):
    exp=high&0x7fff
    assert exp!=0x7fff
    power=max(exp,1)-16383-63
    result=Fraction(low << max(power,0),1 << max(-power,0))
    return -result if high&0x8000 else result


def arithmetic_event(value,precision,rc,sqrt=False):
    """Exact rational retained-bit decision, including 64-bit x80 and sqrt.

    No SoftFloat/host-float result or status packet contributes to this oracle.
    The sqrt decision compares the radicand to the square of the half-ULP
    boundary using integers. Masked x80 overflow is infinity or max finite.
    """
    assert precision in (24,53,64) and rc in range(4)
    if not value: return 0
    assert not sqrt or value>0
    n,d=abs(value).numerator,abs(value).denominator
    exponent=n.bit_length()-d.bit_length()
    if n << max(-exponent,0) < d << max(exponent,0): exponent-=1
    if sqrt: exponent//=2
    unit=max(exponent,-16382)-precision+1
    shift=unit*(2 if sqrt else 1)
    n <<= max(-shift,0); d <<= max(shift,0)
    q=isqrt(n//d) if sqrt else n//d
    discarded=n!=(q*q if sqrt else q)*d
    midpoint=(2*q+1)**2*d if sqrt else (2*q+1)*d
    scaled=n*(4 if sqrt else 2)
    away=(rc==1 and value<0) or (rc==2 and value>0)
    inc=int((rc==0 and (scaled>midpoint or (scaled==midpoint and q&1))) or (away and discarded))
    if exponent>16383 or (exponent==16383 and q+inc==1<<precision):
        return int(rc==0 or away)
    return inc


def cases():
    rows = []
    exponents = [0,1,2,*[16383+e for e in (-1076,-1075,-1074,-1023,-1022,
        -1021,-151,-150,-149,-127,-126,-125,-1,0,1,126,127,128,1022,1023,1024)],32765,32766]
    lows = {0x8000000000000000,0xffffffffffffffff}
    for p in (24,53):
        unit = 1 << (64-p); half = unit//2
        lows.update((1<<63)+n for n in (1,half-1,half,half+1,unit+half,2*unit+half))
    for kind,prec in ((0,0),(1,0),(2,0),(2,1),(2,2)):
        for rc in range(4):
            for sign in range(2):
                for exp in exponents:
                    for low in (sorted(lows) if exp else (0,1,2,3,(1<<62),(1<<63)-1)):
                        power = max(exp,1)-16383-63
                        value = Fraction(low << max(power,0), 1 << max(-power,0))
                        if sign: value = -value
                        fmt = (24,-126,127) if kind==0 else (53,-1022,1023)
                        if kind==2:
                            expected = 0 if prec==0 else store_c1(value,53 if prec==1 else 24,-16382,16383,rc)
                        else:
                            expected = store_c1(value,*fmt,rc)
                        rows.append(dict(args=(kind,prec,rc,exp|(sign<<15),low,0,0),expected=expected))
                # Nonfinite packs must not retain the deliberately poisoned event.
                for low in (1<<63,0xc000000000000001,0x8000000000000001):
                    rows.append(dict(args=(kind,prec,rc,0x7fff|(sign<<15),low,0,0),expected=0))
    one=(16383,1<<63)
    pairs=[(one,(16383+e,l)) for e in (-65,-64,-63,-53,-52,-24,-23,0,1)
           for l in (1<<63,3<<62,(1<<64)-1)]
    pairs += [(one,(16384,3<<62)),((16384,1<<63),(16384,3<<62)),
              ((32766,(1<<64)-1),(16384,1<<63)),
              ((1,1<<63),(16382,1<<63)),((0,1),(16382,1<<63)),
              ((0,(1<<63)-1),(16383,(1<<63)+1))]
    rng=random.Random(0xC180)
    for _ in range(64):
        pair=tuple((rng.choice((1,16283,16382,16383,16384,16483,32766)),
                    (1<<63)|rng.getrandbits(63)) for _ in range(2))
        pairs.append(pair)
    for kind in range(3,8):
        for prec,p in enumerate((64,53,24)):
            for rc in range(4):
                for a,b in pairs:
                    for signs in ((0,0),) if kind==7 else ((0,0),(0,1),(1,0),(1,1)):
                        aa=(a[0]|(signs[0]<<15),a[1]); bb=(b[0]|(signs[1]<<15),b[1])
                        av,bv=exact_value(*aa),exact_value(*bb)
                        value={3:lambda:av+bv,4:lambda:av-bv,5:lambda:av*bv,
                               6:lambda:av/bv,7:lambda:av}[kind]()
                        rows.append(dict(args=(kind,prec,rc,*aa,*bb),
                            expected=arithmetic_event(value,p,rc,kind==7)))
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True)
    ap.add_argument('--build',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args(); source=a.source.resolve(strict=True); build=a.build.resolve(strict=True)
    root=a.out.resolve(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>4*1024**3
    assert Path(os.environ['TMPDIR']).resolve()==scratch and os.sched_getaffinity(0)=={12}
    assert os.environ.get('INVOCATION_ID')
    root.mkdir()
    def save(name,obj):
        with (root/name).open('x') as f: json.dump(obj,f,indent=2)
    pins={}
    def pin(p):
        p=Path(p).resolve(strict=True)
        digest=sha(p)
        assert str(p) not in pins or pins[str(p)]==digest,('input changed',str(p))
        pins[str(p)]=digest
        return p
    originals={n:pin(source/n).read_text() for n in recipe.PARENTS}
    changed=recipe.transform(originals)
    commands=json.loads(pin(build/'compile_commands.json').read_text())
    command=next(shlex.split(r['command']) for r in commands
                 if r['file'].endswith('/fpu/softfloat.c') and
                 '-o libqemu-i386-linux-user.fa.p/fpu_softfloat.c.o ' in r['command'])
    assert command[0]=='cc' and command[-2:]==['-c','../observer-source/fpu/softfloat.c']
    # Preserve target configuration/includes, but use bounded O1 without debug
    # output and never write objects or dependency files into the frozen build.
    flags=[]; i=1
    while i<len(command)-2:
        token=command[i]
        if token in ('-MQ','-MF','-o'): i+=2; continue
        if token in ('-MD','-g','-O2'): i+=1; continue
        flags.append(token); i+=1
    flags += ['-O1','-g0']
    pin(shutil.which(command[0]))
    headers=sorted((source/'include/fpu').glob('*.h'))
    pieces=[source/'fpu'/n for n in ('softfloat.c','softfloat-parts.c.inc',
                                  'softfloat-parts-addsub.c.inc','softfloat-specialize.c.inc')]
    for p in (*headers,*pieces,Path(__file__),Path(recipe.__file__),
              Path(__file__).with_name('round_increment_probe.c'),REPO/'fp_shared/tb/check_remaining_c1.py',
              REPO/'fp_shared/tb/check_preexit_c1_native.py',REPO/'fp_shared/tb/run_srt_c1_observe.py'):
        pin(p)
    # Keep the exact tested harness/recipe/oracle inputs, even after subsequent
    # repository edits. This is evidence, not an alternate imported oracle.
    archive=root/'driver-inputs'; archive.mkdir()
    for p in (Path(__file__),Path(recipe.__file__),
              Path(__file__).with_name('round_increment_probe.c'),
              REPO/'fp_shared/tb/check_remaining_c1.py',REPO/'fp_shared/tb/check_preexit_c1_native.py',
              REPO/'fp_shared/tb/run_srt_c1_observe.py'):
        shutil.copyfile(p,archive/p.name)
        assert sha(archive/p.name)==pins[str(p.resolve())]
        pin(archive/p.name)
    rows=cases()
    data=''.join(f'{k} {p} {r} {h:x} {l:x} {bh:x} {bl:x}\n'
                 for row in rows for k,p,r,h,l,bh,bl in [row['args']])
    save('cases.json',rows)
    variants={}
    for label in ('control','candidate','nonzero-inc','missing-reset'):
        work=root/label; (work/'include/fpu').mkdir(parents=True); (work/'fpu').mkdir()
        for p in (*headers,*pieces):
            rel=str(p.relative_to(source)); text=changed.get(rel,p.read_text()) if label!='control' else p.read_text()
            if label=='nonzero-inc' and rel=='fpu/softfloat-parts.c.inc':
                text=recipe.change(text,'inc > round_mask - (p->frac_lo & round_mask)','inc != 0',3)
            if label=='missing-reset' and rel in ('fpu/softfloat-parts.c.inc','fpu/softfloat.c'):
                text=recipe.change(text,'    s->float_round_increment = false;\n','',
                                   text.count('    s->float_round_increment = false;\n'))
            (work/rel).write_text(text); pin(work/rel)
        shutil.copyfile(Path(__file__).with_name('round_increment_probe.c'),work/'probe.c'); pin(work/'probe.c')
        variants[label]=work
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],cases=len(rows),
        affinity=sorted(os.sched_getaffinity(0)),canonical_oracle_changed=False,architectural_c1=False))
    start=time.monotonic(); result=dict(passed=False,errors=[],rows=[],gameplay_ipc=None,
        standard_suite=False,hardware_acceptance=False,architectural_c1=False,canonical_gate=False)
    controls=None
    try:
        for label,work in variants.items():
            local=['-iquote',str(work/'include'),*flags]
            if label!='control': local+=['-DVTM_ROUND_EVENT']
            def execute(phase,cmd):
                save(label+'-'+phase+'-command.json',cmd)
                with (work/(phase+'.log')).open('x') as log:
                    done=subprocess.run(cmd,cwd=build,stdout=log,stderr=subprocess.STDOUT,timeout=120)
                assert done.returncode==0,(label,phase,done.returncode)
            def dependencies(path):
                names=shlex.split(path.read_text().replace('\\\n',' '))[1:]
                return {(Path(p) if Path(p).is_absolute() else build/p).resolve(strict=True) for p in names}
            # Discover and hash the actual transitive headers BEFORE compilation,
            # then require the compiler's own dependency lists to match exactly.
            before={}
            for name,src in (('softfloat',work/'fpu/softfloat.c'),('probe',work/'probe.c')):
                dep=work/(name+'-pre.d')
                execute(name+'-dependencies',['cc',*local,'-M','-MF',str(dep),'-MT',name,str(src)])
                before[name]=dependencies(dep)
                for p in before[name]: pin(p)
            save(label+'-compile-inputs.json',dict(pins=pins))
            assert all(sha(p)==h for p,h in pins.items()),'input drift before compiler'
            for name,src in (('softfloat',work/'fpu/softfloat.c'),('probe',work/'probe.c')):
                execute(name+'-compile',['cc',*local,'-MD','-MF',str(work/(name+'.d')),
                    '-c',str(src),'-o',str(work/(name+'.o'))])
                assert dependencies(work/(name+'.d'))==before[name],('dependency drift',label,name)
            execute('link',['cc',str(work/'probe.o'),str(work/'softfloat.o'),
                '-lglib-2.0','-lm','-o',str(work/'probe')])
            assert all(sha(p)==h for p,h in pins.items()),'input drift after compiler'
            deps=before['softfloat']
            assert work/'include/fpu/softfloat-types.h' in deps and work/'fpu/softfloat-parts.c.inc' in deps
            ran=subprocess.run([str(work/'probe')],input=data,capture_output=True,text=True,timeout=60)
            (work/'stdout').write_text(ran.stdout); (work/'stderr').write_text(ran.stderr)
            assert ran.returncode==0 and not ran.stderr
            values=[tuple(int(v,16) for v in line.split()[:3])+(int(line.split()[3]),) for line in ran.stdout.splitlines()]
            assert len(values)==len(rows)
            if label=='control': controls=[v[:3] for v in values]
            assert [v[:3] for v in values]==controls,'numeric value/exception drift'
            errors=[i for i,(r,v) in enumerate(zip(rows,values)) if v[3]!=r['expected']]
            if label=='candidate': assert not errors,errors[:20]
            if label in ('nonzero-inc','missing-reset'): assert errors,'mutant escaped'
            result['rows'].append(dict(label=label,native_exit=0,records=len(values),
                values_and_exceptions_equal=True,event_mismatches=len(errors),first_event_mismatches=errors[:10],
                binary_sha256=sha(work/'probe'),stdout_sha256=sha(work/'stdout')))
        result['passed']=True
    except Exception as e:
        result['errors'].append(dict(error=repr(e),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-start,pins=pins,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print({k:v for k,v in result.items() if k!='pins'},flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
