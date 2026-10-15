"""Independently regrade the composition's complete replay and pairing cases.

Reuse every record-level check, retaining canonical failures and existing mask
disclosures. The four source deltas are checked against the common parent.
"""
import ast
from pathlib import Path


def derive():
    path = Path(__file__).with_name('audit_pair_next_disjoint.py')
    text = path.read_text()
    old = 'import prepare_pair_next_disjoint as recipe'
    assert text.count(old) == 1
    text = text.replace(old, 'import prepare_fetch_pair_next as recipe')
    text = text.replace('recipe.once(', 'recipe.pair.once(')
    for old, new in (
        ('9beb7023ddfd56888fe6eac6b12ed2feebdbcb7fc367748a989fcb2b63292516',
         '8eaf19eddc32b69549842d52b9b2f5865ea23962d3a520a2a8a660854e1c79d1'),
        ('pair-next-disjoint-core-r1', 'fetch-pair-next-core-r1'),
        ('pair-next-disjoint-replay-r1', 'fetch-pair-next-replay-r1'),
        ('pair-next-disjoint-coldalias-r1', 'fetch-pair-next-coldalias-r1'),
        ('pair-next-disjoint-load-r1', 'fetch-pair-next-load-r1'),
        ('pair-next-disjoint-store-r1', 'fetch-pair-next-store-r1'),
        ('pair-next-disjoint-regression-audit.json', 'fetch-pair-next-regression-audit.json'),
        ('complete three-file source delta', 'complete four-file source delta'),
    ):
        assert old in text, old
        text = text.replace(old, new)
    # The native cache leaf is byte-identical to the previous disjoint leaf;
    # its proof is valid for that file only, not whole-core composition behavior.
    anchor = '    build=load(core/\'build-started.json\')'
    assert text.count(anchor) == 1
    text = text.replace(anchor,
        f"    pins[{str(path.resolve())!r}]=sha({str(path.resolve())!r})\n" + anchor)
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
