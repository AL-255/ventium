#pragma once
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// Test-only external halt/resume stimulus. Internal state is READ ONLY.
// Linked to the original frozen RTL archive; no STEP, breakpoint, saved-state
// restore, register write or device-memory injection is performed.
struct RepDebugProbe {
    bool enabled=false, started_phase=false, fired=false, released=false;
    bool source_edge=false;
    uint32_t pc=0;
    uint64_t requested=0, parked=0;
    unsigned held=0;
    std::array<uint32_t,10> stopped{};
    [[noreturn]] static void fail(const char* text) {
        std::fprintf(stderr,"[REP-DEBUG] FAIL %s\n",text); std::abort();
    }
    RepDebugProbe() {
        const char* text=std::getenv("VEN_TEST_REP_DEBUG_PC");
        if (!text) return;
        char* end=nullptr; errno=0;
        unsigned long value=std::strtoul(text,&end,0);
        if (errno || !*text || *text=='-' || *end || value>UINT32_MAX)
            fail("invalid target PC");
        pc=uint32_t(value);
        const char* phase=std::getenv("VEN_TEST_REP_DEBUG_PHASE");
        if (!phase || (std::strcmp(phase,"pending") && std::strcmp(phase,"started")))
            fail("phase must be pending or started");
        started_phase=!std::strcmp(phase,"started"); enabled=true;
    }
    template<class T> void pre_edge(const T& t) {
        if (!enabled || fired) return;
        const auto& r=*t.rootp;
#define RD(name) r.ventium_top__DOT__u_core__DOT__##name
        // First physical read of element two; observe the settled request
        // before its clock edge, then request HALT only after that edge.
        source_edge=RD(state)==3 && RD(q_pc)==pc && RD(gpr_o)[1]==31 &&
                    RD(gpr_o)[6]==0x2004 && RD(gpr_o)[7]==0x3004 &&
                    r.ventium_top__DOT__core_mem_req && !RD(bd_we);
#undef RD
    }
    template<class T, class M> void post_edge(T& t, const M& memory, uint64_t cycle) {
        if (!enabled || released) return;
        const auto& r=*t.rootp;
#define RD(name) r.ventium_top__DOT__u_core__DOT__##name
        if (!fired) {
            bool pending=RD(rep_movs_stream_pending_q) && RD(q_pc)==pc &&
                         RD(gpr_o)[1]==31 && RD(gpr_o)[6]==0x2004 && RD(gpr_o)[7]==0x3004;
            if ((started_phase && source_edge) || (!started_phase && pending)) {
                if (t.dbg_halt_req || t.dbg_step || t.dbg_bp_en) fail("another debugger owns the pins");
                fired=true; requested=cycle; t.dbg_halt_req=1;
                std::fprintf(stderr,"[REP-DEBUG] REQUEST phase=%s cycle=%llu pc=%08x pending=%u source_edge=%u\n",
                    started_phase?"started":"pending",(unsigned long long)cycle,pc,unsigned(pending),unsigned(source_edge));
            }
            return;
        }
        if (cycle-requested>5000) fail("halt did not quiesce and resume");
        if (t.dbg_step || t.dbg_bp_en) fail("STEP or breakpoint unexpectedly active");
        if (!t.dbg_halted) {
            if (held) fail("HALTED dropped while request remained asserted");
            return;
        }
        std::array<uint32_t,10> now{};
        for (unsigned i=0;i<8;++i) now[i]=RD(gpr_o)[i];
        now[8]=RD(eip); now[9]=RD(eflags);
        if (!held) {
            unsigned committed=started_phase?2:1;
            if (now[1]!=32-committed || now[6]!=0x2000+4*committed ||
                now[7]!=0x3000+4*committed || now[8]!=pc)
                fail("imprecise REP restart boundary");
            stopped=now; parked=cycle;
            std::fprintf(stderr,"[REP-DEBUG] HALTED cycle=%llu ecx=%u esi=%08x edi=%08x eip=%08x\n",
                (unsigned long long)cycle,now[1],now[6],now[7],now[8]);
        } else if (now!=stopped) fail("architectural state changed while halted");
        // Let normal posted writes drain without assuming HALTED means DDR is
        // already quiescent. At latency <=31 this bound exceeds all queued beats.
        if (++held==1024) {
            unsigned committed=32-stopped[1];
            for (unsigned i=0;i<32;++i) {
                uint32_t wanted=i<committed?memory.read32(0x2000+4*i):0;
                if (memory.read32(0x3000+4*i)!=wanted) fail("wrong committed prefix or touched suffix");
            }
            t.dbg_halt_req=0; released=true;
            std::fprintf(stderr,"[REP-DEBUG] RESUME cycle=%llu stable_edges=1024 committed=%u\n",
                (unsigned long long)cycle,committed);
        }
#undef RD
    }
    void finish() const {
        if (!enabled) return;
        if (!fired || !released || held!=1024) fail("missing halt/resume witness");
        std::fprintf(stderr,"[REP-DEBUG] PASS phase=%s requested=%llu parked=%llu stable_edges=%u\n",
            started_phase?"started":"pending",(unsigned long long)requested,(unsigned long long)parked,held);
    }
};
