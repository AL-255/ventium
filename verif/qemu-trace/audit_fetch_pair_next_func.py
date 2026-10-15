"""Regrade every fresh private-reference record without altering gate policy."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import subprocess
import sys

import run_fetch_pair_next_func as runner

REPO = runner.REPO
ROOT = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X').resolve(strict=True)
sys.path.insert(0, str(REPO/'verif/diff'))
import compare
import tracefmt


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def mask_args(manifest):
    """Same manifest-scoped policy as the unchanged canonical worker."""
    def span(row):
        return f'{row[0]}:{"" if len(row)<2 or row[1] is None else row[1]}' + (
            f'={row[2]}' if len(row)>=3 and row[2] else '')
    args = []
    for key, mask in (('x87_fprem1_cc_ranges','0x4300'), ('x87_stkflt_fstat_ranges','0x4741')):
        if manifest.get(key):
            args += ['--mask-fstat-exc', mask]
            for row in manifest[key]:
                args += ['--mask-fstat-range', span(row)]
    for row in manifest.get('x87_stkflt_fpr_ranges', []):
        args += ['--mask-fpr-range', span(row)]
    if not args and manifest.get('x87_stkflt_arch'):
        args += ['--mask-fstat-exc','0x4741','--mask-x87-fpr']
    return args


def same_elf_except_gcc_file_symbol(before, after):
    """Allow only GCC's random STT_FILE basename outside every PT_LOAD range.

    No code/data, headers, addresses, relocations or symbol attributes may
    differ. This compares files in memory; it never rewrites an ELF or trace.
    """
    assert len(before)==len(after) and before[:7]==after[:7]==b'\x7fELF\x01\x01\x01'
    headers = [struct.unpack_from('<16sHHIIIIIHHHHHH', data) for data in (before, after)]
    assert headers[0]==headers[1]
    h = headers[0]
    assert h[1:3]==(2,3) and h[9]==32 and h[11]==40
    ph = [struct.unpack_from('<8I',before,h[5]+32*i) for i in range(h[10])]
    sh = [struct.unpack_from('<10I',before,h[6]+40*i) for i in range(h[12])]
    assert all(before[h[5]+32*i:h[5]+32*(i+1)]==after[h[5]+32*i:h[5]+32*(i+1)] for i in range(h[10]))
    assert all(before[h[6]+40*i:h[6]+40*(i+1)]==after[h[6]+40*i:h[6]+40*(i+1)] for i in range(h[12]))
    allowed = set()
    for s in sh:
        if s[1]!=2:
            continue
        assert s[9]==16 and s[5]%16==0
        strings = sh[s[6]]
        assert strings[1]==3 and not strings[2]&2  # SHT_STRTAB, not SHF_ALLOC.
        for off in range(s[4],s[4]+s[5],16):
            symbol = struct.unpack_from('<IIIBBH',before,off)
            assert before[off:off+16]==after[off:off+16]
            if symbol[3]!=4:  # STT_FILE, STB_LOCAL.
                continue
            begin = strings[4]+symbol[0]
            end = before.index(b'\0',begin)
            assert end < strings[4]+strings[5] and after.index(b'\0',begin)==end
            if before[begin:end]==after[begin:end]:
                continue
            assert re.fullmatch(rb'cc[A-Za-z0-9]{6}\.o',before[begin:end])
            assert re.fullmatch(rb'cc[A-Za-z0-9]{6}\.o',after[begin:end])
            assert all(not (p[0]==1 and begin < p[1]+p[4] and end>=p[1]) for p in ph)
            allowed.update(range(begin,end))
    differences = {i for i,(a,b) in enumerate(zip(before,after)) if a!=b}
    assert differences <= allowed
    return len(differences)


def main():
    root = ROOT/'fetch-pair-next-freshfunc-r1'
    core = ROOT/'fetch-pair-next-core-r1'
    start, closed = load(root/'started.json'), load(root/'closed.json')
    assert __debug__ and not (root/'audit.json').exists()
    assert closed['passed'] and closed['pins_unchanged'] and closed['fresh_qemu']
    assert not closed['authenticated_input_replay'] and not closed['canonical_gate_passed']
    assert start['model'] == runner.MODEL and start['oracle'] == runner.ORACLE
    assert start['workers'] == 4 and len(start['jobs']) == len(closed['rows']) == 108
    assert all(closed['memory_events'][k] == '0' for k in ('oom','oom_kill','oom_group_kill'))
    pins = dict(start['pins'])
    assert all(sha(p) == h for p,h in pins.items())
    unit = 'ventium-fetch-pair-next-freshfunc-oct15-r1.service'
    keys = ('ActiveState','SubState','MainPID','ExecMainStatus','InvocationID','Result','ControlGroup','MemoryPeak')
    owner = dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show',unit,*['-p'+k for k in keys]], text=True).splitlines())
    assert owner['InvocationID'] == start['invocation']
    assert owner['ActiveState']=='active' and owner['SubState']=='exited' and owner['MainPID']=='0'
    assert owner['ExecMainStatus']=='0' and owner['Result']=='success'
    if owner['ControlGroup']:
        assert not (Path('/sys/fs/cgroup')/owner['ControlGroup'].lstrip('/')/'cgroup.procs').read_text().strip()
    assert start['environment']['VTM_QEMU_GDB_PREEXIT']=='1'
    assert start['environment']['TB_EXTRA_FLAGS']=='--cycle-func --l1-axi'
    assert start['environment']['AXI_RLAT']==start['environment']['AXI_WLAT']=='7'
    goldens = {}
    for path in (root/'private-enabled-cache').glob('*.vtrace'):
        trace = tracefmt.read_trace(str(path))
        name = re.search(r'elf=(\w+)\.func\.elf ', trace.hdr['note']).group(1)
        assert name not in goldens and trace.hdr['producer']=='qemu-gdbstub'
        goldens[name] = path
    assert len(goldens)==108
    count = paired = metadata_only_elf_changes = 0
    unmasked_failures = []
    for job, row in zip(start['jobs'], closed['rows']):
        name = job[1]
        assert row['name']==name and row['passed'] and row['actual_wait'] and row['error'] is None
        assert row['native_worker_exit']==0 and row['affinity_verified']
        cpu = int(row['command'][2])
        assert cpu in range(13,17)
        assert {p['executable'] for p in row['observed_affinity'].values()}=={'tb_ventium','qemu-i386'}
        assert all(p['affinity']==[cpu] for p in row['observed_affinity'].values())
        rtl = root/'work'/(name+'.func_rtl.vtrace')
        golden = goldens[name]
        rt, qt = tracefmt.read_trace(str(rtl)), tracefmt.read_trace(str(golden))
        assert rt.hdr['producer']=='rtl' and rt.mode==qt.mode=='func'
        assert len(rt.records)==len(qt.records) and rt.x87==qt.x87==bool(int(job[6]))
        assert [r['n'] for r in rt.records]==list(range(len(rt.records)))
        # GCC embeds a randomized temporary-object STT_FILE name in some ELFs.
        # Everything except that non-loadable string must be byte-identical.
        elf = root/'work'/(name+'.func.elf')
        old_elf = core/'generic-work'/elf.name
        metadata_only_elf_changes += bool(same_elf_except_gcc_file_symbol(old_elf.read_bytes(), elf.read_bytes()))
        assert (root/'work'/(name+'.func.flat')).read_bytes()==(core/'generic-work'/(name+'.func.flat')).read_bytes()
        pins[str(old_elf)]=sha(old_elf)
        args = mask_args(load(Path(job[2]).parent/'manifest.json'))
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            assert compare.main(['--mode','func','--all',*args,str(golden),str(rtl)])==0
            raw = compare.main(['--mode','func','--all',str(golden),str(rtl)])
        if raw:
            unmasked_failures.append(name)
        log = (root/'work'/(name+'.func_rtl.log')).read_text()
        assert '--l1-axi selected' in log
        paired += int(re.search(r'pairedV=(\d+)',log)[1])
        count += len(rt.records)
    assert count==80800 and paired==30132
    assert sorted(unmasked_failures)==['tx_regform','tx_regform2','tx_stack']
    for p in (Path(__file__), Path(runner.__file__), runner.BASE,
              Path(compare.__file__), Path(tracefmt.__file__)):
        pins[str(p)]=sha(p)
    artifacts = {str(p):sha(p) for p in root.rglob('*') if p.is_file()}
    assert all(sha(p)==h for p,h in pins.items())
    result = dict(passed=True, fresh_qemu=True, qualified_private_reference=True,
        model=runner.MODEL, oracle=runner.ORACLE, owner=owner, input_pins=len(pins),
        functional_passes=108, functional_records=count, v_retirements=paired,
        metadata_only_elf_changes=metadata_only_elf_changes, executable_images_unchanged=True,
        unmasked_functional_passes=105, unmasked_failures=sorted(unmasked_failures),
        pins=pins, artifacts=artifacts, canonical_gate_passed=False,
        standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    with (root/'audit.json').open('x') as stream:
        json.dump(result,stream,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','artifacts')},indent=2))


if __name__ == '__main__':
    main()
