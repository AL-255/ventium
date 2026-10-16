"""Regrade all fresh functional traces without changing canonical policy."""
import hashlib
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/issue_uv'))
import audit_v_result_carry_func as previous


def derive():
    assert hashlib.sha256(Path(previous.__file__).read_bytes()).hexdigest() == (
        '02147131e111dba468bb34469a1c7b5e2201afc594a5b36efdcd23afa17d0571')
    text = previous.derive()
    for old, new in (
        ('import run_v_result_carry_func as runner',
         'import run_next_ready_func as runner\nrunner.REPO=runner.previous.REPO'),
        ('v-result-carry-func-r1', 'next-ready-func-r1'),
        ('v-result-carry-core-r1', 'next-ready-core-r1'),
        ('ventium-v-result-carry-func-oct16-r1.service',
         'ventium-next-ready-func-oct16-r1.service'),
        ('cpu in range(12,16)', 'cpu in range(4,8)'),
        ('runner.SOURCE, Path(',
         'runner.SOURCE, Path('+repr(str(Path(previous.__file__)))+'), Path('),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    compile(text, __file__, 'exec')
    return text


if __name__ == '__main__':
    exec(compile(derive(), __file__, 'exec'), globals())
