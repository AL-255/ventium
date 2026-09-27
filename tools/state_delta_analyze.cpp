// Stream/reconstruct EVERY field at EVERY cycle; no trace subsampling.
// Output a general field activity table and cycle-level CPU correlations.
#include <zlib.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include "state_delta_focus.h"

struct Input {
    gzFile f;
    explicit Input(const char* path): f(gzopen(path,"rb")) {
        if (!f) throw std::runtime_error("open trace");
        gzbuffer(f, 1<<20);
    }
    ~Input() { if (f) gzclose(f); }
    void read(void* p, size_t n) {
        auto* b = static_cast<uint8_t*>(p);
        while (n) {
            unsigned k = unsigned(std::min<size_t>(n, 1<<20));
            if (gzread(f,b,k) != int(k)) throw std::runtime_error("truncated/corrupt trace");
            b += k; n -= k;
        }
    }
    template<class T> T get() { T v; read(&v,sizeof(v)); return v; }
    std::string string() {
        auto n=get<uint32_t>(); if(n>1<<20) throw std::runtime_error("string too long");
        std::string s(n,'\0'); read(s.data(),n); return s;
    }
    void magic(const char* s) { char b[8]; read(b,8); if(memcmp(b,s,8)) throw std::runtime_error("bad magic"); }
};
struct Field { std::string name,type; uint32_t offset,size; uint64_t changes=0,bytes=0,last=0; };
int main(int argc,char** argv) try {
    if(argc!=3 && argc!=4) throw std::runtime_error("usage: state_delta_analyze TRACE.gz OUTPUT_PREFIX [FPD_LAYOUT.tsv]");
    Input in(argv[1]); in.magic("VENDLT01");
    auto nf=in.get<uint32_t>(); auto first=in.get<uint64_t>(); auto count=in.get<uint64_t>(); auto size=in.get<uint32_t>();
    if(!nf || nf>1000000 || !count || count>1000000 || size>(1u<<30)) throw std::runtime_error("header limits");
    std::vector<Field> fields;
    std::map<std::string, unsigned> lookup;
    uint64_t offset=0;
    for(unsigned i=0;i<nf;++i) {
        auto name=in.string(), type=in.string(); auto n=in.get<uint32_t>();
        if(!n || offset+n>size || !lookup.emplace(name,i).second) throw std::runtime_error("field layout");
        fields.push_back({name,type,uint32_t(offset),n}); offset+=n;
    }
    if(offset!=size) throw std::runtime_error("size mismatch");
    std::vector<uint8_t> state(size); in.read(state.data(),size);
    const auto initial=state;
    std::vector<unsigned> owner(size);
    for(unsigned i=0;i<nf;++i) std::fill(owner.begin()+fields[i].offset,owner.begin()+fields[i].offset+fields[i].size,i);
    const std::string core="system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__";
    auto field = [&](const std::string& name) -> unsigned {
        auto it=lookup.find(name); if(it==lookup.end()) throw std::runtime_error("missing field: "+name); return it->second;
    };
    auto scalar = [&](unsigned id) -> uint64_t {
        const auto& f=fields[id]; if(f.size>8) throw std::runtime_error("not scalar: "+f.name);
        uint64_t v=0; memcpy(&v,state.data()+f.offset,f.size); return v;
    };
    auto optional_field = [&](const std::string& name) -> unsigned {
        auto it=lookup.find(name); return it==lookup.end() ? nf : it->second;
    };
    auto optional_scalar = [&](unsigned id) -> uint64_t {return id==nf ? 0 : scalar(id);};
    StateDeltaFocus focus([&](const std::string& name) -> int {
        // Verilator canonicalizes the core's output port onto its parent's
        // connected net. This is .mem_req(core_mem_req), NOT bd_req or the
        // pre-store-queue request, whose fault/cancellation gates differ.
        std::string path=core+name;
        if(name=="mem_req") path="system__DOT__u_cpu__DOT__u_core__DOT__core_mem_req";
        else if(name.rfind("axi.",0)==0)
            path="system__DOT__u_cpu__DOT__u_core__DOT__u_l1axi__DOT__u_axi__DOT__"+name.substr(4);
        else if(name.rfind("l1.",0)==0)
            path="system__DOT__u_cpu__DOT__u_core__DOT__u_l1axi__DOT__u_l1d__DOT__"+name.substr(3);
        else if(name.rfind("backend.",0)==0)
            path="system__DOT__cache__DOT__"+name.substr(8);
        else if(name=="bridge.state") path="system__DOT__u_cpu__DOT__u_bridge__DOT__state";
        // system.v connects both shim.avm_waitrequest and cache.CPU_BUSY here.
        else if(name=="bridge.waitrequest") path="system__DOT__mem_waitrequest";
        auto it=lookup.find(path);
        return it==lookup.end() ? -1 : int(it->second);
    });
    auto ret_id=field("harness.retired");
    auto state_id=field(core+"state"), pc_id=field(core+"eip");
    auto pending_id=field(core+"fp_async_pending"), hold_id=field(core+"fp_async_hold");
    const auto stream_count=lookup.find(core+"fp_async_count");
    auto fault_id=field(core+"fp_async_fault_hold"), mem_id=field(core+"pipe_mem_active_q");
    const auto chain_accept=lookup.find(core+"mc_accept");
    auto ack_id=field(core+"mem_ack"), pair_id=field(core+"pipe_pair_reason");
    auto commit_id=field(core+"pipe_int_commit");
    auto front_id=field(core+"pipe_frontend_ready");
    auto stall_id=field(core+"stall_cnt"), penalty_id=field(core+"pending_mem_pen");
    auto bubbles_id=field(core+"mispred_bubbles"), agi_id=field(core+"pipe_agi");
    auto block_id=field(core+"fp_issue_block"), sysbail_id=field(core+"fp_sys_bail");
    auto enabled_id=field(core+"fsm_case_enabled");
    auto full_memwait_id=field(core+"pipe_mem_wait");
    auto brvalid_id=field(core+"btb_resolve_valid"), brpc_id=field(core+"btb_resolve_pc");
    auto brtaken_id=field(core+"btb_resolve_taken");
    std::ofstream branches(std::string(argv[2])+".branches.tsv");
    if(!branches) throw std::runtime_error("branch observation output open");
    branches<<"cycle\tpc\ttaken\n";
    // Optional decoded-pair attribution. The layout must come from the package
    // used to build this trace, not an unrelated checkout's packed struct.
    std::map<std::string,std::pair<unsigned,unsigned>> descriptor_layout;
    unsigned ud_id=0, vd_id=0, vbytes_id=0, vavail_id=0;
    if(argc==4) {
        std::ifstream layout(argv[3]);
        if(!layout) throw std::runtime_error("descriptor layout open");
        std::string name,line,extra; unsigned bit,width; std::array<bool,210> used{};
        while(std::getline(layout,line)) {
            std::istringstream row(line);
            if(!(row>>name>>bit>>width) || (row>>extra))
                throw std::runtime_error("malformed descriptor layout row");
            if(!width || width>32 || bit>=used.size() || width>used.size()-bit ||
               !descriptor_layout.emplace(name,std::make_pair(bit,width)).second)
                throw std::runtime_error("descriptor layout entry");
            for(unsigned b=bit;b<bit+width;++b) {
                if(used[b]) throw std::runtime_error("descriptor layout overlap");
                used[b]=true;
            }
        }
        if(layout.bad() || !std::all_of(used.begin(),used.end(),[](bool b){return b;}))
            throw std::runtime_error("descriptor layout incomplete");
        ud_id=field(core+"u_d"); vd_id=field(core+"v_d");
        for(auto id:{ud_id,vd_id})
            if(fields[id].size!=28 || fields[id].type.find("209:0")==std::string::npos)
                throw std::runtime_error("unsupported descriptor trace layout");
        vbytes_id=field(core+"v_bytes_ok"); vavail_id=field(core+"uc_v_avail");
    }
    auto descriptor = [&](unsigned id,const std::string& name) -> uint32_t {
        auto range=descriptor_layout.at(name); uint32_t value=0;
        for(unsigned b=0;b<range.second;++b) {
            unsigned bit=range.first+b;
            value|=uint32_t((state[fields[id].offset+bit/8]>>(bit%8))&1)<<b;
        }
        return value;
    };
    auto memory_pair_class = [&]() -> std::string {
        if(argc!=4 || !scalar(front_id) || !scalar(vbytes_id) ||
           !scalar(vavail_id) || scalar(pair_id)!=6) return {};
        auto kind = [&](unsigned id) -> std::string {
            if(descriptor(id,"is_stack")) return "stack";
            if(descriptor(id,"is_fp")) return "fp";
            if(descriptor(id,"is_store")) return "store";
            if(descriptor(id,"is_load")) return descriptor(id,"w8") ? "mov8" :
                                                   descriptor(id,"w16") ? "mov16" : "mov32";
            return descriptor(id,"is_mem") ? "memory_alu" : "register";
        };
        return kind(ud_id)+"_v_"+kind(vd_id);
    };
    // Initial in-flight packets have unknown admission-time V validity. Exclude
    // those until the first observed capture, rather than guessing from a live
    // frontend which may have been invalidated while the packet was held.
    std::string held_pair_class;
    struct ReadGeometry { bool reads=false,same_segment=false,same_line=false,contained=false; };
    unsigned gpr_id=0, segbase_id=0, sysmode_id=0;
    if(argc==4) {
        gpr_id=field(core+"gpr_o"); segbase_id=field(core+"seg_base"); sysmode_id=field(core+"sys_mode");
        if(fields[gpr_id].size!=32 || fields[segbase_id].size!=24)
            throw std::runtime_error("unsupported GPR/segment array layout");
    }
    auto read_geometry = [&]() -> ReadGeometry {
        ReadGeometry g;
        if(argc!=4) return g;
        for(auto id:{ud_id,vd_id})
            if(!descriptor(id,"is_mem") || descriptor(id,"is_store") ||
               descriptor(id,"is_stack") || descriptor(id,"is_fp")) return g;
        g.reads=true;
        auto word = [&](unsigned id,unsigned index) -> uint32_t {
            uint32_t v; memcpy(&v,state.data()+fields[id].offset+4*index,4); return v;
        };
        auto linear = [&](unsigned id) -> uint32_t {
            uint32_t address=descriptor(id,"mem_disp");
            if(descriptor(id,"mem_base_en")) address+=word(gpr_id,descriptor(id,"base"));
            if(descriptor(id,"mem_index_en")) address+=word(gpr_id,descriptor(id,"mem_index"))<<descriptor(id,"mem_scale");
            // The core's checked fast AGU uses 32-bit offsets. Segment indices
            // are SG_SS=1 and SG_DS=2 in this pinned elaboration.
            if(scalar(sysmode_id)) address+=word(segbase_id,descriptor(id,"mem_ss") ? 1 : 2);
            return address;
        };
        auto bytes = [&](unsigned id) {return descriptor(id,"w8") ? 1u : descriptor(id,"w16") ? 2u : 4u;};
        uint32_t u=linear(ud_id),v=linear(vd_id);
        g.same_segment=descriptor(ud_id,"mem_ss")==descriptor(vd_id,"mem_ss");
        g.same_line=(u>>5)==(v>>5);
        g.contained=(u&31)+bytes(ud_id)<=32 && (v&31)+bytes(vd_id)<=32;
        return g;
    };
    ReadGeometry held_geometry;
    auto intr_id=field(core+"intr_take"), irq0_id=field("system__DOT__irq_0");
    auto vector_id=field(core+"int_vec"), pending_irq_id=field(core+"intr_pending");
    std::ofstream interrupts(std::string(argv[2])+".interrupts.tsv");
    if(!interrupts) throw std::runtime_error("interrupt observation output open");
    interrupts<<"cycle\tirq0\tintr_pending\tintr_take\tstate\tvector\teip\treported_retires\n";
    std::array<uint64_t,3> previous_irq{scalar(irq0_id),scalar(pending_irq_id),scalar(intr_id)};
    auto rv_id=field("system__DOT__u_cpu__DOT__u_core__DOT__core_retire_valid");
    auto rv2_id=field("system__DOT__u_cpu__DOT__u_core__DOT__core_retire2_valid");
    auto qpc_id=field(core+"q_pc"), qpc2_id=field(core+"q_pc2"), snap_id=field(core+"snap");
    auto qkind_id=optional_field(core+"q_kind"), qst_id=optional_field(core+"q_st");
    auto movs_fuse_id=optional_field(core+"rep_movs_load_fuse");
    auto movs_stream_id=optional_field(core+"rep_movs_stream_arm");
    if(fields[snap_id].size!=48) throw std::runtime_error("unknown integer retire snapshot layout");
    std::ofstream commits(std::string(argv[2])+".commit_observations.bin",std::ios::binary);
    if(!commits) throw std::runtime_error("commit observation output open");
    const std::string l1="system__DOT__u_cpu__DOT__u_core__DOT__u_l1axi__DOT__";
    auto val_id=field(l1+"u_l1d__DOT__dc_val"), tag_id=field(l1+"u_l1d__DOT__dc_tag");
    auto req_id=field(l1+"l1d_c_req"), we_id=field(core+"bd_we"), addr_id=field(core+"bd_addr");
    auto data_access_id=field(core+"cur_is_d");
    auto l1state_id=field(l1+"u_l1d__DOT__st"), flush_id=field(l1+"__Vcellinp__u_l1d__flush_all");
    auto cacheable_id=field(l1+"l1d_cacheable"), l1ack_id=field(l1+"l1d_c_ack");
    auto rd_hit_id=field(l1+"u_l1d__DOT__rd_hit"), xline_id=field(l1+"u_l1d__DOT__xline");
    auto lookup_addr_id=field(l1+"u_l1d__DOT__lookup_addr");
    auto next_lookup_id=field(l1+"u_l1d__DOT__mc_lookup_next");
    auto miss_perf_id=field(l1+"u_l1d__DOT__perf_miss_start");
    const uint64_t initial_miss_perf=scalar(miss_perf_id);
    auto flin_id=field(core+"flin"), ic_ready_id=field(core+"ic_fetch_ready");
    auto uc_pd_id=field(core+"uc_updvalid"), uc_boundary_id=field(core+"uc_ubvalid");
    auto uc_cross_id=field(core+"uc_cross_ready"), uc_repair_id=field(core+"uc_repair_start");
    auto uc_sources_id=optional_field(core+"uc_cross_sources_ready");
    auto ic_fb_id=optional_field(core+"ic_fb_avail");
    const std::string uc=core+"u_uopcache__DOT__";
    auto uc_wst_id=optional_field(uc+"wst"), uc_woff_id=optional_field(uc+"woff");
    auto uc_wslot_id=optional_field(uc+"wslot"), uc_wsteps_id=optional_field(uc+"wsteps");
    auto uc_wrepair_id=optional_field(uc+"wrepair"), uc_wanchor_id=optional_field(uc+"wanchor");
    auto uc_wset_id=optional_field(uc+"wset");
    auto uc_repair_ready_id=optional_field(uc+"repair_ready");
    auto uc_fill_start_id=optional_field(uc+"pd_start_live");
    auto uc_fill_pending_id=optional_field(uc+"pd_pend_live");
    auto uc_next_valid_id=optional_field(uc+"wnext_valid");
    auto uc_next_kill_id=optional_field(uc+"wnext_kill");
    auto uc_poison_id=optional_field(uc+"wpz");
    auto uc_pd_exec_id=optional_field(uc+"pd_exec");
    auto uc_pd_len_id=optional_field(uc+"pd_len");
    auto uc_primary_valid_id=optional_field(uc+"cross_valid_q");
    auto uc_primary_set_id=optional_field(uc+"cross_set_q");
    auto uc_primary_off_id=optional_field(uc+"cross_off_q");
    auto uc_index_valid_id=optional_field(uc+"cross_index_valid");
    auto uc_index_meta_id=optional_field(uc+"cross_index_meta");
    if(uc_index_meta_id!=nf && fields[uc_index_meta_id].size!=128)
        throw std::runtime_error("unknown cross-index metadata geometry");
    auto bypass_id=field(l1+"u_l1d__DOT__bypass_q"), fset_id=field(l1+"u_l1d__DOT__fset");
    auto fway_id=field(l1+"u_l1d__DOT__fway");
    auto ftag_id=field(l1+"u_l1d__DOT__ftag"), fbase_id=field(l1+"u_l1d__DOT__fbase");
    auto fw_id=field(l1+"u_l1d__DOT__fw"), poison_id=field(l1+"u_l1d__DOT__fill_poison");
    auto early_addr_id=field(l1+"u_l1d__DOT__early_addr_q");
    auto win_valid_id=field(l1+"u_l1d__DOT__window_valid_q");
    auto early_armed_id=field(l1+"u_l1d__DOT__early_armed");
    auto axi_read_state_id=field(l1+"u_axi__DOT__rst");
    auto axi_primed_id=field(l1+"u_axi__DOT__rd_primed");
    auto axi_read_hs_id=field(l1+"u_axi__DOT__r_hs");
    auto backing_ack_id=field(l1+"m_ack");
    auto write_busy_id=field(l1+"u_axi__DOT__wr_busy");
    auto bridge_state_id=field("system__DOT__u_cpu__DOT__u_bridge__DOT__state");
    auto backend_state_id=field("system__DOT__cache__DOT__state");
    auto win_addr_id=field(l1+"u_l1d__DOT__rd_addr_q"), capture_id=field(l1+"u_l1d__DOT__do_rd_cap");
    bool kept_window=scalar(win_valid_id);
    if(fields[val_id].size!=256 || fields[tag_id].size!=1024) throw std::runtime_error("not full P5 cache geometry");
    // The L1 array also receives instruction fills. Attribute only a
    // *witnessed* data-origin line evicted by an instruction-origin fill;
    // pre-trace resident ways have unknown provenance and are not guessed.
    std::array<std::array<uint8_t,2>,128> line_origin{}; // 0 unknown, 1 I, 2 D
    std::map<uint32_t,uint64_t> code_evicted_data;
    uint8_t active_fill_origin=0;
    auto resident_line = [&](unsigned set,unsigned way) -> uint32_t {
        uint32_t tag;
        memcpy(&tag,state.data()+fields[tag_id].offset+4*(2*set+way),4);
        return (tag<<12)|(set<<5);
    };
    std::vector<std::array<uint64_t,5>> eviction_examples;
    auto bail_id=field(core+"pp_bail");
    if(fields[bail_id].size!=14*8) throw std::runtime_error("unknown pp_bail layout");
    std::array<uint64_t,14> old_bail{};
    memcpy(old_bail.data(),state.data()+fields[bail_id].offset,14*8);
    std::map<std::array<uint64_t,4>,uint64_t> bail_joint;
    std::map<std::array<uint64_t,2>,uint64_t> pc_bail;
    std::map<std::string,uint64_t> totals;
    std::map<unsigned,uint64_t> states, nostates, pairs, holdstates;
    std::map<uint32_t,uint64_t> pc_clocks, pc_no_retire;
    // Pre-edge string service, grouped by the retained instruction PC. These
    // are actual levels/ACKs, never a prediction of clocks saved by a policy.
    struct StringService {
        uint64_t clocks=0, load=0, store=0, load_ack=0, store_ack=0;
        uint64_t fused_load_ack=0, streamed_store_ack=0;
        uint64_t load_busy=0, load_hit_capture=0, load_miss=0, store_wait=0;
    };
    std::map<std::array<uint64_t,2>,StringService> string_service;
    // Same-edge no-retirement ownership, keyed by PRE-edge PC. Keep this
    // separate from the historical post-edge PC/host-retirement hot table.
    std::map<std::array<uint64_t,2>,uint64_t> pc_edge_no_retire;
    std::map<std::array<uint64_t,5>,uint64_t> joint;
    // This report deliberately joins actual per-edge observations, not the
    // independently aggregated bail_joint and settled joint tables. Host DPI
    // observes the previous registered retirement, while pp_bail describes the
    // edge just processed and commit is the next-edge combinational level.
    std::map<std::array<uint64_t,18>,uint64_t> control_joint;
    std::map<std::array<uint64_t,12>,uint64_t> edge_control;
    std::map<std::array<uint64_t,6>,uint64_t> edge_joint;
    std::map<std::array<uint64_t,6>,uint64_t> cache_backend;
    std::ofstream uop_holes(std::string(argv[2])+".uop_holes.tsv");
    if(!uop_holes) throw std::runtime_error("uop hole output open");
    uop_holes<<"cycle\teip\tflin\toffset\tic_ready\tpd_valid\tboundary_valid\tcross_ready\tcross_sources_ready\tic_fb_avail\trepair_start\trepair_ready\tfill_start\tfill_pending\twalker_state\twalker_offset\twalker_slot\twalker_steps\twalker_repair\twalker_anchor\twalker_set\tprimary_valid\tprimary_set\tprimary_off\tindex_slot_valid\tindex_meta\n";
    std::ofstream repair_events(std::string(argv[2])+".uop_repair_transitions.tsv");
    if(!repair_events) throw std::runtime_error("uop repair transition output open");
    repair_events<<"cycle\tpre_state\tpost_state\tpre_repair\tpost_repair\tpre_set\tpost_set\tpre_anchor\tpost_anchor\tpre_offset\tpre_next_valid\tpre_next_kill\tpre_poison\tpre_fill_start\tpre_fill_pending\tpre_pd_exec\tpre_pd_len\tpre_primary_set\tpre_primary_off\tpost_primary_set\tpost_primary_off\n";
    // Kind 0: current instruction-fetch miss; 1: current data miss;
    // 2: rejected read-chain NEXT query (not a backing transaction).
    std::map<std::array<uint32_t,2>,uint64_t> miss_lines;
    std::array<std::array<uint64_t,3>,128> miss_sets{};
    std::ofstream miss_events(std::string(argv[2])+".miss_events.tsv");
    if(!miss_events) throw std::runtime_error("miss event output open");
    miss_events<<"cycle\tphysical_line\tset\tkind\tcore_eip\n";
    uint64_t previous_retired=scalar(ret_id), retired_start=previous_retired, stall_run=0,max_stall=0,max_stall_end=0;
    const uint64_t initial_registered_retire=scalar(rv_id) ? (scalar(rv2_id) ? 2 : 1) : 0;
    uint64_t changed_blocks=0;
    for(uint64_t index=0;index<count;++index) {
        focus.before(scalar);
        bool prior_mem_active=scalar(mem_id);
        // Active may remain asserted while a chained successor replaces its
        // owner. Old schemas without mc_accept fail closed at a committing
        // active->active boundary; live frontend descriptors prove neither
        // the replacement packet's admission nor its saved address geometry.
        bool prior_mem_replace=prior_mem_active &&
            (chain_accept!=lookup.end() ? scalar(chain_accept->second) : scalar(commit_id));
        std::string prior_pair_class=prior_mem_active ? std::string{} : memory_pair_class();
        ReadGeometry prior_geometry=prior_pair_class.empty() ? ReadGeometry{} : read_geometry();
        uint64_t prior_hold=scalar(hold_id), prior_front=scalar(front_id), prior_pc=scalar(pc_id);
        const uint64_t prior_flin=scalar(flin_id);
        const unsigned prior_cross_index=unsigned((prior_flin>>5)&31u);
        uint32_t prior_cross_meta=0;
        if(uc_index_meta_id!=nf)
            memcpy(&prior_cross_meta,state.data()+fields[uc_index_meta_id].offset+4*prior_cross_index,4);
        const uint64_t prior_index_valid=(optional_scalar(uc_index_valid_id)>>prior_cross_index)&1u;
        const uint64_t prior_primary_valid=optional_scalar(uc_primary_valid_id);
        const uint64_t prior_primary_set=optional_scalar(uc_primary_set_id);
        const uint64_t prior_primary_off=optional_scalar(uc_primary_off_id);
        const uint64_t prior_repair_ready=optional_scalar(uc_repair_ready_id);
        const uint64_t prior_fill_start=optional_scalar(uc_fill_start_id);
        const uint64_t prior_fill_pending=optional_scalar(uc_fill_pending_id);
        const uint64_t prior_next_valid=optional_scalar(uc_next_valid_id);
        const uint64_t prior_next_kill=optional_scalar(uc_next_kill_id);
        const uint64_t prior_poison=optional_scalar(uc_poison_id);
        const uint64_t prior_pd_exec=optional_scalar(uc_pd_exec_id);
        const uint64_t prior_pd_len=optional_scalar(uc_pd_len_id);
        const std::array<uint64_t,15> prior_uop{scalar(ic_ready_id),scalar(uc_pd_id),
            scalar(uc_boundary_id),scalar(uc_cross_id),optional_scalar(uc_sources_id),
            optional_scalar(ic_fb_id),scalar(uc_repair_id),
            optional_scalar(uc_wst_id),optional_scalar(uc_woff_id),optional_scalar(uc_wslot_id),
            optional_scalar(uc_wsteps_id),optional_scalar(uc_wrepair_id),optional_scalar(uc_wanchor_id),
            optional_scalar(uc_wset_id),uint64_t(prior_flin&31u)};
        uint64_t prior_state=scalar(state_id);
        // K_STR=13 and ST_MOVS=0 in this trace's pinned decode package. Leave
        // the subtype in the output so other string ops remain distinguishable.
        if(qkind_id!=nf && qst_id!=nf && scalar(qkind_id)==13) {
            auto& row=string_service[{scalar(qpc_id),scalar(qst_id)}];
            ++row.clocks;
            if(prior_state==3) {
                ++row.load;
                row.load_ack+=bool(scalar(ack_id));
                row.fused_load_ack+=bool(scalar(ack_id) && optional_scalar(movs_fuse_id));
                if(scalar(req_id) && !scalar(we_id) && !scalar(l1ack_id)) {
                    if(scalar(l1state_id)!=0) ++row.load_busy;
                    else if(scalar(cacheable_id) && !scalar(rd_hit_id)) ++row.load_miss;
                    else if(scalar(capture_id)) ++row.load_hit_capture;
                }
            } else if(prior_state==6) {
                ++row.store;
                row.store_ack+=bool(scalar(ack_id));
                row.streamed_store_ack+=bool(scalar(ack_id) && optional_scalar(movs_stream_id));
                row.store_wait+=bool(scalar(req_id) && !scalar(ack_id));
            }
        }
        bool prior_memwait=scalar(mem_id) && !scalar(ack_id);
        bool prior_full_memwait=scalar(full_memwait_id), prior_fault=scalar(fault_id);
        std::array<uint64_t,11> prior_control{scalar(mem_id),scalar(stall_id),
            scalar(penalty_id),scalar(bubbles_id),scalar(agi_id),scalar(block_id),
            scalar(sysbail_id),scalar(enabled_id),
            argc==4 ? descriptor(ud_id,"is_fp") : 2u,
            argc==4 ? descriptor(ud_id,"fp_kind") : 255u,
            argc==4 ? descriptor(ud_id,"is_mem") : 2u};
        // Resolution inputs are sampled before the state update, exactly like
        // the predictor's real register/update port. No use of future outcomes
        // is permitted when replaying an alternative predictor from this file.
        bool prior_branch=scalar(brvalid_id), prior_taken=scalar(brtaken_id);
        uint32_t prior_branch_pc=scalar(brpc_id);
        uint32_t retire_count=scalar(rv_id) ? (scalar(rv2_id) ? 2 : 1) : 0;
        uint32_t retire_pc=scalar(qpc_id), retire_pc2=scalar(qpc2_id);
        std::array<uint8_t,48> retire_snapshot;
        memcpy(retire_snapshot.data(),state.data()+fields[snap_id].offset,48);
        bool prior_store=scalar(req_id) && scalar(we_id) && scalar(l1state_id)==0 && !scalar(flush_id);
        uint32_t prior_addr=scalar(addr_id);
        if(scalar(flush_id)) code_evicted_data.clear();
        if(prior_store) {
            // A write to an evicted line changes its backing contents, so a
            // later read miss cannot be ascribed to the earlier I-fill alone.
            const uint32_t physical=uint32_t(scalar(lookup_addr_id));
            code_evicted_data.erase(physical&~31u);
            code_evicted_data.erase(uint32_t(physical+3u)&~31u);
        }
        const unsigned prior_l1state=unsigned(scalar(l1state_id));
        const unsigned prior_fset=unsigned(scalar(fset_id));
        const unsigned prior_fway=unsigned(scalar(fway_id));
        const uint8_t prior_request_origin=scalar(data_access_id) ? 2 : 1;
        const bool prior_fill_bypass=scalar(bypass_id);
        const bool prior_victim_valid=state[fields[val_id].offset+2*prior_fset+prior_fway];
        const uint32_t prior_victim_line=resident_line(prior_fset,prior_fway);
        const uint32_t prior_fill_line=(uint32_t(scalar(ftag_id))<<12)|(prior_fset<<5);
        // Match ven_l1d's existing perf_miss_start predicate exactly, then
        // separate actual demand misses from failed read-chain NEXT queries.
        // rd_hit and the tag arrays refer to lookup_addr, which is redirected
        // to the next request while mc_lookup_next is high. The legacy perf
        // name does not distinguish these non-transactional lookup rejects.
        if(scalar(req_id) && !scalar(we_id) && scalar(l1state_id)==0 &&
           scalar(cacheable_id) && !scalar(rd_hit_id)) {
            const uint32_t line=uint32_t(scalar(lookup_addr_id))&~31u;
            const unsigned kind=scalar(next_lookup_id) ? 2u :
                                unsigned(bool(scalar(data_access_id)));
            ++miss_lines[{line,kind}];
            ++miss_sets[(line>>5)&127u][kind];
            if(kind==1 && code_evicted_data.erase(line))
                ++totals["l1_data_miss_after_witnessed_code_eviction"];
            miss_events<<first+index+1<<'\t'<<std::hex<<line<<std::dec<<'\t'
                       <<((line>>5)&127u)<<'\t'<<kind<<'\t'
                       <<std::hex<<prior_pc<<std::dec<<'\n';
        }
        // Shadow only the validity bit, retaining the trace's actual capture
        // data/address. This measures eligibility on the observed request
        // sequence, not the timing of a counterfactual faster core.
        if(scalar(capture_id)) kept_window=scalar(l1state_id)==0 && scalar(rd_hit_id);
        bool window_store_conflict=(prior_addr>>5)==(scalar(win_addr_id)>>5) ||
            (scalar(xline_id) && ((uint32_t(prior_addr+32)>>5)==(scalar(win_addr_id)>>5)));
        if(scalar(flush_id) || scalar(l1state_id)!=0 ||
           (scalar(req_id) && (scalar(we_id) ? window_store_conflict : (!scalar(cacheable_id) || !scalar(rd_hit_id))))) kept_window=false;
        auto cycle=in.get<uint64_t>(); auto nc=in.get<uint32_t>();
        if(cycle!=first+index+1 || nc>(size+15)/16) throw std::runtime_error("nonconsecutive cycle / count");
        int64_t last=-16;
        for(unsigned j=0;j<nc;++j) {
            auto pos=in.get<uint32_t>(); auto mask=in.get<uint16_t>();
            if(pos%16 || int64_t(pos)<=last || !mask || pos>=size) throw std::runtime_error("invalid block");
            last=pos;
            uint8_t bytes[16]; in.read(bytes,__builtin_popcount(unsigned(mask))); unsigned k=0;
            for(unsigned bit=0;bit<16;++bit) if(mask&(1u<<bit)) {
                if(pos+bit>=size) throw std::runtime_error("invalid mask");
                auto& f=fields[owner[pos+bit]];
                if(owner[pos+bit]==val_id && state[pos+bit] && !bytes[k]) {
                    ++totals["l1_valid_to_invalid"];
                    unsigned wayindex=pos+bit-fields[val_id].offset;
                    uint32_t tag; memcpy(&tag,state.data()+fields[tag_id].offset+4*wayindex,4);
                    uint32_t victim=(tag<<12)|((wayindex/2)<<5);
                    if(prior_store && victim!=(prior_addr&~31u) && victim!=((prior_addr+3)&~31u)) {
                        ++totals["l1_nonmatching_line_drop_during_store"];
                        if(eviction_examples.size()<256) eviction_examples.push_back({cycle,prior_pc,prior_addr,victim,wayindex%2});
                    }
                }
                if(f.last!=cycle) {++f.changes; f.last=cycle;}
                ++f.bytes; state[pos+bit]=bytes[k++];
            }
        }
        changed_blocks+=nc;
        if(prior_l1state==0 && scalar(l1state_id)==1 && !scalar(bypass_id)) {
            active_fill_origin=prior_request_origin;
            ++totals[active_fill_origin==1 ? "l1_code_fill_started" : "l1_data_fill_started"];
        }
        if(prior_l1state==1 && !prior_fill_bypass && scalar(l1state_id)==0) {
            const unsigned set=prior_fset, way=prior_fway;
            if(prior_victim_valid && prior_victim_line!=prior_fill_line) {
                const uint8_t victim_origin=line_origin[set][way];
                if(active_fill_origin==1 && victim_origin==2) {
                    ++totals["l1_code_fill_evicted_witnessed_data_line"];
                    code_evicted_data[prior_victim_line]=cycle;
                } else if(active_fill_origin==1 && victim_origin==0)
                    ++totals["l1_code_fill_evicted_unknown_origin_line"];
            }
            if(state[fields[val_id].offset+2*set+way]) {
                line_origin[set][way]=active_fill_origin;
                code_evicted_data.erase(prior_fill_line);
                ++totals[active_fill_origin==1 ? "l1_code_fill_completed" : "l1_data_fill_completed"];
            } else {
                line_origin[set][way]=0;
                ++totals["l1_fill_completed_invalid"];
            }
            active_fill_origin=0;
        }
        focus.after(scalar);
        const uint64_t post_wst=optional_scalar(uc_wst_id);
        const uint64_t post_wrepair=optional_scalar(uc_wrepair_id);
        const uint64_t post_wset=optional_scalar(uc_wset_id);
        const uint64_t post_wanchor=optional_scalar(uc_wanchor_id);
        if(prior_uop[11] != post_wrepair ||
           (prior_uop[11] && (prior_uop[7] != post_wst ||
                              prior_uop[13] != post_wset ||
                              prior_uop[12] != post_wanchor))) {
            repair_events<<cycle<<'\t'<<prior_uop[7]<<'\t'<<post_wst
                         <<'\t'<<prior_uop[11]<<'\t'<<post_wrepair
                         <<'\t'<<prior_uop[13]<<'\t'<<post_wset
                         <<'\t'<<prior_uop[12]<<'\t'<<post_wanchor
                         <<'\t'<<prior_uop[8]<<'\t'<<prior_next_valid
                         <<'\t'<<prior_next_kill<<'\t'<<prior_poison
                         <<'\t'<<prior_fill_start<<'\t'<<prior_fill_pending
                         <<'\t'<<prior_pd_exec<<'\t'<<prior_pd_len
                         <<'\t'<<prior_primary_set<<'\t'<<prior_primary_off
                         <<'\t'<<optional_scalar(uc_primary_set_id)
                         <<'\t'<<optional_scalar(uc_primary_off_id)<<'\n';
        }
        if(prior_branch)
            branches<<cycle<<'\t'<<std::hex<<prior_branch_pc<<std::dec<<'\t'<<prior_taken<<'\n';
        if(!prior_mem_active && scalar(mem_id)) {held_pair_class=prior_pair_class; held_geometry=prior_geometry;}
        if(!scalar(mem_id) || prior_mem_replace) {
            held_pair_class.clear(); held_geometry={};
            if(argc==4 && prior_mem_replace && scalar(mem_id))
                ++totals["v_memory_attribution_unproven_chain_replacements"];
        }
        uint64_t retired=scalar(ret_id); if(retired<previous_retired) throw std::runtime_error("retirement reset");
        uint64_t delta=retired-previous_retired; previous_retired=retired;
        std::array<uint64_t,3> irq{scalar(irq0_id),scalar(pending_irq_id),scalar(intr_id)};
        if(irq!=previous_irq) {
            interrupts<<cycle<<'\t'<<irq[0]<<'\t'<<irq[1]<<'\t'<<irq[2]<<'\t'<<scalar(state_id)<<'\t'<<scalar(vector_id)<<'\t'<<std::hex<<scalar(pc_id)<<std::dec<<'\t'<<retired<<'\n';
            previous_irq=irq;
        }
        // The generated DPI caller consumes the PRE-edge registered valid,
        // q_pc/q_pc2 and snap. Validate that phase against the actual host count.
        if(delta!=retire_count) throw std::runtime_error("retirement observation phase mismatch");
        if(retire_count) {
            commits.write(reinterpret_cast<const char*>(&retired),8);
            commits.write(reinterpret_cast<const char*>(&cycle),8);
            commits.write(reinterpret_cast<const char*>(&retire_pc),4);
            commits.write(reinterpret_cast<const char*>(&retire_pc2),4);
            commits.write(reinterpret_cast<const char*>(&retire_count),4);
            commits.write(reinterpret_cast<const char*>(retire_snapshot.data()),48);
        }
        unsigned edge_bail=14; // no S_PIPE counter event on this edge
        for(unsigned bucket=0;bucket<14;++bucket) {
            uint64_t value; memcpy(&value,state.data()+fields[bail_id].offset+8*bucket,8);
            if(value<old_bail[bucket] || value-old_bail[bucket]>1) throw std::runtime_error("pp_bail discontinuity");
            if(value!=old_bail[bucket]) {
                if(edge_bail!=14) throw std::runtime_error("multiple pp_bail events per edge");
                edge_bail=bucket;
                ++bail_joint[{bucket,prior_hold,prior_front,uint64_t(bool(delta))}];
                ++pc_bail[{prior_pc,bucket}];
            }
            old_bail[bucket]=value;
        }
        if(edge_bail==3) {
            uop_holes<<cycle<<'\t'<<std::hex<<prior_pc<<'\t'<<prior_flin<<std::dec
                     <<'\t'<<prior_uop[14];
            for(unsigned i=0;i<7;++i) uop_holes<<'\t'<<prior_uop[i];
            uop_holes<<'\t'<<prior_repair_ready<<'\t'<<prior_fill_start
                     <<'\t'<<prior_fill_pending;
            for(unsigned i=7;i<14;++i) uop_holes<<'\t'<<prior_uop[i];
            uop_holes<<'\t'<<prior_primary_valid<<'\t'<<prior_primary_set
                     <<'\t'<<prior_primary_off<<'\t'<<prior_index_valid
                     <<'\t'<<std::hex<<prior_cross_meta<<std::dec<<'\n';
        }
        unsigned st=scalar(state_id); uint32_t pc=scalar(pc_id);
        ++states[st]; ++pc_clocks[pc];
        bool pending=scalar(pending_id), hold=scalar(hold_id), fault=scalar(fault_id);
        bool memwait=scalar(mem_id) && !scalar(ack_id), frontend=scalar(front_id);
        const uint64_t edge_retires=scalar(rv_id) ? (scalar(rv2_id) ? 2 : 1) : 0;
        ++edge_joint[{prior_state,prior_hold,uint64_t(prior_fault),
                     uint64_t(prior_full_memwait),prior_front,edge_retires}];
        totals["edge_retired"]+=edge_retires;
        totals["edges_with_retirement"]+=bool(edge_retires);
        totals["edges_retiring_two"]+=edge_retires==2;
        // Actual edge productivity: new registered retire_valid, paired with
        // the controls sampled before that SAME edge. Unlike the older joint
        // table, this never combines delayed host counts and future controls.
        if(!scalar(rv_id)) {
            ++totals["no_edge_retire_total"];
            ++totals["no_edge_retire_state_"+std::to_string(prior_state)];
            const std::string reason=prior_state!=28 ? "outside_pipe" :
                prior_hold ? "async_hold" : prior_fault ? "async_fault" :
                prior_full_memwait ? "memory_wait_including_admission" :
                !prior_front ? "frontend_unavailable" : "ready_control";
            ++totals["no_edge_retire_"+reason];
            const unsigned cause=prior_state!=28 ? 0 : prior_hold ? 1 :
                prior_fault ? 2 : prior_full_memwait ? 3 : !prior_front ? 4 : 5;
            ++pc_edge_no_retire[{prior_pc,cause}];
            if(reason=="ready_control") {
                std::array<uint64_t,12> key{};
                key[0]=edge_bail;
                std::copy(prior_control.begin(),prior_control.end(),key.begin()+1);
                ++edge_control[key];
                const char* control_reason=prior_control[5] ? "issue_block" :
                    !prior_control[7] ? "fsm_fault_or_diversion" :
                    prior_control[1] ? "stall_countdown" :
                    prior_control[2] ? "pending_memory_penalty" :
                    argc==4 && prior_control[8] ? "fp_admission" :
                    prior_control[6] ? "slow_integer_dispatch" :
                    prior_control[3] ? "branch_recovery" :
                    prior_control[4] ? "agi_interlock" : "other";
                ++totals[std::string("no_edge_retire_ready_control_")+control_reason];
            }
        }
        if(!delta && st==28 && !hold && !memwait && frontend) {
            ++totals["ready_control_residual_total"];
            ++control_joint[{prior_state,prior_hold,uint64_t(prior_memwait),prior_front,
                edge_bail,scalar(rv_id),scalar(commit_id),scalar(mem_id),scalar(stall_id),
                scalar(penalty_id),scalar(bubbles_id),scalar(agi_id),scalar(block_id),
                scalar(sysbail_id),scalar(enabled_id),
                argc==4 ? descriptor(ud_id,"is_fp") : 2u,
                argc==4 ? descriptor(ud_id,"fp_kind") : 255u,
                argc==4 ? descriptor(ud_id,"is_mem") : 2u}];
            // A disjoint phase-aware description, NOT saved-cycle accounting.
            // A newly registered retirement has already completed useful work
            // despite this clock's zero host-reported retirement count.
            const char* reason=scalar(rv_id) ? "registered_retire_awaiting_report" :
                scalar(commit_id) ? "integer_commit_ready_next_edge" :
                scalar(block_id) ? "issue_block" :
                !scalar(enabled_id) ? "fsm_fault_or_diversion" :
                scalar(stall_id) ? "stall_countdown" :
                scalar(penalty_id) ? "pending_memory_penalty" :
                argc==4 && descriptor(ud_id,"is_fp") ? "fp_admission" :
                scalar(sysbail_id) ? "slow_integer_dispatch" :
                scalar(bubbles_id) ? "branch_recovery" :
                scalar(agi_id) ? "agi_interlock" :
                scalar(full_memwait_id) ? "fresh_memory_admission_wait" : "other";
            ++totals[std::string("ready_control_residual_")+reason];
        }
        // Counterfactual eligibility, NOT predicted saved cycles. A changed
        // response schedule would expose requests not present in this trace.
        // EN_L2=0 has no external snoop input in this measured model; flush is
        // checked explicitly. Use the WRAP beat cursor to reconstruct landed
        // words when fill_word_valid was optimized out in the serialized build.
        bool waiting_read=scalar(req_id) && !scalar(we_id) && !scalar(l1ack_id);
        if(scalar(l1state_id)==1) {
            ++cache_backend[{scalar(axi_read_state_id), scalar(bridge_state_id),
                             scalar(backend_state_id), scalar(backing_ack_id),
                             scalar(write_busy_id), uint64_t(waiting_read)}];
        }
        // Disjoint settled-level partition of actual L1 read waits. This is
        // request service, not necessarily a blocking architectural operand:
        // instruction fetch and physical sequencers share this seam too.
        if(waiting_read) {
            ++totals["l1_read_wait_total"];
            const char* category = scalar(l1state_id)!=0 ? "busy" :
                !scalar(cacheable_id) ? "idle_uncacheable" :
                scalar(flush_id) ? "idle_flush" :
                !scalar(rd_hit_id) ? "idle_miss" :
                scalar(capture_id) ? "idle_hit_capture" : "idle_hit_not_capturing";
            ++totals[std::string("l1_read_wait_")+category];
            ++totals[std::string("l1_read_wait_state_")+std::to_string(st)+"_"+category];
            // The core's retained translation selector distinguishes the
            // first I-fill beat in S_PIPE from an integer operand there.
            // "data" also includes physical/system sequencers, not just
            // retired guest loads. These are live request-wait levels; they
            // do not identify the owner of a background fill's every beat.
            const char* source=scalar(data_access_id) ? "data" : "instruction";
            ++totals[std::string("l1_read_wait_source_")+source];
            ++totals[std::string("l1_read_wait_source_")+source+"_"+category];
            ++totals[std::string("l1_read_wait_state_")+std::to_string(st)+"_source_"+source+"_"+category];
        }
        // R_AR=1, R_DATA=2 in this elaboration. The first cache-line burst
        // is intentionally discarded by the HP-port stale-response workaround.
        bool priming=!scalar(axi_primed_id) &&
                     (scalar(axi_read_state_id)==1 || scalar(axi_read_state_id)==2);
        totals["axi_priming_address_or_data_clocks"]+=priming;
        totals["l1_fill_during_axi_priming_clocks"]+=priming && scalar(l1state_id)==1;
        totals["l1_read_wait_during_axi_priming_clocks"]+=priming && waiting_read;
        if(scalar(axi_read_hs_id))
            ++totals[scalar(axi_primed_id) ? "axi_real_read_handshake_levels" :
                                           "axi_discarded_priming_handshake_levels"];
        if(waiting_read && scalar(l1state_id)==0 && scalar(cacheable_id) && scalar(rd_hit_id) &&
           !scalar(flush_id) && (scalar(addr_id)&31)<=28 &&
           (scalar(addr_id)>>5)==(scalar(win_addr_id)>>5) && kept_window && !scalar(win_valid_id))
            ++totals["counterfactual_keep_window_across_store_eligible_clocks"];
        bool resident_fill=scalar(l1state_id)==1 && !scalar(bypass_id);
        uint32_t request_addr=scalar(addr_id);
        if(waiting_read && resident_fill && scalar(cacheable_id) && !scalar(flush_id) && !scalar(xline_id)) {
            bool other_set=((request_addr>>5)&127)!=scalar(fset_id);
            if(other_set && scalar(rd_hit_id)) ++totals["counterfactual_hit_under_fill_eligible_clocks"];
            unsigned landed_distance=(((request_addr>>2)&7)-((scalar(fbase_id)>>2)&7))&7;
            bool same_line=!other_set && (request_addr>>12)==scalar(ftag_id);
            if(same_line && !(request_addr&3) && !scalar(poison_id) &&
               request_addr!=scalar(early_addr_id) && landed_distance<scalar(fw_id))
                ++totals["counterfactual_fill_forward_eligible_clocks"];
        }
        totals["retired"]+=delta;
        totals["cycles_with_retirement"]+=bool(delta);
        totals["cycles_retiring_two"]+=delta==2;
        totals["async_pending"]+=pending;
        totals["async_hold"]+=hold;
        if(stream_count!=lookup.end()) {
            const auto owners=scalar(stream_count->second);
            if(owners>4) throw std::runtime_error("FP owner count exceeds capacity");
            ++totals["fp_owner_count_"+std::to_string(owners)];
        }
        // Settled-level classification, not causal saved cycles: frontend
        // availability takes priority over descriptor shape. A descriptor may
        // still be blocked by other checks after this observed hold is removed.
        if(hold && argc==4) {
            std::string reason;
            if(st!=28) reason="outside_pipe";
            else if(!scalar(front_id)) reason="frontend_unavailable";
            else if(descriptor(ud_id,"is_fp")) {
                reason="fp_descriptor";
                ++totals["fp_hold_descriptor_kind_"+std::to_string(descriptor(ud_id,"fp_kind"))];
                ++totals["fp_hold_descriptor_aluop_"+std::to_string(descriptor(ud_id,"fp_aluop"))];
                // FK_MEM=0 is the shared-FP memory admission descriptor.
                // decode.sv intentionally leaves the INTEGER is_mem flag
                // clear: S_FLOAD, not the integer pipeline, owns this access.
                const std::string operand = descriptor(ud_id,"fp_kind")==0 ? "memory" : "register";
                ++totals["fp_hold_descriptor_operand_"+operand];
                ++totals["fp_hold_descriptor_kind_"+std::to_string(descriptor(ud_id,"fp_kind"))+"_"+operand];
            }
            else if(!descriptor(ud_id,"simple")) reason="nonsimple_integer";
            else if(descriptor(ud_id,"is_stack")) reason="stack";
            else if(descriptor(ud_id,"is_branch")) reason="branch";
            else if(descriptor(ud_id,"is_mem")) reason="memory";
            else reason="other";
            ++totals["fp_hold_observed_"+reason];
        }
        totals["async_fault_hold"]+=fault;
        totals["pipe_mem_wait"]+=memwait;
        totals["pending_and_int_commit_level"]+=pending && scalar(commit_id);
        if(hold) ++holdstates[st];
        if(st==28) ++pairs[scalar(pair_id)];
        if(argc==4 && st==28 && scalar(commit_id)) {
            const auto category=scalar(mem_id) ? held_pair_class : memory_pair_class();
            if(!category.empty()) {
                ++totals["v_memory_completed_u_"+category];
                ++totals[scalar(mem_id) ? "v_memory_completed_u_held_packet" :
                                          "v_memory_completed_u_fresh_packet"];
                const auto geometry=scalar(mem_id) ? held_geometry : read_geometry();
                if(geometry.reads) {
                    ++totals["read_pair_completed_u"];
                    if(geometry.same_segment && geometry.same_line && geometry.contained) {
                        ++totals["read_pair_same_segment_line_contained"];
                        // Existing full-line registered window only. Do not
                        // count critical-word responses or external/MMIO reads.
                        if(scalar(req_id) && !scalar(we_id) && scalar(ack_id) && scalar(l1ack_id) &&
                           scalar(l1state_id)==0 && scalar(cacheable_id) && scalar(rd_hit_id) &&
                           !scalar(flush_id) && !scalar(early_armed_id) && scalar(win_valid_id) &&
                           (scalar(addr_id)>>5)==(scalar(win_addr_id)>>5))
                            ++totals["read_pair_same_line_complete_registered_window"];
                    }
                }
            }
        }
        // Count settled admission levels, not saved cycles. PR_VMEM is the
        // leaf's last rejection: normal simple/class/RAW/WAW checks have passed.
        // U actually committing removes repetitions caused by its own stalls.
        if(argc==4 && st==28 && scalar(commit_id) && !scalar(mem_id) &&
           frontend && scalar(vbytes_id) && scalar(vavail_id) && scalar(pair_id)==6 &&
           !descriptor(ud_id,"is_mem") && !descriptor(ud_id,"is_stack") &&
           !descriptor(ud_id,"is_branch") && !descriptor(ud_id,"is_fp")) {
            ++totals["counterfactual_u_register_v_memory_commit_levels"];
            if(descriptor(vd_id,"is_load") && !descriptor(vd_id,"is_store") &&
               !descriptor(vd_id,"is_stack") && !descriptor(vd_id,"is_fp")) {
                ++totals["counterfactual_u_register_v_mov_load_commit_levels"];
                if(!descriptor(vd_id,"w8") && !descriptor(vd_id,"w16"))
                    ++totals["counterfactual_u_register_v_mov32_load_commit_levels"];
            }
        }
        ++joint[{st,uint64_t(hold),uint64_t(memwait),uint64_t(frontend),uint64_t(bool(delta))}];
        if(!delta) {
            ++nostates[st]; ++pc_no_retire[pc]; ++stall_run;
            if(stall_run>max_stall) {max_stall=stall_run;max_stall_end=cycle;}
            // Disjoint descriptive partition; level co-occurrence is NOT causal attribution.
            ++totals[hold ? "no_retire_async_hold" : fault ? "no_retire_async_fault" : memwait ? "no_retire_pipe_mem_wait" : "no_retire_other"];
        } else stall_run=0;
    }
    in.magic("ENDDLT01"); if(in.get<uint64_t>()!=count) throw std::runtime_error("footer count");
    std::vector<uint8_t> final(size); in.read(final.data(),size);
    if(state!=final) throw std::runtime_error("lossless reconstruction failed");
    const uint64_t final_registered_retire=scalar(rv_id) ? (scalar(rv2_id) ? 2 : 1) : 0;
    std::array<uint64_t,3> counted_misses{};
    for(const auto& set:miss_sets)
        for(unsigned kind=0;kind<counted_misses.size();++kind)
            counted_misses[kind]+=set[kind];
    const uint64_t reported_misses=scalar(miss_perf_id)-initial_miss_perf;
    const uint64_t demand_misses=counted_misses[0]+counted_misses[1];
    // Traces built before the counter repair include rejected read-chain
    // lookups; current builds exclude them. Both schedules must reconcile
    // exactly, never silently accept an unrelated counter mismatch.
    const bool legacy_miss_counter=counted_misses[2] &&
        (reported_misses==demand_misses+counted_misses[2]);
    if(!legacy_miss_counter && reported_misses!=demand_misses)
        throw std::runtime_error("lookup-miss histogram disagrees with L1 counter");
    totals["initial_registered_retire"]=initial_registered_retire;
    totals["final_registered_retire"]=final_registered_retire;
    if(totals["edge_retired"]+initial_registered_retire!=
       previous_retired-retired_start+final_registered_retire)
        throw std::runtime_error("edge/host retirement conservation failed");
    uint8_t extra; int tail=gzread(in.f,&extra,1);
    if(tail!=0 || !gzeof(in.f)) throw std::runtime_error("trailing data / gzip CRC error");
    std::string prefix=argv[2];
    focus.write(prefix);
    std::ofstream summary(prefix+".summary.tsv"), activity(prefix+".fields.tsv"), hot(prefix+".pcs.tsv"), matrix(prefix+".joint.tsv");
    if(!summary || !activity || !hot || !matrix) throw std::runtime_error("output open");
    summary<<"metric\tvalue\ncycles\t"<<count<<"\nstart\t"<<first<<"\nend\t"<<first+count<<"\nfields\t"<<nf<<"\nstate_bytes\t"<<size<<"\nchanged_blocks\t"<<changed_blocks<<"\n";
    summary<<"ipc\t"<<double(previous_retired-retired_start)/count<<"\nlongest_no_retire\t"<<max_stall<<"\nlongest_no_retire_end\t"<<max_stall_end<<"\n";
    summary<<"l1_demand_miss_code\t"<<counted_misses[0]<<"\n"
           <<"l1_demand_miss_data\t"<<counted_misses[1]<<"\n"
           <<"l1_next_lookup_miss_reject\t"<<counted_misses[2]<<"\n"
           <<"l1_reported_miss_counter_delta\t"<<reported_misses<<"\n"
           <<"l1_miss_counter_includes_next\t"<<legacy_miss_counter<<"\n";
    for(auto& kv:totals) summary<<kv.first<<'\t'<<kv.second<<'\n';
    for(auto& kv:states) summary<<"state_"<<kv.first<<'\t'<<kv.second<<'\n';
    for(auto& kv:nostates) summary<<"no_retire_state_"<<kv.first<<'\t'<<kv.second<<'\n';
    for(auto& kv:holdstates) summary<<"async_hold_state_"<<kv.first<<'\t'<<kv.second<<'\n';
    for(auto& kv:pairs) summary<<"pipe_pair_reason_level_"<<kv.first<<'\t'<<kv.second<<'\n';
    activity<<"name\tsize\tchanged_cycles\tchanged_bytes\n";
    std::ofstream backend(prefix+".cache_backend.tsv");
    if(!backend) throw std::runtime_error("cache backend report open");
    backend<<"axi_read_state\tbridge_state\tbackend_state\tbacking_ack\twrite_busy\tread_waiting\tcycles\n";
    for(const auto& kv:cache_backend) {
        for(auto value:kv.first) backend<<value<<'\t';
        backend<<kv.second<<'\n';
    }
    std::ofstream miss_set_out(prefix+".miss_sets.tsv"), miss_line_out(prefix+".miss_lines.tsv");
    if(!miss_set_out || !miss_line_out) throw std::runtime_error("miss histogram output open");
    miss_set_out<<"set\tcode_misses\tdata_misses\tnext_rejects\ttotal\n";
    for(unsigned set=0;set<miss_sets.size();++set)
        miss_set_out<<set<<'\t'<<miss_sets[set][0]<<'\t'<<miss_sets[set][1]<<'\t'
                    <<miss_sets[set][2]<<'\t'
                    <<miss_sets[set][0]+miss_sets[set][1]+miss_sets[set][2]<<'\n';
    miss_line_out<<"physical_line\tkind\tcount\n";
    for(const auto& kv:miss_lines)
        miss_line_out<<std::hex<<kv.first[0]<<std::dec<<'\t'<<kv.first[1]<<'\t'<<kv.second<<'\n';
    for(const auto& f:fields) activity<<f.name<<'\t'<<f.size<<'\t'<<f.changes<<'\t'<<f.bytes<<'\n';
    hot<<"eip\tclocks\tno_retire\n";
    for(auto& kv:pc_clocks) hot<<std::hex<<kv.first<<std::dec<<'\t'<<kv.second<<'\t'<<pc_no_retire[kv.first]<<'\n';
    std::ofstream string_out(prefix+".string_service.tsv");
    if(!string_out) throw std::runtime_error("string service output open");
    string_out<<"q_pc\tq_st\tclocks\tload\tstore\tload_ack\tstore_ack\t"
              <<"fused_load_ack\tstreamed_store_ack\tload_busy\t"
              <<"load_hit_capture\tload_miss\tstore_wait\n";
    for(const auto& [key,row]:string_service)
        string_out<<std::hex<<key[0]<<std::dec<<'\t'<<key[1]<<'\t'
                  <<row.clocks<<'\t'<<row.load<<'\t'<<row.store<<'\t'
                  <<row.load_ack<<'\t'<<row.store_ack<<'\t'
                  <<row.fused_load_ack<<'\t'<<row.streamed_store_ack<<'\t'
                  <<row.load_busy<<'\t'<<row.load_hit_capture<<'\t'
                  <<row.load_miss<<'\t'<<row.store_wait<<'\n';
    std::ofstream pc_causes(prefix+".pc_edge_causes.tsv");
    if(!pc_causes) throw std::runtime_error("PC edge cause output open");
    pc_causes<<"eip\toutside_pipe\tasync_hold\tasync_fault\tmemory_wait_including_admission\tfrontend_unavailable\tready_control\ttotal\n";
    std::map<uint64_t,std::array<uint64_t,6>> pc_cause_rows;
    for(const auto& kv:pc_edge_no_retire) pc_cause_rows[kv.first[0]][kv.first[1]]+=kv.second;
    uint64_t pc_cause_total=0;
    for(const auto& kv:pc_cause_rows) {
        pc_causes<<std::hex<<kv.first<<std::dec;
        uint64_t row_total=0;
        for(uint64_t value:kv.second) {pc_causes<<'\t'<<value; row_total+=value;}
        pc_causes<<'\t'<<row_total<<'\n';
        pc_cause_total+=row_total;
    }
    if(pc_cause_total!=totals["no_edge_retire_total"])
        throw std::runtime_error("PC edge cause partition mismatch");
    matrix<<"state\tasync_hold\tpipe_mem_wait\tfrontend_ready\tretired\tcycles\n";
    for(auto& kv:joint) {for(auto v:kv.first) matrix<<v<<'\t'; matrix<<kv.second<<'\n';}
    std::ofstream cj(prefix+".ready_control.tsv");
    cj<<"previous_state\tprevious_async_hold\tprevious_pipe_mem_wait\tprevious_frontend_ready\tedge_bail_bucket\tregistered_retire\tnext_edge_int_commit\tpipe_mem_active\tstall_count\tpending_memory_penalty\tbranch_bubbles\tagi\tissue_block\tsystem_bail\tfsm_enabled\tu_is_fp\tu_fp_kind\tu_is_mem\tcycles\n";
    for(const auto& kv:control_joint) {for(auto v:kv.first) cj<<v<<'\t'; cj<<kv.second<<'\n';}
    std::ofstream ec(prefix+".edge_ready_control.tsv");
    ec<<"edge_bail_bucket\tprevious_pipe_mem_active\tprevious_stall_count\tprevious_pending_memory_penalty\tprevious_branch_bubbles\tprevious_agi\tprevious_issue_block\tprevious_system_bail\tprevious_fsm_enabled\tprevious_u_is_fp\tprevious_u_fp_kind\tprevious_u_is_mem\tcycles\n";
    for(const auto& kv:edge_control) {for(auto v:kv.first) ec<<v<<'\t'; ec<<kv.second<<'\n';}
    std::ofstream ej(prefix+".edge_joint.tsv");
    ej<<"previous_state\tprevious_async_hold\tprevious_async_fault\tprevious_pipe_mem_wait\tprevious_frontend_ready\tedge_retired\tcycles\n";
    for(const auto& kv:edge_joint) {for(auto v:kv.first) ej<<v<<'\t'; ej<<kv.second<<'\n';}
    std::ofstream bj(prefix+".bail_joint.tsv"), pb(prefix+".pc_bail.tsv");
    bj<<"bail_counter_bucket\tprevious_settled_async_hold\tprevious_settled_frontend_ready\tretired\tcycles\n";
    for(auto& kv:bail_joint) {for(auto v:kv.first) bj<<v<<'\t'; bj<<kv.second<<'\n';}
    pb<<"previous_settled_eip\tbail_counter_bucket\tcycles\n";
    for(auto& kv:pc_bail) pb<<std::hex<<kv.first[0]<<std::dec<<'\t'<<kv.first[1]<<'\t'<<kv.second<<'\n';
    std::ofstream ev(prefix+".store_victims.tsv");
    ev<<"cycle\tprevious_eip\tstore_address\tvictim_line_address\tway\n";
    for(const auto& x:eviction_examples) ev<<x[0]<<'\t'<<std::hex<<x[1]<<'\t'<<x[2]<<'\t'<<x[3]<<std::dec<<'\t'<<x[4]<<'\n';
    // Exact bookends enable arbitrary array/counter diffs without rescanning gzip.
    std::ofstream a(prefix+".initial.bin",std::ios::binary), b(prefix+".final.bin",std::ios::binary);
    a.write(reinterpret_cast<const char*>(initial.data()),size); b.write(reinterpret_cast<const char*>(final.data()),size);
    std::ofstream schema(prefix+".schema.tsv"); schema<<"name\toffset\tsize\ttype\n";
    for(const auto& f:fields) schema<<f.name<<'\t'<<f.offset<<'\t'<<f.size<<'\t'<<f.type<<'\n';
    if(!summary || !activity || !hot || !matrix || !a || !b || !schema || !bj || !pb || !ev || !commits || !interrupts || !cj || !branches || !ec || !ej) throw std::runtime_error("output write");
    std::cout<<"STATE-DELTA-ANALYZE-OK cycles="<<count<<" fields="<<nf<<" IPC="<<double(previous_retired-retired_start)/count<<" reconstruction=exact\n";
} catch(const std::exception& e) {std::cerr<<e.what()<<'\n'; return 2;}
