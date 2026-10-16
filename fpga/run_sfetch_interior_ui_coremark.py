"""Parallel cold CRC controls of the composed fetch/UI model, not full scores."""
import argparse
from pathlib import Path

import build_sfetch_interior_ui_soc as build
import run_retained_ui_coremark as previous


def derive():
    assert build.sha(previous.__file__) == '6a9792f61556acf9e538b22d30ad212c900c663c95f38bcd88367628aef23bb3'
    text = previous.derive()
    for old,new in (
        ('ventium-retained-ui-cm10-','ventium-sfetch-interior-ui-cm10-'),
        ("{'performance':4767218,'validation':4753406}","{'performance':4771298,'validation':4755366}"),
        ('for p in (ORIGINAL,Path(native_observation.__file__),',
         'for p in (Path(previous.__file__),Path(build.__file__),ORIGINAL,Path(native_observation.__file__),'),
        ("assert started['parent_model']==PARENT_MODEL and started['controller_sha256']==CONTROLLER",
         "assert started['parent_model']==PARENT_MODEL and started['controller_sha256']==CONTROLLER\n"
         "assert soc == build.ROOT/'sfetch-interior-ui-soc-r1'\n"
         "assert started['input_parent_model']==build.UI_MODEL and started['directed_model']==build.cpu.CORE_MODEL\n"
         "assert json.loads((soc/'build-wait-closed.json').read_text())['passed']"),
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
    assert soc == build.ROOT/'sfetch-interior-ui-soc-r1'
    done = build.load(soc/'build-closed.json')
    assert done['passed'] and done['inputs_unchanged'] and done['native_exit'] == 0
    assert build.stable(build.load(soc/'build-started.json')['pins'])
    namespace = dict(previous.__dict__,__file__=__file__,previous=previous,build=build,
                     MODEL=done['binary_sha256'],PARENT_MODEL=build.PARENT_MODEL)
    exec(compile(derive(),__file__,'exec'),namespace)
