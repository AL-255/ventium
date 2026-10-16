"""Run the identical public-wire matrix on a separate prepared injector repair."""
import inspect
import json
from pathlib import Path

import prepare_kbd_inhibit as recipe
import run_kbd_inhibit_witness as witness


def derive():
    text=inspect.getsource(witness.main)
    edits=(
        ('assert sha(INJECTOR)==INJECTOR_SHA',
         "prepared=json.loads((INJECTOR.parent/'prepared.json').read_text())\n"
         "    assert prepared['parent_sha256']==recipe.witness.INJECTOR_SHA\n"
         "    assert sha(INJECTOR)==prepared['candidate_sha256']\n"
         "    assert all(sha(p)==h for p,h in prepared['pins'].items())\n"
         "    assert INJECTOR.read_text()==recipe.transform(recipe.witness.INJECTOR.read_text())"),
        ('out.mkdir();(out/\'source\').mkdir()',
         "pins.update(prepared['pins'])\n"
         "    for p in (Path(witness.__file__).resolve(),Path(recipe.__file__).resolve(),INJECTOR.parent/'prepared.json'):\n"
         "        pins[str(p)]=sha(p)\n"
         "    out.mkdir();(out/'source').mkdir()"),
        ('parent_only=True,correctness=False','parent_only=False,endpoint_contract_only=True'),
        ("good=(code==1 and f'KBD-EARLY-READY-WHILE-INHIBITED hz={hz} phase={phase}' in text)\n"
         "        if phase>=21:good=code==0 and f'KBD-INHIBIT-OK hz={hz} phase={phase} retry=0 reset_cancel=1' in text",
         "good=(code==0 and f'KBD-INHIBIT-OK hz={hz} phase={phase} retry={int(phase<21)} reset_cancel=1' in text\n"
         "              and 'FATAL' not in text)"),
        ('expected_red=phase<21','expected_red=False'),
        ('witness_matrix_passed=good,correctness=False','candidate_matrix_passed=good,endpoint_contract_only=True'),
    )
    for old,new in edits:
        assert text.count(old)==1,old;text=text.replace(old,new)
    compile(text,__file__,'exec')
    return text


if __name__=='__main__':
    namespace=dict(witness.__dict__,__file__=__file__,recipe=recipe,witness=witness)
    namespace['INJECTOR']=witness.ROOT/'kbd-inhibit-candidate-r1/ven_ps2_kbd_inject.v'
    exec(compile(derive(),__file__,'exec'),namespace)
    raise SystemExit(namespace['main']())
