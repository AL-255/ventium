"""Cold page-fault repair/retry with the complete unchanged QEMU comparator.

Only the fixture, case selection and explicit AXI latency differ from the
qualified fault driver. This is an isolated SMSW model, not FPGA acceptance.
"""
import ast
import hashlib
from pathlib import Path

import prepare_retry as fixture

original=Path(__file__).with_name('run_fault.py')
text=original.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='112cc52b128e4d38b26f50d285ff6e7bceb55d665050cd933a2888c42110e26f'


def change(old,new,count=1):
    global text
    assert text.count(old)==count,old
    text=text.replace(old,new)


change('"""'+ast.get_docstring(ast.parse(text),clean=False)+'"""',repr(__doc__))
change('    args = ap.parse_args()',
       "    ap.add_argument('--latency',type=int,choices=(0,7,31),required=True)\n    args = ap.parse_args()")
change("assert sha(model) == built['binary_sha256']",
       "assert sha(model) == built['binary_sha256'] == 'cbf749f16babd88fb5dcf508c2381d48b77dedd348e9b23a5ed9083de9f4e65e'")
change("(Path(__file__),HERE/'run_probe.py',HERE/'fault.S',HERE/'fault.ld',",
       "(Path(__file__),original,Path(fixture.__file__),HERE/'run_probe.py',HERE/'fault.S',HERE/'fault.ld',")
change("AXI_RLAT='7',AXI_WLAT='7'","AXI_RLAT=str(args.latency),AXI_WLAT=str(args.latency)")
change('range(9)','range(4,9)',2)
change('    root.mkdir()\n',
       "    root.mkdir()\n    source=root/'retry.S'\n"
       "    source.write_text(fixture.transform((HERE/'fault.S').read_text()))\n"
       "    pins[str(source)]=sha(source)\n")
change('affinity=cpus,definitions=before', 'affinity=cpus,axi_latency=args.latency,definitions=before')
change("'-c',HERE/'fault.S','-o',obj]", "'-c',source,'-o',obj]")
change("len(result['rows'])==45", "len(result['rows'])==25")
exec(compile(text,str(Path(__file__)),'exec'),globals())
