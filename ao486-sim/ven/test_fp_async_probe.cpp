// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "fp_async_probe.h"
#include <cassert>
#include <cstring>

struct Sample {
#define FIELD(name) unsigned system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__##name
    FIELD(fp_async_pending)=1;
    FIELD(fp_async_hold)=0;
    FIELD(fp_async_fault_hold)=0;
    FIELD(fp_async_start)=0;
    FIELD(pipe_int_commit)=1;
    FIELD(pipe_pair)=1;
#undef FIELD
};
int main() {
    FILE *f=std::tmpfile(); assert(f);
    const Sample r;
    assert(ven_fp_async_probe(f,r,123,0));
    std::rewind(f);
    char line[256]; assert(std::fgets(line,sizeof(line),f));
    assert(!std::strcmp(line,"[VEN-FPASYNC] cyc=123 pending=1 hold=0 fault_hold=0 start=0 int_commit=1 pair=1\n"));
    assert(!std::fgets(line,sizeof(line),f));
    std::fclose(f);
    // A non-async/optimized-away model emits nothing, with no fake zero witness.
    struct Absent {};
    f=std::tmpfile(); assert(f);
    assert(!ven_fp_async_probe(f,Absent{},456,0));
    assert(std::ftell(f)==0);
    std::fclose(f);
    std::puts("FP-ASYNC-PROBE-OK");
}
