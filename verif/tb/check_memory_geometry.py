#!/usr/bin/env python3
"""Strict normal-EXT geometry qualification; not an architectural comparator.

Requires a model proof/binary binding and an independent explicit byte oracle.
NC checks cover an isolated run's complete narrow transaction stream; no
current-PC attribution of backing traffic. Chain admissions remain unsupported.
"""
import argparse
import json
from pathlib import Path
import sys

from memory_geometry_proof import load, require, sha, verify_binding


def nc_pieces(addresses):
    """Exact canonical NC byte/word pieces, not destination-width-derived."""
    if len(addresses) == 2 and addresses[0] % 2 == 0 and addresses[1] == addresses[0] + 1:
        return [(addresses[0], 1)]
    return [(a, 0) for a in addresses]


def cache_fill_words(request):
    """Protocol-implied R beat addresses, not addresses present on AXI R.

    Retained observers record each accepted R handshake's clock/ID/data/last.
    Address order follows the accepted AR burst contract. This is not an
    independent oracle for the cache-fill word CONTENTS.
    """
    address = request['address']
    require(type(address) is int and 0 <= address < 2**40 and
            request['size'] == 2 and request['len'] == 7, 'unexpected cache-fill geometry')
    if request['burst'] == 1:
        require(address % 32 == 0, 'misaligned INCR cache fill')
        words = [address + 4*i for i in range(8)]
    else:
        require(request['burst'] == 2 and address % 4 == 0, 'invalid WRAP32 cache fill')
        base = address & ~31
        words = [base + ((address-base+4*i) % 32) for i in range(8)]
    require(len(set(words)) == 8 and sorted(words) == list(range(address & ~31, (address & ~31)+32, 4)),
            'incomplete/out-of-line cache fill')
    return words


def check(rows, spec, mapping, profile, retire_cycles):
    require(spec['schema'] == 1 and spec['mode'] in ('ram', 'nc-isolated'), 'unsupported geometry scope')
    ops = spec['operations']
    require(ops and len(retire_cycles) == len(ops), 'empty/missing retirement oracle')
    require(all(type(c) is int and c > 0 for c in retire_cycles) and
            retire_cycles == sorted(set(retire_cycles)), 'invalid target retirement clocks')
    for op in ops:
        require(type(op['require_fast']) is bool, 'explicit fast/fallback qualification required')
        require(op['width'] in (1, 2) and len(op['physical_bytes']) == op['width'] and
                len(op['linear_bytes']) == op['width'], 'source-width oracle mismatch')
        require(op['linear_bytes'] == list(range(op['linear_bytes'][0], op['linear_bytes'][0]+op['width'])),
                'noncontiguous source linear oracle')
        require(all(type(x) is int and 0 <= x <= 0xffffffff
                    for x in op['physical_bytes'] + op['linear_bytes']), 'invalid source byte')
        if spec['mode'] == 'nc-isolated':
            require(len(op['axi_bytes']) == op['width'] and
                    all(type(x) is int and 0 <= x < 2**40 for x in op['axi_bytes']), 'invalid NC physical oracle')
    require(len(rows) >= 2 and rows[0]['type'] == 'begin' and rows[-1]['type'] == 'complete',
            'incomplete geometry observation')
    begin, end = rows[0], rows[-1]
    require(begin['schema'] == 1 and begin['profile_sha256'] == profile and
            begin['target_pc'] == spec['target_pc'] and begin['expected_reads'] == len(ops), 'profile/target mismatch')
    for field, name in [('load_state', 'S_LOAD'), ('exec_state', 'S_EXEC'), ('pipe_state', 'S_PIPE'),
                        ('walk_state', 'S_WALK'), ('ext_kind', 'K_EXT')]:
        require(begin[field] == mapping[name], 'FSM map differs from proven compiler map')
    require(end['records'] == len(rows) and end['final_reads'] == len(ops), 'truncated/count-mismatched observation')
    seen_final, fast, accepted, linear, offered_at = [], [], [], [], []
    ar, offers, responses = {}, [], {}
    last_cycle = 0
    complete_index = 0
    core_clocks = set()
    for row in rows[1:-1]:
        typ = row['type']
        require(typ in ('reset', 'core', 'axi_ar_offer', 'axi_ar', 'axi_r'), 'error/unsupported geometry row')
        require(not row.get('chain_accept') and not row.get('chain_owner'), 'chain-owner ambiguity')
        cycle = row['cycle']
        require(type(cycle) is int and last_cycle <= cycle <= end['last_cycle'], 'invalid observation cycle')
        last_cycle = cycle
        if typ == 'reset':
            require(not ar and not seen_final and not accepted, 'reset during observed work unsupported')
        elif typ == 'core':
            require(cycle not in core_clocks, 'duplicate per-edge core observation')
            core_clocks.add(cycle)
            require(row['owner'] in ('slow-ext', 'pipe-held', 'pipe-live'), 'unknown producer owner')
            producer = row['walk_return'] if row['walk'] else row['state']
            require((row['state'] == mapping['S_WALK']) == bool(row['walk']), 'walk state mismatch')
            allowed = (mapping['S_LOAD'], mapping['S_EXEC']) if row['owner'] == 'slow-ext' else (mapping['S_PIPE'],)
            require(producer in allowed and (row['owner'] != 'pipe-held' or row['pipe_active']), 'producer state mismatch')
            require(row['accepted'] == int(bool(row['req'] and row['beat_ack'])), 'invented accepted core beat')
            if row['owner_pc'] != spec['target_pc']:
                require(begin['has_consumer'] and row['owner_pc'] == begin['consumer_pc'] and not row['final_read'],
                        'unexpected/non-target completion')
                continue
            if row['walk']:
                require(not row['final_read'] and not row['pipe_commit'], 'walk counted as operand')
                continue
            # EXEC rows after final ACK are diagnostics only, never new source offers.
            if row['req']:
                require(complete_index < len(ops) and not row['we'], 'extra read/source write')
                op = ops[complete_index]
                if len(offered_at) == complete_index:
                    offered_at.append(cycle)
                require(row['strobes'] in (1, 3) and 1 <= row['extent'] <= op['width'], 'widened/noncanonical source offer')
                count = row['strobes'].bit_count()
                offered = list(range(row['physical'], row['physical'] + count))
                lin = list(range(row['linear'], row['linear'] + count))
                offset = len(accepted)
                require(offered == op['physical_bytes'][offset:offset+count] and
                        lin == op['linear_bytes'][offset:offset+count], 'wrong/extra/repeated source byte geometry')
                if row['accepted']:
                    accepted += offered
                    linear += lin
            if row['pipe_commit']:
                require(row['state'] == mapping['S_PIPE'] and row['fsm_enabled'] and row['final_ack'] and row['final_read'],
                        'unqualified target fast commit')
                fast.append(cycle)
            if row['final_read']:
                require(complete_index < len(ops) and row['fsm_enabled'] and row['final_ack'], 'invalid final read')
                op = ops[complete_index]
                require(accepted == op['physical_bytes'] and linear == op['linear_bytes'], 'missing accepted operand bytes')
                require(cycle <= retire_cycles[complete_index] and
                        (complete_index == 0 or cycle > retire_cycles[complete_index-1]), 'completion/retirement ownership mismatch')
                if row['state'] == mapping['S_LOAD']:
                    require(not row['xp_cross'] or row['xp_pending'], 'first split beat counted final')
                else:
                    require(row['state'] == mapping['S_PIPE'] and row['pipe_commit'], 'invalid final producer')
                if op['require_fast']:
                    require(row['pipe_commit'] and cycle == retire_cycles[complete_index], 'missing actual fast retirement witness')
                seen_final.append(cycle)
                complete_index += 1
                accepted, linear = [], []
        elif typ == 'axi_ar_offer':
            offers.append(row)
        elif typ == 'axi_ar':
            tid = row['transaction']
            require(tid == len(ar)+1, 'missing/duplicate AXI transaction')
            require(all(len(responses.get(t, [])) == a['len']+1 for t, a in ar.items()), 'overlapping AXI read')
            matches = [o for o in offers if o['cycle'] == cycle and o['accepted'] and
                       all(o[k] == row[k] for k in ('address', 'id', 'len', 'size', 'burst', 'narrow'))]
            require(len(matches) == 1, 'AR handshake missing actual matching offer')
            if row['narrow']:
                require(row['burst'] == 1 and row['len'] == 0 and row['size'] in (0, 1) and row['address'] % (1 << row['size']) == 0,
                        'widened/misaligned NC transaction')
            else:
                cache_fill_words(row)
            ar[tid] = row
            responses[tid] = []
        elif typ == 'axi_r':
            tid = row['transaction']
            require(tid in ar and row['resp'] == 0 and row['id'] == ar[tid]['id'] and
                    row['narrow'] == ar[tid]['narrow'], 'errored/unowned AXI response')
            require(cycle >= ar[tid]['cycle'] and
                    (not responses[tid] or cycle > responses[tid][-1]['cycle']),
                    'reordered/duplicate accepted R handshake')
            responses[tid].append(row)
            require(row['last'] == int(len(responses[tid]) == ar[tid]['len']+1), 'wrong RLAST/count')
    require(complete_index == len(ops) and not accepted and end['fast_commits'] == len(fast), 'incomplete final/fast evidence')
    require(end['axi_reads'] == len(ar) and end['axi_beats'] == sum(map(len, responses.values())) and
            all(len(responses[t]) == a['len']+1 for t, a in ar.items()), 'incomplete AXI stream')
    require(sum(o['accepted'] for o in offers) == len(ar), 'accepted AR offer missing handshake')
    actual_nc = [(r['address'], r['size']) for r in ar.values() if r['narrow']]
    expected_nc = [piece for op in ops for piece in nc_pieces(op['axi_bytes'])] if spec['mode'] == 'nc-isolated' else []
    require(actual_nc == expected_nc, 'NC byte extent/order mismatch or unexpected NC traffic')
    if spec['mode'] == 'nc-isolated':
        narrow = [(tid, r) for tid, r in ar.items() if r['narrow']]
        offset = 0
        for i, op in enumerate(ops):
            count = len(nc_pieces(op['axi_bytes']))
            for tid, r in narrow[offset:offset+count]:
                require(offered_at[i] <= r['cycle'] and responses[tid][-1]['cycle'] <= seen_final[i],
                        'NC backing transaction outside owning operand lifetime')
            offset += count
    return {'operands': len(ops), 'fast_commits': len(fast), 'nc_transactions': len(actual_nc),
            'cache_fills': len(ar)-len(actual_nc),
            'wrap32_fills': sum(not r['narrow'] and r['burst'] == 2 for r in ar.values()),
            'scope': 'normal-EXT geometry only; architectural differential gate still required'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for arg in ('log', 'spec', 'receipt', 'binding', 'binary', 'vtrace', 'out'):
        p.add_argument('--'+arg, type=Path, required=True)
    a = p.parse_args()
    receipt, spec = load(a.receipt), load(a.spec)
    profile = verify_binding(receipt, load(a.binding), a.binary)
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'diff'))
    import tracefmt
    trace = tracefmt.read_trace(str(a.vtrace))
    cycles = [r['cyc'] for r in trace.records if int(r['pc'], 0) == spec['target_pc']]
    rows = [json.loads(line) for line in a.log.read_text().splitlines()]
    result = check(rows, spec, receipt['mapping'], profile, cycles)
    result['inputs_sha256'] = {name: sha(getattr(a, name)) for name in
                              ('log', 'spec', 'receipt', 'binding', 'binary', 'vtrace')}
    with a.out.open('x') as f: json.dump(result, f, indent=2)
    print('EXT-MEMORY-GEOMETRY-OK')


if __name__ == '__main__':
    main()
