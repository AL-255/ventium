"""Independently recheck the sealed parallel-admission hardware source set."""
import argparse
import inspect
import json
from pathlib import Path

import freeze_parallel_write_rk_candidate as export
import system_read_ack_evidence as template

native = export.native
MANIFEST = 'e745cf4cffcf5143298293e021b678803204fa18dbd32328b2079c481743143f'
MODEL, VARIANT = export.MODEL, export.VARIANT


def check(source):
    assert native.sha(template.__file__) == '4eaed2e81c4503bf5004af8e0725b9fa0ec900cd15bc23d67725200a00f40207'
    source = Path(source).resolve(strict=True)
    assert source == native.ROOT/'parallel-write-fpga-r1'
    text = native.recipe.once(inspect.getsource(template.check),
        '(Path(__file__).resolve(),Path(export.__file__).resolve(),Path(native.__file__).resolve(),',
        '(Path(__file__).resolve(),Path(template.__file__).resolve(),Path(export.__file__).resolve(),Path(native.__file__).resolve(),')
    scope = dict(template.__dict__, __file__=__file__, template=template, native=native,
                 export=export, MANIFEST=MANIFEST, MODEL=MODEL, VARIANT=VARIANT)
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
    with (source/'source-audit.json').open('x') as stream: json.dump(result, stream, indent=2)
    print(json.dumps(result))
