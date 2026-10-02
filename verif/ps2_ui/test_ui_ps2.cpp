// Narrow production ps2.v/simple_fifo.v microTB source, no complete PC/guest.
// SOURCE ONLY; expected bug witnesses are labelled, not correctness passes.
#include "Vui_ps2_probe.h"
#include "verilated.h"
#include "ui_input_host.h"
#include <functional>
#include <iostream>
#include <memory>
#include <utility>

#define CHECK(expr) do { if (!(expr)) throw std::runtime_error(#expr); } while (0)
class Harness {
public:
    Vui_ps2_probe d;
    uint64_t cycle=0;
    std::unique_ptr<ven_ui::Input> input;
    ven_ui::Lines external;
    bool input_wire_enabled=true; // Negative evidence may continue ordinary wires after refusal.
    std::vector<uint8_t> raw_receipts, guest_reads;
    std::function<void(Harness&)> preedge_stimulus;
    ven_ui::ReceiveProof last;
    Harness(bool translate=true) {
        d.clk=0; d.rst_n=0; d.io_address=0; d.io_read=0; d.io_write=0;
        d.io_cs=0; d.ctl_cs=0; d.io_writedata=0; d.inspect_index=0;
        d.ps2_kbclk=1; d.ps2_kbdat=1; d.ps2_mouseclk=1; d.ps2_mousedat=1;
        for (unsigned n=0;n<32;++n) step();
        d.rst_n=1;
        for (unsigned n=0;n<32;++n) step();
        write(4,0x60); write(0,translate?0x41:0x01);
        for (unsigned n=0;n<32;++n) step();
        CHECK(bool(d.translated)==translate);
        CHECK(!d.fifo_full && d.fifo_empty);
    }
    void step() {
        auto lines=external;
        if (input) {
            input->prefix_context_before(cycle,d.translated,d.escape_state,
                                         !d.rst_n || d.self_test,d.timeout_event);
            if (input_wire_enabled)
                lines=input->drive(cycle,!d.rst_n,d.ps2_kbclk_out,d.ps2_kbdat_out,
                                   d.controller_state==0);
        }
        d.ps2_kbclk=lines.clock && d.ps2_kbclk_out;
        d.ps2_kbdat=lines.data && d.ps2_kbdat_out;
        d.inspect_index=d.write_index;
        d.clk=0; d.eval();
        if (preedge_stimulus) { preedge_stimulus(*this); d.eval(); }
        ven_ui::ReceiveProof p;
        p.final=d.recv_final; p.reset=!d.rst_n; p.clear=d.self_test;
        p.translated=d.translated; p.escape_before=d.escape_state;
        p.autoack=d.autoack; p.reply=d.reply_done;
        p.write_request=d.write_request; p.full=d.fifo_full;
        p.read_request=d.fifo_read_request; p.raw=d.recv_raw;
        p.translated_value=d.translated_value; p.produced_value=d.produced_value;
        p.old_write_index=d.write_index;
        const bool consumed=d.fifo_read_request && !d.fifo_empty;
        const uint8_t consumed_value=d.fifo_q;
        d.clk=1; d.eval();
        p.new_write_index=d.write_index; p.post_memory_at_old_write_index=d.inspect_memory;
        p.escape_after=d.escape_state;
        if (p.final && !p.reset) raw_receipts.push_back(p.raw);
        if (consumed && !p.reset && !p.clear) guest_reads.push_back(consumed_value);
        if (input) {
            input->controller_reset_edge(cycle,p.reset || p.clear);
            input->accepted_edge(cycle,p);
            input->guest_read_edge(cycle,consumed,consumed_value);
        }
        last=p; ++cycle;
    }
    void write(unsigned address,uint8_t value) {
        d.io_cs=1; d.io_address=address; d.io_writedata=value; d.io_read=0; d.io_write=1;
        step(); d.io_write=0; step();
    }
    uint8_t read(unsigned address) {
        d.io_cs=1; d.io_address=address; d.io_write=0; d.io_read=1;
        step(); const uint8_t v=d.io_readdata;
        d.io_read=0; step(); return v;
    }
    void start(const std::string &commands,uint64_t half=32) {
        CHECK(!input);
        input=std::make_unique<ven_ui::Input>(ven_ui::Timing::ordinary(45000000,half),nullptr);
        input->feed(commands.data(),commands.size(),cycle);
    }
    void finish_input(const std::vector<uint8_t> &expected,uint64_t budget=4000000) {
        for (uint64_t n=0;n<budget;++n) {
            step();
            if (input->failed()) throw std::runtime_error("unexpected input/controller error");
            if ((cycle&7)==0 && d.output_full) (void)read(0);
            if (!input->pending() && !input->inflight() && !d.output_full && d.fifo_empty) {
                for (unsigned k=0;k<64;++k) step();
                CHECK(input->finish(cycle)); CHECK(guest_reads==expected); return;
            }
        }
        throw std::runtime_error("microTB cycle budget exhausted");
    }
    void wait_start() {
        CHECK(input);
        for (unsigned n=0;n<200000;++n) {
            step(); if (input->inflight()) return;
        }
        throw std::runtime_error("pending byte never started");
    }
    void manual_byte(uint8_t raw,uint64_t half,bool bad_parity=false) {
        std::array<bool,11> bits{}; bits[0]=false; bool parity=true;
        for (unsigned k=0;k<8;++k) { bits[k+1]=(raw>>k)&1; parity^=bits[k+1]; }
        bits[9]=bad_parity?!parity:parity; bits[10]=true;
        for (unsigned bit=0;bit<11;++bit) {
            external.data=bits[bit]; external.clock=true;
            for (uint64_t n=0;n<half;++n) step();
            external.clock=false;
            for (uint64_t n=0;n<half;++n) step();
        }
        external={}; for (unsigned n=0;n<128;++n) step();
    }
};

static void ordinary_stream_tests() {
    for (uint64_t half : {uint64_t(32),uint64_t(64),uint64_t(1875),uint64_t(2917)}) {
        Harness h; h.start("1 key ctrl+esc\n2 key alt+f4\n3 key up\n",half);
        h.finish_input({0x1d,0x01,0x81,0x9d,0x38,0x3e,0xbe,0xb8,0xe0,0x48,0xe0,0xc8});
        std::cout<<"PS2-ORDINARY-STREAM half="<<half<<" OK\n";
    }
    Harness text;
    text.start("1 key w\n2 key i\n3 key n\n4 key v\n5 key e\n6 key r\n7 key enter\n");
    text.finish_input({0x11,0x91,0x17,0x97,0x31,0xb1,0x2f,0xaf,0x12,0x92,0x13,0x93,0x1c,0x9c});
    Harness raw(false); raw.start("1 key enter\n"); raw.finish_input({0x5a,0xf0,0x5a});
}
static void timing_characterization() {
    // 16 and legacy24 are characterization-only, not supported driver timings.
    // The >=32 margin becomes qualified ONLY when required tests actually pass.
    for (uint64_t half : {uint64_t(16),uint64_t(24),uint64_t(32),uint64_t(64),uint64_t(1875)}) {
        Harness h; h.manual_byte(0x5a,half);
        const bool accepted=h.raw_receipts==std::vector<uint8_t>({0x5a}) && h.d.output_full;
        uint8_t got=0; if (h.d.output_full) got=h.read(0);
        std::cout<<"PS2-FILTER-CHAR half="<<half<<" raw_received="<<accepted
                 <<" guest="<<unsigned(got)<<"\n";
        if (half>=32) CHECK(accepted && got==0x1c);
    }
}
static void autoack_exactly_once() {
    Harness h; h.write(0,0xf4);
    for (unsigned n=0;n<32;++n) h.step();
    CHECK(h.d.output_full && h.read(0)==0xfa);
    for (unsigned n=0;n<128;++n) h.step();
    CHECK(h.d.fifo_empty && !h.d.output_full && !h.d.input_full);
    CHECK(h.guest_reads==std::vector<uint8_t>({0xfa}));
}
static void idle_inhibition() {
    Harness h; h.write(4,0xad); h.start("1 key tab\n");
    for (unsigned n=0;n<20000;++n) h.step();
    CHECK(!h.input->failed() && h.input->pending()==1 && !h.input->inflight());
    h.write(4,0xae); h.finish_input({0x0f,0x8f});
}
static void initial_host_write_race() {
    Harness h; h.start("1 key enter\n"); bool injected=false;
    h.preedge_stimulus=[&](Harness &x) {
        if (!injected && x.input->inflight() && x.d.controller_state==0) {
            x.d.io_cs=1; x.d.io_address=0; x.d.io_writedata=0xf4; x.d.io_write=1;
            injected=true;
        } else x.d.io_write=0;
    };
    for (unsigned n=0;n<20000 && !h.input->failed();++n) h.step();
    CHECK(injected && h.input->failed());
    CHECK(h.input->pending()==1 && h.input->accepted_front()==0 && h.input->inflight());
    std::cout<<"PS2-HOST-WRITE-START-RACE protected_fail_closed=1\n";
}
static void exact_autoack_rx_collision(bool translated,uint8_t collide_raw,size_t index) {
    Harness h(translated); h.start("1 key enter\n",64); bool injected=false, witnessed=false;
    h.preedge_stimulus=[&](Harness &x) {
        // Ordinary port60 write on first high synchronization edge after stop.
        // On the following edge wtk_q and recv_final coincide. No pokes/force.
        if (!injected && x.d.controller_state==12 && !x.d.synced_clock &&
            x.d.synced_data && x.d.ps2_kbclk && x.d.ps2_kbdat &&
            x.input->accepted_front()==index && x.d.recv_raw==collide_raw) {
            x.d.io_cs=1; x.d.io_address=0; x.d.io_writedata=0xf4; x.d.io_write=1;
            injected=true;
        } else x.d.io_write=0;
    };
    for (unsigned n=0;n<100000;++n) {
        h.step();
        if (h.last.final && h.last.autoack) {
            CHECK(h.last.raw==collide_raw && h.last.produced_value==0xfa);
            CHECK(h.last.post_memory_at_old_write_index==0xfa);
            witnessed=true;
        }
        if (h.input->failed()) break;
        if (injected && !h.input->pending()) break;
    }
    CHECK(injected && witnessed);
    if (translated && collide_raw==0xf0) {
        CHECK(!h.input->failed()); // F0 parser prefix survives; no scan byte required.
        CHECK(h.raw_receipts==std::vector<uint8_t>({0x5a,0xf0,0x5a}));
        CHECK(h.d.escape_state==0);
        // Actual FIFO order is make, ACK, break. Reading these is separate proof.
        for (unsigned n=0;n<128;++n) h.step();
        CHECK(h.read(0)==0x1c); CHECK(h.read(0)==0xfa); CHECK(h.read(0)==0x9c);
    } else {
        CHECK(h.input->failed() && h.input->pending()==1 && h.input->inflight());
        CHECK(h.input->accepted_front()==index && h.input->owned_byte()==collide_raw);
        const uint8_t lost=translated ? (index?0x9c:0x1c) : collide_raw;
        std::cout<<"PS2-CONTROLLER-BUG-WITNESS autoack_overwrites_scan=1 raw="
                 <<unsigned(collide_raw)<<" translated="<<translated<<" index="<<index
                 <<" lost="<<unsigned(lost)<<" driver_refused_accept=1\n";
    }
}
static void full_fifo_scan_drop() {
    Harness h; h.start("1 key enter\n",1875); h.wait_start();
    for (unsigned n=0;n<10000 && h.d.controller_state!=10;++n) h.step();
    CHECK(h.d.controller_state==10 && !h.input->failed());
    // Fill solely through ordinary port60 writes + production AUTOACK while
    // the receiver is busy; host inhibit can only begin after it returns IDLE.
    for (unsigned n=0;n<64;++n) {
        h.write(0,0xf4);
        for (unsigned k=0;k<8;++k) h.step();
        CHECK(!h.d.input_full);
    }
    CHECK(h.d.fifo_full);
    bool witnessed=false;
    for (unsigned n=0;n<100000 && !h.input->failed();++n) {
        h.step();
        if (h.last.final) {
            CHECK(h.last.full && !h.last.read_request && !h.last.autoack);
            CHECK(h.last.new_write_index==h.last.old_write_index); witnessed=true;
        }
    }
    CHECK(witnessed && h.input->failed() && h.input->accepted_front()==0);
    CHECK(h.input->pending()==1 && h.input->inflight());
    std::cout<<"PS2-CONTROLLER-BUG-WITNESS full_fifo_scan_drop=1 driver_refused_accept=1\n";
}
static void full_fifo_autoack_drop() {
    Harness h;
    for (unsigned n=0;n<64;++n) { h.write(0,0xf4); for (unsigned k=0;k<8;++k) h.step(); }
    CHECK(h.d.fifo_full);
    const uint8_t old=h.d.write_index;
    h.write(0,0xf4); for (unsigned n=0;n<16;++n) h.step();
    CHECK(h.d.write_index==old && h.d.fifo_full && !h.d.input_full);
    std::cout<<"PS2-CONTROLLER-BUG-WITNESS autoack_full_drop_and_ibf_cleared=1\n";
}
static void reset_and_selftest_interrupt() {
    for (bool selftest : {false,true}) {
        Harness h; h.start("1 key ctrl+esc\n",64); h.wait_start();
        for (unsigned n=0;n<256;++n) h.step();
        if (selftest) h.write(4,0xaa);
        else { h.d.rst_n=0; h.step(); }
        CHECK(h.input->failed() && h.input->pending()==1 && h.input->inflight());
        CHECK(h.input->accepted_front()==0);
    }
}
static void bad_parity_rejected() {
    Harness h; h.manual_byte(0x5a,64,true);
    CHECK(h.raw_receipts.empty() && h.d.fifo_empty && !h.d.output_full);
    CHECK(h.read(4)&0x80);
}
static void prefix_timeout_suffix_refusal() {
    Harness h; h.start("1 key enter\n",64);
    for (unsigned n=0;n<100000 && h.input->accepted_front()!=2;++n) h.step();
    CHECK(h.input->accepted_front()==2 && h.input->prefix_owned() && !h.input->inflight());
    CHECK(h.d.escape_state && h.read(0)==0x1c);
    // Ordinary host LED/keyboard command starts an inhibited host send while
    // the sender waits BETWEEN bytes. No injected mid-frame interruption.
    h.write(0,0xed);
    for (unsigned n=0;n<32;++n) h.step();
    CHECK(h.read(0)==0xfa);
    for (unsigned n=0;n<1200000 && !h.input->failed();++n) h.step();
    CHECK(h.input->failed() && h.input->prefix_owned() && !h.input->inflight());
    CHECK(h.input->accepted_front()==2 && h.input->pending()==1 && !h.d.escape_state);
    // The diagnostic native would stop on refusal. Only this negative microTB
    // continues ordinary physical clocks/pins to prove the DUT's wrong MAKE.
    h.input_wire_enabled=false; h.external={};
    for (unsigned n=0;n<128;++n) h.step();
    h.manual_byte(0x5a,64);
    CHECK(h.d.output_full && h.read(0)==0x1c); // Required suffix was break 9c.
    CHECK(h.input->accepted_front()==2 && h.input->prefix_owned() && h.input->pending()==1);
    std::cout<<"PS2-CONTROLLER-BUG-WITNESS prefix_timeout_suffix_make=1 driver_refused_accept=1\n";
    Harness control; control.start("1 key enter\n",64);
    for (unsigned n=0;n<100000 && !control.input->prefix_owned();++n) control.step();
    CHECK(control.input->prefix_owned() && control.d.escape_state);
    control.finish_input({0x1c,0x9c}); CHECK(!control.input->prefix_owned());
    std::cout<<"PS2-PREFIX-SUFFIX-CONTROL preserved_prefix_then_break=1\n";
}
int main(int argc,char **argv) {
    Verilated::commandArgs(argc,argv);
    try {
        ordinary_stream_tests(); timing_characterization(); autoack_exactly_once();
        idle_inhibition(); initial_host_write_race();
        exact_autoack_rx_collision(true,0x5a,0);
        exact_autoack_rx_collision(false,0x5a,0);
        exact_autoack_rx_collision(true,0x5a,2); // Break suffix loss, after accepted F0.
        exact_autoack_rx_collision(true,0xf0,1); // Prefix-only concurrent ACK control.
        full_fifo_scan_drop(); full_fifo_autoack_drop();
        reset_and_selftest_interrupt(); bad_parity_rejected();
        prefix_timeout_suffix_refusal();
    } catch (const std::exception &e) {
        std::cerr<<"UI-PS2-MICRO-FAIL: "<<e.what()<<"\n"; return 1;
    }
    std::cout<<"UI-PS2-MICRO-OK controller_bug_witnesses_expected=1 rtl_unchanged=1\n";
    return 0;
}
