"""Bind unchanged processor checks to the prefix-opcode experiment.

Canonical failures stay failures. No masks, bands, fixtures or comparisons change.
"""
import ast
import hashlib
from pathlib import Path
import sys

REPO=Path(__file__).resolve().parents[2]
PARENT='e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6'
MODEL='14435a4d189ed3d0d441e14d356877cf6492c4c50077f80093b5d92ea8b4aff5'
SOURCES={
    'checks':('verif/sys/fp_env_store/run_write_checks.py','e22906bbc0c19d1e37ab59eb34539ecbc29ad2249b81f8f43c6608f8285bcb9d'),
    'replay':('verif/l1/run_window_current_same_input.py','60eaf87e536a6fc3a24467c4a294433cde3ccf484bcb7eaa919ee7b95a369890'),
    'system':('verif/segment_extent/run_fast_segment_system.py','8ce6e23f796cb5e366ee340c89a1ca3fa464c3af2f356a894efdcd9ec004a29e')}


def derive(mode):
    name,digest=SOURCES[mode]; source=REPO/name
    text=source.read_text(); assert hashlib.sha256(text.encode()).hexdigest()==digest
    if mode=='checks':
        substitutions=[
            ('import prepare_write_class as recipe','import prepare_prefix_opcode as recipe'),
            ('\nREPO=Path(__file__).resolve().parents[3]\n','\nREPO=Path(__file__).resolve().parents[2]\n'),
            ("parent=scratch/'ventium-data-size.v2HaTO2X/core-r1'","parent=scratch/'ventium-data-size.v2HaTO2X/prefix-payload-core-r1'"),
            ('fef9f3b6ad52a1dbf86ec19c8e6eb50dd79d3b4aa9f3601e35797cb93a62a041',PARENT),
            ('    env=dict(os.environ)','    pins['+repr(str(source))+']='+repr(digest)+'\n    env=dict(os.environ)')]
    elif mode=='replay':
        substitutions=[
            ('window-current-same-input-r1','prefix-opcode-same-input-r1'),
            ('window-current-func-r1','prefix-opcode-func-r1'),
            ('env-write-core-r1','prefix-payload-core-r1'),
            ('window-current-core-r1','prefix-opcode-core-r1'),
            ('360c79d44282f77b7deef21a8c4192258c549e85aacd51a80200bc1a62076779',PARENT),
            ('737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7',MODEL),
            ("    pins = dict(started['pins'])","    pins = dict(started['pins'])\n    pins["+repr(str(source))+']='+repr(digest))]
    else:
        substitutions=[
            ('import prepare_fast_segment as recipe','import prepare_prefix_opcode as recipe'),
            ('139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7',PARENT),
            ('1fb2f09e09ccddfca30ef2423e96226ddae40b4df44b4089204bed2cd79e505c',MODEL),
            ('for p in (Path(__file__),Path(recipe.__file__),',
             'for p in (Path('+repr(str(source))+'),Path('+repr(str(source.with_name('run_leaf.py')))+'),Path(__file__),Path(recipe.__file__),')]
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
    if mode=='system': sys.path.insert(0,str(REPO/'verif/segment_extent'))
    exec(compile(derive(mode)[0],str(__file__),'exec'),globals())
