#include "irq_inject_probe.h"
#include <cassert>
#include <cstring>
struct NoSoc {};
struct EmptyRoot {};
struct SocOnly { unsigned intr=0,inta=0,soc_en=0,inta_vector=0; EmptyRoot* rootp=nullptr; };
struct Root {
    unsigned ventium_top__DOT__u_core__DOT__fp_async_count=2;
    unsigned ventium_top__DOT__core_retire_valid=1;
    unsigned ventium_top__DOT__core_retire_pc=0x8008;
    unsigned ventium_top__DOT__u_core__DOT__eip=0x8009;
};
struct Full { unsigned intr=0,inta=0,soc_en=0,inta_vector=0; Root state; Root* rootp=&state; };
template<class T> void dormant(T& t) {
    IrqInjectProbe p; p.drive(t,0,0); p.pre_edge(t,1,0); p.post_edge(t,0); p.finish();
}
int main(int argc,char** argv) {
    unsetenv("VEN_TEST_IRQ_PC"); NoSoc no; SocOnly soc; Full full;
    dormant(no); dormant(soc); dormant(full);
    assert(!full.intr && !full.soc_en);
    setenv("VEN_TEST_IRQ_PC","0x8008",1);
    setenv("VEN_TEST_IRQ_VECTOR","64",1);
    setenv("VEN_TEST_IRQ_COUNT","1",1);
    IrqInjectProbe p;
    const char* mode=argc>1?argv[1]:"ok";
    if (!strcmp(mode,"nosoc")) p.drive(no,0,0);
    if (!strcmp(mode,"noasync")) p.drive(soc,0,0);
    if (!strcmp(mode,"unsolicited")) { full.inta=1; p.pre_edge(full,0,0); }
    p.drive(full,10,0); assert(full.intr && full.soc_en && p.issued==1);
    full.state.ventium_top__DOT__core_retire_valid=0;
    p.pre_edge(full,11,0); p.post_edge(full,0);
    p.drive(full,20,0); assert(full.intr && p.issued==1 && p.acked==0);
    if (!strcmp(mode,"timeout")) p.drive(full,10011,0);
    if (!strcmp(mode,"missing")) p.finish();
    full.inta=1;
    if (strcmp(mode,"owners")) full.state.ventium_top__DOT__u_core__DOT__fp_async_count=0;
    if (!strcmp(mode,"vector")) full.inta_vector=65;
    p.pre_edge(full,21,0); assert(full.intr && p.acked==0);
    p.post_edge(full,0); assert(!full.intr && p.acked==1);
    if (!strcmp(mode,"duplicate")) p.pre_edge(full,22,0);
    full.inta=0; p.drive(full,22,0); p.finish();
}
