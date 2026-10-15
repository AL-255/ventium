"""Original 44 environment-store fault cases with the qualified transport."""
import ast
import hashlib
from pathlib import Path

import run_prefix_opcode_env_faults as previous
import run_fetch_fragment_owned as tooling

SOURCE = previous.SOURCE


def derive():
    text = previous.derive()
    for old, new in (
        ('import prepare_prefix_opcode as recipe', 'import prepare_fetch_fragment_extent as recipe'),
        ('14435a4d189ed3d0d441e14d356877cf6492c4c50077f80093b5d92ea8b4aff5', tooling.MODEL),
        ("    pins = dict(before['pins'])",
         "    pins = dict(before['pins'])\n    tooling_deltas=tooling.qualify_tooling(pins)\n"
         "    pins[str(Path(previous.__file__))]=hashlib.sha256(Path(previous.__file__).read_bytes()).hexdigest()"),
        ("save(root/'started.json',dict(pins=pins,cases=cases,invocation=os.environ['INVOCATION_ID'],",
         "save(root/'started.json',dict(pins=pins,cases=cases,tooling_deltas=tooling_deltas,invocation=os.environ['INVOCATION_ID'],")):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    ast.parse(text)
    return text


if __name__ == '__main__': exec(compile(derive(), str(__file__), 'exec'), globals())
