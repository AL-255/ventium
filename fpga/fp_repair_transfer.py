"""Compose previously tested environment/FRNDINT repairs on the full PC.

No new RTL semantics. Every stage enforces its own exact input hash and the
finished bytes must match the independently tested whole-core candidate.
"""
import hashlib
import importlib.util
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def module(name, relative, digest):
    path = REPO / relative
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise ValueError('repair recipe drift: ' + relative)
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


restore = module('transfer_restore', 'verif/sys/fp_env_restore/prepare.py',
    'd149ca58f5cc90f7409bd384ce89cffc658311f54353e1fc3eec8e17a4b8c18b')
store = module('transfer_store', 'verif/sys/fp_env_store/prepare.py',
    '387c21c5a2e6247ad594c79dae8205474aede054bde91c0b5c38edff35da9c9a')
rounding = module('transfer_rounding', 'verif/sys/frndint/prepare.py',
    'b66cde024117f79eccb76f8348b9556b147b9be88d565d1b40d91c433c6aedc1')
PARENTS = {
    'fp_shared/ven_fp_misc.sv': '4ac4e9d37dc57f6af3fd2babe41a13df5069a2797ab7b6dd8b811ff511fe0161',
    'fp_shared/ven_fp_top.sv': 'de65098da526dd472b34ac0b46c664d55ef60617305cc93e7e68fafcf7a92c57',
    'rtl/core/core.sv': '27e3faf2f9d8f6a912748a0443a083f3fa1e50404e5368b7678ac72debec9b42',
    'rtl/fpu/fpu_x87_pkg.sv': 'ae0b7bdb71e8c3450a7704a70c4742cf04eba4cc17c7e82aba40361855c59a01',
}
RESULTS = {
    'fp_shared/ven_fp_misc.sv': '74130e7d43fd2e0a863fcc23702d31e4c96a7b824f1c04b3aa7a4bd9929339b7',
    'fp_shared/ven_fp_top.sv': '05bfa2a4d6eb1a3d3911b31a71c7d8ce1ec161d0e60f2408c6ae0061efb77aeb',
    'rtl/core/core.sv': '259b394486502308f7e745b0ab1e0b821a9461283f12173fb24c9856dfbb0f6a',
    'rtl/fpu/fpu_x87_pkg.sv': '03cd7681a72b9861863a77337cad29bbd9c49910b9f9190f0b5b52d109d0a071',
}


def transform(source, name):
    if name not in PARENTS or hashlib.sha256(source.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('FP repair transfer source drift/reapplication: ' + name)
    for stage in (restore, store, rounding):
        if name in stage.PARENTS:
            source = stage.transform(source, name)
    if hashlib.sha256(source.encode()).hexdigest() != RESULTS[name]:
        raise ValueError('FP repair transfer does not match tested core: ' + name)
    return source
