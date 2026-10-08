"""Compile the actual shim ordering logic; do not duplicate its predicate."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

REPO=Path(__file__).resolve().parents[2]


class OrderingTests(unittest.TestCase):
    def test_actual_io_debug_contract(self):
        source=(REPO/'ao486-sim/ven/ven_ao486_shim.sv').read_text()
        first=source.index('`ifdef VEN_DDR_POSTED\n')
        last=source.index('    // -------------------------------------------------------- A20',first)
        drain=source[first:last]
        first=source.index('    logic io_done_seen;')
        last=source.index('\n`ifdef VEN_DBG_CORE',first)
        io=source[first:last]
        halted=re.search(r'    wire d_platform_halted = .*?;',source)[0]
        step=re.search(r'\.dbg_step\((.*?)\),',source)[1]
        self.assertIn('d_scan_data, d_platform_halted,',source)
        tb='''module ordering_tb;
        logic clk=0; always #5 clk=~clk;
        logic rst_n=0;
        logic [127:0] dbg_cmp=0;
        logic v_m_idle=0, d_halted=0;
        logic v_io_req=0,v_io_we=0,io_read_done=0,io_write_done=0;
        logic [15:0] v_io_addr=0;
        logic [2:0] v_io_size=1;
        logic [31:0] v_io_wdata=0,io_read_data=0;
        wire io_read_do,io_write_do,v_io_ack;
        wire [15:0] io_read_address,io_write_address;
        wire [2:0] io_read_length,io_write_length;
        wire [31:0] io_write_data,v_io_rdata;
        '''+drain+io+halted+'\nwire step='+step+''';
        initial begin
          repeat(3) @(negedge clk); rst_n=1;
          for(int cap=0;cap<2;cap++)
          for(int outer=0;outer<2;outer++)
          for(int inner=0;inner<2;inner++)
          for(int wr=0;wr<2;wr++) begin
            bit ready;
            @(negedge clk); dbg_cmp[108]=1'(cap); dbg_cmp[107]=1'(outer);
            dbg_cmp[65]=1; v_m_idle=1'(inner); d_halted=1;
            v_io_req=1; v_io_we=1'(wr);
`ifdef VEN_DDR_POSTED
            ready=cap && outer && inner;
`else
            ready=1;
`endif
            #1;
            if(d_platform_halted!==ready || step!==ready ||
               io_write_do!==(ready && wr) || io_read_do!==(ready && !wr))
              $fatal(1,"early/blocked ordered effect");
            @(negedge clk); v_io_req=0; dbg_cmp[65]=0; d_halted=0;
          end
          // A delayed external completion holds IN/OUT, then permits one
          // ordinary transaction. Done combinationally suppresses retrigger.
          @(negedge clk); dbg_cmp[108]=1; dbg_cmp[107]=0; v_m_idle=1;
          v_io_req=1; v_io_we=0;
          repeat(8) begin @(negedge clk);
`ifdef VEN_DDR_POSTED
            if(io_read_do) $fatal(1,"I/O before external drain");
`endif
          end
          dbg_cmp[107]=1; #1;
          if(!io_read_do) $fatal(1,"I/O failed to release");
          @(negedge clk); io_read_done=1; io_read_data=32'h12345678; #1;
          if(io_read_do || !v_io_ack || v_io_rdata!=32'h12345678)
            $fatal(1,"completion/retrigger error");
          @(negedge clk); io_read_done=0;
          repeat(4) begin @(negedge clk); if(io_read_do) $fatal(1,"duplicate I/O"); end
          v_io_req=0; @(negedge clk); v_io_req=1; #1;
          if(!io_read_do) $fatal(1,"next request not armed");
          $display("POSTED-ORDERING-OK"); $finish;
        end
        endmodule
        '''
        with tempfile.TemporaryDirectory(prefix='ventium-posted-order-') as temp:
            root=Path(temp); (root/'tb.sv').write_text(tb)
            for posted in (False,True):
                args=['iverilog','-g2012','-DVEN_DBG_CORE']
                if posted: args+=['-DVEN_DDR_POSTED']
                p=subprocess.run(args+['-s','ordering_tb','-o',str(root/'test'),str(root/'tb.sv')],capture_output=True,text=True,timeout=30)
                self.assertEqual(p.returncode,0,p.stderr)
                p=subprocess.run(['vvp',str(root/'test')],capture_output=True,text=True,timeout=30)
                self.assertEqual(p.returncode,0,p.stdout+p.stderr)
                self.assertIn('POSTED-ORDERING-OK',p.stdout)


if __name__=='__main__': unittest.main()
