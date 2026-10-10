#!/usr/bin/env python3
"""Host-only guards for the exact performance profile and simulator projection."""
import unittest
import freeze_performance_rk_candidate as freeze


class Contracts(unittest.TestCase):
    def setUp(self):
        self.parent = [f'BASE_{i}' for i in range(107)] + [
            'VEN_FE_PIPE','VEN_FE_DTLB_MULTI','VEN_FE_DTLB_PERM','VEN_DDR_POSTED',
            *freeze.ADDITIONS]
        self.simulated = sorted((set(self.parent) | set(freeze.PERF_DEFINES)) -
                                {'SYNTHESIS','VTM_NO_DPI'})
        self.hardware = (b'module system\r\n(\r\ninput x\r\n);\r\n'
            b'l2_cache cache\r\n(\r\n.DDRAM_BUSY (DDRAM_BUSY),\r\n'
            b'.DDRAM_DOUT (DDRAM_DOUT),\r\n.DDRAM_DOUT_READY (DDRAM_DOUT_READY),\r\n'
            b'.dbg_cmp (cpu_dbg_cmp)\r\n);\r\nendmodule\r\n')
        self.sim = (b'module system #(parameter BOARD_POSTED=1, parameter BOARD_WRITE_SLOTS=16)\n'
            b'(\n`include "board_transport_ports.svh"\ninput x\n);\n'
            b'`include "board_transport_body.svh"\n\nl2_cache #(.CACHE_SETS(1024)) cache\n(\n'
            b'.DDRAM_BUSY (board_ddram_busy),\n.DDRAM_DOUT (board_ddram_data),\n'
            b'.DDRAM_DOUT_READY (board_ddram_valid),\n.dbg_cmp (board_dbg_cmp)\n);\nendmodule\n')

    def test_exact_profile(self):
        out = freeze.profile(self.parent,self.simulated)
        self.assertEqual(len(out),135)
        self.assertEqual(out,self.parent[:-3]+list(freeze.PERF_DEFINES)+list(freeze.ADDITIONS))
        self.assertEqual(set(out)-set(self.simulated),{'SYNTHESIS','VTM_NO_DPI'})

    def test_demand16_exact_profile(self):
        simulated = self.simulated + ['VEN_SFETCH16_DEMAND']
        out = freeze.profile(self.parent, simulated, 'sfetch16')
        self.assertEqual(len(out), 136)
        self.assertEqual(out[111:132], list(freeze.PERF_DEFINES))
        self.assertEqual(out[132:], ['VEN_SFETCH16_DEMAND', *freeze.ADDITIONS])
        self.assertEqual(set(out)-set(simulated), {'SYNTHESIS', 'VTM_NO_DPI'})

    def test_demand16_never_inferred_by_count(self):
        for variant, simulated in (
                ('performance', self.simulated+['VEN_SFETCH16_DEMAND']),
                ('sfetch16', self.simulated),
                ('sfetch16', self.simulated+['VEN_RET_SHORT_WINDOW']),
                ('sfetch16', self.simulated+['VEN_P54_WBUF_ADMIT_DISPATCH']),
                ('auto', self.simulated)):
            with self.subTest(variant=variant, simulated=simulated), self.assertRaises(freeze.FreezeError):
                freeze.profile(self.parent, simulated, variant)

    def test_demand16_missing_old_feature_refused(self):
        for name in freeze.PERF_DEFINES:
            simulated = [x for x in self.simulated if x != name] + ['VEN_SFETCH16_DEMAND', 'UNKNOWN']
            with self.subTest(name=name), self.assertRaises(freeze.FreezeError):
                freeze.profile(self.parent, simulated, 'sfetch16')

    def test_each_missing_feature_refused(self):
        for name in freeze.PERF_DEFINES:
            with self.subTest(name=name), self.assertRaises(freeze.FreezeError):
                freeze.profile(self.parent,[x for x in self.simulated if x != name])

    def test_same_count_wrong_feature_refused(self):
        for bad in ('VEN_CACHE_HALF','VEN_IC_NARROWB','VEN_UOPCACHE','VEN_LOAD_USE_FORWARD'):
            with self.subTest(bad=bad), self.assertRaises(freeze.FreezeError):
                freeze.profile(self.parent,self.simulated[:-1]+[bad])

    def test_duplicate_refused(self):
        with self.assertRaises(freeze.FreezeError):
            freeze.profile(self.parent,self.simulated[:-1]+[self.simulated[0]])

    def test_wrong_parent_order_refused(self):
        parent = list(self.parent); parent[109],parent[110] = parent[110],parent[109]
        with self.assertRaises(freeze.FreezeError): freeze.profile(parent,self.simulated)

    def test_extended_parent_refused(self):
        parent = list(self.parent);parent[0]=freeze.PERF_DEFINES[0]
        with self.assertRaises(freeze.FreezeError): freeze.profile(parent,self.simulated)

    def test_invalid_define_refused(self):
        parent = list(self.parent);parent[0]='BASE_0;exec nope'
        sim = sorted((set(parent) | set(freeze.PERF_DEFINES))-{'SYNTHESIS','VTM_NO_DPI'})
        with self.assertRaises(freeze.FreezeError): freeze.profile(parent,sim)

    def test_hardware_projection_preserves_crlf(self):
        out=freeze.hardware_system(self.hardware,self.sim)
        self.assertEqual(out,self.hardware.replace(b'l2_cache cache',b'l2_cache #(.CACHE_SETS(1024)) cache'))
        self.assertNotIn(b'board_transport',out)
        self.assertNotIn(b'BOARD_POSTED',out)
        self.assertEqual(out.count(b'\r\n'),self.hardware.count(b'\r\n'))

    def test_projection_preserves_lf(self):
        hardware=self.hardware.replace(b'\r\n',b'\n')
        self.assertEqual(freeze.hardware_system(hardware,self.sim),
            hardware.replace(b'l2_cache cache',b'l2_cache #(.CACHE_SETS(1024)) cache'))

    def test_every_simulator_connection_drift_refused(self):
        for before,after in ((b'BOARD_POSTED=1',b'BOARD_POSTED=0'),
                (b'BOARD_WRITE_SLOTS=16',b'BOARD_WRITE_SLOTS=1'),
                (b'board_transport_ports.svh',b'wrong_ports.svh'),
                (b'board_transport_body.svh',b'wrong_body.svh'),
                (b'board_ddram_busy',b'DDRAM_BUSY'),
                (b'board_ddram_data',b'DDRAM_DOUT'),
                (b'board_ddram_valid',b'DDRAM_DOUT_READY'),
                (b'board_dbg_cmp',b'cpu_dbg_cmp'),
                (b'CACHE_SETS(1024)',b'CACHE_SETS(128)'),(b'input x',b'input y')):
            with self.subTest(before=before), self.assertRaises(freeze.FreezeError):
                freeze.hardware_system(self.hardware,self.sim.replace(before,after))

    def test_system_missing_duplicate_and_existing_geometry(self):
        for hardware in (self.hardware.replace(b'l2_cache cache',b'no_cache'),
                         self.hardware+b'l2_cache cache\n',
                         self.hardware.replace(b'l2_cache cache',b'l2_cache #(.CACHE_SETS(1024)) cache')):
            with self.subTest(hardware=hardware), self.assertRaises(freeze.FreezeError):
                freeze.hardware_system(hardware,self.sim)


class SourceClosure(unittest.TestCase):
    def setUp(self):
        self.payload = {name: dict(data=data) for name, data in {
            'ventium/rtl_ven_core.f': b'+incdir+rtl/core\nrtl/core/core.sv\n',
            'ventium/rtl_ven_soc.f': b'// no additional modules\n',
            'ventium/rtl/core/core.sv': b'`include "body.svh"\n',
            'ventium/rtl/core/body.svh': b'// `include "ignored.svh"\n',
        }.items()}

    def test_exact_closure(self):
        self.assertEqual(freeze.source_closure(self.payload),
                         dict(filelist_units=1, include_edges=1))

    def test_unresolved_include(self):
        del self.payload['ventium/rtl/core/body.svh']
        with self.assertRaisesRegex(freeze.FreezeError, 'missing/ambiguous'):
            freeze.source_closure(self.payload)

    def test_ambiguous_include(self):
        self.payload['ventium/body.svh'] = dict(data=b'')
        with self.assertRaisesRegex(freeze.FreezeError, 'missing/ambiguous'):
            freeze.source_closure(self.payload)

    def test_hidden_or_escaping_includes(self):
        for line in (b'`include `DYNAMIC\n', b'`include "../outside.svh"\n',
                     b'`include "/absolute.svh"\n'):
            with self.subTest(line=line), self.assertRaises(freeze.FreezeError):
                self.payload['ventium/rtl/core/core.sv']['data'] = line
                freeze.source_closure(self.payload)

    def test_hidden_or_unresolved_filelist(self):
        for line in (b'-f hidden.f\n', b'+define+EXTRA\n', b'missing.sv\n',
                     b'+incdir+../outside\n', b'/absolute.sv\n'):
            with self.subTest(line=line), self.assertRaises(freeze.FreezeError):
                self.payload['ventium/rtl_ven_soc.f']['data'] = line
                freeze.source_closure(self.payload)

    def test_conditional_missing_include_refused(self):
        self.payload['ventium/rtl/core/core.sv']['data'] = (
            b'`ifdef DISABLED\n`include "missing.svh"\n`endif\n')
        with self.assertRaises(freeze.FreezeError): freeze.source_closure(self.payload)


if __name__ == '__main__': unittest.main()
