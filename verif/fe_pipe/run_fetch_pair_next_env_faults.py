"""Recheck the unchanged 44 x87 environment fault images on the composition.

Keep complete architectural comparisons, precise-fault self-checks and actual
UV-fast/AXI execution. No old tooling pins are migrated for this direct build.
"""
import ast
import hashlib
from pathlib import Path
import sys

import run_prefix_opcode_env_faults as previous

SOURCE = previous.SOURCE
sys.path.insert(0, str(SOURCE.parents[3] / 'verif/l1'))


def derive():
    text = previous.derive()
    for old, new in (
        ('import prepare_prefix_opcode as recipe', 'import prepare_fetch_pair_next as recipe'),
        ('14435a4d189ed3d0d441e14d356877cf6492c4c50077f80093b5d92ea8b4aff5',
         '8eaf19eddc32b69549842d52b9b2f5865ea23962d3a520a2a8a660854e1c79d1'),
        ("before['changes']==[recipe.FILE]", "before['changes']==sorted(recipe.PARENTS)"),
        ("[n for n in parent_files if parent_files[n]!=actual_files[n]]==[recipe.FILE]",
         "sorted(n for n in parent_files if parent_files[n]!=actual_files[n])==sorted(recipe.PARENTS)"),
        ("        assert (core/'candidate'/recipe.FILE).read_text()==recipe.transform((original/'candidate'/recipe.FILE).read_text())",
         "        for name in sorted(recipe.PARENTS):\n"
         "            assert (core/'candidate'/name).read_text()==recipe.transform((original/'candidate'/name).read_text(),name)"),
        ('for p in (SOURCE, Path(__file__), Path(recipe.__file__),',
         'for p in (SOURCE, Path(__file__), Path(previous.__file__), Path(recipe.__file__),\n'
         '              Path(recipe.fetch.__file__), Path(recipe.pair.__file__),'),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
