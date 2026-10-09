#!/usr/bin/env python3
"""Host-only tests; no RTL build, guest mutation, signals or administrator access."""
import copy
import ctypes
import os
from pathlib import Path
import struct
import subprocess
import tempfile
from types import SimpleNamespace
import unittest

import live_sim_counters as live


def valid():
    return dict(pp_cycles=100, pp_ret1=40, pp_ret2=20, pp_state=[70, 30],
                pp_mem_wait=[10, 12], pp_mem_ack=[11, 13],
                l1_perf_fill_cycles=34, l1_perf_fill_wait=30, l1_perf_fill_ack=4)


class Tests(unittest.TestCase):
    def test_fields_exclude_scratch_and_non_counters(self):
        text = '\n'.join([
            f'QData/*63:0*/ {live.CORE}pp_cycles;',
            f'QData/*63:0*/ {live.CORE}pp_ret1;',
            f'QData/*63:0*/ {live.CORE}pp_ret2;',
            f'VlUnpacked<QData/*63:0*/, 64> {live.CORE}pp_state;',
            f'QData/*63:0*/ __Vdly__{live.CORE}pp_cycles;',
            f'QData/*63:0*/ {live.CORE}fpu_register;',
            f'QData/*63:0*/ {live.L1}perf_hit_ack;',
            f'VlUnpacked<QData/*63:0*/, 4> {live.CORE}pp_fp_stream_cycle;',
            f'QData/*47:0*/ {live.CORE}pp_slowop_first_bytes;'])
        fields = live.counter_fields(text)
        self.assertEqual(set(fields), {'pp_cycles', 'pp_ret1', 'pp_ret2', 'pp_state', 'l1_perf_hit_ack'})
        self.assertEqual(fields['pp_state'][1:], (64, True))
        with self.assertRaises(ValueError):
            live.counter_fields(text + f'\nQData/*63:0*/ {live.CORE}pp_cycles;')

    def test_missing_profiler(self):
        with self.assertRaises(ValueError):
            live.counter_fields('')

    def test_invariants(self):
        live.validate(valid())
        for key, bad in [('pp_cycles', 101), ('pp_ret1', 101), ('pp_ret2', 41),
                         ('pp_mem_wait', [69, 12]), ('pp_mem_ack', [11]),
                         ('l1_perf_fill_ack', 3)]:
            with self.subTest(key=key):
                counters = valid(); counters[key] = bad
                with self.assertRaises(ValueError):
                    live.validate(counters)

    def test_layout_bounds(self):
        layout = dict(schema=1, byteorder='little', root_size=128, rootp_offset=48,
                      fields={'pp_cycles': dict(offset=8, count=1, array=False)})
        live.check_layout(layout)
        for key, bad in [('root_size', live.LIMIT+1), ('rootp_offset', -1), ('schema', 0),
                         ('byteorder', 'big')]:
            altered = copy.deepcopy(layout); altered[key] = bad
            with self.subTest(key=key), self.assertRaises(ValueError):
                live.check_layout(altered)
        for name, offset, count in [('guest_memory', 8, 1), ('pp_cycles', 124, 1),
                                    ('pp_cycles', 0, 0), ('pp_cycles', -8, 1),
                                    ('pp_cycles', 0, 4097)]:
            altered = copy.deepcopy(layout)
            altered['fields'] = {name: dict(offset=offset, count=count, array=False)}
            with self.subTest(name=name, offset=offset, count=count), self.assertRaises(ValueError):
                live.check_layout(altered)

    def test_decode_and_real_child_read_only(self):
        # The parent may read its own child under normal Linux ptrace policy.
        # Closing the pipe lets the child exit normally; no kill/stop signal.
        payload = ctypes.create_string_buffer(struct.pack('<QQQQQ', 100, 40, 20, 70, 30))
        fields = {name: dict(offset=off, count=count, array=array) for name,off,count,array in
                  [('pp_cycles', 0, 1, False), ('pp_ret1', 8, 1, False),
                   ('pp_ret2', 16, 1, False), ('pp_state', 24, 2, True)]}
        rd, wr = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(wr)
            os.read(rd, 1)
            os._exit(0)
        os.close(rd)
        try:
            expected = Path('/proc/self/exe').resolve()
            self.assertTrue(live.identity(pid, expected))
            with self.assertRaises(ValueError):
                live.identity(pid, Path('/usr/bin/true').resolve())
            fd = os.open(f'/proc/{pid}/mem', os.O_RDONLY)
            try:
                data = live.read_exact(fd, 40, ctypes.addressof(payload))
            finally:
                os.close(fd)
            counters = live.decode(data, 0, fields)
            live.validate(counters)
            self.assertEqual(counters['pp_state'], [70, 30])
            self.assertEqual(payload.raw[:40], data)
        finally:
            os.close(wr)
            self.assertEqual(os.waitpid(pid, 0)[1], 0)

    def test_short_read(self):
        fd = os.open('/dev/null', os.O_RDONLY)
        try:
            with self.assertRaises(ValueError):
                live.read_exact(fd, 8, 0)
        finally:
            os.close(fd)

    def test_complete_layout_and_native_reader(self):
        # A tiny owned native fixture validates the actual ELF symbol, PIE
        # mapping, pointer and generated-header workflow without sudo.
        scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
        with tempfile.TemporaryDirectory(prefix='ventium-live-counter-test.', dir=scratch) as folder:
            root = Path(folder); obj = root / 'obj'; obj.mkdir()
            header = '\n'.join([
                '#pragma once', '#include <array>', '#include <cstdint>',
                'using QData = uint64_t;',
                'template<class T, unsigned N> using VlUnpacked = std::array<T,N>;',
                'struct Vsystem___024root {',
                f'QData/*63:0*/ {live.CORE}pp_cycles;',
                f'QData/*63:0*/ {live.CORE}pp_ret1;',
                f'QData/*63:0*/ {live.CORE}pp_ret2;',
                f'VlUnpacked<QData/*63:0*/, 2> {live.CORE}pp_state;', '};'])
            (obj / 'Vsystem___024root.h').write_text(header)
            (obj / 'Vsystem.h').write_text('#pragma once\n#include "Vsystem___024root.h"\n'
                                         'struct Vsystem { Vsystem___024root* rootp; };\n')
            board_header = obj/'board_axi_memory.h'
            board_header.write_text('#pragma once\n#include <cstdint>\nnamespace ven_board {\n'
                'struct AxiMemory { uint64_t aw_count=0,w_count=0,b_count=0,ar_count=0,r_count=0; }; }\n')
            (obj / 'Vsystem.mk').write_text('VERILATOR_ROOT = /usr\n')
            (obj / 'fixture.cpp').write_text('#include "Vsystem.h"\n#include "board_axi_memory.h"\n#include <cstdio>\n'
                'static ven_board::AxiMemory board_memory;\nVsystem* top;\nstatic uint64_t main_time;\nint main() {\n'
                'Vsystem___024root root{100,40,20,{70,30}}; Vsystem model{&root};\n'
                'board_memory.aw_count=board_memory.w_count=board_memory.b_count=2;\n'
                'board_memory.ar_count=3; board_memory.r_count=24;\n'
                'top=&model; main_time=101; puts("ready"); fflush(stdout); getchar(); return 0; }\n')
            binary = obj / 'native'
            subprocess.run(['g++', '-O0', '-fPIE', '-pie', str(obj/'fixture.cpp'),
                            '-o', str(binary)], check=True, timeout=30)
            live.prepare(SimpleNamespace(obj=obj, binary=binary, out=root/'layout', board_header=board_header))
            child = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            try:
                self.assertEqual(child.stdout.readline(), b'ready\n')
                args = SimpleNamespace(layout=root/'layout/layout.json', pid=child.pid,
                                       out=root/'sample.json')
                live.sample(args)
                import json
                result = json.loads(args.out.read_text())
                self.assertEqual(result['counters']['pp_cycles'], 100)
                self.assertEqual(result['counters']['board_r_count'], 24)
                self.assertEqual(result['counters']['board_b_count'], 2)
                self.assertEqual(result['maximum_skew_clocks'], 0)
                self.assertFalse(result['signals_sent'])
                self.assertFalse(result['memory_writes'])
                # Missing generated-header ownership and stale binaries must
                # fail before touching process memory.
                (obj/'Vsystem.h').write_text('// input drift\n')
                with self.assertRaises(ValueError):
                    live.sample(args)
            finally:
                child.stdin.close()
                self.assertEqual(child.wait(timeout=5), 0)
                child.stdout.close()


if __name__ == '__main__':
    unittest.main()
