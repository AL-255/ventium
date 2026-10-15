"""Fresh 108-program QEMU comparison for the composed FPGA timing candidate.

Use the independently qualified private P54C reference, not replayed goldens.
Keep canonical FAIL, existing masks and cycle-band requirements explicit.
"""
import ast
import hashlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO/'verif/qemu-trace/c1_reference/run_func.py'
BASE_SHA = '9e5e78a4f70e1fff7a2894cda8d7d3ba6dc0cc2006400f7a958b1f4cdc98062f'
MODEL = '8eaf19eddc32b69549842d52b9b2f5865ea23962d3a520a2a8a660854e1c79d1'
ORACLE = 'da49b8105f90b4257494a7b7f1e57e5428fa66dc667278b824d381d9d0e9f84d'


def derive():
    text = BASE.read_text()
    assert hashlib.sha256(text.encode()).hexdigest() == BASE_SHA
    for old, new in (
        ('REPO=Path(__file__).resolve().parents[3]', 'REPO=Path('+repr(str(REPO))+')'),
        ("assert sha(model)=='369a23b48abaebd54991533e8933094c9791d6b6d9a6a13edb1f128029c6b150'",
         'assert sha(model)=='+repr(MODEL)),
        ("assert sha(qemu)==built['sha256']", "assert sha(qemu)==built['sha256']=="+repr(ORACLE)),
        ('set(range(8,12))', 'set(range(13,17))'),
        ('cpu=8+index%4', 'cpu=13+index%4'),
        ('for p in (Path(__file__),model,qemu,jobs_file,',
         "qualification=build.parent/'audit.json'\n"
         "    assert sha(qualification)=='5efd6ee2365ac757517ec858cc393c7326a8178cdb093ee4ab8d3b2d233080af'\n"
         "    assert json.loads(qualification.read_text())['passed']\n"
         "    for p in (BASE,qualification,REPO/'verif/qemu-trace/owned_gdb.py',Path(__file__),model,qemu,jobs_file,"),
        ('result=dict(passed=passed,rows=rows,pins_unchanged=stable,seconds=time.monotonic()-begin,',
         'result=dict(passed=passed,rows=rows,pins_unchanged=stable,seconds=time.monotonic()-begin,\n'
         '        fresh_qemu=True,authenticated_input_replay=False,qualified_private_reference=True,'),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
