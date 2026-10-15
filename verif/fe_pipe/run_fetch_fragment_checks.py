"""Bind the unchanged processor checks to the fetch-fragment extent candidate.

Canonical reference failures remain failures. The installed cache identity
repair is explicitly pinned by this candidate's build; comparison policy,
fixtures, modes, cycle bands and limits are unchanged.
"""
import ast
import hashlib
from pathlib import Path
import sys

import run_prefix_opcode_checks as base

BASE_SHA='f95fd93a150d7f014da628b6d59bcb8edc93380d4178ddbd3ae819c0e7b3d372'
MODEL='0698ce2f2e0de10ec1952704b63b40fd70fc8cbb682171d5ed83cade6e612c6c'


def derive(mode):
    path=Path(base.__file__)
    assert hashlib.sha256(path.read_bytes()).hexdigest()==BASE_SHA
    text,_=base.derive(mode)
    substitutions=[]
    if mode!='replay':
        substitutions.append(('import prepare_prefix_opcode as recipe',
                              'import prepare_fetch_fragment_extent as recipe'))
    if mode in ('replay','system'):
        substitutions.append((base.MODEL,MODEL))
    if mode=='replay':
        for suffix in ('same-input-r1','func-r1','core-r1'):
            substitutions.append(('prefix-opcode-'+suffix,'fetch-fragment-'+suffix))
    anchor={'checks':'    env=dict(os.environ)',
            'replay':'    golden_by_name = {}',
            'system':'    qemu=REPO/'}[mode]
    substitutions.append((anchor,'    pins['+repr(str(path))+']='+repr(BASE_SHA)+'\n'+anchor))
    for before,after in substitutions:
        assert text.count(before)==1,before
        text=text.replace(before,after)
    ast.parse(text)
    return text,substitutions


if __name__=='__main__':
    mode=sys.argv[1]
    assert mode in ('canonical','func','replay','system')
    if mode in ('replay','system'): sys.argv.pop(1)
    else: mode='checks'
    if mode=='system': sys.path.insert(0,str(base.REPO/'verif/segment_extent'))
    exec(compile(derive(mode)[0],str(__file__),'exec'),globals())
