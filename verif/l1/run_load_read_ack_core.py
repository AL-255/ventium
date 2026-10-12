#!/usr/bin/env python3
"""Run unchanged corpora with equal, complete rem-split feature profiles.

Only profile admission changes from the prior timing driver. All state/cycle
comparisons, fixtures, failure handling and actual-pair witnesses are retained.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import run_payload_code_hint_core as corpus
import run_canonical_same_input_ab as canonical


def adapt(source, suite):
    replace = corpus.replace_once
    if suite == 'canonical':
        text = replace(source, '    assert profiles[0]==profiles[1] and len(profiles[0])==150',
                       '    assert profiles[0]==profiles[1] and len(profiles[0])==152')
        return 'import sys\nsys.path.insert(0, '+repr(str(corpus.base.HERE))+')\n'+text
    text = corpus.base.adapt(source, suite)
    if suite == 'fp':
        text = replace(text, "added = {'"+corpus.base.FLAG+"'}", 'added = set()')
    elif suite == 'integer':
        text = replace(text, "    flag = '"+corpus.base.FLAG+"'\n", '')
        text = replace(text, "    assert flag not in profiles['control']\n"
                       "    assert profiles['candidate'] == profiles['control'] | {flag}",
                       "    assert profiles['candidate'] == profiles['control']")
    else:
        raise ValueError('unsupported corpus')
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=('fp','integer','canonical'), required=True)
    parser.add_argument('--out', type=Path, required=True)
    args, extra = parser.parse_known_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = args.out.resolve()
    assert __debug__ and out != scratch and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    source = Path(canonical.__file__) if args.suite=='canonical' else corpus.SOURCES[args.suite]
    driver = out.with_suffix('.driver.py')
    with driver.open('x') as stream:
        stream.write(adapt(source.read_text(),args.suite))
    pins = {str(p):corpus.base.sha(p) for p in
            (Path(__file__),source,driver,Path(corpus.__file__),Path(corpus.base.__file__))}
    command = [sys.executable,'-B',str(driver),'--out',str(out),*extra]
    with out.with_suffix('.driver.json').open('x') as stream:
        json.dump(dict(command=command,pins=pins,suite=args.suite,added_defines=[],
            complete_architectural_comparison=True,complete_cycle_equality_required=True,
            standard_suite=False,gameplay_ipc=None),stream,indent=2)
    status = subprocess.run(command).returncode
    assert all(corpus.base.sha(p)==h for p,h in pins.items())
    return status


if __name__=='__main__': raise SystemExit(main())
