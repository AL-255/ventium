#pragma once
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

// Test-only external interrupt source. Never changes internal RTL/guest state.
// A registered primary retirement raises a held level on the existing SOC pins;
// only a real pre-edge INTA handshake lowers it. Entirely inert without the PC.
struct IrqInjectProbe {
    bool enabled=false, pending=false, accepted=false;
    uint32_t pc=0, vector=0, limit=0, issued=0, acked=0;
    uint64_t requested_at=0;
    static void fail(const char* why) {
        std::fprintf(stderr,"[TEST-IRQ] FAIL %s\n",why); std::abort();
    }
    static uint32_t number(const char* name) {
        const char* s=std::getenv(name); char* end=nullptr;
        if (!s || !*s || *s=='-') fail("missing/invalid IRQ option");
        errno=0; const unsigned long value=std::strtoul(s,&end,0);
        if (errno || *end || value>UINT32_MAX) fail("invalid IRQ number");
        return uint32_t(value);
    }
    IrqInjectProbe() {
        if (!std::getenv("VEN_TEST_IRQ_PC")) return;
        pc=number("VEN_TEST_IRQ_PC"); vector=number("VEN_TEST_IRQ_VECTOR");
        limit=number("VEN_TEST_IRQ_COUNT");
        if (vector<32 || vector>255 || !limit) fail("invalid vector/count");
#if defined(VEN_DOS_MODELS) || defined(VEN_RTL_IRQ)
        fail("test source cannot share IRQ pins with a PIC driver");
#endif
        enabled=true;
    }
    template<class T> auto drive(T& t,uint64_t cycle,int) -> decltype(
        (void)t.intr,(void)t.inta,(void)t.soc_en,(void)t.inta_vector,
        (void)t.rootp->ventium_top__DOT__u_core__DOT__fp_async_count,
        (void)t.rootp->ventium_top__DOT__core_retire_valid,
        (void)t.rootp->ventium_top__DOT__core_retire_pc,
        (void)t.rootp->ventium_top__DOT__u_core__DOT__eip,void()) {
        if (!enabled) return;
        const auto& r=*t.rootp;
        if (!pending && issued<limit && r.ventium_top__DOT__core_retire_valid &&
            r.ventium_top__DOT__core_retire_pc==pc) {
            pending=true; requested_at=cycle; ++issued;
            std::fprintf(stderr,"[TEST-IRQ] REQUEST n=%u cycle=%llu pc=%08x next=%08x owners=%u vector=%u\n",
                issued,(unsigned long long)cycle,pc,r.ventium_top__DOT__u_core__DOT__eip,
                unsigned(r.ventium_top__DOT__u_core__DOT__fp_async_count),vector);
        }
        if (pending && cycle-requested_at>10000) fail("held IRQ not acknowledged");
        t.soc_en=1; t.intr=pending; t.inta_vector=vector;
    }
    template<class T> void drive(T&,uint64_t,long) {
        if (enabled) fail("requires SOC IRQ ports and shared FP owner state");
    }
    template<class T> auto pre_edge(const T& t,uint64_t cycle,int) -> decltype(
        (void)t.inta,(void)t.inta_vector,
        (void)t.rootp->ventium_top__DOT__u_core__DOT__fp_async_count,
        (void)t.rootp->ventium_top__DOT__u_core__DOT__eip,void()) {
        if (!enabled) return;
        accepted=t.inta;
        if (!accepted) return;
        if (!pending || t.inta_vector!=vector) fail("unsolicited/wrong-vector INTA");
        const auto& r=*t.rootp;
        if (r.ventium_top__DOT__u_core__DOT__fp_async_count) fail("INTA before FP owner drain");
        std::fprintf(stderr,"[TEST-IRQ] INTA n=%u cycle=%llu next=%08x owners=0 vector=%u\n",
            acked+1,(unsigned long long)cycle,r.ventium_top__DOT__u_core__DOT__eip,vector);
    }
    template<class T> void pre_edge(const T&,uint64_t,long) {}
    template<class T> auto post_edge(T& t,int) -> decltype((void)t.intr,void()) {
        if (enabled && accepted) { ++acked; pending=false; accepted=false; t.intr=0; }
    }
    template<class T> void post_edge(T&,long) {}
    void finish() const {
        if (!enabled) return;
        if (pending || issued!=limit || acked!=limit) fail("missing/duplicate IRQ delivery");
        std::fprintf(stderr,"[TEST-IRQ] PASS requests=%u acknowledgements=%u vector=%u\n",issued,acked,vector);
    }
};
