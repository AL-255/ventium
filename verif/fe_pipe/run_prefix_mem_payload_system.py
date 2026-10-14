"""Repeat unchanged cold system/fault controls on the prefix-payload candidate."""
import ast
import hashlib
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[2]
ORIGINAL = REPO/'verif/segment_extent/run_fast_segment_system.py'
ORIGINAL_SHA = '8ce6e23f796cb5e366ee340c89a1ca3fa464c3af2f356a894efdcd9ec004a29e'
sys.path.insert(0, str(ORIGINAL.parent))


def derive():
    text = ORIGINAL.read_text()
    assert hashlib.sha256(text.encode()).hexdigest() == ORIGINAL_SHA
    replacements = (
        ('import prepare_fast_segment as recipe', 'import prepare_prefix_mem_payload as recipe'),
        ('139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7',
         '1fb2f09e09ccddfca30ef2423e96226ddae40b4df44b4089204bed2cd79e505c'),
        ('1fb2f09e09ccddfca30ef2423e96226ddae40b4df44b4089204bed2cd79e505c\x27\n    assert recipe.transform',
         'e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6\x27\n    assert recipe.transform'),
        ("recipe.transform((parent/'candidate'/recipe.FILE).read_text())",
         "recipe.transform((parent/'candidate'/recipe.FILE).read_text(), (parent/'candidate'/recipe.DECODER_FILE).read_text())"),
        ('for p in (Path(__file__),Path(recipe.__file__),',
         "for p in (ORIGINAL,ORIGINAL.with_name('run_leaf.py'),Path(__file__),Path(recipe.__file__),"),
    )
    for before, after in replacements:
        assert text.count(before) == 1, before
        text = text.replace(before, after)
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
