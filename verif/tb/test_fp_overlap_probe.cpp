#include "fp_overlap_probe.h"
#include <cassert>
#include <initializer_list>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#include <csignal>

struct SharedRoot {
    unsigned ventium_top__DOT__u_core__DOT__u_fp_shared__DOT__top_state=0;
    unsigned ventium_top__DOT__core_retire_pc=0x100;
    bool ventium_top__DOT__core_retire_valid=true;
};
struct OtherRoot {};

template<class F> void rejects(F action) {
    const pid_t child=fork();
    assert(child>=0);
    if (!child) {
        const rlimit limit{0,0};
        setrlimit(RLIMIT_CORE,&limit);
        action();
        _exit(0);
    }
    int status=0;
    assert(waitpid(child,&status,0)==child);
    assert(WIFSIGNALED(status) && WTERMSIG(status)==SIGABRT);
}

int main() {
    unsetenv("VEN_FP_OVERLAP_LO");
    unsetenv("VEN_FP_OVERLAP_HI");
    FpOverlapProbe disabled;
    disabled.sample(OtherRoot{},0);
    assert(!disabled.enabled);
    assert(FpOverlapProbe::address("0Xffffffff")==0xffffffffu);
    assert(FpOverlapProbe::address("100")==0x100);
    for (const char* bad : {"", "0x", "-1", "100000000", "10junk"})
        rejects([&]{ FpOverlapProbe::address(bad); });
    setenv("VEN_FP_OVERLAP_LO","100",1);
    rejects([]{ FpOverlapProbe probe; }); // missing upper bound
    setenv("VEN_FP_OVERLAP_HI","100",1);
    rejects([]{ FpOverlapProbe probe; }); // empty range
    setenv("VEN_FP_OVERLAP_HI","110",1);
    FpOverlapProbe probe;
    rejects([&]{ probe.sample(OtherRoot{},0); });
    SharedRoot root;
    probe.sample(root,0); // integer retirement, idle FPU
    root.ventium_top__DOT__u_core__DOT__u_fp_shared__DOT__top_state=1;
    probe.sample(root,0); // positive concurrency witness, inclusive lower bound
    root.ventium_top__DOT__core_retire_pc=0x110;
    probe.sample(root,0); // exclusive upper bound
    root.ventium_top__DOT__core_retire_pc=0xff;
    probe.sample(root,0);
    root.ventium_top__DOT__core_retire_pc=0x108;
    root.ventium_top__DOT__core_retire_valid=false;
    probe.sample(root,0); // invalid retirement must not count
    assert(probe.busy==4 && probe.integer==2 && probe.overlap==1);
    assert(root.ventium_top__DOT__core_retire_pc==0x108);
    assert(!root.ventium_top__DOT__core_retire_valid);
    assert(probe.overlap_at_commit==0);
    // The pre-edge sample sees retirement *from the previous edge*. A busy
    // transition now must not retroactively classify a preceding retirement;
    // a transition to IDLE must not lose a retirement on the final busy edge.
    FpOverlapProbe aligned;
    root.ventium_top__DOT__core_retire_pc=0x100;
    root.ventium_top__DOT__core_retire_valid=true;
    root.ventium_top__DOT__u_core__DOT__u_fp_shared__DOT__top_state=1;
    aligned.sample(root,0);
    assert(aligned.overlap==1 && aligned.overlap_at_commit==0);
    root.ventium_top__DOT__u_core__DOT__u_fp_shared__DOT__top_state=0;
    aligned.sample(root,0);
    assert(aligned.overlap==1 && aligned.overlap_at_commit==1);
    aligned.sample(root,0);
    assert(aligned.overlap_at_commit==1);
    std::puts("FP-OVERLAP-PROBE-OK");
}
