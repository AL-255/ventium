#!/usr/bin/env python3
"""Summarize existing Vivado full-clock setup reports; never launch Vivado.

These are reported path delays, not RTL ownership or physically measured Fmax.
Only same-clock, single-period paths are admitted for the frequency estimate.
The input report is hashed and untouched. Optional regex markers partition each
path's *data* delay (not clock insertion delay), with an explicit remainder.
Optimized/routed reports require an explicit expected state; even a routed
report is not a complete timing, exception, or hardware acceptance audit.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re


NUMBER = r"[-+]?\d+\.\d+"
STATES = ('Synthesized', 'Optimized', 'Routed')


def require(pattern, text):
    matches = re.findall(pattern, text, re.M)
    if len(matches) != 1:
        raise ValueError(f"expected one match: {pattern!r}, got {len(matches)}")
    return matches[0]


def parse_path(block, markers=()):
    source = require(r"^  Source:\s+(\S+)$", block)
    destination = require(r"^  Destination:\s+(\S+)$", block)
    group = require(r"^  Path Group:\s+(\S+)$", block)
    require(r"^  Path Type:\s+Setup \(Max at .+ Process Corner\)$", block)
    clocks = re.findall(r"clocked by (\S+)\s+\{[^}\n]*period=(" + NUMBER + r")ns\}", block)
    if len(clocks) != 2 or clocks[0] != clocks[1] or clocks[0][0] != group:
        raise ValueError("frequency estimate requires two identical endpoint clocks")
    period = float(clocks[0][1])
    requirement = float(require(r"^  Requirement:\s+(" + NUMBER + r")ns.*$", block))
    if period <= 0 or abs(period - requirement) > .001:
        raise ValueError("not a positive, single-period setup requirement")
    verdict, slack = require(r"^Slack \((MET|VIOLATED)\)\s*:\s*(" + NUMBER + r")ns.*$", block)
    slack = float(slack)
    if (slack >= 0) != (verdict == 'MET'):
        raise ValueError("slack sign disagrees with verdict")
    total, logic, route = map(float, require(
        r"^  Data Path Delay:\s+(" + NUMBER + r")ns\s+\(logic (" + NUMBER +
        r")ns \([^)]+\)\s+route (" + NUMBER + r")ns \([^)]+\)\)$", block))
    if abs(total - logic - route) > .002:
        raise ValueError("data-delay summary does not add up")
    levels = int(require(r"^  Logic Levels:\s+(\d+)\s+.*$", block))
    scd = float(require(r"^    Source Clock Delay\s+\(SCD\):\s+(" + NUMBER + r")ns$", block))
    row_pattern = re.compile(r"^\s*(.*?)\s+(" + NUMBER + r")\s+(" + NUMBER +
                             r")\s+(?:[rf]\s+)?(\S+)\s*$")
    rows = []
    inside = False
    finished = False
    pending = ""
    last = scd
    for line in block.splitlines():
        # The source clock pin appears once in the expanded source-clock path.
        if not inside:
            if re.search(r"\s[rf]\s+" + re.escape(source) + r"$", line):
                inside = True
            continue
        if re.search(r"\s[rf]\s+" + re.escape(destination) + r"$", line):
            finished = True
            break
        if not line.strip() or set(line.strip()) <= {"-", " "}:
            continue
        match = row_pattern.match(line)
        if not match:
            if pending or not re.fullmatch(
                    r"\s*(?:\w+_X\d+Y\d+\s+)?\w+ \(Prop_[^)]+\)\s*", line):
                raise ValueError(f"unparsed data-path row: {line!r}")
            pending = line.strip()
            continue
        kind, increment, arrival, resource = match.groups()
        kind = kind.strip() or pending
        if pending and kind != pending:
            raise ValueError("unconsumed wrapped timing row")
        pending = ""
        increment, arrival = float(increment), float(arrival)
        if not kind or abs(arrival - last - increment) > .0021:
            raise ValueError(f"discontinuous data path at {resource}")
        rows.append(dict(kind=kind, increment_ns=increment, arrival_ns=arrival,
                         data_elapsed_ns=round(arrival - scd, 6), resource=resource))
        last = arrival
    if not finished or pending or not rows or abs(last - scd - total) > .0021:
        raise ValueError("incomplete data path or arrival disagrees with summary")
    required = float(require(r"^\s+required time\s+(" + NUMBER + r")\s*$", block))
    arrival = float(require(r"^\s+arrival time\s+(" + NUMBER + r")\s*$", block))
    footer_slack = float(require(r"^\s+slack\s+(" + NUMBER + r")\s*$", block))
    if abs(arrival + last) > .0021 or abs(required + arrival - slack) > .0021 or abs(footer_slack - slack) > .0021:
        raise ValueError("arrival/required/slack footer disagrees with data path")
    if period - slack <= 0:
        raise ValueError("nonpositive derived period")
    cuts = []
    for label, pattern in markers:
        hits = [r for r in rows if re.search(pattern, r['resource'])]
        if hits:
            # A marker is a named net, not an inferred boundary of an RTL block.
            if len(hits) != 1:
                raise ValueError(f"ambiguous marker {label!r}: {len(hits)} rows")
            cuts.append((hits[0]['data_elapsed_ns'], label, hits[0]['resource']))
    cuts.sort()
    segments = []
    previous = 0.0
    for end, label, resource in cuts + [(total, 'endpoint', destination)]:
        segments.append(dict(through=label, resource=resource,
            delay_ns=round(end - previous, 6), data_elapsed_ns=end))
        previous = end
    family = re.sub(r"\[\d+\]", "[*]", destination)
    return dict(source=source, destination=destination, destination_family=family,
        clock=group, period_ns=period, requirement_ns=requirement, slack_ns=slack,
        estimate_mhz=1000 / (period - slack), data_delay_ns=total,
        logic_delay_ns=logic, route_delay_ns=route, logic_levels=levels,
        source_clock_delay_ns=scd, segments=segments, rows=rows)


def analyze(text, markers=(), *, expected_state='Synthesized'):
    if expected_state not in STATES:
        raise ValueError("unsupported expected design state")
    state = require(r"^\| Design State\s*:\s*(.+)$", text).strip()
    if state != expected_state:
        raise ValueError(f"expected {expected_state.lower()} report, got {state!r}")
    command = require(r"^\| Command\s*:\s*(.+)$", text)
    # Native report_timing may omit its default max-delay option. Validate
    # every path's explicit Setup/Max type below instead of assuming it.
    if (not command.startswith('report_timing ') or
        '-path_type full_clock_expanded' not in command or
        re.search(r'(?:^|\s)-hold(?:\s|$)', command) or
        re.search(r'(?:^|\s)-delay_type\s+(?!max(?:\s|$))', command)):
        raise ValueError("expected a full_clock_expanded setup report")
    blocks = re.split(r"(?=^Slack \((?:MET|VIOLATED)\)\s*:)", text, flags=re.M)[1:]
    if not blocks:
        raise ValueError("no setup paths")
    paths = [parse_path(b, markers) for b in blocks]
    if len({(p['clock'], p['period_ns']) for p in paths}) != 1:
        raise ValueError("mixed clocks or periods")
    paths.sort(key=lambda p: p['slack_ns'])
    return dict(design_state=state, paths_reported=len(paths),
        worst_slack_ns=paths[0]['slack_ns'], estimated_fmax_mhz=paths[0]['estimate_mhz'],
        endpoint_families=dict(Counter(p['destination_family'] for p in paths)),
        paths=paths, routed=state == 'Routed', physical_frequency_mhz=None,
        timing_signoff=False,
        caveat=("Conditional routed setup estimate" if state == 'Routed' else "Unplaced report estimate") +
               "; listed paths are not all paths. Rebuilt hierarchy is not RTL ownership. "
               "Not complete timing/exception or hardware acceptance.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('--state', choices=STATES, default='Synthesized',
                        help='required native design state (default: Synthesized)')
    parser.add_argument('--marker', action='append', default=[], metavar='NAME=REGEX')
    parser.add_argument('--include-rows', action='store_true')
    args = parser.parse_args()
    markers = []
    for spec in args.marker:
        name, separator, pattern = spec.partition('=')
        if not name or not separator or not pattern or name in {n for n, _ in markers}:
            parser.error('markers must be unique nonempty NAME=REGEX pairs')
        re.compile(pattern)
        markers.append((name, pattern))
    raw = args.report.read_bytes()
    result = analyze(raw.decode('utf-8'), markers, expected_state=args.state)
    result.update(report=str(args.report.resolve()), report_sha256=hashlib.sha256(raw).hexdigest(),
                  marker_patterns=dict(markers))
    if not args.include_rows:
        for path in result['paths']:
            del path['rows']
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
