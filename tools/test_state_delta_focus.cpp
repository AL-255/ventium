#include "state_delta_focus.h"
#include <iostream>

int main(int argc, char** argv) {
    if (argc!=2) return 2;
    auto names=StateDeltaFocus::names();
    for(const auto& name:StateDeltaFocus::backend_names()) names.push_back(name);
    std::map<std::string,unsigned> ids;
    for (unsigned n=0;n<names.size();++n) ids[names[n]]=n;
    auto lookup=[&](const std::string& s) {auto it=ids.find(s); return it==ids.end()?-1:int(it->second);};
    std::vector<uint64_t> values(names.size());
    auto read=[&](unsigned n) {return values.at(n);};
    auto set=[&](const std::string& s,uint64_t n) {values.at(ids.at(s))=n;};
    StateDeltaFocus focus(lookup);
    set("pp_umap_base_safe",1); set("pp_umap_ref_fastctx",1);
    set("flin",0x1234); set("u_uopcache__DOT__wst",4);
    set("u_uopcache__DOT__woff",2); set("u_uopcache__DOT__wanchor",31);
    set("pp_umap_end_reason",1); set("state",3); set("q_pc",0x5678);
    set("q_kind",22); set("q_st",0); set("q_w",4); set("mem_req",1);
    set("axi.wq_count",2); set("axi.b_hs",1); set("bridge.state",4);
    set("l1.do_rd_cap",1);
    set("backend.state",9); set("backend.vgabusy",1); set("backend.vga_wr",1);
    set("backend.vga_be",15); set("backend.vga_ba",2); set("backend.vga_wa",0x123);
    set("backend.vga_next_be",15);
    if(!focus.backend_available()) return 5;
    focus.before(read);
    // Change every attribution field AFTER sampling: the row must retain old
    // PC/width/ACK, not borrow the following instruction's settled values.
    for (auto& value:values) value=0;
    set("pp_umap_ref_simple_fastctx",1);
    focus.after(read);
    focus.before(read); focus.after(read);
    if(focus.holes()!=1) return 3;
    focus.write(argv[1]);
    auto must_fail=[](const std::function<void()>& call) {
        try {call();} catch(const std::runtime_error&) {return;}
        throw std::runtime_error("negative test did not fail");
    };
    must_fail([&] {focus.after(read);});
    focus.before(read);
    must_fail([&] {focus.before(read);});
    set("pp_umap_ref_simple_fastctx",2);
    must_fail([&] {focus.after(read);});
    StateDeltaFocus missing([](const std::string&) {return -1;});
    if(missing.available()) return 4;
    missing.before(read); missing.after(read);
    missing.write(std::string(argv[1])+"-missing");
    // Losing ANY backend field disables this optional report, never silently
    // substitutes zero, while keeping the original focus report available.
    for(const auto& omitted:StateDeltaFocus::backend_names()) {
        StateDeltaFocus partial([&](const std::string& s) {return s==omitted?-1:lookup(s);});
        if(!partial.available() || partial.backend_available()) return 6;
        partial.before(read); partial.after(read);
    }
    std::cout<<"STATE-DELTA-FOCUS-UNIT-OK\n";
}
