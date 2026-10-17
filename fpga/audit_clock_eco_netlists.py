"""Require an unchanged exported SoC netlist across a clock-leaf replacement."""
import argparse
import hashlib
import json
from pathlib import Path


def logical_hash(path):
    digest = hashlib.sha256()
    modules = 0
    with path.open('rb') as stream:
        for line in stream:
            # Vivado's leading // banner carries export time and output path.
            # Comments/blank lines have no logic; all attributes/code are kept.
            if line.lstrip().startswith(b'//') or not line.strip():
                continue
            modules += line.startswith(b'module ')
            digest.update(line)
    if modules < 100:
        raise ValueError('missing full SoC hierarchy')
    return dict(sha256=digest.hexdigest(), modules=modules)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    before, after = logical_hash(args.before), logical_hash(args.after)
    result = dict(before=before, after=after, identical=before==after)
    with args.out.open('x') as stream:
        json.dump(result, stream, indent=2)
    if before != after:
        raise ValueError('clock repair changed the SoC logical export')
    print('CLOCK-ECO-SOC-UNCHANGED', before['sha256'])


if __name__ == '__main__': main()
