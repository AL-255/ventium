"""Transfer the verified CS-request cofactor into the matched UV-fast PC model.

Keep the full existing regression admission, 102 common RTL sources and all
156 definitions. Also require real new/held-memory coverage and observer A/B.
Canonical failures remain unwaived; no timing or FPGA acceptance is inherited.
"""
import ast
import hashlib
from pathlib import Path

original = Path(__file__).with_name('build_fp_high_valid_soc.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == 'b108da0a9ca84038e7e40392760f54528485541d99d44e2f7b72621d7d2bb895'


def change(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)


def admit_cs(core, coverage):
    from run_pipe_cs_coverage import observations
    before, done = load(coverage/'started.json'), load(coverage/'closed.json')
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert done['runs'] == 288 and len(done['rows']) == 72
    assert before['models']['candidate'] == str(core/'obj/tb_ventium')
    pins = dict(before['pins'])
    assert stable(pins)
    for row in done['rows']:
        folder = coverage/(row['name']+'-'+'-'.join(map(str,row['case'])))
        path = folder/f"observer-on-l{row['latency']}-{row['mode']}.stderr"
        got = observations(path.read_text(), row['case'][0], row['name']=='interior')
        assert got == {k:row[k] for k in got}
        pins[str(path)] = sha(path)
    for p in (coverage/'started.json',coverage/'closed.json',
              original.parents[1]/'verif/l1/run_pipe_cs_coverage.py'):
        pins[str(p)] = sha(p)
    return pins


change('"""'+ast.get_docstring(ast.parse(text), clean=False)+'"""', repr(__doc__))
change('import prepare_fp_high_valid_cofactor as recipe', 'import prepare_prime_cs_transfer as recipe')
change("PARENT_MODEL='45dc4daf68980bba3ca36f9b8d2c6c4ec4464a07657f70669f00e085478893f5'",
       "PARENT_MODEL='64ef07765e1d8829dc89f851f4fab29bb88e6b997f7f4b259b0939bcb8a87f25'")
change("CORE_MODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'",
       "CORE_MODEL='73f6f9dbd0ca16640456304a01453a8bfd5c28a98fa0c9ec5548a9d1fdd61dca'")
change('def prepare(parent,core,proof,fp,root):', 'def prepare(parent,core,proof,fp,coverage,root):')
change('    pins,stats=regressions(core,proof,fp)',
       '    pins,stats=regressions(core,proof,fp)\n    pins.update(admit_cs(core,coverage))')
change("'sim_fp_high_valid_'", "'sim_prime_cs_'")
change('Path(recipe.__file__),Path(base.__file__),',
       'original,Path(recipe.__file__),Path(recipe.cofactor.__file__),Path(base.__file__),')
change("for name in ('parent','core','proof','fp'):", "for name in ('parent','core','proof','fp','coverage'):")
change('assert all((args.parent,args.core,args.proof,args.fp))',
       'assert all((args.parent,args.core,args.proof,args.fp,args.coverage))')
change("for n in ('parent','core','proof','fp')),root)",
       "for n in ('parent','core','proof','fp','coverage')),root)")
change('Prepared source-matched FP high-valid PC candidate; compiler not started.',
       'Prepared source-matched CS-request PC candidate; compiler not started.')
exec(compile(text, str(Path(__file__)), 'exec'), globals())
