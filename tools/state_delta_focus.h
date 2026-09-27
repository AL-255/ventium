// Optional read-only correlations for the recorded predecode and string paths.
// Uses PRE-edge controls and validates the matching POST-edge hardware counter.
// Counts are observations, not counterfactual saved clocks or predicted IPC.
#pragma once
#include <array>
#include <cstdint>
#include <fstream>
#include <functional>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

class StateDeltaFocus {
public:
    using Read = std::function<uint64_t(unsigned)>;
    using Lookup = std::function<int(const std::string&)>;
    static std::vector<std::string> names() {
        return {"pp_umap_base_safe", "pp_umap_ref_fastctx", "pp_umap_ref_simple_fastctx",
                "flin", "pp_umap_end_reason", "uc_repair_start",
                "u_uopcache__DOT__wst", "u_uopcache__DOT__woff", "u_uopcache__DOT__wanchor",
                "u_uopcache__DOT__wset", "u_uopcache__DOT__wway", "u_uopcache__DOT__wnext_valid",
                "u_uopcache__DOT__cross_seek_yield", "u_uopcache__DOT__pd_start_live",
                "u_uopcache__DOT__pd_pend_live", "u_uopcache__DOT__wpz",
                "state", "q_pc", "q_kind", "q_st", "q_w", "mem_req", "mem_ack",
                "fsm_case_enabled", "pipe_frontend_ready",
                "axi.wq_count", "axi.wr_enq", "axi.wr_dispatch", "axi.aw_hs", "axi.w_hs", "axi.b_hs",
                "bridge.state", "bridge.waitrequest", "l1.do_rd_cap", "l1.window_valid_q"};
    }
    static std::vector<std::string> backend_names() {
        return {"backend.state", "backend.vgabusy", "backend.vga_wr",
                "backend.vga_be", "backend.vga_ba", "backend.vga_wa",
                "backend.vga_next_be"};
    }
    explicit StateDeltaFocus(const Lookup& lookup) {
        for (const auto& name : names()) {
            int id = lookup(name);
            if (id < 0) { available_ = false; return; }
            ids_.push_back(unsigned(id));
        }
        available_ = true;
        for (const auto& name : backend_names()) {
            int id = lookup(name);
            if (id < 0) { backend_ids_.clear(); return; }
            backend_ids_.push_back(unsigned(id));
        }
    }
    bool available() const { return available_; }
    bool backend_available() const { return backend_ids_.size()==7; }
    void before(const Read& read) {
        if (!available_) return;
        if (armed_) throw std::runtime_error("focus duplicate pre-edge sample");
        for (unsigned n=0; n<ids_.size(); ++n) pre_[n]=read(ids_[n]);
        for (unsigned n=0; n<backend_ids_.size(); ++n) backend_pre_[n]=read(backend_ids_[n]);
        armed_=true;
    }
    void after(const Read& read) {
        if (!available_) return;
        if (!armed_) throw std::runtime_error("focus missing pre-edge sample");
        armed_=false;
        uint64_t current=read(ids_[2]);
        bool hole=pre_[0] && pre_[1];
        if (current<pre_[2] || current-pre_[2]!=uint64_t(hole))
            throw std::runtime_error("focus hole-counter phase mismatch");
        if (hole) {
            std::array<uint64_t,13> key{};
            for (unsigned n=0; n<key.size(); ++n) key[n]=pre_[3+n];
            ++holes_[key];
            ++hole_count_;
        }
        // All walker clocks, separated from core availability. A busy repair
        // while the core is waiting for data is not necessarily on its path.
        ++walker_[{pre_[6],pre_[7],pre_[8],pre_[16],pre_[24],pre_[5]}];
        // Raw enum values deliberately retained. Decode q_kind/q_st/state
        // only with the actual trace build's package/FSM definitions.
        if (pre_[16]==3 || pre_[16]==6) {
            ++memory_[{pre_[16],pre_[17],pre_[18],pre_[19],pre_[20],
                       pre_[21],pre_[22],pre_[23]}];
            ++service_[{pre_[16],pre_[17],pre_[18],pre_[19],pre_[20],pre_[21],pre_[22],
                        pre_[25],pre_[26],pre_[27],pre_[28],pre_[29],pre_[30],
                        pre_[31],pre_[32],pre_[33],pre_[34]}];
        }
        // Observe the original backend byte port, without inferring memory
        // attribution from unrelated counters.  States 8/9 are this pinned
        // ao486 backend's VGABYTECHECK/VGAWRITE, NOT the core state enum.
        if (backend_available() &&
            (backend_pre_[0]==8 || backend_pre_[0]==9 ||
             ((pre_[16]==3 || pre_[16]==6) && pre_[18]==13))) {
            ++vga_[{pre_[16],pre_[17],pre_[18],pre_[19],pre_[20],pre_[21],pre_[22],pre_[23],
                    pre_[31],backend_pre_[0],backend_pre_[1],backend_pre_[2],backend_pre_[3],
                    backend_pre_[4],backend_pre_[5],backend_pre_[6],pre_[25],pre_[32],pre_[24]}];
        }
        ++cycles_;
    }
    uint64_t holes() const { return hole_count_; }
    void write(const std::string& prefix) const {
        if (armed_) throw std::runtime_error("focus uncompleted edge");
        std::ofstream status(prefix+".focus_status.tsv");
        status<<"available\tcycles\tverified_fast_context_holes\tbackend_available\n"
              <<available_<<'\t'<<cycles_<<'\t'<<hole_count_<<'\t'<<backend_available()<<'\n';
        if (!status) throw std::runtime_error("focus status write");
        if (!available_) return;
        output(prefix+".frontend_repair.tsv",
               "linear_pc\tend_reason\trepair_start\twstate\twoff\twanchor\twset\twway\tnext_valid\tyield\trefill_live\trefill_pending\tpoison\tclocks", holes_);
        output(prefix+".walker_core.tsv",
               "wstate\twoff\twanchor\tcore_state\tfrontend_ready\trepair_start\tclocks", walker_);
        output(prefix+".slow_memory_width.tsv",
               "core_state\tq_pc\tq_kind\tq_string\twidth\trequest\tack\tfsm_enabled\tclocks", memory_);
        output(prefix+".slow_memory_service.tsv",
               "core_state\tq_pc\tq_kind\tq_string\twidth\trequest\tack\twq_count\twr_enq\twr_dispatch\taw_hs\tw_hs\tb_hs\tbridge_state\tavalon_busy\tread_capture\twindow_valid\tclocks", service_);
        if (backend_available())
            output(prefix+".vga_service.tsv",
                "core_state\tq_pc\tq_kind\tq_string\twidth\trequest\tack\tfsm_enabled\tbridge_state\tbackend_state\tvga_busy\tvga_write\tvga_be\tvga_byte\tvga_word\tvga_next_be\twq_count\tavalon_busy\tfrontend_ready\tclocks", vga_);
    }
private:
    template<size_t N> static void output(const std::string& path, const char* header,
        const std::map<std::array<uint64_t,N>,uint64_t>& rows) {
        std::ofstream out(path);
        out<<header<<'\n';
        for (const auto& row:rows) {
            for (auto value:row.first) out<<value<<'\t';
            out<<row.second<<'\n';
        }
        if (!out) throw std::runtime_error("focus table write");
    }
    bool available_=false, armed_=false;
    std::vector<unsigned> ids_;
    std::vector<unsigned> backend_ids_;
    std::array<uint64_t,35> pre_{};
    std::array<uint64_t,7> backend_pre_{};
    uint64_t cycles_=0, hole_count_=0;
    std::map<std::array<uint64_t,13>,uint64_t> holes_;
    std::map<std::array<uint64_t,6>,uint64_t> walker_;
    std::map<std::array<uint64_t,8>,uint64_t> memory_;
    std::map<std::array<uint64_t,17>,uint64_t> service_;
    std::map<std::array<uint64_t,19>,uint64_t> vga_;
};
