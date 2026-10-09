#!/usr/bin/env python3
"""Prepare (do not build/run) a private frozen full-PC + real board AXI model.

No live RTL/submodule edits. The installed image's explicit manifest supplies
RTL; current host-source include closure is separately pinned. Snapshots gain
an incompatible AXI-memory prefix: no old DDR-FIFO snapshot migration/repair.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile

REPO=Path(__file__).resolve().parents[1]


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--inputs',type=Path,required=True)
    ap.add_argument('--write-slots',type=int,choices=(4,8,16),default=16)
    args=ap.parse_args()
    frozen=args.inputs.resolve(strict=True)
    scratch=Path(os.environ['TMPDIR']).resolve(strict=True)
    assert scratch==Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert os.statvfs(scratch).f_bavail*os.statvfs(scratch).f_frsize>6*1024**3
    root=Path(tempfile.mkdtemp(prefix='ventium-board-transport-sim.',dir=scratch))
    dst=root/'source'; dst.mkdir()
    digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    manifest=json.loads((frozen/'input-manifest.json').read_text())
    pins={str(frozen/'input-manifest.json'):digest(frozen/'input-manifest.json')}
    def copy(src,target):
        before=digest(src);target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(src,target);assert digest(target)==before==digest(src)
        pins[str(src)]=before
    for record in manifest['files']:
        src=frozen/record['frozen'];assert digest(src)==record['sha256'],src
        relative=Path(record['frozen'])
        if relative.parts[0]=='ventium':copy(src,dst/Path(*relative.parts[1:]))
    # Preserve the pristine serial RTL alongside the actual candidate module.
    copy(frozen/'flow/src/ven_ddram_axi.v',dst/'fpga/ven_ddram_axi.v')
    for rel in ('fpga/ven_ddram_axi_posted.sv','ao486-sim/ven/ven_ao486_shim.sv',
                'ao486-sim/ven/board_transport_ports.svh','ao486-sim/ven/board_transport_body.svh',
                'ao486-sim/ven/board_transport_connections.svh'):
        copy(REPO/rel,dst/rel)

    # Follow quoted host includes only, not RTL directory globs. Generated
    # Verilator headers and the disabled generated delta observer are explicit.
    hosts=['ao486-sim/ven/sim_ven.cpp','ao486-sim/ven/vtm_dpi.cpp',
           'ao486-sim/ps/ps_shim.cpp','ao486-sim/ps/ide.cpp','ao486-sim/ps/support/x86/x86.cpp',
           'ao486-sim/ven/board_axi_memory.h']
    visited=set()
    def host(rel):
        src=(REPO/rel).resolve(strict=True)
        if src in visited:return
        visited.add(src);copy(src,dst/src.relative_to(REPO))
        for inc in re.findall(r'^\s*#\s*include\s*"([^"]+)"',src.read_text(),re.M):
            if inc in ('Vsystem.h','Vsystem___024root.h','verilated.h','verilated_save.h','ven_state_fields.inc'):continue
            candidates=[src.parent/inc,REPO/'ao486-sim/ps'/inc,REPO/'ao486-sim/ven'/inc]
            found=next((p for p in candidates if p.is_file()),None)
            if found is None:raise RuntimeError(f'unresolved host include: {src}: {inc}')
            host(found.relative_to(REPO))
    for rel in hosts:host(Path(rel))
    def once(text,old,new):
        assert text.count(old)==1,old
        return text.replace(old,new)

    system=dst/'3rd-party/ao486_MiSTer/rtl/system.v'
    text=system.read_text()
    text=once(text,'module system\n(', 'module system #(parameter BOARD_POSTED=1, parameter BOARD_WRITE_SLOTS=16)\n(\n`include "board_transport_ports.svh"')
    text=once(text,'l2_cache cache','`include "board_transport_body.svh"\n\nl2_cache cache')
    for port,net in (('DDRAM_BUSY','board_ddram_busy'),('DDRAM_DOUT','board_ddram_data'),('DDRAM_DOUT_READY','board_ddram_valid')):
        text,count=re.subn(r'(\.'+port+r'\s*\()'+port+r'(\))',r'\g<1>'+net+r'\2',text)
        assert count==1,port
    text,count=re.subn(r'(\.dbg_cmp\s*\()cpu_dbg_cmp(\))',r'\1board_dbg_cmp\2',text);assert count==1
    system.write_text(text)

    harness=dst/'ao486-sim/ven/sim_ven.cpp'
    text=harness.read_text()
    text=once(text,'#include "verilated_save.h"','#include "verilated_save.h"\n#include "board_axi_memory.h"\nstatic ven_board::AxiMemory board_memory;')
    text=once(text,'    set_clocks(0); top->eval();','''    set_clocks(0);
    // The external AXI domain resets only at initial power-on, not guest reset.
    top->board_axi_resetn = main_time >= 4;
    board_memory.drive(*top, main_time, [](uint32_t a) {
        a &= DDR_WORDS-1;
        return (g_mem_top_words && a>=g_mem_top_words) ?
            ~((uint64_t)a*0x0100000001000001ull) : ddr[a];
    });
    top->eval();''')
    text=once(text,'    set_clocks(1); step_vga_clock(); top->eval();','''    // Sample settled handshakes before this edge; commit only real B events.
    board_memory.sample(*top, main_time, [](uint32_t a,uint64_t value,uint8_t be) {
        a &= DDR_WORDS-1;
        if(g_mem_top_words && a>=g_mem_top_words) return;
        uint64_t mask=0;
        for(unsigned lane=0;lane<8;lane++) if(be&(1u<<lane)) mask|=uint64_t(255)<<(8*lane);
        ddr[a]=(ddr[a]&~mask)|(value&mask);
        if(uint64_t(a)*8>g_max_waddr) g_max_waddr=uint64_t(a)*8;
    });
    set_clocks(1); step_vga_clock(); top->eval();
    if(top->board_transport_fault) throw std::runtime_error("real board transport fault");''')
    text=once(text,'    ddr_service(); top->eval();','    // Real transport RTL + AXI memory model exclusively own DDR here.\n    top->eval();')
    text=once(text,'    VerilatedSave os; os.open(fn);','''    VerilatedSave os; os.open(fn);
    board_memory.save(os);
    const uint32_t board_profile=(VEN_BOARD_POSTED_PROFILE<<8)|VEN_BOARD_WRITE_SLOTS;
    os.write(&board_profile,sizeof(board_profile));''')
    text=once(text,'    VerilatedRestore is; is.open(fn);','''    VerilatedRestore is; is.open(fn);
    board_memory.load(is);
    uint32_t board_profile=99; is.read(&board_profile,sizeof(board_profile));
    if(board_profile!=((VEN_BOARD_POSTED_PROFILE<<8)|VEN_BOARD_WRITE_SLOTS)) checkpoint_fail("board transport snapshot profile/depth mismatch");''')
    old=next(x for x in text.splitlines() if 'getenv("FPGA_DDR")' in x)
    text=once(text,old,'''    if(const char* e=getenv("FPGA_DDR")) {
        if(strcmp(e,"3")) { fprintf(stderr,"real board-transport model requires FPGA_DDR=3\\n"); return 2; }
    }
    g_fpga_ddr=3;
    fprintf(stderr,"[BOARD_AXI] real RTL profile=%d slots=%d B-delay=20 R-first=21 gap=1; new snapshot prefix\\n",VEN_BOARD_POSTED_PROFILE,VEN_BOARD_WRITE_SLOTS);''')
    # Give the harness a unique basename, avoiding historical VPATH object reuse.
    harness.unlink()
    (harness.parent/'sim_board_transport.cpp').write_text(text)
    defs=(frozen/'defines.txt').read_text().splitlines()
    assert len(defs)==113 and 'VEN_DDR_POSTED' not in defs
    defs=[d for d in defs if d not in ('SYNTHESIS','VTM_NO_DPI','VEN_ALTSYNCRAM_XPM')]+['VEN_DDR_POSTED']
    copy(frozen/'defines.txt',root/'baseline-defines.txt')
    (root/'defines.txt').write_text('\n'.join(defs)+'\n')
    assert all(digest(Path(p))==h for p,h in pins.items())
    (root/'prepared.json').write_text(json.dumps(dict(qualification='UNBUILT_EXPERIMENTAL_BOARD_TRANSPORT_SIM',
        baseline_manifest=pins[str(frozen/'input-manifest.json')],source_pins=pins,
        simulator_defines=defs,build_profiles=[0,1],write_slots=args.write_slots,host_sources=hosts,
        note='All standard/differential acceptance and gameplay measurements remain pending'),indent=2)+'\n')
    print(root)


if __name__=='__main__':main()
