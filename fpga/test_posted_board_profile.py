#!/usr/bin/env python3
"""Apply the opt-in board patch to a scratch copy and test real Tcl admission."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    frozen=Path(sys.argv[1]).resolve(strict=True)
    here=Path(__file__).resolve().parent
    repo=here.parent
    scratch=Path(os.environ['TMPDIR']).resolve(strict=True)
    assert scratch==Path('/home/yukidama/external/tmp').resolve(strict=True)
    original=frozen/'flow/src/rk_ao486_system_pl.v'
    digest=lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    pin=digest(original)
    with tempfile.TemporaryDirectory(prefix='ventium-posted-profile.',dir=scratch) as directory:
        root=Path(directory); flow=root/'flow'; source=root/'source'
        (flow/'hw').mkdir(parents=True); (flow/'src').mkdir()
        shutil.copyfile(frozen/'flow/hw/create_project.tcl',flow/'hw/create_project.tcl')
        top=flow/'src/rk_ao486_system_pl.v'; shutil.copyfile(original,top)
        shim=source/'ao486-sim/ven/ven_ao486_shim.sv'; shim.parent.mkdir(parents=True)
        shim.write_text((repo/'ao486-sim/ven/ven_ao486_shim.sv').read_text())
        (source/'fpga').mkdir()
        shutil.copyfile(here/'ven_ddram_axi_posted.sv',source/'fpga/ven_ddram_axi_posted.sv')
        p=subprocess.run(['patch','--batch','--forward','-p3','-i',str(here/'patches/0010-posted-ddr-transport.patch')],
                         cwd=flow,capture_output=True,text=True,timeout=10)
        assert p.returncode==0,p.stdout+p.stderr
        defs=(frozen/'defines.txt').read_text().splitlines()
        assert len(defs)==113 and defs[110:]==['SYNTHESIS','VTM_NO_DPI','VEN_ALTSYNCRAM_XPM']
        profile=root/'defines.txt'
        profile.write_text('\n'.join(defs[:110]+['VEN_DDR_POSTED']+defs[110:])+'\n')
        def check(error=None):
            p=subprocess.run(['tclsh',str(here/'test_rk_wrapper.tcl'),
                str(here/'create_project_3mhz_wrapper.tcl'),str(flow),str(profile),
                str(source),str(frozen/'template')],capture_output=True,text=True,timeout=10)
            out=p.stdout+p.stderr
            if error is None:
                assert p.returncode==0 and 'POSTED-DDR-SOURCE-CONTRACT-OK' in out,out
            else:
                assert p.returncode!=0 and error in out,out
        check()
        top_text=top.read_text(); shim_text=shim.read_text()
        for before,after in (('.drained(ddr_posted_drained)', '.drained()'),
                            ("18'd0, ddr_posted_fault, 1'b1, ddr_posted_drained", "21'd0"),
                            ('.WRITE_SLOTS(16)', '.WRITE_SLOTS(1)')):
            assert top_text.count(before)==1
            top.write_text(top_text.replace(before,after)); check('platform drain wiring missing')
        top.write_text(top_text)
        for before,after in (('dbg_cmp[108] && dbg_cmp[107] && v_m_idle','v_m_idle'),
                            ('d_halted && platform_memory_drained','d_halted'),
                            ('.dbg_step(dbg_cmp[65] & platform_memory_drained)', '.dbg_step(dbg_cmp[65])')):
            assert shim_text.count(before)==1
            shim.write_text(shim_text.replace(before,after)); check('shim drain wiring missing')
        for signal in ('io_read_do','io_write_do'):
            line=next(x for x in shim_text.splitlines() if 'assign '+signal+' ' in x)
            assert '& platform_memory_drained;' in line
            shim.write_text(shim_text.replace(line,line.replace(' & platform_memory_drained','')))
            check('shim drain wiring missing: '+signal)
        shim.write_text(shim_text)
        # Compile the actual patched packed-control assignment. Check all
        # transport status combinations and preservation of the 107 old bits.
        start=top_text.index("    assign cpu_dbg_cmp = {18'd0")
        pack=top_text[start:top_text.index(';',start)+1]
        tb='''module pack_tb;
          logic ddr_posted_fault,ddr_posted_drained;
          logic [6:0] dbg_arch_sel;
          logic dbg_bp_clr,dbg_bp_en,dbg_step,dbg_halt_req;
          logic [31:0] dbg_bp_addr,dbg_cmp_range,dbg_cmp_cfg;
          logic [106:0] old_bits;
          wire [127:0] cpu_dbg_cmp;
        '''+pack+'''
          initial begin
            for(int pattern=0;pattern<32;pattern++) begin
              old_bits={32'(pattern*345679),32'(pattern*234577),32'(pattern*123457),11'(pattern)};
              {dbg_arch_sel,dbg_bp_clr,dbg_bp_addr,dbg_bp_en,dbg_step,dbg_halt_req,dbg_cmp_range,dbg_cmp_cfg}=old_bits;
              for(int fault=0;fault<2;fault++) for(int drained=0;drained<2;drained++) begin
                ddr_posted_fault=1'(fault); ddr_posted_drained=1'(drained); #1;
                if(cpu_dbg_cmp[127:110]!==0 || cpu_dbg_cmp[109]!==1'(fault) ||
                   cpu_dbg_cmp[108]!==1 || cpu_dbg_cmp[107]!==1'(drained) ||
                   cpu_dbg_cmp[106:0]!==old_bits) $fatal(1,"packed-control mismatch");
              end
            end
            $display("POSTED-PACK-OK"); $finish;
          end
        endmodule
        '''
        (root/'pack.sv').write_text(tb)
        p=subprocess.run(['iverilog','-g2012','-s','pack_tb','-o',str(root/'pack'),str(root/'pack.sv')],capture_output=True,text=True,timeout=10)
        assert p.returncode==0,p.stderr
        p=subprocess.run(['vvp',str(root/'pack')],capture_output=True,text=True,timeout=10)
        assert p.returncode==0 and 'POSTED-PACK-OK' in p.stdout,p.stdout+p.stderr
    assert digest(original)==pin
    print('POSTED-BOARD-PROFILE-OK: 9 admission cases, 128 control-pack cases; no Vivado or deployment')


if __name__=='__main__': main()
