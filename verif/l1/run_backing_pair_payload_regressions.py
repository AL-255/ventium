"""Keep the whole-core regression plan unchanged for the backing-payload cut.

Only exact parent/candidate identities change. Full architectural comparisons,
cycle equality, FP-matrix prerequisite, fault priorities and red canonical
status remain authoritative; there is no synthesis or physical-board waiver.
"""
import hashlib
from pathlib import Path

original=Path(__file__).with_name('run_fp_high_valid_regressions.py')
text=original.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='f850f47f0439d7ff0f896f12f862ef23720b8492713e90b5957b9f6730906b01'
old='from build_fp_high_valid_core import MODEL as PARENT_MODEL'
assert text.count(old)==1
text=text.replace(old,"PARENT_MODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'")
old="MODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'"
# Do not replace the new PARENT_MODEL suffix by substring accident.
assert text.count('\n'+old+'\n')==1
text=text.replace('\n'+old+'\n',"\nMODEL='4c410b962f602cbb52d402c2072413ec74bc4d2fb020d392511d4637db24ec15'\n")
old="pins={str(Path(__file__).resolve()):sha(__file__)}"
assert text.count(old)==1
text=text.replace(old,old+"\n    pins[str(Path(__file__).with_name('run_fp_high_valid_regressions.py'))]=sha(Path(__file__).with_name('run_fp_high_valid_regressions.py'))")
exec(compile(text,str(Path(__file__)),'exec'),globals())
