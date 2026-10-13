"""Transfer the source-checked register-only branch flags to the matched PC.

Keep all 102 common RTL inputs, 156 definitions, full regression admission,
native host/header audit and canonical failure. No hardware pass is inherited.
"""
import ast
import hashlib
from pathlib import Path

original=Path(__file__).with_name('build_fp_high_valid_soc.py')
text=original.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='b108da0a9ca84038e7e40392760f54528485541d99d44e2f7b72621d7d2bb895'


def change(old,new):
    global text
    assert text.count(old)==1,old
    text=text.replace(old,new)


def bound_build(command):
    """Lower this guarded build's ceiling before any compiler can start."""
    assert command[:2]==[str(base.REPO/'tools/build_scope.sh'),'--']
    limiter=('set -e; '
        'case "$(cat /proc/self/cgroup)" in */ventium-ipc-parallel32.scope) ;; *) exit 70;; esac; '
        'systemctl --user set-property --runtime ventium-ipc-parallel32.scope MemoryMax=10G MemorySwapMax=2G; '
        'test "$(systemctl --user show ventium-ipc-parallel32.scope -p MemoryMax --value)" = 10737418240; '
        'test "$(systemctl --user show ventium-ipc-parallel32.scope -p MemorySwapMax --value)" = 2147483648; '
        'exec "$@"')
    return command[:2]+['bash','-c',limiter,'prime-reg-build-cap']+command[2:]


def admit_flags(core):
    path=core.parent/'prime-reg-core-audit-r1.json'
    assert sha(path)=='f826b73fd800c991ce937cdee74f85502cca05db7be88abf35c6167b6db13bed'
    checked=load(path)
    assert checked['passed'] and checked['model']==CORE_MODEL
    assert checked['probe_runs']==4240 and checked['corner_runs']==72
    assert checked['changed_files']==CHANGES and checked['same_input_cases']==108
    assert checked['same_input_records']==80800 and not checked['canonical_gate_passed']
    assert checked['canonical_native_exit']==2 and checked['native_result_recovered_from_durable_marker']
    assert checked['corner_counts']==[
        dict(offers=384,commits=384,rejects=0,alu=0,shift=384,preserve=0),
        dict(offers=384,commits=384,rejects=0,alu=0,shift=0,preserve=384),
        dict(offers=48,commits=24,rejects=24,alu=48,shift=0,preserve=0)]
    assert stable(checked['pins'])
    return dict(checked['pins'],**{str(path):sha(path)})


change('"""'+ast.get_docstring(ast.parse(text),clean=False)+'"""',repr(__doc__))
change('import prepare_fp_high_valid_cofactor as recipe','import prepare_prime_reg_flags as recipe')
change("PARENT_MODEL='45dc4daf68980bba3ca36f9b8d2c6c4ec4464a07657f70669f00e085478893f5'",
       "PARENT_MODEL='95f7c9b3c6a00bcc04976305abea88560268e20c05fd996d36aa188d3b908f79'")
change("CORE_MODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'",
       "CORE_MODEL='0070aec34169c368f11fb723f33aaeb8f60f0617d9e2f33948e2cd347567c143'")
change('CHANGES=sorted(recipe.PARENTS)',"CHANGES=['rtl/core/core_mem_chain.svh']")
change('    pins,stats=regressions(core,proof,fp)',
       '    pins,stats=regressions(core,proof,fp)\n    pins.update(admit_flags(core))')
change('    for name in CHANGES:\n        assert recipe.transform((source/name).read_text(),name)==(core/\'candidate\'/name).read_text()',
       "    inputs={name:(source/'rtl/core'/name).read_text() for name in recipe.PARENTS}\n"
       "    assert recipe.transform(inputs)==(core/'candidate'/CHANGES[0]).read_text()")
change("'sim_fp_high_valid_'","'sim_prime_reg_flags_'")
change('    defs=[s[2:] for s in command',
       '    command=bound_build(command)\n    defs=[s[2:] for s in command')
change('Path(recipe.__file__),Path(base.__file__),','original,Path(recipe.__file__),Path(base.__file__),')
change('Prepared source-matched FP high-valid PC candidate; compiler not started.',
       'Prepared source-matched register branch flags PC; compiler not started.')
exec(compile(text,str(Path(__file__)),'exec'),globals())
