"""Exact eight-file repair composition from the last synthesized FPGA source."""
from pathlib import Path

import fp_repair_transfer as pc

lmsw = pc.module('hardware_lmsw', 'verif/sys/lmsw/prepare_lmsw.py',
    'eb9e9d3b3a95280942d9b0fd3166f908ca840f8535f8f15d4b5862896205ce0d')
extent = pc.module('hardware_extent', 'verif/segment_extent/prepare.py',
    'ea998bca6550c15d5675195ad8f84c94ec3143c2db6f9d55d442318bb32681c1')
obsolete = pc.module('hardware_obsolete', 'verif/sys/obsolete_fp/prepare_repaired.py',
    '19d75c46aae59a021df2bb110e59edfb582c127e3c2013f9d1b756fd45fc7bde')
CHANGES = sorted(set(pc.PARENTS) | {'rtl/core/' + name for name in lmsw.PARENTS})


def transform(source, name):
    if name not in CHANGES:
        raise ValueError('unreviewed hardware transfer: ' + name)
    if name.startswith('rtl/core/') and Path(name).name in lmsw.PARENTS:
        source = lmsw.transform(source, Path(name).name)
    if name == extent.FILE:
        source = extent.transform(source)
    if name.startswith('rtl/core/') and Path(name).name in obsolete.PARENTS:
        source = obsolete.transform(source, Path(name).name)
    if name in pc.PARENTS:
        source = pc.transform(source, name)
    return source
