"""Independent closure/CRC/tick audit of the UI-disabled two-seed controls."""
import hashlib
from pathlib import Path

import run_retained_ui_coremark as runner

ORIGINAL=Path(__file__).with_name('audit_v_carry_payload_coremark.py')
SOURCE_SHA='c674a2804c03d6bf97724a3eff620fffea4cdd253b38aca0a12a9adda0d23103'


def derive():
    assert hashlib.sha256(ORIGINAL.read_bytes()).hexdigest()==SOURCE_SHA
    text=ORIGINAL.read_text()
    for old,new in (
        ("root = soc / 'coremark'","root = soc / 'coremark-ui-disabled-r1'"),
        ("parent = scratch / 'ventium-fp-exec-cut.MNkzxfBO/soc'",
         "parent = scratch / 'ventium-fprem-sequence.iSZ9BAj4/v-result-carry-soc-r1'"),
        ("assert start['model'] == load(soc/'build-closed.json')['binary_sha256']",
         "assert start['model'] == load(soc/'build-closed.json')['binary_sha256'] == runner.MODEL\n"
         "build=load(soc/'build-started.json')\n"
         "assert build['parent_model']==runner.PARENT_MODEL and build['controller_sha256']==runner.CONTROLLER\n"
         "assert build['processor_rtl_changes']==[] and build['added_defines']==[]\n"
         "assert build['binding_read_wire']=='kb_fifo_rdreq' and start['ui_disabled']"),
        ("native['affinity'] == [11]","native['affinity'] == [12 if seed=='performance' else 13]"),
        ("    log = (work/'run.log').read_text()",
         "    log = (work/'run.log').read_text()\n    assert '[UI-' not in log and '--ui-fifo' not in argv"),
        ("for p in (Path(__file__),root/'started.json'",
         "for p in (ORIGINAL,Path(runner.__file__),Path(__file__),root/'started.json'"),
    ):
        text=runner.once(text,old,new)
    assert text.count("parent/'coremark/")==4
    text=text.replace("parent/'coremark/","parent/'coremark-r1/")
    compile(text,__file__,'exec')
    return text


if __name__=='__main__':exec(compile(derive(),__file__,'exec'),globals())
