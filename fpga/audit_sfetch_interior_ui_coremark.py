"""Regrade composed-model CRC controls against the exact fetch-size parent."""
import argparse
from pathlib import Path
from types import SimpleNamespace

import audit_retained_ui_coremark as previous
import build_sfetch_interior_ui_soc as integration
import run_sfetch_interior_ui_coremark as current_runner


def derive():
    assert integration.sha(previous.__file__) == 'c47e50b09583e60ec15ed7cc6e9af7f26972f1de887508476dca95c10d92fe9c'
    text = previous.derive()
    for old,new in (
        ('ventium-fprem-sequence.iSZ9BAj4/v-result-carry-soc-r1',
         'ventium-fprem-sequence.iSZ9BAj4/sfetch-interior-soc-r1'),
        ("assert build['binding_read_wire']=='kb_fifo_rdreq' and start['ui_disabled']",
         "assert build['binding_read_wire']=='kb_fifo_rdreq' and start['ui_disabled']\n"
         "assert soc == integration.ROOT/'sfetch-interior-ui-soc-r1'\n"
         "assert build['input_parent_model']==integration.UI_MODEL\n"
         "assert build['directed_model']==integration.cpu.CORE_MODEL"),
        ('for p in (ORIGINAL,Path(runner.__file__),',
         'for p in (Path(previous.__file__),Path(integration.__file__),ORIGINAL,Path(runner.__file__),'),
    ):
        assert text.count(old) == 1,old
        text = text.replace(old,new)
    compile(text,__file__,'exec')
    return text


if __name__ == '__main__':
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--soc',type=Path,required=True)
    args,_ = parser.parse_known_args()
    soc = args.soc.resolve(strict=True)
    assert soc == integration.ROOT/'sfetch-interior-ui-soc-r1'
    built = integration.load(soc/'build-closed.json')
    assert built['passed'] and built['inputs_unchanged'] and built['native_exit'] == 0
    runner = SimpleNamespace(MODEL=built['binary_sha256'],PARENT_MODEL=integration.PARENT_MODEL,
                             CONTROLLER=integration.ui.PS2_SHA,__file__=current_runner.__file__)
    namespace = dict(previous.__dict__,__file__=__file__,previous=previous,integration=integration,runner=runner)
    exec(compile(derive(),__file__,'exec'),namespace)
