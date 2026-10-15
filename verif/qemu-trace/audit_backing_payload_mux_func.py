"""Regrade the payload-mux corpus with the unchanged full-record audit.

Only the candidate identity, output directory and owner change. Preserve the
existing manifest masks, independent unmasked comparison, native ownership,
affinity, full source pins and non-loadable GCC STT_FILE normalization.
"""
import ast
from pathlib import Path

BASE = Path(__file__).with_name('audit_fetch_pair_next_func.py')


def derive():
    text = BASE.read_text()
    replacements = {
        'import run_fetch_pair_next_func as runner':
            'import run_backing_payload_mux_func as runner\n'
            'from run_fetch_pair_next_func import ORACLE',
        "ROOT/'fetch-pair-next-freshfunc-r1'": "ROOT/'backing-payload-mux-freshfunc-r1'",
        "ROOT/'fetch-pair-next-core-r1'": "ROOT/'backing-payload-mux-core-r1'",
        "'ventium-fetch-pair-next-freshfunc-oct15-r1.service'":
            "'ventium-backing-payload-mux-freshfunc-oct15-r1.service'",
        'Path(compare.__file__), Path(tracefmt.__file__))':
            f'Path(compare.__file__), Path(tracefmt.__file__), Path({str(BASE.resolve())!r}))',
    }
    for before, after in replacements.items():
        assert text.count(before) == 1, before
        text = text.replace(before, after, 1)
    assert text.count('runner.ORACLE') == 2
    text = text.replace('runner.ORACLE', 'ORACLE')
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
