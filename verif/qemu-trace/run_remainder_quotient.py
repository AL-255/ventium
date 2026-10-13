"""Bounded private SoftFloat quotient tests; no canonical QEMU replacement."""
import argparse
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import random
import shlex
import shutil
import subprocess
import time
import traceback

import prepare_remainder_quotient as recipe

REPO = Path(__file__).resolve().parents[2]
MASK = (1 << 64) - 1


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def value(high, low):
    exponent = high & 0x7fff
    assert exponent != 0x7fff
    shift = max(exponent, 1) - 16383 - 63
    v = Fraction(low << max(shift, 0), 1 << max(-shift, 0))
    return -v if high & 0x8000 else v


def quotient(a, b, mod):
    """Integer quotient magnitude, independent of SoftFloat/RTL outputs."""
    ratio = abs(a / b)
    q, r = divmod(ratio.numerator, ratio.denominator)
    if not mod and (2*r > ratio.denominator or (2*r == ratio.denominator and q & 1)):
        q += 1
    return q & MASK


def cases():
    one = (16383, 1 << 63)
    pairs = []
    # +/- half, one-and-a-half, two-and-a-half: nearest-even quotient parity;
    # plus immediate x80 neighbours and each exponent-difference boundary.
    for exponent in (-2, -1, 0, 1, 2, 62, 63, 64, 65, 125, 126, 127, 128, 1024):
        for low in (1 << 63, (1 << 63)+1, 5 << 61, 3 << 62, (3 << 62)+1, MASK):
            pairs.append(((16383+exponent, low), one))
    # Smallest subnormal, normal/subnormal boundary, and quotient low-bit wrap.
    pairs += [((0, 1), (0, 2)), ((0, 3), (0, 2)), ((0, 5), (0, 2)),
              ((1, 1 << 63), (0, 3)), ((0, (1 << 63)-1), (1, 1 << 63)),
              ((16446, MASK), one), ((32766, MASK), (0, 3))]
    rng = random.Random(0xF9E1)
    for _ in range(64):
        exponent = rng.choice((1, 16320, 16382, 16383, 16384, 16446, 32700))
        difference = rng.choice((-2, -1, 0, 1, 62, 63, 64, 65))
        other = min(32766, max(1, exponent-difference))
        pairs.append(((exponent, (1 << 63)|rng.getrandbits(63)),
                      (other, (1 << 63)|rng.getrandbits(63))))
    rows = []
    for mod in (0, 1):
        for prec in range(3):
            for rc in range(4):
                for a, b in pairs:
                    expected = quotient(value(*a), value(*b), mod)
                    for sa, sb in ((0,0), (0,1), (1,0), (1,1)):
                        rows.append(dict(args=(mod,prec,rc,a[0]|(sa<<15),a[1],b[0]|(sb<<15),b[1]),
                                         expected_quotient=expected))
                # Poison-output reset for zero, Inf, NaN, invalid x80 encodings.
                special = [(0,0), (0x8000,0), (0x7fff,1<<63),
                           (0x7fff,0xc000000000000001), (0x7fff,0x8000000000000001),
                           (16383,1)]
                for a, b in [(x,one) for x in special]+[(one,x) for x in special]:
                    rows.append(dict(args=(mod,prec,rc,*a,*b), expected_quotient=0))
    # Shared binary32/64/128 callers must retain nearest, not silently become mod.
    for kind, ebits, mbits in ((2,8,23), (3,11,52), (4,15,112)):
        bits = 1 + ebits + mbits
        bias = (1 << (ebits-1))-1
        raws = [0,1, (1<<mbits)-1, 1<<mbits, bias<<mbits,
                ((bias+1)<<mbits)|(1<<(mbits-1)),
                ((1<<ebits)-1)<<mbits, (((1<<ebits)-1)<<mbits)|1]
        pairbits = [(a,b) for a in raws for b in raws]
        pairbits += [(rng.getrandbits(bits),rng.getrandbits(bits)) for _ in range(256)]
        for rc in range(4):
            for a,b in pairbits:
                rows.append(dict(args=(kind,0,rc,a>>64,a&MASK,b>>64,b&MASK),
                                 expected_quotient=MASK))
    return rows


def parse(text):
    result = []
    for line in text.splitlines():
        fields = line.split()
        assert len(fields) == 4
        result.append(tuple(int(v,16) for v in fields))
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--build', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    source, build = a.source.resolve(strict=True), a.build.resolve(strict=True)
    root = a.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 4*1024**3
    assert Path(os.environ['TMPDIR']).resolve() == scratch and os.sched_getaffinity(0) == {13}
    assert os.environ.get('INVOCATION_ID')
    root.mkdir()
    def save(name, obj):
        with (root/name).open('x') as f:
            json.dump(obj, f, indent=2)
    pins = {}
    def pin(p):
        p = Path(p).resolve(strict=True)
        digest = sha(p)
        assert str(p) not in pins or pins[str(p)] == digest
        pins[str(p)] = digest
        return p
    originals = {n:pin(source/n).read_text() for n in recipe.PARENTS}
    changed = recipe.transform(originals)
    commands = json.loads(pin(build/'compile_commands.json').read_text())
    command = next(shlex.split(r['command']) for r in commands
                   if r['file'].endswith('/fpu/softfloat.c') and
                   '-o libqemu-i386-linux-user.fa.p/fpu_softfloat.c.o ' in r['command'])
    assert command[0] == 'cc' and command[-2:] == ['-c','../observer-source/fpu/softfloat.c']
    flags = []
    i = 1
    while i < len(command)-2:
        token = command[i]
        if token in ('-MQ','-MF','-o'):
            i += 2
            continue
        if token in ('-MD','-g','-O2'):
            i += 1
            continue
        flags.append(token)
        i += 1
    flags += ['-O1','-g0']
    pin(shutil.which(command[0]))
    headers = sorted((source/'include/fpu').glob('*.h'))
    pieces = [source/'fpu'/n for n in ('softfloat.c','softfloat-parts.c.inc',
                                     'softfloat-parts-addsub.c.inc','softfloat-specialize.c.inc')]
    drivers = (Path(__file__), Path(recipe.__file__), Path(__file__).with_name('remainder_quotient_probe.c'))
    archive = root/'driver-inputs'
    archive.mkdir()
    for p in (*headers,*pieces,*drivers):
        pin(p)
    for p in drivers:
        shutil.copyfile(p,archive/p.name)
        pin(archive/p.name)
    rows = cases()
    data = ''.join(f'{k} {p} {r} {h:x} {l:x} {bh:x} {bl:x}\n'
                   for row in rows for k,p,r,h,l,bh,bl in [row['args']])
    save('cases.json',rows)
    variants = {}
    for label in ('control','candidate','missing-increment','wrong-mode'):
        work = root/label
        (work/'include/fpu').mkdir(parents=True)
        (work/'fpu').mkdir()
        for p in (*headers,*pieces):
            rel = str(p.relative_to(source))
            content = changed.get(rel,p.read_text()) if label != 'control' else p.read_text()
            if rel == 'fpu/softfloat.c' and label == 'missing-increment':
                content = recipe.change(content,'            ++quot;\n','',2)
            if rel == 'fpu/softfloat.c' and label == 'wrong-mode':
                content = recipe.change(content,'parts_modrem(&pa, &pb, mod, quotient, status)',
                                         'parts_modrem(&pa, &pb, true, quotient, status)')
            (work/rel).write_text(content)
            pin(work/rel)
        shutil.copyfile(drivers[-1],work/'probe.c')
        pin(work/'probe.c')
        variants[label] = work
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],cases=len(rows),
                            affinity=sorted(os.sched_getaffinity(0)),canonical_oracle_changed=False))
    start = time.monotonic()
    result = dict(passed=False,errors=[],rows=[],gameplay_ipc=None,standard_suite=False,
                  hardware_acceptance=False,architectural_helper_qualified=False,canonical_gate=False)
    control = None
    try:
        for label, work in variants.items():
            local = ['-iquote',str(work/'include'),*flags]
            def execute(phase,cmd):
                save(label+'-'+phase+'-command.json',cmd)
                with (work/(phase+'.log')).open('x') as log:
                    done = subprocess.run(cmd,cwd=build,stdout=log,stderr=subprocess.STDOUT,timeout=120)
                assert done.returncode == 0,(label,phase,done.returncode)
            def dependencies(path):
                names = shlex.split(path.read_text().replace('\\\n',' '))[1:]
                return {(Path(p) if Path(p).is_absolute() else build/p).resolve(strict=True) for p in names}
            before = {}
            for name, src in (('softfloat',work/'fpu/softfloat.c'),('probe',work/'probe.c')):
                dep = work/(name+'-pre.d')
                execute(name+'-dependencies',['cc',*local,'-M','-MF',str(dep),'-MT',name,str(src)])
                before[name] = dependencies(dep)
                for p in before[name]:
                    pin(p)
            save(label+'-compile-inputs.json',dict(pins=pins))
            assert all(sha(p) == h for p,h in pins.items())
            for name, src in (('softfloat',work/'fpu/softfloat.c'),('probe',work/'probe.c')):
                execute(name+'-compile',['cc',*local,'-MD','-MF',str(work/(name+'.d')),
                                        '-c',str(src),'-o',str(work/(name+'.o'))])
                assert dependencies(work/(name+'.d')) == before[name]
            execute('link',['cc',str(work/'probe.o'),str(work/'softfloat.o'),'-lglib-2.0','-lm','-o',str(work/'probe')])
            assert all(sha(p) == h for p,h in pins.items())
            assert work/'include/fpu/softfloat-types.h' in before['softfloat']
            assert work/'fpu/softfloat-parts.c.inc' in before['softfloat']
            ran = subprocess.run([str(work/'probe')],input=data,capture_output=True,text=True,timeout=60)
            (work/'stdout').write_text(ran.stdout)
            (work/'stderr').write_text(ran.stderr)
            assert ran.returncode == 0 and not ran.stderr
            records = parse(ran.stdout)
            assert len(records) == len(rows)
            if label == 'control':
                control = records
            numeric = [i for i,(c,v) in enumerate(zip(control,records)) if c[:3] != v[:3]]
            wrong = [i for i,(r,v) in enumerate(zip(rows,records)) if r['expected_quotient'] != v[3]]
            trunc = [i for i,(r,c,v) in enumerate(zip(rows,control,records)) if r['args'][0] == 1 and c != v]
            # Original truncation quotients also fail for long exponent gaps.
            # Accept a changed output only when the candidate equals the exact
            # independently calculated quotient; never change remainder/flags.
            if label in ('control','candidate','missing-increment'):
                assert not numeric
            if label == 'candidate':
                assert not wrong,wrong[:10]
                assert all(control[i][3] != rows[i]['expected_quotient'] and
                           records[i][3] == rows[i]['expected_quotient'] for i in trunc)
            else:
                assert wrong,(label,'quotient negative control escaped')
            if label == 'wrong-mode':
                assert numeric,'mode negative control escaped'
            result['rows'].append(dict(label=label,native_exit=0,records=len(records),
                numeric_exception_mismatches=len(numeric),quotient_mismatches=len(wrong),
                truncation_mismatches=len(trunc),first_quotient_mismatches=wrong[:10],
                binary_sha256=sha(work/'probe'),stdout_sha256=sha(work/'stdout')))
        result['passed'] = True
    except Exception as e:
        result['errors'].append(dict(error=repr(e),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-start,pins=pins,pins_unchanged=all(sha(p) == h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print({k:v for k,v in result.items() if k != 'pins'},flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
