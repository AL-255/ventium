#pragma once
#include "memory_geometry_probe.h"

// Intentionally no fallback reconstruction from public top mem_*: those are
// zeroed in L1 mode. Compiling this adapter requires every actual model field.
// A build without a verified map/adapter remains usable with the probe OFF;
// requesting the probe in that build must call unsupported() and fail closed.
template<class Top, class Root>
MemoryGeometrySample memory_geometry_sample(const Top& top,const Root& r,uint64_t cycle) {
    MemoryGeometrySample s;
#define C(x) r.ventium_top__DOT__u_core__DOT__##x
#define T(x) r.ventium_top__DOT__##x
    s.cycle=cycle; s.reset=!top.rst_n; s.l1_enabled=top.l1axi_en;
    s.state=C(state); s.walk_return=C(walk_ret_state);
    s.eip=C(eip); s.q_pc=C(q_pc); s.pipe_pc=C(pipe_mem_eip_q);
    s.q_kind=C(q_kind); s.q_src_width=C(q_ext_srcw); s.q_dst_width=C(q_w);
    s.pipe_active=C(pipe_mem_active_q); s.pipe_new_load=C(pipe_new_load_req);
    s.pipe_commit=C(pipe_int_commit); s.fsm_enabled=C(fsm_case_enabled);
    s.chain_accept=C(mc_accept); // reject unrecorded next-read ownership
    s.req=T(core_mem_req); s.we=C(bd_we); s.beat_ack=T(core_mem_ack);
    s.final_ack=C(mem_ack); s.strobes=T(core_mem_wstrb);
    // Verified RTL aliases: mem_addr=bd_addr, mem_we=bd_we. They survive
    // optimization whereas the identically wired core_mem_addr may not.
    // The model's source-coverage receipt must cover these assignments too.
    s.physical=C(bd_addr); s.linear=C(cur_lin); s.extent=C(cur_size);
    s.xp_cross=C(xp_cross); s.xp_pending=C(xp_pend);
    s.fx_active=C(fx_act); s.fx_start=C(fx_start); s.fx_phase=C(fx_ph);
    s.arvalid=top.m_axi_arvalid; s.arready=top.m_axi_arready;
    s.araddr=top.m_axi_araddr; s.arid=top.m_axi_arid; s.arlen=top.m_axi_arlen;
    s.arsize=top.m_axi_arsize; s.arburst=top.m_axi_arburst;
    // ARCACHE is constant 0011 in this master, not a cacheability witness.
    s.ar_narrow=r.ventium_top__DOT__u_l1axi__DOT__u_axi__DOT__narrow_q;
    s.rvalid=top.m_axi_rvalid; s.rready=top.m_axi_rready;
    s.rlast=top.m_axi_rlast; s.rid=top.m_axi_rid;
    s.rresp=top.m_axi_rresp; s.rdata=top.m_axi_rdata;
#undef C
#undef T
    return s;
}
