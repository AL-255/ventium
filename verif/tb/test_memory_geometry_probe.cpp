#include "memory_geometry_adapter.h"
#include <cassert>
#include <string>

// Synthetic profile IDs, deliberately NOT a claim about any Verilated model.
constexpr MemoryGeometryStates states{3,5,28,40,5,
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"};
struct MockTop {
    unsigned rst_n=1,l1axi_en=1;
    unsigned mem_req=0,mem_we=0,mem_addr=0,mem_wstrb=0; // public ports stay zero
    unsigned m_axi_arvalid=0,m_axi_arready=0,m_axi_arid=0,m_axi_arlen=0,m_axi_arsize=0,m_axi_arburst=1;
    uint64_t m_axi_araddr=0;
    unsigned m_axi_rvalid=0,m_axi_rready=0,m_axi_rlast=0,m_axi_rid=0,m_axi_rresp=0,m_axi_rdata=0;
};
struct MockRoot {
#define F(x) unsigned ventium_top__DOT__u_core__DOT__##x=0;
    F(state) F(walk_ret_state) F(eip) F(q_pc) F(pipe_mem_eip_q) F(q_kind) F(q_ext_srcw) F(q_w)
    F(pipe_mem_active_q) F(pipe_new_load_req) F(pipe_int_commit) F(fsm_case_enabled) F(mc_accept)
    F(bd_we) F(mem_ack) F(bd_addr) F(cur_lin) F(cur_size)
    F(xp_cross) F(xp_pend) F(fx_act) F(fx_start) F(fx_ph)
#undef F
    unsigned ventium_top__DOT__core_mem_req=0,ventium_top__DOT__core_mem_ack=0;
    unsigned ventium_top__DOT__core_mem_wstrb=0;
    unsigned ventium_top__DOT__u_l1axi__DOT__u_axi__DOT__narrow_q=0;
};

int main(int argc,char** argv) {
    const std::string mode=argc>1?argv[1]:"ok";
    if(mode=="off") {
        unsetenv("VEN_MEM_GEOM_LOG");
        MemoryGeometryProbe p; p.unsupported(); p.pre_edge({}); p.finish();
        return 0;
    }
    MemoryGeometryProbe p;
    if(mode=="unsupported") p.unsupported();
    auto selected=states;
    if(mode=="profile-suffix") selected.profile="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef!";
    if(mode=="exec-alias") selected.exec=selected.pipe;
    p.configure(selected);
    if(mode=="missing-finish") return 0; // destructor must reject truncation
    MockTop top; MockRoot root;
#define R(x) root.ventium_top__DOT__u_core__DOT__##x
    R(state)=states.load; R(q_kind)=states.ext_kind; R(q_pc)=0x8000;
    R(eip)=0xbad; R(pipe_mem_eip_q)=0xdead; // wrong live/stale alternatives
    R(q_ext_srcw)=2; R(q_w)=4; R(fsm_case_enabled)=1;
    R(bd_addr)=0xfff; R(cur_lin)=0x404fff; R(cur_size)=1; R(xp_cross)=1;
    root.ventium_top__DOT__core_mem_req=1; root.ventium_top__DOT__core_mem_wstrb=1;
    root.ventium_top__DOT__u_l1axi__DOT__u_axi__DOT__narrow_q=1;
    top.m_axi_arvalid=1; top.m_axi_araddr=0x100000001ull; top.m_axi_arid=3;
    auto one=memory_geometry_sample(top,root,1);
    assert(one.req && one.physical==0xfff && one.strobes==1 && top.mem_addr==0);
    if(mode=="public-zero-negative") {
        one.req=top.mem_req; one.physical=top.mem_addr; one.strobes=top.mem_wstrb;
        // This negative adapter mutation must fail the same positive mapping check.
        if(!(one.req && one.physical==0xfff && one.strobes==1)) std::exit(7);
    }
    p.pre_edge(one);
    if(mode=="gap") { auto wrong=one; wrong.cycle=3; p.pre_edge(wrong); }
    top.m_axi_arready=1;
    root.ventium_top__DOT__core_mem_ack=1; R(mem_ack)=1;
    p.pre_edge(memory_geometry_sample(top,root,2)); // accepted frag1, not final
    if(mode=="outstanding") p.finish();
    top.m_axi_arvalid=0; top.m_axi_rvalid=1; top.m_axi_rready=1; top.m_axi_rlast=1; top.m_axi_rid=3;
    if(mode=="rresp") top.m_axi_rresp=2;
    R(state)=states.walk; R(walk_ret_state)=states.load; R(bd_addr)=0x12000;
    if(mode=="bad-id") top.m_axi_rid=2;
    if(mode=="bad-last") top.m_axi_rlast=0;
    if(mode=="overlap") { top.m_axi_rvalid=0; top.m_axi_arvalid=1; }
    if(mode=="reset") top.rst_n=0;
    p.pre_edge(memory_geometry_sample(top,root,3)); // walker ACK cannot complete EXT
    top.m_axi_rvalid=0; top.m_axi_arvalid=1; top.m_axi_araddr=0x100000002ull;
    if(mode=="bad-narrow") { top.m_axi_arsize=1; top.m_axi_araddr=0x100000003ull; }
    R(state)=states.load; R(xp_pend)=1; R(bd_addr)=0x2000; R(cur_lin)=0x405000;
    p.pre_edge(memory_geometry_sample(top,root,4)); // slow final fragment
    top.m_axi_arvalid=0; top.m_axi_rvalid=1;
    R(state)=states.exec; root.ventium_top__DOT__core_mem_req=0;
    p.pre_edge(memory_geometry_sample(top,root,5));
    R(state)=states.pipe; R(pipe_mem_active_q)=1; R(pipe_mem_eip_q)=0x8000;
    R(eip)=0xcafe; R(q_pc)=0xbeef; R(xp_pend)=0; R(xp_cross)=0;
    R(fx_act)=1; R(fx_ph)=0; R(mem_ack)=0; R(bd_addr)=0x3000;
    root.ventium_top__DOT__core_mem_req=1;
    top.m_axi_rvalid=0; top.m_axi_arvalid=1; top.m_axi_araddr=0x200003000ull;
    p.pre_edge(memory_geometry_sample(top,root,6)); // held-packet owner, frag1
    R(state)=states.walk; R(walk_ret_state)=states.pipe; R(mem_ack)=1; R(bd_addr)=0x13000;
    top.m_axi_arvalid=0; top.m_axi_rvalid=1;
    p.pre_edge(memory_geometry_sample(top,root,7));
    R(state)=states.pipe; R(fx_ph)=1; R(pipe_int_commit)=1; R(bd_addr)=0x4000;
    if(mode=="chain-accept") R(mc_accept)=1;
    top.m_axi_rvalid=0; top.m_axi_arvalid=1; top.m_axi_araddr=0x200004000ull;
    p.pre_edge(memory_geometry_sample(top,root,8)); // actual final packet ACK/commit
    R(pipe_mem_active_q)=0; R(eip)=0x8003; R(fx_act)=0;
    root.ventium_top__DOT__core_mem_req=0;
    top.m_axi_arvalid=0; top.m_axi_rvalid=1;
    p.pre_edge(memory_geometry_sample(top,root,9)); // immediate consumer, no read
    if(mode=="unsolicited-r") p.pre_edge(memory_geometry_sample(top,root,10));
    p.finish();
#undef R
}
