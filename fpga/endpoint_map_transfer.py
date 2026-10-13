"""Exact four-file SMSW + endpoint-map transfer from the PRIME-REG PC image."""
import importlib.util
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'verif/l1'))
import prepare_endpoint_map as endpoint

spec = importlib.util.spec_from_file_location('endpoint_transfer_smsw',
    REPO/'verif/sys/smsw_memory/prepare.py')
smsw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smsw)
PARENTS = {'rtl/core/'+name:digest for name,digest in smsw.PARENTS.items()}
PARENTS[endpoint.FILE] = endpoint.PARENT


def transform(source, name):
    if name == endpoint.FILE:
        return endpoint.transform(source)
    if name in PARENTS:
        return smsw.transform(source,Path(name).name)
    raise ValueError('unreviewed SMSW/endpoint transfer file: '+name)
