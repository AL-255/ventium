"""Retain strict CPU lint for the exact qualified-pair-credit FPGA export."""
from pathlib import Path

import freeze_qualified_pair_credit_rk_candidate as export
import lint_system_read_ack_rk as template


def derive():
    assert export.native.sha(template.__file__) == 'bf31a1cf7dd841650ac06c37a0015f3684859f5848c4688cbd609617be3103b6'
    text = template.derive()
    before = '(Path(__file__),Path(previous.__file__),original,driver,Path(export.__file__))'
    after = '(Path(__file__),Path(template.__file__),Path(previous.__file__),original,driver,Path(export.__file__))'
    assert text.count(before) == 1
    return text.replace(before, after)


def main():
    scope = dict(template.previous.__dict__, __file__=__file__, template=template,
                 previous=template.previous, export=export)
    exec(compile(derive(), __file__, 'exec'), scope)
    return scope['main']()


if __name__ == '__main__':
    raise SystemExit(main())
