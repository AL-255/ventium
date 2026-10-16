"""Independently verify the sealed two-file FPGA export; no acceptance grant."""
import argparse
import inspect
import json
from pathlib import Path

import freeze_qualified_pair_credit_rk_candidate as export
import system_read_ack_evidence as previous

native = export.native
MANIFEST = 'ad6b7c19643faf50a98d12d96d0edaa018716566d64bd0d498566156570b7964'
MODEL, VARIANT = export.MODEL, export.VARIANT


def check(source):
    assert native.sha(previous.__file__) == '4eaed2e81c4503bf5004af8e0725b9fa0ec900cd15bc23d67725200a00f40207'
    text = inspect.getsource(previous.check)
    old = '(Path(__file__).resolve(),Path(export.__file__).resolve(),Path(native.__file__).resolve(),'
    assert text.count(old) == 1
    text = text.replace(old, '(Path(__file__).resolve(),Path(previous.__file__).resolve(),Path(export.__file__).resolve(),Path(native.__file__).resolve(),')
    scope = dict(previous.__dict__, __file__=__file__, previous=previous,
                 native=native, export=export, MANIFEST=MANIFEST, MODEL=MODEL, VARIANT=VARIANT)
    exec(compile(text, __file__, 'exec'), scope)
    return scope['check'](source)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    source = ap.parse_args().source.resolve(strict=True)
    pins = check(source)
    result = dict(source_seal_checked=True, pins_checked=len(pins), manifest_sha256=MANIFEST,
                  processor_model=MODEL, changed_payloads=export.CHANGES, full_wrapper_elaborated=False,
                  canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False,
                  fmax_mhz=None, gameplay_ipc=None)
    with (source/'source-audit.json').open('x') as f:
        json.dump(result, f, indent=2)
    print(json.dumps(result))
