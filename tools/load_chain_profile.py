#!/usr/bin/env python3
"""Screen adjacent load completions in a bounded VENSTATE/VENL1 observation.

This is not an eligibility or saved-cycle oracle. Missing instruction length,
address dependencies, strobes, segment/translation context and event state must
still be checked before a core can issue a younger load. State IDs are specific
to the explicitly selected model. No .vtrace is produced or rewritten.
"""
import argparse
from collections import Counter, deque

from state_profile import records as state_records
from l1_fill_profile import records as l1_records


def pairs(lines):
    """Require the actual producer's one STATE then one L1 record per cycle."""
    pending = None
    previous_cycle = previous_n = None
    for line in lines:
        if line.startswith('VENSTATE '):
            if pending is not None:
                raise ValueError('missing VENL1 partner')
            pending = next(state_records([line]))
        elif line.startswith('VENL1 '):
            if pending is None:
                raise ValueError('VENL1 without preceding VENSTATE')
            memory = next(l1_records([line]))
            if pending['cyc'] != memory['cyc']:
                raise ValueError('mismatched observation cycles')
            if previous_cycle is not None and pending['cyc'] != previous_cycle + 1:
                raise ValueError('nonconsecutive joined observations')
            if previous_n is not None and pending['n'] < previous_n:
                raise ValueError('retirement count decreased')
            previous_cycle, previous_n = pending['cyc'], pending['n']
            yield pending, memory
            pending = None
    if pending is not None:
        raise ValueError('incomplete final observation')


def summarize(observations, pipe_state, retire_lag):
    if not 1 <= retire_lag <= 8:
        raise ValueError('retire lag must be in [1,8]')
    counts = Counter()
    gaps = Counter()
    history = deque(maxlen=retire_lag+1)
    prior_load = first = last = None
    for current in observations:
        state, memory = current
        if first is None:
            first = state
        last = state
        counts['observations'] += 1
        history.append(current)
        if len(history) == retire_lag+1:
            old, old_mem = history[0]
            # VENSTATE samples before the edge. In the current full-PC model,
            # core commit registers retire_valid, the top invokes DPI at the
            # following edge, and the counter is visible in the next pre-edge
            # sample: lag=2, not 1. Keep this explicit and model-specific.
            retired = state['n'] - history[-2][0]['n']
            if retired:
                counts['retirement_groups'] += 1
                read_complete = (old['state'] == pipe_state and old['ack']
                                 and old_mem['req'] and old_mem['ack'] and not old_mem['we'])
                if read_complete:
                    counts['all_read_completion_groups'] += 1
                    if retired == 2:
                        counts['paired_read_completion_groups'] += 1
                is_load = retired == 1 and read_complete
                if is_load:
                    counts['single_read_completion_groups'] += 1
                    if prior_load is not None:
                        earlier, earlier_mem = prior_load
                        counts['adjacent_single_read_pairs'] += 1
                        distance = old['eip'] - earlier['eip']
                        # Necessary screening only: positive <=7-byte progress
                        # is not proof of a sequential instruction or CS identity.
                        if (0 < distance <= 7 and old['eip'] >> 5 == earlier['eip'] >> 5):
                            counts['nearby_same_code_line'] += 1
                            if old_mem['addr'] >> 12 == earlier_mem['addr'] >> 12:
                                counts['also_same_physical_data_page'] += 1
                                if all(m['cacheable'] and m['hit'] and not m['xline']
                                       and not m['flush'] and (m['addr'] & 31) <= 28
                                       for m in (old_mem, earlier_mem)):
                                    counts['also_cacheable_resident_non_crossing'] += 1
                                    gaps[old['cyc'] - earlier['cyc']] += 1
                    prior_load = history[0]
                else:
                    prior_load = None
    if first is None or last['cyc'] == first['cyc']:
        raise ValueError('need at least two joined cycles')
    counts['counter_cycles'] = last['cyc'] - first['cyc']
    counts['retired_instructions'] = last['n'] - first['n']
    return counts, gaps


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log')
    parser.add_argument('--pipe-state', type=int, required=True,
                        help='S_PIPE numeric value in the measured generated model')
    parser.add_argument('--retire-lag', type=int, required=True, choices=range(1, 9),
                        help='pre-edge sample lag from core commit to observed DPI counter (current full-PC: 2)')
    args = parser.parse_args()
    try:
        with open(args.log) as stream:
            counts, gaps = summarize(pairs(stream), args.pipe_state, args.retire_lag)
        for key, value in counts.items():
            print(f'{key}: {value}')
        print('Screened-pair retirement gaps (cycles: pairs): ' + str(dict(sorted(gaps.items()))))
        print('Screening only: not accepted younger requests, saved cycles, or a throughput prediction.')
        print('EIP offsets and physical pages do not prove code/translation identity; dependencies and events are unobserved.')
        if not counts['single_read_completion_groups']:
            print('WARNING: no correlated read completions; verify sample phase/lag before drawing any opportunity conclusion.')
    except (OSError, ValueError) as exc:
        parser.exit(2, f'LOAD-CHAIN-PROFILE-ERROR: {exc}\n')


if __name__ == '__main__':
    main()
