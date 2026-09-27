// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Include the implementation to exercise the actual DPI path without a slow
// RTL rebuild. VENTIUM_DPI_SOURCE permits byte-for-byte pre-refactor A/B.
#ifndef VENTIUM_DPI_SOURCE
#define VENTIUM_DPI_SOURCE "dpi_retire.cpp"
#endif
#include VENTIUM_DPI_SOURCE
#include <cassert>
#include <string>

int main(int argc, char** argv) {
    assert(argc == 2);
    using namespace ventium;
    for (unsigned mode = 0; mode < 6; ++mode) {
        TraceWriter writer;
        if (mode == 5) writer.open_discard();
        else assert(writer.open(std::string(argv[1]) + "/mode" +
                                std::to_string(mode) + ".vtrace", "dpi-capture",
                                mode == 1 || mode == 3, mode == 4,
                                mode == 2 || mode == 3));
        g_trace = &writer;
        for (unsigned n = 0; n < 6; ++n) {
            writer.set_clock(100 + n / 2); // paired clocks preserved
            if (n % 3 != 2) {
                vtm_retire_cycle(n, n % 2, 1);
                vtm_retire_sys(n, 0x80000011, n, 0x123000, 0);
                vtm_retire_x87(n, 0x37f, 0x3800 + n, 0xfffc,
                    n, 0x3fff, n+1, 0x4000, n+2, 0x4001, n+3, 0x4002,
                    n+4, 0x4003, n+5, 0x4004, n+6, 0x4005, n+7, 0x4006);
            }
            vtm_retire(n, 0x1000 + n, 0x202,
                       n, n+1, n+2, n+3, n+4, n+5, n+6, n+7,
                       8, 16, 24, 32, 40, 48);
            assert(writer.retired() == n + 1);
            assert(g_last_arch.n == n && g_last_arch.pc == 0x1000 + n);
            assert(g_last_arch.gpr[7] == n + 7 && g_last_arch.seg[5] == 48);
        }
        g_trace = nullptr;
        writer.close();
    }
    // Exercise the actual dispatcher, not just the queue class. Live counters
    // and observers advance while output is deferred; completion formatting
    // must not count those instructions a second time.
    TraceWriter deferred;
    assert(deferred.open(std::string(argv[1]) + "/deferred.vtrace",
                         "dpi-deferred", true, false, true));
    g_trace = &deferred;
    X87State completed;
    completed.fctrl = 0x37f; completed.fstat = 0x8088; completed.ftag = 0xfffc;
    for (unsigned i = 0; i < 8; ++i) {
        completed.st_lo[i] = 0x8000000000000000ULL + i;
        completed.st_hi[i] = 0x3fff + i;
    }
    auto rejected = [](auto f) {
        bool caught = false;
        try { f(); } catch (const std::logic_error&) { caught = true; }
        assert(caught);
    };
    long position = 0;
    for (unsigned n = 0; n < 5; ++n) {
        deferred.set_clock(100 + n / 2);
        if (n == 1) fp_trace_begin(n);
        vtm_retire_sys(n, 0x80000011, n, 0x123000, 0);
        vtm_retire_x87(n, 0x37f, 0, 0xffff,
                      0,0, 0,0, 0,0, 0,0, 0,0, 0,0, 0,0, 0,0);
        vtm_retire(n, 0x1000+n, 0x202, n,n+1,n+2,n+3,n+4,n+5,n+6,n+7,
                   8,16,24,32,40,48);
        assert(deferred.retired() == n+1 && g_last_arch.n == n);
        assert(g_last_arch.gpr[0] == n && g_last_cr0 == 0x80000011);
        if (n == 0) position = std::ftell(deferred.fp());
        if (n >= 1 && n <= 3) {
            assert(std::ftell(deferred.fp()) == position);
            rejected([] { fp_trace_finish(); });
        }
        if (n == 3) {
            rejected([] { fp_trace_begin(4); });
            rejected([&] { fp_trace_complete(2, completed); });
            g_trace = nullptr;
            rejected([] { fp_trace_finish(); });
            g_trace = &deferred;
            deferred.set_clock(9999); // flushing is not an execution clock
            fp_trace_complete(1, completed);
            assert(deferred.retired() == 4 && g_last_arch.n == 3);
            assert(std::ftell(deferred.fp()) > position);
        }
    }
    rejected([&] { fp_trace_complete(1, completed); });
    fp_trace_finish();
    g_trace = nullptr;
    deferred.close();
    TraceWriter streamed;
    assert(streamed.open(std::string(argv[1]) + "/streamed.vtrace",
                         "dpi-streamed", true, false, true));
    g_trace=&streamed;
    auto complete_stream = [&](unsigned owner, unsigned value) {
        vtm_retire_x87(owner,0x37f,value,0xfffc,
                      value,0x3fff, 0,0, 0,0, 0,0, 0,0, 0,0, 0,0, 0,0);
        vtm_fp_async_event(1,owner);
    };
    for (unsigned n=0; n<6; ++n) {
        streamed.set_clock(200+n/2);
        if (!(n%2)) vtm_fp_async_event(2,n);
        vtm_retire_sys(n,0x80000011,n,0x123000,0);
        vtm_retire(n,0x2000+n,0x202,n,n+1,n+2,n+3,n+4,n+5,n+6,n+7,
                   8,16,24,32,40,48);
        if (n==3) complete_stream(0,0x10);
        assert(streamed.retired()==n+1 && g_last_arch.n==n);
    }
    complete_stream(2,0x20);
    assert(fp_pending && fp_pending->pending());
    complete_stream(4,0x30);
    assert(!fp_pending && streamed.retired()==6 && g_last_arch.n==5);
    fp_trace_finish();
    rejected([] { vtm_fp_async_event(3,0); });
    g_trace=nullptr;
    streamed.close();
    std::puts("DPI-RECORD-CAPTURE-OK");
}
