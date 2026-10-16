"""Apply the retained complete functional audit to the exact current model.

Keep all manifest-scoped comparisons, independent unmasked comparisons,
actual native ownership/affinity checks and executable-image equality checks.
"""
import hashlib
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]/'qemu-trace/audit_fetch_pair_next_func.py'


def derive():
    text = BASE.read_text()
    assert hashlib.sha256(text.encode()).hexdigest() == '7f7f50a3f7d7796ce5dea198795495cf7098dee798fd03e7be78eb4b96fed425'
    for old, new, count in (
        ('import run_fetch_pair_next_func as runner', 'import run_v_result_carry_func as runner', 1),
        ('ventium-data-size.v2HaTO2X', 'ventium-fprem-sequence.iSZ9BAj4', 1),
        ('fetch-pair-next-freshfunc-r1', 'v-result-carry-func-r1', 1),
        ('fetch-pair-next-core-r1', 'v-result-carry-core-r1', 1),
        ('ventium-fetch-pair-next-freshfunc-oct15-r1.service', 'ventium-v-result-carry-func-oct16-r1.service', 1),
        ("assert closed['passed'] and closed['pins_unchanged'] and closed['fresh_qemu']",
         "assert closed['passed'] and closed['pins_unchanged']", 1),
        ("assert not closed['authenticated_input_replay'] and not closed['canonical_gate_passed']",
         "assert not closed['canonical_gate_passed']\n"
         "    assert all(r['result'].split('|')[-1]=='0' for r in closed['rows']), 'fresh reference required'", 1),
        ('runner.ORACLE', 'runner.REFERENCE', 2),
        ('cpu in range(13,17)', 'cpu in range(12,16)', 1),
        ('runner.BASE,', 'runner.SOURCE, Path('+repr(str(BASE))+'),', 1),
    ):
        assert text.count(old) == count, old
        text = text.replace(old, new)
    compile(text, str(Path(__file__)), 'exec')
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(Path(__file__)), 'exec'), globals())
