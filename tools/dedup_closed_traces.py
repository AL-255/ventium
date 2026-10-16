"""Share byte-identical, closed private .vtrace artifacts without losing paths.

Only traces beneath a retained terminal receipt qualify. All paths and bytes
survive; shared artifacts become read-only to prevent an accidental append from
corrupting another run's evidence. This never deduplicates disks or snapshots.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import time


def digest(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()


def equal(a,b):
    with a.open('rb') as x,b.open('rb') as y:
        while True:
            left,right=x.read(1024*1024),y.read(1024*1024)
            if left!=right: return False
            if not left: return True


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--apply',action='store_true')
    args=parser.parse_args()
    base=Path('/home/yukidama/external/tmp').resolve(strict=True)
    root,out=args.root.resolve(strict=True),args.out.resolve()
    assert root.is_relative_to(base) and root!=base
    assert out.parent==root and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==base
    groups={};closed={};inputs={};now=time.time()
    paths=subprocess.check_output(['rg','--files','--hidden','--no-ignore',str(root),
                                   '-g','*.vtrace'],text=True).splitlines()
    for name in paths:
        path=Path(name);s=path.lstat()
        if not stat.S_ISREG(s.st_mode) or s.st_size<65536 or s.st_nlink!=1 or now-s.st_mtime<600:
            continue
        owner=next((parent for parent in path.parents if parent!=root and parent.is_relative_to(root)
                    and any((parent/n).is_file() for n in ('closed.json','verify-closed.json'))),None)
        if owner is None: continue
        if owner not in closed:
            receipts=[owner/n for n in ('closed.json','verify-closed.json') if (owner/n).is_file()]
            for receipt in receipts:
                json.loads(receipt.read_text()) # invalid/incomplete receipt is not closure
                inputs[str(receipt)]=digest(receipt)
            closed[owner]=receipts
        h=digest(path)
        groups.setdefault((s.st_size,h),[]).append((path,s))
    pairs=[]
    for (_,h),group in groups.items():
        if len(group)<2: continue
        source,ss=group[0]
        for path,s in group[1:]:
            assert s.st_dev==ss.st_dev and equal(source,path)
            pairs.append(dict(source=str(source),target=str(path),sha256=h,
                              source_inode=ss.st_ino,target_inode=s.st_ino,bytes=s.st_size,
                              blocks=s.st_blocks,mode=stat.S_IMODE(s.st_mode)))
    candidates={row[key] for row in pairs for key in ('source','target')}
    for proc in Path('/proc').iterdir():
        if not proc.name.isdecimal(): continue
        try:
            for fd in (proc/'fd').iterdir():
                try:
                    target=str(fd.resolve(strict=True))
                    if target in candidates:
                        flags=next(line.split()[1] for line in (proc/'fdinfo'/fd.name).read_text().splitlines()
                                   if line.startswith('flags:'))
                        assert int(flags,8)&3 == 0, ('open trace writer',proc,target)
                except (FileNotFoundError,PermissionError,ProcessLookupError): pass
        except (FileNotFoundError,PermissionError,ProcessLookupError): pass
    receipt=dict(apply=args.apply,files=len(pairs),recoverable_bytes=sum(r['blocks']*512 for r in pairs),
                 inputs=inputs,pairs=pairs,tool_sha256=digest(Path(__file__).resolve()))
    with out.open('x') as stream:
        json.dump(receipt,stream,indent=2);stream.flush();os.fsync(stream.fileno())
    if args.apply:
        for row in pairs:
            source,target=Path(row['source']),Path(row['target'])
            assert source.stat().st_ino==row['source_inode']
            assert target.stat().st_ino==row['target_inode'] and target.stat().st_nlink==1
            assert equal(source,target) and digest(source)==row['sha256']
            temp=target.with_name(target.name+'.dedup-link')
            assert not temp.exists()
            os.chmod(source,stat.S_IMODE(source.stat().st_mode)&~0o222)
            os.link(source,temp);os.replace(temp,target)
            assert digest(target)==row['sha256']
        assert all(digest(Path(path))==value for path,value in inputs.items())
        with out.with_suffix('.complete.json').open('x') as stream:
            json.dump(dict(passed=True,files=len(pairs),net_bytes_freed=receipt['recoverable_bytes'],
                           plan_sha256=digest(out),all_paths_preserved=True),stream,indent=2)
    print(json.dumps({k:v for k,v in receipt.items() if k not in ('inputs','pairs')}),flush=True)


if __name__=='__main__': main()
