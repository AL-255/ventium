#!/usr/bin/env python3
"""Synthetic (NOT guest) state-delta cases for V-load, L1 and FP counters.

Use a recorded schema solely for field names/layout. Every fixture value is
synthetic. With --analyzer, check the C++ counters as well as exact reconstruction.
"""
import argparse
import csv
import gzip
import os
from pathlib import Path
import struct
import subprocess
import tempfile

from fpd_layout import layout
from state_delta_read import Reader


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('schema', type=Path)
    p.add_argument('--analyzer', type=Path)
    p.add_argument('--omit-chain-accept', action='store_true',
                   help='exercise older schemas without the optional mc_accept field')
    a = p.parse_args()
    with a.schema.open() as f:
        fields = list(csv.DictReader(f, delimiter='\t'))
    core = 'system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__'
    if a.omit_chain_accept:
        fields = [f for f in fields if f['name'] != core + 'mc_accept']
    size = 0
    for field in fields:
        field['offset'] = str(size)
        size += int(field['size'])
    by_name = {f['name']: f for f in fields}
    package = Path(__file__).resolve().parents[1] / 'rtl/core/ventium_decode_pkg.sv'
    ranges = layout(package.read_text())
    descriptor = {n: (o, w) for n, o, w in ranges}

    def put(state, name, value):
        f = by_name[core + name]
        off, width = int(f['offset']), int(f['size'])
        state[off:off + width] = value.to_bytes(width, 'little')

    def packet(values):
        result = 0
        for n, v in values.items():
            off, width = descriptor[n]
            assert 0 <= v < 1 << width
            result |= v << off
        return result

    def sample(signals=None, u=None, v=None):
        state = bytearray(size)
        defaults = dict(state=28, pipe_int_commit=1, pipe_frontend_ready=1,
                        v_bytes_ok=1, uc_v_avail=1, pipe_pair_reason=6)
        for name, value in dict(defaults, **(signals or {})).items():
            put(state, name, value)
        up = dict(simple=1)
        up.update(u or {})
        put(state, 'u_d', packet(up))
        vp = dict(simple=1, is_mem=1, is_load=1)
        vp.update(v or {})
        put(state, 'v_d', packet(vp))
        return state

    samples = [sample(), sample(v={'is_load': 0}), sample(v={'w8': 1}),
               sample(v={'w16': 1}), sample(v={'is_store': 1}),
               sample(v={'is_stack': 1})]
    for n in ('pipe_int_commit', 'pipe_frontend_ready', 'v_bytes_ok', 'uc_v_avail'):
        samples.append(sample(signals={n: 0}))
    for n in ('is_mem', 'is_stack', 'is_branch', 'is_fp'):
        samples.append(sample(u={n: 1}))
    samples += [sample(signals={'pipe_mem_active_q': 1}),
                sample(signals={'pipe_pair_reason': 4}), sample(signals={'state': 1})]
    # A real admission-time V boundary survives frontend invalidation while U
    # waits. Conversely, a stale V at admission must never become eligible just
    # because a later live frontend happens to show valid bytes.
    samples += [sample(signals={'pipe_int_commit': 0}, u={'is_mem': 1, 'is_load': 1}),
                sample(signals={'pipe_mem_active_q': 1, 'pipe_int_commit': 0,
                                'pipe_frontend_ready': 0, 'uc_v_avail': 0}),
                sample(signals={'pipe_mem_active_q': 1, 'pipe_frontend_ready': 0,
                                'uc_v_avail': 0}, v={'is_load': 0}),
                sample(signals={'pipe_int_commit': 0}),
                sample(signals={'pipe_int_commit': 0, 'uc_v_avail': 0},
                       u={'is_mem': 1, 'is_load': 1}),
                sample(signals={'pipe_mem_active_q': 1})]
    # L1 wait partition: one sample per category plus acknowledged/no-request
    # exclusions. These are deliberately independent of the V-pair predicates.
    l1 = 'system__DOT__u_cpu__DOT__u_core__DOT__u_l1axi__DOT__'
    for case_index, overrides in enumerate(({'u_l1d__DOT__st': 1}, {'l1d_cacheable': 0},
                      {'__Vcellinp__u_l1d__flush_all': 1},
                      {'u_l1d__DOT__rd_hit': 0},
                      {'u_l1d__DOT__do_rd_cap': 1}, {},
                      {'l1d_c_ack': 1}, {'l1d_c_req': 0})):
        state = bytearray(size)
        put(state, 'cur_is_d', case_index % 2)
        values = dict(l1d_c_req=1, l1d_cacheable=1, u_l1d__DOT__rd_hit=1)
        values.update(overrides)
        for name, value in values.items():
            field = by_name[l1 + name]
            off, width = int(field['offset']), int(field['size'])
            state[off:off + width] = value.to_bytes(width, 'little')
        samples.append(state)
    # FP hold classification uses a priority partition of settled levels, not
    # estimated saved clocks. Deliberately overlap predicates to check precedence:
    # outside PIPE wins over frontend, frontend over FP, FP over non-simple,
    # non-simple over stack, stack over branch, and branch over memory.
    fp_cases = [
        ({'state': 1, 'pipe_frontend_ready': 0}, {'is_fp': 1, 'fp_kind': 7}),
        ({'pipe_frontend_ready': 0}, {'is_fp': 1, 'fp_kind': 7}),
        # FK_MEM deliberately leaves integer is_mem clear (decode.sv).
        ({}, {'simple': 0, 'is_fp': 1, 'fp_kind': 0, 'fp_aluop': 6, 'is_mem': 0}),
        ({}, {'is_fp': 1, 'fp_kind': 3, 'fp_aluop': 1}),
        ({}, {'simple': 0, 'is_stack': 1, 'is_branch': 1, 'is_mem': 1}),
        ({}, {'is_stack': 1, 'is_branch': 1, 'is_mem': 1}),
        ({}, {'is_branch': 1, 'is_mem': 1}),
        ({}, {'is_mem': 1}),
        ({}, {}),
        ({'fp_async_hold': 0}, {'is_fp': 1, 'fp_kind': 7}),
    ]
    # Earlier single-owner model schemas have no streaming-owner counter.
    # Keep their original fixtures usable; do not invent an absent RTL field.
    if core + 'fp_async_count' not in by_name:
        fp_cases = []
    before_fp = len(samples)
    for i, (signals, u) in enumerate(fp_cases):
        values = dict(pipe_int_commit=0, fp_async_pending=1,
                      fp_async_hold=1, fp_async_count=i % 4 + 1)
        values.update(signals)
        samples.append(sample(signals=values, u=u))
    before_chain = len(samples)
    # Three owners without an inactive gap. Only the first has observed valid
    # frontend admission. Both successor completions must be excluded even
    # when live decodes advertise a plausible, but unowned, same-line pair.
    # mc_accept is a PRE-edge transfer: the old owner's completion still counts.
    read_u = dict(is_mem=1, is_load=1, mem_disp=0x1000)
    read_v = dict(mem_disp=0x1004)

    def chain_sample(active, commit, replace=0, valid=1, u=None, v=None):
        signals = dict(pipe_mem_active_q=active, pipe_int_commit=commit,
                       pipe_frontend_ready=valid, uc_v_avail=valid)
        if core + 'mc_accept' in by_name:
            signals['mc_accept'] = replace
        return sample(signals=signals, u=read_u if u is None else u,
                      v=read_v if v is None else v)

    samples += [
        chain_sample(0, 0),                       # capture first owner's proof
        chain_sample(1, 0, valid=0),              # ordinary hold retains it
        chain_sample(1, 1, replace=1, valid=0),   # first completion counts
        chain_sample(1, 0, u={'is_store': 1}),    # new owner; misleading live V
        chain_sample(1, 1, replace=1),            # second completion excluded
        chain_sample(1, 1, valid=0),              # third completion excluded
        chain_sample(0, 0),                       # fresh observed admission
        chain_sample(1, 1, valid=0),              # proof may count again
        chain_sample(0, 0, valid=0),              # invalid original admission
        chain_sample(1, 1, replace=1),            # plausible live pair cannot fix it
        chain_sample(1, 1),                       # replacement remains unproven
        chain_sample(0, 0, valid=0),
    ]
    initial = bytes(size)
    with tempfile.TemporaryDirectory(prefix='ventium-vload-fixture.') as directory:
        out = Path(directory)
        trace = out / 'synthetic.delta.gz'
        with gzip.open(trace, 'wb') as f:
            f.write(b'VENDLT01' + struct.pack('<IQQI', len(fields), 0, len(samples), size))
            for field in fields:
                for key in ('name', 'type'):
                    value = field[key].encode()
                    f.write(struct.pack('<I', len(value)) + value)
                f.write(struct.pack('<I', int(field['size'])))
            f.write(initial)
            old = initial
            for cycle, state in enumerate(samples, 1):
                changes = []
                for off in range(0, size, 16):
                    bits = [b for b in range(min(16, size-off)) if old[off+b] != state[off+b]]
                    if bits:
                        changes.append(struct.pack('<IH', off, sum(1 << b for b in bits)) +
                                       bytes(state[off+b] for b in bits))
                f.write(struct.pack('<QI', cycle, len(changes)) + b''.join(changes))
                old = state
            f.write(b'ENDDLT01' + struct.pack('<Q', len(samples)) + samples[-1])
        reconstructed = [(c, bytes(s)) for c, s in Reader(trace).records()]
        assert reconstructed == list(enumerate(map(bytes, samples), 1))
        if a.analyzer:
            table = out / 'layout.tsv'
            table.write_text(''.join(f'{n}\t{o}\t{w}\n' for n, o, w in ranges))
            kwargs = {'pass_fds': (9,)} if os.path.exists('/proc/self/fd/9') else {}
            subprocess.run([str(a.analyzer.resolve()), str(trace), str(out/'analysis'),
                            str(table)], check=True, **kwargs)
            with (out/'analysis.summary.tsv').open() as f:
                totals = {r['metric']: r['value'] for r in csv.DictReader(f, delimiter='\t')}
            # Only the first synthetic L1 case is filling. Its backend fields
            # are all zero and its read request is waiting; exact tuple order
            # and exclusion of non-fill cases are checked here.
            with (out/'analysis.cache_backend.tsv').open() as f:
                backend = list(csv.DictReader(f, delimiter='\t'))
            assert backend == [dict(axi_read_state='0', bridge_state='0',
                                    backend_state='0', backing_ack='0', write_busy='0',
                                    read_waiting='1', cycles='1')]
            for key, expected in [('memory', 6), ('mov_load', 3), ('mov32_load', 1)]:
                assert int(totals[f'counterfactual_u_register_v_{key}_commit_levels']) == expected
            assert int(totals['v_memory_completed_u_mov32_v_mov32']) == 3
            assert int(totals['read_pair_completed_u']) == 4
            assert int(totals['read_pair_same_segment_line_contained']) == 4
            assert int(totals['v_memory_attribution_unproven_chain_replacements']) == 3
            assert int(totals.get('read_pair_same_line_complete_registered_window', '0')) == 0
            assert int(totals['l1_read_wait_total']) == 6
            for case_index, category in enumerate(('busy', 'idle_uncacheable', 'idle_flush',
                             'idle_miss', 'idle_hit_capture', 'idle_hit_not_capturing')):
                assert int(totals['l1_read_wait_' + category]) == 1
                assert int(totals['l1_read_wait_state_0_' + category]) == 1
                source = 'data' if case_index % 2 else 'instruction'
                other = 'instruction' if case_index % 2 else 'data'
                assert int(totals[f'l1_read_wait_source_{source}_{category}']) == 1
                assert int(totals.get(f'l1_read_wait_source_{other}_{category}', '0')) == 0
                assert int(totals[f'l1_read_wait_state_0_source_{source}_{category}']) == 1
            for source in ('instruction', 'data'):
                assert int(totals[f'l1_read_wait_source_{source}']) == 3
            if fp_cases:
                assert int(totals['async_hold']) == 9
                assert int(totals['async_pending']) == 10
                partition = dict(outside_pipe=1, frontend_unavailable=1, fp_descriptor=2,
                                 nonsimple_integer=1, stack=1, branch=1, memory=1, other=1)
                for reason, expected in partition.items():
                    assert int(totals['fp_hold_observed_' + reason]) == expected, reason
                assert sum(partition.values()) == int(totals['async_hold'])
                assert int(totals['fp_hold_descriptor_kind_0']) == 1
                assert int(totals['fp_hold_descriptor_kind_3']) == 1
                assert int(totals.get('fp_hold_descriptor_kind_7', '0')) == 0
                assert int(totals['fp_hold_descriptor_aluop_6']) == 1
                assert int(totals['fp_hold_descriptor_aluop_1']) == 1
                assert int(totals['fp_hold_descriptor_operand_memory']) == 1
                assert int(totals['fp_hold_descriptor_operand_register']) == 1
                assert int(totals['fp_hold_descriptor_kind_0_memory']) == 1
                assert int(totals['fp_hold_descriptor_kind_3_register']) == 1
                assert int(totals.get('fp_hold_descriptor_kind_7_register', '0')) == 0
                for owners, expected in enumerate((before_fp + len(samples) - before_chain, 3, 3, 2, 2)):
                    assert int(totals['fp_owner_count_' + str(owners)]) == expected, owners
            print(f'VLOAD-ATTRIBUTION-OK: {len(samples)} synthetic cases, counters checked')
        else:
            print(f'VLOAD-FIXTURE-OK: {len(samples)} synthetic cases reconstruct; C++ counters NOT checked')


if __name__ == '__main__':
    main()
