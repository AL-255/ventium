"""Remove only regenerable Verilator PCH members from reviewed closed archives.

All non-PCH members, including generated source and objects, are retained and
byte-hashed before/after repacking. An exclusive receipt records the old archive
hash and every removed member. Old archive hashes intentionally change; pinned
archives must be excluded by the caller's explicit protected-input receipts.
No directory deletion, archive extraction, source deletion or binary deletion.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import time

SCRATCH = Path('/home/yukidama/external/tmp')
NAMES = {'compiler-products.tar.zst','generated-objects.tar.zst',
         'read-ack-generated.tar.zst','superseded-objects.tar.zst',
         'generated-model-artifacts.tar.zst','compiler-generated.tar.zst'}
PCH = re.compile(r'V[^/]+__pch\.h\.(fast|slow)\.gch\Z')


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def pch(name):
    path = PurePosixPath(name)
    assert not path.is_absolute() and '..' not in path.parts
    return bool(PCH.fullmatch(path.name))


def idle(path):
    for proc in Path('/proc').iterdir():
        if not proc.name.isdecimal() or int(proc.name)==os.getpid(): continue
        try:
            # No compiler may be using any of these closed intermediates.
            comm = (proc/'comm').read_text().strip()
            assert comm not in ('vivado','verilator_bin','cc1plus','cc1'), (proc,comm)
            for fd in (proc/'fd').iterdir():
                try: assert fd.resolve(strict=True) != path, ('open archive',proc,path)
                except (FileNotFoundError,PermissionError,ProcessLookupError): pass
        except (FileNotFoundError,PermissionError,ProcessLookupError): pass


def inventory(path, output=None):
    """Streaming tar copy: payload hashes plus all retained tar metadata."""
    rows, removed, kept_names = [], [], set()
    reader = subprocess.Popen(['zstd','-q','-d','-c','--',str(path)],stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=reader.stdout,mode='r|') as archive:
            for member in archive:
                discard = pch(member.name)
                assert member.name not in kept_names, ('duplicate member',member.name)
                kept_names.add(member.name)
                assert not discard or member.isfile(), ('PCH is not regular',member.name)
                if member.issym() or member.islnk():
                    assert not pch(member.linkname), ('retained link targets removed PCH',member.name)
                metadata = dict(name=member.name,size=member.size,type=member.type.decode('ascii'),
                    mode=member.mode,uid=member.uid,gid=member.gid,uname=member.uname,gname=member.gname,
                    mtime=member.mtime,linkname=member.linkname,pax=member.pax_headers)
                payload = archive.extractfile(member) if member.isfile() else None
                if payload is not None:
                    class HashedReader:
                        def __init__(self, stream): self.stream=stream;self.digest=hashlib.sha256()
                        def read(self, count=-1):
                            data=self.stream.read(count);self.digest.update(data);return data
                    stream = HashedReader(payload)
                    if output is not None and not discard: output.addfile(member,stream)
                    else:
                        while stream.read(1024*1024): pass
                    metadata['sha256'] = stream.digest.hexdigest()
                elif output is not None and not discard: output.addfile(member)
                (removed if discard else rows).append(metadata)
        # tar ends before the compression stream's optional trailing padding.
        # Drain it to EOF so zstd validates its checksum instead of receiving
        # SIGPIPE from a prematurely closed reader on a larger archive.
        while reader.stdout.read(1024*1024): pass
        reader.stdout.close()
        assert reader.wait(timeout=30)==0
    finally:
        if reader.poll() is None: reader.kill();reader.wait()
    return rows,removed


def collect_pins(value, protected):
    if isinstance(value,dict):
        for key,item in value.items():
            if key.startswith('/') and isinstance(item,str) and re.fullmatch('[0-9a-f]{64}',item):
                protected.add(str(Path(key).resolve()))
            collect_pins(item,protected)
    elif isinstance(value,list):
        for item in value: collect_pins(item,protected)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--protected',type=Path,action='append',required=True)
    ap.add_argument('--apply',action='store_true')
    ap.add_argument('--plan',type=Path,help='required previously inspected dry-run directory for --apply')
    ap.add_argument('--all-zstd',action='store_true',
                    help='inventory every project .tar.zst; still remove ONLY the strict PCH member names')
    args=ap.parse_args()
    scratch=SCRATCH.resolve(strict=True);out=args.out.resolve()
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert out.is_relative_to(scratch) and out!=scratch and not out.exists()
    assert scratch.stat().st_dev!=Path(__file__).resolve().stat().st_dev
    protected=set();protect_receipts={}
    for path in args.protected:
        path=path.resolve(strict=True)
        collect_pins(json.loads(path.read_text()),protected)
        protect_receipts[str(path)]=sha(path)
    # Wider discovery is read-only until the resulting exact archive/member
    # inventory is separately approved via --plan. Non-PCH members survive.
    patterns=['*.tar.zst'] if args.all_zstd else sorted(NAMES)
    found=subprocess.check_output(['rg','--files','--hidden','--no-ignore',str(scratch),
        *[arg for name in patterns for arg in ('-g',name)]],text=True).splitlines()
    paths=[Path(name).resolve(strict=True) for name in found]
    assert len(paths)==len(set(paths))
    assert all(path.relative_to(scratch).parts[0].startswith('ventium-') for path in paths)
    paths=[path for path in paths if str(path) not in protected]
    approved={}
    if args.apply:
        assert args.plan is not None
        plan=args.plan.resolve(strict=True)
        assert plan.is_relative_to(scratch)
        closed=json.loads((plan/'closed.json').read_text())
        selection=json.loads((plan/'selection.json').read_text())
        assert closed['passed'] and not selection['apply']
        assert selection['protected_receipts']==protect_receipts
        for row_path in closed['results']:
            row=json.loads(Path(row_path).read_text())
            assert not row['applied']
            if row['removed']: approved[row['path']]=row['old_sha256']
        assert approved and set(approved).issubset({str(path) for path in paths})
        paths=[path for path in paths if str(path) in approved]
    assert all(path.is_relative_to(scratch) and not path.is_symlink() and path.stat().st_nlink==1 for path in paths)
    out.mkdir()
    def save(path,value):
        with path.open('x') as stream:
            json.dump(value,stream,indent=2);stream.flush();os.fsync(stream.fileno())
    save(out/'selection.json',dict(paths=[str(p) for p in paths],protected_receipts=protect_receipts,
        protected_archive_count=len(found)-len(paths),apply=args.apply,all_zstd=args.all_zstd,
        tool=str(Path(__file__).resolve()),tool_sha256=sha(__file__)))
    def worker(pair):
        index,path=pair
        # This tool owns only these two explicitly bounded worker threads.
        os.sched_setaffinity(0,{12+index%2})
        idle(path)
        before=sha(path);stat=path.stat()
        if args.apply: assert before==approved[str(path)], ('drift after dry-run',path)
        if not args.apply:
            kept,removed=inventory(path)
            result=dict(path=str(path),old_sha256=before,old_bytes=stat.st_size,
                        removed=removed,kept_members=len(kept),applied=False)
        else:
            pending=out/(str(index)+'.tar.zst')
            with pending.open('xb') as stream:
                writer=subprocess.Popen(['zstd','-q','-T1','-3','-c'],stdin=subprocess.PIPE,stdout=stream)
                try:
                    with tarfile.open(fileobj=writer.stdin,mode='w|') as archive:
                        kept,removed=inventory(path,archive)
                    writer.stdin.close()
                    assert writer.wait(timeout=30)==0
                finally:
                    if writer.poll() is None: writer.kill();writer.wait()
            actual,remaining=inventory(pending)
            assert actual==kept and not remaining, ('retained payload or metadata drift',path)
            assert path.stat().st_ino==stat.st_ino and sha(path)==before
            result=dict(path=str(path),old_sha256=before,old_bytes=stat.st_size,
                        new_sha256=sha(pending),new_bytes=pending.stat().st_size,
                        removed=removed,kept=kept,applied=False)
            if removed and pending.stat().st_size<stat.st_size:
                idle(path)
                # Write durable recovery/retention evidence BEFORE replacing the
                # old cache. All non-PCH bytes remain recoverable via this path.
                result['applied']=True
                save(out/(str(index)+'-replacement.json'),result)
                os.chmod(pending,stat.st_mode & 0o777)
                os.replace(pending,path)
                assert sha(path)==result['new_sha256']
            else:
                # Exact tool-created, verified temporary archive, not user data.
                pending.unlink()
        save(out/(str(index)+'-closed.json'),result)
        print(json.dumps({key:value for key,value in result.items() if key not in ('kept','removed')}),flush=True)
        return result
    start=time.monotonic()
    with ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(worker,enumerate(paths)))
    assert all(sha(path)==value for path,value in protect_receipts.items())
    save(out/'closed.json',dict(passed=True,seconds=time.monotonic()-start,
        archives=len(results),changed=sum(row['applied'] for row in results),
        removed_pch_members=sum(len(row['removed']) for row in results if row['applied']),
        net_bytes_freed=sum(row['old_bytes']-row['new_bytes'] for row in results if row['applied']),
        protected_receipts=protect_receipts,results=[str(out/(str(i)+'-closed.json')) for i in range(len(results))]))


if __name__=='__main__': main()
