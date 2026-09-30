// vtm_dpi.cpp — Ventium retire-observation DPI for the ao486-SoC co-sim.
//
// The Ventium core (ventium_top, built WITHOUT VTM_NO_DPI) calls vtm_retire() once
// per retired instruction with the post-commit architectural state, plus vtm_retire_sys
// (cr0/cr2/cr3/cr4), vtm_retire_cycle (pipe/pairing), vtm_retire_x87 (FP state). The
// ao486 build observed the core via Verilated-model member reads; the Ventium build
// uses these callbacks instead. We latch the last-retired state into globals that the
// harness (sim_main.cpp, under VEN_CORE) reads for its periodic eip trace — no core
// internals are poked. See docs/rtl-interface.md §2.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include "../../tools/retire_fault_ring.h"
extern uint64_t *ddr;   // cosim guest memory (sim_ven.cpp)
extern double sc_time_stamp();  // absolute harness cycle, including restored time
extern "C" int ao486_peek_guest(unsigned int phys, void *dst, int nbytes);  // guest-RAM read (sim_ven.cpp)
// Disabled by default; the cold-run harness owns this passive bounded observer.
ven_host::RetireFaultRing *g_vtm_fault_ring = nullptr;

// ---- last-retired architectural snapshot (read by the harness trace) ----------
extern "C" {
uint64_t g_vtm_n        = 0;   // monotonic retire count (core's own counter + 1 on wrap)
uint64_t g_vtm_retires  = 0;   // instructions retired since reset (harness-side)
uint32_t g_vtm_eip      = 0;   // fetch vaddr of the last retired insn
uint32_t g_vtm_eflags   = 0;
uint32_t g_vtm_eax=0,g_vtm_ecx=0,g_vtm_edx=0,g_vtm_ebx=0;
uint32_t g_vtm_esp=0,g_vtm_ebp=0,g_vtm_esi=0,g_vtm_edi=0;
uint16_t g_vtm_cs=0,g_vtm_ss=0,g_vtm_ds=0,g_vtm_es=0,g_vtm_fs=0,g_vtm_gs=0;
uint32_t g_vtm_cr0=0,g_vtm_cr2=0,g_vtm_cr3=0,g_vtm_cr4=0;
// Optional bounded architectural trace, configured by the harness.  The start
// is an absolute post-reset retire number; zero preserves the "first N" form.
int      g_vtm_dump = 0;
uint64_t g_vtm_dump_start = 0;
}

// DPI arm for the ven_l1d [0x607] RMW probe: active during the COMMAND.COM open (disk reads 66..72),
// timing-independent (cycle windows drift with probe overhead). ven_l1d imports this and gates its
// $display forensics on it, so the multiply's store/load are always captured.
extern "C" int ven_l1607_arm() {
    extern volatile unsigned long g_disk_reads;
    return (g_disk_reads >= 66 && g_disk_reads <= 72) ? 1 : 0;
}

extern "C" void vtm_retire(
    unsigned long long n, unsigned int pc, unsigned int eflags,
    unsigned int eax, unsigned int ecx, unsigned int edx, unsigned int ebx,
    unsigned int esp, unsigned int ebp, unsigned int esi, unsigned int edi,
    unsigned short cs, unsigned short ss, unsigned short ds,
    unsigned short es, unsigned short fs, unsigned short gs)
{
    g_vtm_n = n;  g_vtm_retires++;
    g_vtm_eip = pc; g_vtm_eflags = eflags;
    g_vtm_eax=eax; g_vtm_ecx=ecx; g_vtm_edx=edx; g_vtm_ebx=ebx;
    g_vtm_esp=esp; g_vtm_ebp=ebp; g_vtm_esi=esi; g_vtm_edi=edi;
    g_vtm_cs=cs; g_vtm_ss=ss; g_vtm_ds=ds; g_vtm_es=es; g_vtm_fs=fs; g_vtm_gs=gs;
    if (g_vtm_fault_ring && g_vtm_fault_ring->enabled()) {
        ven_host::FaultRetireSnapshot snapshot;
        snapshot.retire = g_vtm_retires;
        snapshot.core_n = n;
        snapshot.cycle = uint64_t(sc_time_stamp());
        snapshot.fetch_pc = pc;
        snapshot.eflags = eflags;
        snapshot.gpr = {eax, ecx, edx, ebx, esp, ebp, esi, edi};
        snapshot.seg = {cs, ss, ds, es, fs, gs};
        g_vtm_fault_ring->retire(snapshot);
    }
    if (g_vtm_dump > 0 && g_vtm_retires >= g_vtm_dump_start) {
        fprintf(stderr,
                "VTM n=%llu %04x:%08x fl=%08x ax=%08x bx=%08x cx=%08x dx=%08x si=%08x di=%08x bp=%08x sp=%08x ds=%04x es=%04x ss=%04x fs=%04x gs=%04x cyc=%llu\n",
                (unsigned long long)g_vtm_retires, cs, pc, eflags,
                eax, ebx, ecx, edx, esi, edi, ebp, esp, ds, es, ss, fs, gs,
                (unsigned long long)sc_time_stamp());
        g_vtm_dump--;
    }
    // [PCTRACE] compact retire trace for the golden-lockstep diff (VEN_PCTRACE=<path>).
    // One line per retire: "<n> <cs>:<eip> esp=<esp> eax=<eax> ecx=<ecx>" — enough to align vs the QEMU
    // golden and spot the first register divergence (esp is the known divergent: golden 0x11b230 vs 0x11b354).
    {
        // [VEN-CODEDUMP] one-shot: bytes of the handler instruction at cs=0018:0x3f49 (phys 0x2aa09) — is it
        // a relative jmp (Ventium spuriously reads ds:[esi]) or jmp [esi] (a jump table)?  Also dump the
        // ds:[esi] target neighborhood for both the small (0x758->0x2ce58) and fatal (0x11b354->0x147a54) esi.
        // [VEN-NULLPTR] the 2nd bug: at cs=00a7:0x515b4 `call eax` with eax=0. The pointer came from
        // `mov eax,[0x5c000]` (linear 0x1005c000). Translate via cr3=0x7e000 and read the ACTUAL table entry
        // from the backing: if it is NON-ZERO -> Ventium's LOAD spuriously returned 0 (a load bug); if it is 0
        // -> the pointer table was never populated (an upstream write/init bug).
        static int nullptr_done = 0;
        if (!nullptr_done && cs==0x00a7 && pc==0x000515b4 && eax==0 && ddr) {
            nullptr_done = 1;
            unsigned char *m=(unsigned char*)ddr;
            auto rd=[&](unsigned a){ return (unsigned)(m[a]|(m[a+1]<<8)|(m[a+2]<<16)|((unsigned)m[a+3]<<24)); };
            unsigned pde40 = rd(0x7e100);            // 0x1005c000>>22 = 0x40
            unsigned ptbase = pde40 & 0xfffff000u;
            unsigned pte5c = rd(ptbase + 0x5c*4);    // (0x1005c000>>12)&0x3ff = 0x5c
            unsigned phys  = (pte5c & 0xfffff000u);  // + (0x1005c000 & 0xfff)=0
            unsigned tblval = (pte5c&1) ? rd(phys) : 0xDEADBEEF;   // the actual [0x5c000] function pointer
            unsigned tbl4[4]; for(int i=0;i<4;i++) tbl4[i]=(pte5c&1)?rd(phys+i*4):0;
            fprintf(stderr, "[VEN-NULLPTR] call eax=0 @00a7:515b4 ebx=%08x | PDE40=%08x PTbase=%08x PTE5c=%08x(P=%d) phys(0x1005c000)=%08x | MEM[0x5c000..0f]=%08x %08x %08x %08x  (loaded eax=0)\n",
                    ebx, pde40, ptbase, pte5c, pte5c&1, phys, tbl4[0],tbl4[1],tbl4[2],tbl4[3]);
        }
        static int codedump2_done = 0;
        if (!codedump2_done && (cs==0x002b || cs==0x0018) && pc>=0x000010d0 && pc<=0x000010de) {
            codedump2_done = 1;
            unsigned char b[32]; ao486_peek_guest(0x00027b90, b, 32);  // 0x26ac0+0x10d0 .. +0x10ef
            fprintf(stderr, "[VEN-HALT10E0] cs=%04x eip=0x%04x; code@lin0x10d0 (phys0x27b90):\n  ", cs, pc);
            for (int i=0;i<32;i++) { fprintf(stderr, "%02x ", b[i]); if ((i&15)==15) fprintf(stderr, "\n  "); }
            fprintf(stderr, "  (0x10e0=byte[0x10]; 0xf4=HLT 0xfa=CLI 0xcd=INT 0xcf=IRET)\n");
            // dump the VGA text buffer (0xB8000, 80x25, char@even bytes) — Sys_Error prints here; so does DOS.
            unsigned char v[4000]; ao486_peek_guest(0x000b8000, v, 4000);
            fprintf(stderr, "[VEN-VGATEXT] 0xB8000 (guest console at halt):\n");
            for (int row=0; row<25; row++) {
                char line[81]; int any=0;
                for (int col=0; col<80; col++) { unsigned char c=v[(row*80+col)*2]; line[col]=(c>=32&&c<127)?c:' '; if(c>=32&&c<127)any=1; }
                line[80]=0; // trim trailing spaces
                int e=80; while(e>0 && line[e-1]==' ') e--; line[e]=0;
                if (any && e>0) fprintf(stderr, "  |%s\n", line);
            }
        }
        static FILE *pctf = (FILE*)-1;
        static unsigned long long pctf_start = 0;
        if (pctf == (FILE*)-1) { const char *p = getenv("VEN_PCTRACE"); pctf = p ? fopen(p, "w") : nullptr;
            const char *st = getenv("VEN_PCTRACE_START"); pctf_start = st ? strtoull(st, 0, 0) : 4600000ull; }
        // gate to the cascade region (retire >= 4.60M, env-overridable), add DS + EFLAGS (bit9=IF) for the halt-idle analysis.
        if (pctf && g_vtm_retires >= pctf_start)
            fprintf(pctf, "%llu %04x:%08x esp=%08x eax=%08x ecx=%08x esi=%08x edi=%08x edx=%08x ds=%04x efl=%08x IF=%d\n",
                          (unsigned long long)g_vtm_retires, cs, pc, esp, eax, ecx, esi, edi, edx, ds, eflags, (eflags>>9)&1);
    }
    // [ESITRAN] Catch the EXACT instruction that first sets esi := 0x11b354 (the fatal
    // base-0x10000000 buffer-end pointer used with a base-0x2c700 segment). Log the
    // transition retire + the 4 preceding retires (PC/esi/edx/ds) so we see whether it's
    // a `mov esi,[mem]` load, a `mov esi,edx` copy, `lodsd`, or a `pop esi`.
    {
        static unsigned int  hist_pc[5]={0,0,0,0,0};
        static unsigned int  hist_esi[5]={0,0,0,0,0};
        static unsigned int  hist_edx[5]={0,0,0,0,0};
        static unsigned short hist_cs[5]={0,0,0,0,0}, hist_ds[5]={0,0,0,0,0};
        static unsigned int  prev_esi = 0;
        static int esitran_hits = 0;
        if (esi == 0x11b354 && prev_esi != 0x11b354 && esitran_hits < 12) {
            esitran_hits++;
            // DECISIVE: read the BACKING (DDR MemModel) at the TSS0070.esi field 0x315ba.
            // If backing==0x11b354 -> a PS/DMA direct write corrupted the backing (cosim/coherence).
            // If backing==0x00000770 (or the last core-written value) -> the phantom is L1-RESIDENT
            //   (ven_l1d returned a stale/aliased line that the backing never held) = pure RTL bug.
            unsigned int back = 0, back2 = 0;
            if (ddr) { unsigned char *m=(unsigned char*)ddr;
                back  = m[0x315ba] | (m[0x315bb]<<8) | (m[0x315bc]<<16) | ((unsigned)m[0x315bd]<<24);
                back2 = m[0x2ff5a] | (m[0x2ff5b]<<8) | (m[0x2ff5c]<<16) | ((unsigned)m[0x2ff5d]<<24); }
            fprintf(stderr, "[ESITRAN] esi %08x->%08x @ %04x:%08x ds=%04x edx=%08x eax=%08x ebx=%08x ecx=%08x edi=%08x retire=%llu | BACKING[0x315ba]=%08x BACKING[0x2ff5a]=%08x %s\n",
                    prev_esi, esi, cs, pc, ds, edx, eax, ebx, ecx, edi, (unsigned long long)g_vtm_retires,
                    back, back2, (back==0x11b354)?"<<TSS-BACKING-CORRUPT":"<<TSS-L1-PHANTOM");
            // [CSTKPTE] Is the CLIENT STACK page 0x1011b000 mapped? (golden PTE @0x7c46c = 0x001dba67 present)
            // Read Ventium's page tables from the backing: cr3=0x7e000 -> PDE[0x40]@0x7e100 -> PT -> PTE(0x11b).
            if (ddr) { unsigned char *m=(unsigned char*)ddr;
                auto rd=[&](unsigned a){ return (unsigned)(m[a] | (m[a+1]<<8) | (m[a+2]<<16) | ((unsigned)m[a+3]<<24)); };
                unsigned pde40 = rd(0x7e100);
                unsigned ptbase = pde40 & 0xfffff000u;
                unsigned pte11b = rd(ptbase + 0x11b*4);
                unsigned pteAt7c46c = rd(0x7c46c);
                fprintf(stderr, "[CSTKPTE] PDE[0x40]@0x7e100=%08x PTbase=%08x PTE(0x1011b000)@%08x=%08x  PTE@0x7c46c=%08x  (golden PTE=0x001dba67 present; present iff bit0=1)\n",
                        pde40, ptbase, ptbase+0x11b*4, pte11b, pteAt7c46c);
            }
            for (int k=0;k<5;k++)
                fprintf(stderr, "[ESITRAN]   prev[-%d] %04x:%08x esi=%08x edx=%08x ds=%04x\n",
                        5-k, hist_cs[k], hist_pc[k], hist_esi[k], hist_edx[k], hist_ds[k]);
        }
        for (int k=0;k<4;k++){hist_pc[k]=hist_pc[k+1];hist_esi[k]=hist_esi[k+1];hist_edx[k]=hist_edx[k+1];hist_cs[k]=hist_cs[k+1];hist_ds[k]=hist_ds[k+1];}
        hist_pc[4]=pc;hist_esi[4]=esi;hist_edx[4]=edx;hist_cs[4]=cs;hist_ds[4]=ds;
        prev_esi = esi;
    }
    // FILE-SEARCH SEQUENCE: the DOS SDA search-FCB name lives at guest 0x11DB (11 bytes, 8.3 space-padded).
    // Log it whenever it changes to a valid-looking name -> the exact order of filename searches during
    // SYSINIT. Shows whether "COMMAND COM" is ever searched (path resolves) and around which retire, so we
    // can pinpoint that dir-scan/compare. Only active once the DOS data seg is up (after many retires).
    if (ddr && g_vtm_retires > 200000) {
        unsigned char *m = (unsigned char *)ddr;
        static unsigned char last[11] = {0};
        if (memcmp(m + 0x11DB, last, 11)) {
            unsigned char *nm = m + 0x11DB; int ok = (nm[0] > 0x20 && nm[0] < 0x7f);
            for (int k = 0; k < 11 && ok; k++) { unsigned char c = nm[k]; if (!((c >= 0x20 && c < 0x7f))) ok = 0; }
            memcpy(last, nm, 11);
            if (ok) {
                fprintf(stderr, "[FCBSEARCH] retire=%llu %04x:%04x name='", (unsigned long long)g_vtm_retires, cs, pc & 0xffff);
                for (int k = 0; k < 11; k++) fprintf(stderr, "%c", nm[k]);
                fprintf(stderr, "'\n");
            }
        }
    }
    // LBA-HIGH-WORD probe: at 0852:0087 (`mov dx,[es:bx+0x1c]`) the driver loads the disk sector's HIGH
    // word for the 32-bit LBA. For COMMAND.COM it should be 0x0002 (LBA 0x2F3C0); it's coming out 0
    // (-> LBA truncated to 0xF3C0=62400 -> wrong sector -> "corrupted"). Compare the loaded dx to the
    // actual memory [es:bx+0x1c]: if mem==2 but dx==0 -> a LOAD bug; if mem==0 -> the store dropped it.
    if (ddr && cs==0x0852 && pc==0x0087) {
        unsigned char *m=(unsigned char*)ddr;
        uint32_t a=((es&0xffff)<<4)+((ebx+0x1c)&0xffff);
        unsigned memv = m[a] | (m[a+1]<<8);
        static int nlog=0;
        if (nlog<8) { fprintf(stderr,"[LBAHI] es:bx+0x1c @%05x  mem=%04x  core-loaded dx=%04x  %s\n",
            a, memv, edx&0xffff, (memv!=(edx&0xffff))?"*** LOAD MISMATCH (core!=mem) ***":(memv==0?"(mem is 0 -> store dropped high word)":"")); nlog++; }
    }
    // SECTOR-HIGH-WORD load probe: at 0756:84ce (`mov ax, ss:[0x607]`) the driver loads the sector high
    // word. It's coming out ax=0 but the cluster->sector routine set ss:[0x607]=0x2. Compare loaded ax to
    // the ACTUAL memory ss:[0x607]: if mem==2 but ax==0 -> a LOAD returns wrong data (THE Ventium bug);
    // if mem==0 -> ss:[0x607] was clobbered by a register-based store before this load.
    if (ddr && cs==0x0756 && pc==0x84ce) {
        unsigned char *m=(unsigned char*)ddr;
        uint32_t a=((ss&0xffff)<<4)+0x607;
        unsigned memv = m[a] | (m[a+1]<<8);
        static int nlog2=0;
        if (nlog2<12) { fprintf(stderr,"[SECHI] ss:[0x607] @%05x  mem=%04x  core-loaded ax=%04x  %s\n",
            a, memv, eax&0xffff, (memv!=(eax&0xffff))?"*** LOAD BUG: core-load != memory ***":(memv==0?"(mem=0: [0x607] was clobbered upstream)":"OK")); nlog2++; }
    }
    // H607 WATCH (root-cause of LBA truncation): track ss:[0x607] high word (linear 0x1297, ss=0x00c9)
    // evolution. The cluster->sector multiword shift (cs=0756:0xb9cc `rcl [0x607],1` loop) SHOULD leave
    // it = 0x0002 for COMMAND.COM; it reads 0 later at the port write. Does the multiply write 0x0002 and
    // it gets clobbered, or does the multiply itself never accumulate? Log every change with the writer PC.
    if (ddr && g_vtm_retires > 200000) {
        unsigned char *m=(unsigned char*)ddr;
        static unsigned last607 = 0xffffffffu;
        unsigned cur = m[0x1297] | (m[0x1298]<<8);
        static int nchg=0;
        if (cur != last607) {
            if (nchg<160) fprintf(stderr,"[H607chg] 0x1297: %04x -> %04x  by %04x:%04x ret=%llu cf=%d dx=%04x\n",
                last607&0xffff, cur, cs, pc&0xffff, (unsigned long long)g_vtm_retires, (int)(eflags&1), edx&0xffff);
            last607 = cur; nchg++;
        }
    }
    // MULLOOP: per-iteration view of the rcl multiword shift (cs=0756:0xb9cc..0xb9d6). Shows CF into each
    // `rcl [0x607]` and the running mem[0x607], across all 6 shift iterations, for the COMMAND.COM sector.
    if (ddr && cs==0x0756 && pc>=0xb9c6 && pc<=0xb9e4) {
        unsigned char *m=(unsigned char*)ddr;
        unsigned hi = m[0x1297] | (m[0x1298]<<8);
        static int nml=0;
        if (nml<120) { fprintf(stderr,"[MULLOOP] pc=%04x cf=%d dx=%08x mem[607]=%04x cx=%04x ret=%llu\n",
            pc&0xffff, (int)(eflags&1), edx, hi, ecx&0xffff, (unsigned long long)g_vtm_retires); nml++; }
    }
    // BUFFER-CACHE SEARCH probe: at 0756:bf7d (`cmp dx,[di+6]`) during the COMMAND.COM sector search
    // (dx=0xEBC0), log the buffer's cached sector [ds:di+6]. If ANY buffer == 0xEBC0 -> the read completed
    // and the memory-operand compare mis-executes (compare bug). If none -> the async read never fills it.
    if (ddr && cs==0x0756 && pc==0xbf7d && (edx&0xffff)==0xebc0) {
        unsigned char *m=(unsigned char*)ddr;
        uint32_t a=((ds&0xffff)<<4)+((edi+6)&0xffff);
        unsigned sec = m[a] | (m[a+1]<<8);
        int zf=(eflags>>6)&1;
        static int nlog=0;
        if (nlog<60) { fprintf(stderr,"[BUFSEARCH] di=%04x mem[di+6]=%04x dx=ebc0 -> core-cmp ZF=%d %s\n",
            edi&0xffff, sec, zf, (sec==0xebc0)?(zf?"MATCH-OK":"*** STALE-LOAD: mem=ebc0 but core says NOT-equal ***"):""); nlog++; }
    }
    // TEMP diagnostic: does the cosim traverse the VGA-BIOS mode-set loop (cs=c000 eip 0x6E00-0x7600)
    // that the FPGA hangs in? Log entries + the exit target so we can compare divergence.
    {
        // POST code: out al,(0x80). Log each distinct POST code (progression through POST).
        static int last_post = -1;
        if (cs == 0xf000 && pc == 0x0556 && (edx & 0xffff) == 0x0080) {
            int code = eax & 0xff;
            if (code != last_post) { last_post = code;
                fprintf(stderr, "[POST] code=%02x at retire=%llu\n", code, (unsigned long long)g_vtm_retires);
            }
        }
        // INT19 (boot) / int13 disk activity: watch for POST completion.
        static int seen_boot = 0;
        if (!seen_boot && cs == 0x0000 && pc == 0x7c00) { seen_boot = 1;
            fprintf(stderr, "[BOOT] reached boot sector 0000:7c00 at retire=%llu\n", (unsigned long long)g_vtm_retires);
        }
        // POST 0x77 outer loop: log the cs=f000 execution flow (dedup consecutive eip buckets, skip
        // io helpers 0x530-0x560) in a window deep in the stall, to reveal the loop + its branch.
        // Does the VGA-BIOS init (far-called by the option-ROM scan at 0x8b45) ever RETURN (0x8b48)?
        static long call_n = 0, ret_n = 0;
        if (cs == 0xf000 && pc == 0x8b45) { call_n++;
            fprintf(stderr, "[VGAINIT-CALL] #%ld cx(seg)=%04x at retire=%llu\n", call_n, ecx & 0xffff, (unsigned long long)g_vtm_retires); }
        if (cs == 0xf000 && pc == 0x8b48) { ret_n++;
            fprintf(stderr, "[VGAINIT-RET]  #%ld at retire=%llu\n", ret_n, (unsigned long long)g_vtm_retires); }
        // Does the scan advance now? cx at 0x8bc2 (cmp cx,ax): 0xc800=done, 0xc000=still looping.
        static int nadv2 = 0;
        if (cs == 0xf000 && pc == 0x8bc2 && nadv2 < 8) { nadv2++;
            fprintf(stderr, "[SCANADV] cx=%04x end=%04x (retire=%llu)\n", ecx & 0xffff, eax & 0xffff, (unsigned long long)g_vtm_retires); }
        // The moffs MOV bug: 0x8b26 `mov al,[0x0002]` (opcode a0) with ds=0xc000 should read c0002.
        // Log the core's al AT 0x8b29 (post-mov) vs guest RAM at c0002 (correct) and at 0002 (ds=0 read).
        static int chk = 6;
        if (chk && cs == 0xf000 && pc == 0x8b29) { chk--;
            unsigned char *m = (unsigned char *)ddr;
            fprintf(stderr, "[MOFFS] core al=%02x | RAM[c0002]=%02x (correct) RAM[0002]=%02x (ds=0) | ds=%04x (retire=%llu)\n",
                    eax & 0xff, m[0xc0002], m[0x0002], ds, (unsigned long long)g_vtm_retires);
        }
        // QUAKE HANG probe: the DOS-extender/Quake spins at cs=0087:eip~0x334 (both cosim + FPGA).
        // Log the loop body's register evolution (CX countdown, flags, the tested operands) to see WHY
        // it never exits — a mis-decremented LOOP/JCXZ, a stuck flag, or a wait on a value that stays put.
        {
            static int qh = 0;
            if (cs == 0x0087 && (pc & 0xffff) >= 0x320 && (pc & 0xffff) <= 0x360 && qh < 120) {
                qh++;
                fprintf(stderr, "[QHANG] %04x:%04x fl=%08x ax=%08x bx=%08x cx=%08x dx=%08x si=%08x di=%08x bp=%08x sp=%08x ds=%04x es=%04x ss=%04x\n",
                        cs, pc & 0xffff, eflags, eax, ebx, ecx, edx, esi, edi, ebp, esp, ds, es, ss);
            }
        }
        // Localize the stack corruption: log sp at the scan's key points during the FIRST scan pass.
        static int trace_scan = 1;
        if (trace_scan && cs == 0xf000) {
            if      (pc == 0x8b35) fprintf(stderr, "[SP] 0x8b35 pre-pushes  sp=%04x ax=%04x\n", esp & 0xffff, eax & 0xffff);
            else if (pc == 0x8b48) fprintf(stderr, "[SP] 0x8b48 vga-ret     sp=%04x\n", esp & 0xffff);
            else if (pc == 0x8b4f) fprintf(stderr, "[SP] 0x8b4f post-popcx  sp=%04x cx=%04x\n", esp & 0xffff, ecx & 0xffff);
            else if (pc == 0x8b6a) fprintf(stderr, "[SP] 0x8b6a PnP-path    sp=%04x\n", esp & 0xffff);
            else if (pc == 0x8b81) fprintf(stderr, "[SP] 0x8b81 PnP-alt     sp=%04x\n", esp & 0xffff);
            else if (pc == 0x8bba) fprintf(stderr, "[SP] 0x8bba pre-popdi   sp=%04x\n", esp & 0xffff);
            else if (pc == 0x8bbb) fprintf(stderr, "[SP] 0x8bbb pre-popax   sp=%04x\n", esp & 0xffff);
            else if (pc == 0x8bbc) { fprintf(stderr, "[SP] 0x8bbc romlen ax=%04x sp=%04x\n", eax & 0xffff, esp & 0xffff); trace_scan = 0; }
        }
    }
    {   // VTM-TSW: capture the Quake 3-task round-robin livelock instruction flow (retires>4.4M window).
        static long vtmc = 0;
        // Hunt the garbage pointer 0x11b354 in ANY committed register (all cs). If it appears,
        // that retire is where it is computed -> traceable. If it NEVER appears, TSS.esi was written
        // from a non-esi source (a store), which pins the origin differently.
        if (0 && g_vtm_retires > 4400000 &&
            (esi==0x11b354 || edi==0x11b354 || eax==0x11b354 || ebx==0x11b354 ||
             ecx==0x11b354 || edx==0x11b354 || ebp==0x11b354) && vtmc < 4000) {
            vtmc++;
            fprintf(stderr, "VTM %04x:%08x fl=%08x ax=%08x bx=%08x cx=%08x dx=%08x si=%08x di=%08x bp=%08x sp=%08x ds=%04x es=%04x ss=%04x fs=%04x\n",
                    cs, pc, eflags, eax, ebx, ecx, edx, esi, edi, ebp, esp, ds, es, ss, fs);
        }
    }
}

extern "C" void vtm_retire_sys(
    unsigned long long n, unsigned int cr0, unsigned int cr2,
    unsigned int cr3, unsigned int cr4)
{
    (void)n; g_vtm_cr0=cr0; g_vtm_cr2=cr2; g_vtm_cr3=cr3; g_vtm_cr4=cr4;
}

extern "C" void vtm_retire_cycle(unsigned long long n, unsigned int pipe, unsigned int paired)
{ (void)n; (void)pipe; (void)paired; }

// The full-PC harness observes live retirement counters/GPRs; it does not emit
// architectural x87 .vtrace records (the x87 callback below is intentionally
// inert). Therefore it has no deferred record queue to begin or complete.
// Keep this observer stateless so a native restore does not depend on an
// unserialized host-side FP owner. The differential TB implements the actual
// record buffering contract separately in verif/tb/dpi_retire.cpp.
extern "C" void vtm_fp_async_event(unsigned int event_kind,
                                    unsigned long long owner)
{
    (void)owner;
    if (event_kind > 2) {
        fprintf(stderr, "invalid FP async observation event: %u\n", event_kind);
        std::abort();
    }
}

extern "C" void vtm_retire_x87(
    unsigned long long n,
    unsigned int fctrl, unsigned int fstat, unsigned int ftag,
    unsigned long long st0_lo, unsigned short st0_hi,
    unsigned long long st1_lo, unsigned short st1_hi,
    unsigned long long st2_lo, unsigned short st2_hi,
    unsigned long long st3_lo, unsigned short st3_hi,
    unsigned long long st4_lo, unsigned short st4_hi,
    unsigned long long st5_lo, unsigned short st5_hi,
    unsigned long long st6_lo, unsigned short st6_hi,
    unsigned long long st7_lo, unsigned short st7_hi)
{
    (void)n;(void)fctrl;(void)fstat;(void)ftag;
    (void)st0_lo;(void)st0_hi;(void)st1_lo;(void)st1_hi;(void)st2_lo;(void)st2_hi;
    (void)st3_lo;(void)st3_hi;(void)st4_lo;(void)st4_hi;(void)st5_lo;(void)st5_hi;
    (void)st6_lo;(void)st6_hi;(void)st7_lo;(void)st7_hi;
}
