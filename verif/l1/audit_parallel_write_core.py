"""Reconstruct parallel-admission core checks; preserve canonical verdicts."""
import inspect
import json
from pathlib import Path

import audit_qualified_pair_credit_core as template
import build_parallel_write_core as build
import run_parallel_write_core as run


def adapted_audit():
    source=inspect.getsource(template.audit)
    for old,new in (
        ('qualified-pair-credit-core-r1','parallel-write-core-r1'),
        ('qualified-pair-credit-system-r1','parallel-write-system-r1'),
        ('ventium-qualified-pair-core-oct16-r1.service','ventium-parallel-write-core-oct16-r1.service'),
        ('e45d4f5570e845e4a740c0d8e61a3d35','1535db71879742e28860c8c54a2f2103'),
        ('ventium-qualified-pair-system-oct16-r1.service','ventium-parallel-write-system-oct16-r1.service'),
        ('ventium-qualified-pair-verify-oct16-r1.service','ventium-parallel-write-verify-oct16-r1.service'),
        ("*system.rglob('*'), Path(__file__),", "*system.rglob('*'), Path(template.__file__), Path(__file__),"),
    ):
        source=run.recipe.once(source,old,new)
    return source


def audit(root):
    scope=dict(template.__dict__,__file__=__file__,template=template,build=build,run=run)
    exec(compile(adapted_audit(),__file__,'exec'),scope)
    result=scope['audit'](root)
    core=root/'parallel-write-core-r1'
    start=json.loads((core/'build-started.json').read_text())
    host=Path(start['host']);obj=core/'obj'
    assert host.name.startswith('tb_parallel_write_') and (obj/(host.stem+'.o')).is_file()
    dep=obj/(host.stem+'.d')
    headers=[Path(name) for name in dep.read_text().replace('\\\n',' ').split()
             if Path(name).name=='Vventium_top___024root.h']
    assert len(headers)==1
    header=headers[0] if headers[0].is_absolute() else obj/headers[0]
    assert header.resolve()==(obj/'Vventium_top___024root.h').resolve()
    result['private_model_header_verified']=True
    for path in (dep,header,obj/(host.stem+'.o'),core/'build.log'):
        result['pins'][str(path)]=template.common.sha(path)
    return result


if __name__=='__main__':
    ap=template.argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,required=True)
    root=ap.parse_args().root.resolve(strict=True)
    assert root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    result=audit(root)
    template.common.save(root/'parallel-write-core-audit-r1.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'},indent=2))
