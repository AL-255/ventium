#!/usr/bin/env python3
"""Difference cumulative simulator observations, never architectural vtraces.

Samples inside the inclusive requested cycle range are used; report their
actual endpoints. Legacy logs support IPC only. Counter families overlap:
their percentages must not be added together. No FPS or silicon IPC inference.
"""
import argparse
import re
import sys

PROGRESS = re.compile(r"^\[\s*(\d+)\] retires=(\d+)\b")
ARRAYS = {"state", "mem_wait", "mem_ack", "bail", "alu_load",
          "alu_load_wait", "alu_load_ack"}
REQUIRED = {"cycle", "retires", "clocks", "u", "v", "load_wait",
            "store_wait"} | ARRAYS


def samples(lines, start=0, end=None):
    """Keep only endpoints, using O(one sample) memory even for large logs."""
    bounds = {"profile": [None, None], "legacy": [None, None]}
    previous = {}
    for line in lines:
        # Combined stdout/stderr can prepend an unfinished diagnostic to a
        # complete profiler record. Keep strict field validation after the
        # marker; never attempt to repair records split inside their fields.
        marker = line.find("[VEN-PERF] cycle=")
        if marker >= 0:
            line = line[marker:]
            fields = dict(part.split("=", 1) for part in line.split()[1:])
            if not REQUIRED <= fields.keys():
                raise ValueError("incomplete VEN-PERF sample")
            sample = {k: tuple(int(n) for n in v.split(",")) if k in ARRAYS
                      else int(v) for k, v in fields.items()}
            kind = "profile"
        else:
            match = PROGRESS.match(line)
            if not match:
                continue
            sample = dict(zip(("cycle", "retires"), map(int, match.groups())))
            kind = "legacy"
        # Validate every sample, including those outside the requested range.
        # Concatenated/restarted runs must never silently yield a bogus delta.
        if kind in previous:
            delta(previous[kind], sample)
        previous[kind] = sample
        if sample["cycle"] < start or (end is not None and sample["cycle"] > end):
            continue
        pair = bounds[kind]
        if pair[0] is None:
            pair[0] = sample
        pair[1] = sample
    # Fall back only when no profile observations exist in the interval.
    # One profile observation is not sufficient for a counter delta.
    pair = bounds["profile"] if bounds["profile"][0] is not None else bounds["legacy"]
    if pair[0] is None or pair[0]["cycle"] == pair[1]["cycle"]:
        raise ValueError("need at least two samples within the requested interval")
    return pair


def delta(first, last):
    if first.keys() != last.keys():
        raise ValueError("sample schema changed")
    result = {}
    for key in first:
        a, b = first[key], last[key]
        if isinstance(a, tuple):
            if len(a) != len(b):
                raise ValueError(f"counter length changed: {key}")
            value = tuple(y - x for x, y in zip(a, b))
            negative = any(n < 0 for n in value)
        else:
            value = b - a
            negative = value < 0
        if negative:
            raise ValueError(f"counter decreased (reset/concatenated log?): {key}")
        result[key] = value
    return result


def report(first, last):
    d = delta(first, last)
    if d["cycle"] <= 0:
        raise ValueError("empty cycle interval")
    lines = [f"Actual interval: {first['cycle']:,}..{last['cycle']:,}",
             f"Retired instructions: {d['retires']:,}",
             f"Simulation cycles: {d['cycle']:,}",
             f"IPC: {d['retires'] / d['cycle']:.6f}",
             f"CPI: {d['cycle'] / d['retires']:.6f}" if d['retires'] else
             "CPI: undefined (no retirement)"]
    if "clocks" not in d:
        return "\n".join(lines + ["Legacy log: no interval stall counters available."])
    clocks = d["clocks"]
    # These count retire_valid/retire2_valid, including slow-path primary
    # retirements. They are not fast-path issue counts or pairing eligibility.
    observed_retires = d["u"] + d["v"]
    lines += [f"Profile clocks: {clocks:,}",
              f"Primary retirement events: {d['u']:,}",
              f"Secondary retirement events: {d['v']:,}",
              (f"Secondary share of profiler retirements: {100 * d['v'] / observed_retires:.2f}%"
               if observed_retires else "Secondary share of profiler retirements: undefined"),
              "Counter families overlap; do not sum percentages."]
    for key in ("load_wait", "store_wait", "state", "mem_wait", "alu_load",
                "alu_load_wait", "bail", "mem_ack", "alu_load_ack"):
        values = d[key] if isinstance(d[key], tuple) else (d[key],)
        entries = sorted(enumerate(values), key=lambda item: (-item[1], item[0]))
        # pp_bail records the first rejecting arm on each S_PIPE clock, not
        # a count of distinct instructions. Acknowledgements are events.
        is_cycles = key not in {"mem_ack", "alu_load_ack"}
        for index, value in entries:
            if not value:
                continue
            label = f"{key}[{index}]" if isinstance(d[key], tuple) else key
            suffix = f" ({100 * value / clocks:.2f}% of profile clocks)" if is_cycles and clocks else ""
            lines.append(f"  {label}: {value:,}{suffix}")
    return "\n".join(lines)


def slow_samples(lines, start=0, end=None):
    first = last = previous = None
    pattern = re.compile(r"\[VEN-SLOW-DECODE\] cycle=(\d+) prefixed=(\d+) clocks=([0-9,]+)\s*$")
    for line in lines:
        if "[VEN-SLOW-DECODE]" not in line:
            continue
        match = pattern.search(line)
        if not match:
            raise ValueError("malformed slow-decode sample")
        cycle, prefixed, values = match.groups()
        clocks = tuple(map(int, values.split(',')))
        if len(clocks) != 513:
            raise ValueError("slow-decode requires 513 opcode buckets")
        sample = dict(cycle=int(cycle), prefixed=int(prefixed), clocks=clocks)
        if sample['prefixed'] > sum(clocks):
            raise ValueError("prefixed clocks exceed decode residency")
        if previous is not None:
            d = delta(previous, sample)
            if d['prefixed'] > sum(d['clocks']) or sum(d['clocks']) > d['cycle']:
                raise ValueError("inconsistent slow-decode interval")
        previous = sample
        if sample['cycle'] < start or (end is not None and sample['cycle'] > end):
            continue
        if first is None:
            first = sample
        last = sample
    if first is None or first['cycle'] == last['cycle']:
        raise ValueError("need at least two slow-decode samples within the requested interval")
    return first, last


def slow_report(first, last):
    d = delta(first, last)
    total = sum(d['clocks'])
    lines = [f"Actual interval: {first['cycle']:,}..{last['cycle']:,}",
             f"Slow-decode residency: {total:,} clocks",
             f"Prefixed residency: {d['prefixed']:,} clocks (subset)",
             "Includes holds/retries; these are NOT instruction or retirement counts."]
    for index, value in sorted(enumerate(d['clocks']), key=lambda item: (-item[1], item[0])):
        if not value:
            continue
        label = (f"{index:02x}" if index < 256 else
                 f"0f {index - 256:02x}" if index < 512 else "unavailable/overlength")
        lines.append(f"  {label}: {value:,} ({100 * value / total:.2f}% of decode clocks)")
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log")
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--end", type=int)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--slow-decode", action="store_true",
                        help="report host-side slow-decode opcode residency instead of IPC")
    modes.add_argument("--uop-map", action="store_true",
                       help="classify resident predecode-map holes in the selected interval")
    args = parser.parse_args()
    try:
        if args.start < 0 or (args.end is not None and args.end < args.start):
            raise ValueError("invalid cycle range")
        with open(args.log) as stream:
            reader, writer = ((umap_samples, umap_report) if args.uop_map else
                              (slow_samples, slow_report) if args.slow_decode else
                              (samples, report))
            first, last = reader(stream, args.start, args.end)
        print(writer(first, last))
    except (OSError, ValueError) as exc:
        print(f"cpi_interval: {exc}", file=sys.stderr)
        return 2
    return 0


UMAP_CLASSES = ('fp', 'nonsimple', 'simple_mem', 'fastctx', 'sysblock')
UMAP_ARRAYS = ('fastend', 'would_issue_end')
UMAP_END_NAMES = ('none/invalid', 'physical line end', 'slot capacity',
                  'foreground step cap', 'unknown grammar', 'known cross-line form')


def umap_valid(sample):
    """The RTL classifies each raw hole once; subpopulations overlap it."""
    if any(n < 0 for v in sample.values() for n in (v if isinstance(v, tuple) else (v,))):
        raise ValueError('negative uop-map counter')
    if any(len(sample[k]) != 6 for k in UMAP_ARRAYS):
        raise ValueError('uop-map requires six walker-end buckets')
    if sum(sample[k] for k in UMAP_CLASSES) != sample['raw']:
        raise ValueError('uop-map classes do not partition raw holes')
    if (sum(sample['fastend']) != sample['fastctx'] or
            sum(sample['would_issue_end']) != sample['would_issue'] or
            sample['would_issue'] > sample['fastctx'] or
            any(a > b for a, b in zip(sample['would_issue_end'], sample['fastend']))):
        raise ValueError('inconsistent uop-map subsets')
    if sample['raw'] > sample['cycle']:
        raise ValueError('uop-map holes exceed elapsed clocks')


def umap_samples(lines, start=0, end=None):
    first = last = previous = None
    required = {'cycle', 'raw', 'would_issue', *UMAP_CLASSES, *UMAP_ARRAYS}
    for line in lines:
        marker = line.find('[VEN-UMAP]')
        if marker < 0:
            continue
        fields = dict(part.split('=', 1) for part in line[marker:].split()[1:])
        if fields.keys() != required:
            raise ValueError('incomplete or unknown VEN-UMAP schema')
        sample = {k: tuple(map(int, v.split(','))) if k in UMAP_ARRAYS else int(v)
                  for k, v in fields.items()}
        umap_valid(sample)
        if previous is not None:
            umap_valid(delta(previous, sample))
        previous = sample
        if sample['cycle'] < start or (end is not None and sample['cycle'] > end):
            continue
        if first is None:
            first = sample
        last = sample
    if first is None or first['cycle'] == last['cycle']:
        raise ValueError('need at least two uop-map samples within the requested interval')
    return first, last


def umap_report(first, last):
    d = delta(first, last)
    lines = [f"Actual interval: {first['cycle']:,}..{last['cycle']:,}",
             f"Resident map-hole clocks: {d['raw']:,}",
             'Observations, not retired instructions or guaranteed recoverable cycles.']
    for key in (*UMAP_CLASSES, 'would_issue'):
        lines.append(f"  {key}: {d[key]:,} ({100 * d[key] / d['cycle']:.2f}% of interval clocks)")
    lines.append('would_issue is a subset of fastctx; do not add them.')
    for key in UMAP_ARRAYS:
        lines.append(key + ':')
        for name, value in zip(UMAP_END_NAMES, d[key]):
            if value:
                lines.append(f'  {name}: {value:,}')
    return '\n'.join(lines)


if __name__ == "__main__":
    sys.exit(main())
