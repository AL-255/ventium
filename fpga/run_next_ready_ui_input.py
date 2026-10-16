"""Run the unchanged cold keyboard guest against the composed timing/UI PC."""
import inspect
from pathlib import Path
import sys

import build_next_ready_ui_soc as build

sys.path.insert(0,str(build.cpu.REPO/'verif/ps2_ui'))
import run_retained_pc_input as previous


def derive():
    assert build.sha(previous.__file__) == '9e0f06cca2b51c1bd0a18ae4fe46e977fed04b93a54d7c09aef88db1817c946a'
    text = inspect.getsource(previous.main)
    old = "    assert not start['original_transport_gate_passed'] and not start['full_pc_input_qualified']"
    new = ("    assert soc == build.ROOT/'next-ready-ui-soc-r1'\n"
           "    assert start['parent_model'] == build.PARENT_MODEL\n"
           "    assert start['input_parent_model'] == build.UI_MODEL\n"
           "    assert start['directed_model'] == build.cpu.CORE_MODEL\n"
           "    assert start['binding_read_wire'] == 'kb_fifo_rdreq'")
    assert text.count(old) == 1; text = text.replace(old,new)
    old = 'for p in (Path(__file__),model,'
    assert text.count(old) == 1
    text = text.replace(old,'for p in (Path(__file__),Path(previous.__file__),Path(build.__file__),model,')
    compile(text,__file__,'exec')
    return text


if __name__ == '__main__':
    namespace = dict(previous.__dict__,__file__=__file__,previous=previous,build=build)
    exec(compile(derive(),__file__,'exec'),namespace)
    raise SystemExit(namespace['main']())
