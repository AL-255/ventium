// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

// Passive observer for the existing frozen107 generated model. Reads only;
// no DUT writes, extra evals, IRQ injection, forced ACK or guessed FSM enum.
class PreludeOwnerProbe {
    FILE* out_=nullptr;
    uint32_t start_=0, out_pc_=0;
    uint64_t lines_=0;
    bool returned_=false, terminal_=false, finished_=false;
    [[noreturn]] static void fail(const char* why) {
        std::fprintf(stderr,"[PRELUDE-OWNER] FAIL %s\n",why); std::abort();
    }
    static uint32_t number(const char* name) {
        const char* text=std::getenv(name);
        if(!text || !*text) fail("missing observer PC");
        errno=0; char* end=nullptr;
        const auto n=std::strtoull(text,&end,0);
        if(errno || *end || n>UINT32_MAX) fail("invalid observer PC");
        return uint32_t(n);
    }
public:
    PreludeOwnerProbe() {
        const char* path=std::getenv("VEN_PRELUDE_OWNER_LOG");
        if(!path) return;
        start_=number("VEN_PRELUDE_START_PC");
        out_pc_=number("VEN_PRELUDE_OUT_PC");
        if(start_!=0x59000) fail("unexpected payload entry");
        out_=std::fopen(path,"wx");
        if(!out_) fail("log exists or cannot be created");
        std::fprintf(out_,"{\"type\":\"begin\",\"schema\":1,\"start_pc\":%u,\"out_pc\":%u,\"passive\":true}\n",start_,out_pc_);
    }
    template<class Top> void sample(const Top& t,uint64_t cycle) {
        if(!out_) return;
        const auto& r=*t.rootp;
#define C(x) r.ventium_top__DOT__u_core__DOT__##x
#define R(x) r.ventium_top__DOT__##x
#define L(x) r.ventium_top__DOT__u_l1axi__DOT__##x
        // Exact frozen core.sv:6185 owner selection. q_pc is NOT a fresh
        // S_PIPE owner and must not label an immediate accepted transaction.
        const uint32_t owner=C(pipe_mem_active_q) ? C(pipe_mem_eip_q) : C(eip);
        const bool window=owner>=0x59662 && owner<0x596d0;
        const bool uaccepted=C(pipe_store_req) && R(core_mem_req) &&
            C(bd_we) && R(core_mem_ack) && C(mem_ack) &&
            L(l1d_c_req) && L(l1d_c_ack) && !C(pipe_mem_abort_now);
        // V uses its independent physical address/ack. Correlate this edge
        // with the registered V retirement / DPI row at cycle+1; never guess
        // V PC from a stale q_pc2 at the current acceptance edge.
        // Generated model optimizes away core_store_pair_ack. This exact
        // retained-field equivalent is frozen top.sv:1472 + seam.sv:1281.
        const bool vqualified=bool(t.l1axi_en) && R(l1_store_pair_ready) &&
            L(l1d_store_pair_ack);
        const bool vaccepted=R(core_store_pair_req) && vqualified &&
            C(mem_ack) && !C(pipe_mem_abort_now);
        const bool retired=(R(core_retire_valid) && R(core_retire_pc)>=start_ &&
            R(core_retire_pc)<0x5a000) || (R(core_retire2_valid) &&
            C(q_pc2)>=start_ && C(q_pc2)<0x5a000);
        const bool return_now=!returned_ && C(eip)==0x59800 &&
            C(seg_sel)[0]==0xa7; // frozen core.sv:1338 SG_CS=0
        const bool terminal_now=!terminal_ && C(eip)==out_pc_;
        returned_|=return_now; terminal_|=terminal_now;
        if(!(window || retired || return_now || terminal_now)) return;
        if(++lines_>200000) fail("observer sample bound exceeded");
        std::fprintf(out_,"{\"type\":\"sample\",\"cycle\":%llu,\"registered_commit_cycle\":%llu,\"state\":%u,\"eip\":%u,\"owner_pc\":%u,\"active\":%u,\"load_req\":%u,\"store_req\":%u,\"pair_eff\":%u,\"commit\":%u,\"abort\":%u,\"core_req\":%u,\"core_ack\":%u,\"mem_ack\":%u,\"we\":%u,\"strb\":%u,\"physical\":%u,\"data\":%u,\"l1_req\":%u,\"l1_ack\":%u,\"u_store_accepted\":%u,\"v_req\":%u,\"v_ack_inner\":%u,\"v_qualified_ack\":%u,\"v_physical\":%u,\"v_data\":%u,\"v_store_accepted\":%u,\"retire_valid\":%u,\"retire_pc\":%u,\"retire2_valid\":%u,\"retire2_pc\":%u,\"return\":%u,\"terminal\":%u,\"intr\":%u,\"inta\":%u,\"flags\":%u,\"cr0\":%u,\"cr3\":%u,\"gpr\":[",
            (unsigned long long)cycle,(unsigned long long)(cycle-1),unsigned(C(state)),C(eip),owner,unsigned(C(pipe_mem_active_q)),unsigned(C(pipe_load_req)),unsigned(C(pipe_store_req)),unsigned(C(pipe_pair_eff)),unsigned(C(pipe_int_commit)),unsigned(C(pipe_mem_abort_now)),unsigned(R(core_mem_req)),unsigned(R(core_mem_ack)),unsigned(C(mem_ack)),unsigned(C(bd_we)),unsigned(R(core_mem_wstrb)),uint32_t(t.store_policy_addr),R(core_mem_wdata),unsigned(L(l1d_c_req)),unsigned(L(l1d_c_ack)),unsigned(uaccepted),unsigned(R(core_store_pair_req)),unsigned(L(l1d_store_pair_ack)),unsigned(vqualified),R(core_store_pair_addr),R(core_store_pair_wdata),unsigned(vaccepted),unsigned(R(core_retire_valid)),R(core_retire_pc),unsigned(R(core_retire2_valid)),C(q_pc2),unsigned(return_now),unsigned(terminal_now),unsigned(t.intr),unsigned(t.inta),C(eflags),C(creg0),C(creg3));
        for(unsigned i=0;i<8;++i) std::fprintf(out_,"%s%u",i?",":"",C(gpr_o)[i]);
        std::fprintf(out_,"],\"segments\":[");
        for(unsigned i=0;i<6;++i) std::fprintf(out_,"%s%u",i?",":"",unsigned(C(seg_sel)[i]));
        std::fprintf(out_,"]}\n");
        if(window && owner==0x59680) {
            std::fprintf(out_,"{\"type\":\"branch-owner\",\"cycle\":%llu,\"owner\":%u,\"active\":%u,\"pair\":%u,\"commit\":%u,\"abort\":%u,\"request\":%u,\"ack\":%u,\"predicted\":%u,\"taken\":%u,\"target\":%u,\"u_flags\":%u,\"read_data\":%u,\"offset\":%u,\"physical\":%u,\"u_len\":%u,\"v_len\":%u,\"u_packet\":[",
                (unsigned long long)cycle,owner,unsigned(C(pipe_mem_active_q)),
                unsigned(C(pipe_pair_eff)),unsigned(C(pipe_int_commit)),
                unsigned(C(pipe_mem_abort_now)),unsigned(R(core_mem_req)),
                unsigned(C(mem_ack)),unsigned(C(v_pred_taken)),
                unsigned(C(v_br_taken_eff)),C(v_target),C(u_flags),
                R(core_mem_rdata),C(pipe_load_addr),uint32_t(t.store_policy_addr),
                unsigned((C(pipe_u_eff)[6]>>14)&15),
                unsigned((C(pipe_v_eff)[6]>>14)&15));
            for(unsigned i=0;i<7;++i) std::fprintf(out_,"%s%u",i?",":"",C(pipe_u_eff)[i]);
            std::fprintf(out_,"],\"v_packet\":[");
            for(unsigned i=0;i<7;++i) std::fprintf(out_,"%s%u",i?",":"",C(pipe_v_eff)[i]);
            std::fprintf(out_,"]}\n");
        }
        if(std::ferror(out_)) fail("observer write failed");
#undef C
#undef R
#undef L
    }
    void finish() {
        if(!out_) return;
        if(finished_) fail("duplicate finish");
        std::fprintf(out_,"{\"type\":\"complete\",\"samples\":%llu,\"return_seen\":%u,\"terminal_seen\":%u}\n",(unsigned long long)lines_,unsigned(returned_),unsigned(terminal_));
        if(std::fflush(out_) || std::ferror(out_)) fail("observer flush failed");
        if(std::fclose(out_)) fail("observer close failed");
        out_=nullptr; finished_=true;
        std::fprintf(stderr,"[PRELUDE-OWNER] COMPLETE samples=%llu return=%u terminal=%u\n",(unsigned long long)lines_,unsigned(returned_),unsigned(terminal_));
    }
    ~PreludeOwnerProbe() { if(out_ && !finished_) fail("observer finish missing"); }
};
