import unittest
from pathlib import Path
import re
import subprocess
import tempfile
from ven_total_retire import CAPABILITY, DATA, SELECTOR, read_total_retire


class Counter:
    def __init__(self, values=(), capability=CAPABILITY):
        self.selector = 12
        self.values = iter(values)
        self.capability = capability
        self.writes = []

    def read(self, address):
        if address == SELECTOR:
            return self.selector
        assert address == DATA
        if self.selector == 78:
            return self.capability
        return next(self.values)

    def write(self, address, value):
        assert address == SELECTOR
        self.writes.append(value)
        self.selector = value


class TotalRetireTests(unittest.TestCase):
    def test_actual_shim_mux_all_selectors(self):
        repo = Path(__file__).resolve().parents[2]
        source = (repo/'ao486-sim/ven/ven_ao486_shim.sv').read_text()
        blocks = re.findall(r'    always_comb begin\n        case \(dbg_cmp\[106:100\]\).*?    end\n', source, re.S)
        self.assertEqual(len(blocks), 1)
        self.assertIn('assign dbg_bus = { d_scan_data,', source)
        # Compile the actual selection block, not a second implementation.
        tb = '''module mux_tb;
          logic [127:0] dbg_cmp;
          logic [63:0] v_retire_count;
          logic [31:0] d_arch_data, d_scan_data, expected;
`ifdef VEN_DDR_POSTED
          localparam POSTED=1;
`else
          localparam POSTED=0;
`endif
        ''' + blocks[0] + '''
          initial begin
            dbg_cmp=0;
            for (int k=0;k<32;k++) begin
              dbg_cmp[109:107]=3'(k);
              v_retire_count={32'(k*1234567),32'(32'hffffffff-k*7654321)};
              d_arch_data=32'h12340000|32'(k);
              for (int sel=0;sel<128;sel++) begin
                dbg_cmp[106:100]=7'(sel); #1;
                expected=sel==76 ? v_retire_count[31:0] :
                         sel==77 ? v_retire_count[63:32] :
                         sel==78 ? 32'h55563634 :
                         sel==79 ? (POSTED ? (32'h50440000 | {29'd0,dbg_cmp[109:107]}) : 0) : d_arch_data;
                if(d_scan_data !== expected) $fatal(1,"selector %0d",sel);
              end
            end
            $display("UV64-MUX-OK 4096 cases"); $finish;
          end
        endmodule
        '''
        with tempfile.TemporaryDirectory(prefix='ventium-uv64-') as temp:
            root = Path(temp)
            (root/'tb.sv').write_text(tb)
            for posted in (False,True):
                args=['iverilog','-g2012']+(['-DVEN_DDR_POSTED'] if posted else [])
                build = subprocess.run(args+['-s','mux_tb','-o',str(root/'test'),str(root/'tb.sv')],capture_output=True,text=True,timeout=30)
                self.assertEqual(build.returncode,0,build.stderr)
                run = subprocess.run(['vvp',str(root/'test')],capture_output=True,text=True,timeout=30)
                self.assertEqual(run.returncode,0,run.stdout+run.stderr)
                self.assertIn('UV64-MUX-OK',run.stdout)

    def test_stable_and_preserve_selector(self):
        c = Counter([7, 123, 7])
        self.assertEqual(read_total_retire(c.read, c.write), (7 << 32) | 123)
        self.assertEqual(c.selector, 12)

    def test_low_word_rollover_retries(self):
        c = Counter([0, 0xffffffff, 1, 1, 17, 1])
        self.assertEqual(read_total_retire(c.read, c.write), (1 << 32) | 17)
        self.assertEqual(c.writes, [78, 77, 76, 77, 77, 76, 77, 12])

    def test_old_image_rejected_not_zero(self):
        c = Counter(capability=0)
        with self.assertRaisesRegex(RuntimeError, 'lacks total-U'):
            read_total_retire(c.read, c.write)
        self.assertEqual(c.selector, 12)

    def test_concurrent_selector_is_not_clobbered(self):
        c = Counter()
        def changed_read(address):
            if address == DATA:
                c.selector = 64
                return CAPABILITY
            return c.read(address)
        with self.assertRaisesRegex(RuntimeError, 'concurrently'):
            read_total_retire(changed_read, c.write)
        self.assertEqual(c.selector, 64)

    def test_bounded_retry(self):
        c = Counter([v for i in range(8) for v in (i,0,i+1)])
        with self.assertRaisesRegex(RuntimeError, 'stable'):
            read_total_retire(c.read, c.write)
        self.assertEqual(c.selector, 12)


if __name__ == '__main__':
    unittest.main()
