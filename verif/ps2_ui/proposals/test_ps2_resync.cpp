// SOURCE ONLY. Narrow reset/AA receive resynchronization corner, ordinary pins
// and I/O only. The independent device never observes AA, reset or DUT RXstate.
#include "Vps2_resync_probe.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <deque>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#ifndef RESYNC_OLD_CONTROL
#define RESYNC_OLD_CONTROL 0
#endif
#define CHECK(x) do { if(!(x)) throw std::runtime_error(std::string(__func__)+": "+#x); } while(0)
struct Received {
    bool mouse;
    uint8_t value;
    bool operator==(const Received &r) const { return mouse==r.mouse && value==r.value; }
};
struct Point {
    const char *name;
    unsigned bit;
    bool low;
    bool complete_boundary;
};
// bit0=start; bits1..8=data; bit9=parity; bit10=stop.
// Stop-low is AFTER the physical eleventh falling edge: no mandatory retry.
static const std::array<Point,9> points={{{"start_low",0,true,false},
    {"data0_high",1,false,false},{"data3_low",4,true,false},
    {"data7_high",8,false,false},{"parity_high",9,false,false},
    {"parity_low",9,true,false},{"stop_high_pre11",10,false,false},
    {"stop_low_post11",10,true,true},{"completed_idle",11,false,true}}};

class Device {
public:
    std::deque<uint8_t> queue;
    bool active=false,clock=true,data=true,low=false,physical_complete=false;
    unsigned bit=0;
    uint64_t elapsed=0,idle_high=0,host_low=0,longest_host_low=0;
    uint64_t started=0,completed=0,aborted=0,inhibit_observed=0,continued_after_flush=0;
    const uint64_t half,idle_min,abort_min;
    bool flush_has_happened=false;
    std::array<bool,11> bits{};
    Device(uint64_t hz,uint64_t h):half(h),idle_min((hz+19999)/20000),
        abort_min((hz+9999)/10000) {}
    void offer(uint8_t b) { queue.push_back(b); }
    void start() {
        CHECK(!queue.empty());
        bits[0]=false; bool p=true;
        for(unsigned n=0;n<8;++n) { bits[n+1]=(queue.front()>>n)&1; p^=bits[n+1]; }
        bits[9]=p; bits[10]=true;
        active=true; physical_complete=false; bit=0; low=false; elapsed=0;
        idle_high=0; ++started;
    }
    void before(bool host_clock_release,bool physical_clock,bool physical_data) {
        // Host inhibition is detected ONLY from actual host output release,
        // never from controller command/reset/state or our own low clock phase.
        if(!host_clock_release) {
            if(!host_low) ++inhibit_observed;
            ++host_low; if(host_low>longest_host_low) longest_host_low=host_low;
            idle_high=0;
            // Explicit device-model contract: after continuous100us host
            // inhibition, abandon an unfinished byte and retry it later.
            // The Microchip timing source does not prove this retry threshold.
            if(active && host_low>=abort_min) {
                if(!physical_complete) ++aborted;
                active=false; clock=data=true; elapsed=0; low=false;
            }
            return; // A low host clock prevents further ordinary wire cells.
        }
        host_low=0;
        if(!active) {
            clock=data=true;
            if(physical_clock && physical_data) ++idle_high; else idle_high=0;
            if(!queue.empty() && idle_high>=idle_min) start();
        }
        if(active) {
            clock=!low; data=bits[bit];
            if(bit==10 && low && !physical_complete) {
                // Count completion on the actual device-driven stop falling
                // edge, not a scheduled phase advance or an internal RXstate.
                physical_complete=true; ++completed; queue.pop_front();
            }
        }
    }
    void after(bool host_clock_release) {
        if(!host_clock_release || !active) return;
        if(flush_has_happened) ++continued_after_flush;
        ++elapsed;
        if(!low && elapsed==half) {
            low=true; elapsed=0;
        } else if(low && elapsed==half) {
            elapsed=0; low=false;
            if(bit==10) { active=false; clock=data=true; idle_high=0; }
            else ++bit;
        }
    }
    bool done() const { return queue.empty() && !active; }
};

class Harness {
public:
    Vps2_resync_probe d;
    uint64_t cycle=0;
    Device dev;
    bool mouse;
    std::vector<Received> reads;
    std::vector<uint8_t> key_raw,mouse_raw;
    bool triggered=false,reset_case=false;
    unsigned reset_left=0;
    const Point *target=nullptr;
    uint64_t trigger_cycle=0;
    unsigned trigger_state=0;
    bool output_was_pending=false;
    Harness(bool m,uint64_t hz,uint64_t half):dev(hz,half),mouse(m) {
        d.clk=0; d.rst_n=0; d.io_address=0; d.io_read=d.io_write=0;
        d.io_cs=d.ctl_cs=0; d.io_writedata=0; d.inspect_index=0;
        d.ps2_kbclk=d.ps2_kbdat=d.ps2_mouseclk=d.ps2_mousedat=1;
        for(unsigned n=0;n<32;++n) step();
        d.rst_n=1;
        // Constructor settles the initial reset/inhibit without a queued byte.
        for(unsigned n=0;n<16000;++n) step();
        write(4,0x60); write(0,0x43);
        for(unsigned n=0;n<128;++n) step();
        CHECK(d.translated && d.fifo_empty && d.mouse_fifo_empty);
        dev.longest_host_low=dev.host_low=dev.inhibit_observed=0;
    }
    bool clock_out() const { return mouse?d.ps2_mouseclk_out:d.ps2_kbclk_out; }
    bool data_out() const { return mouse?d.ps2_mousedat_out:d.ps2_kbdat_out; }
    bool point_matches() const {
        if(!target || triggered) return false;
        if(target->bit==11)
            return dev.completed==1 && !dev.active && dev.idle_high==dev.idle_min/2;
        return dev.active && dev.bit==target->bit && dev.low==target->low &&
               dev.elapsed==dev.half/2;
    }
    void step() {
        if(cycle>=1000000) throw std::runtime_error("bounded resync case exceeded1M clocks");
        // The device observes ordinary actual output pins and physical bus,
        // not reset, AA, internal RXstate, a synthetic capture or an oracle.
        bool hc=clock_out(),hd=data_out();
        bool pc=(dev.clock && hc),pd=(dev.data && hd);
        dev.before(hc,pc,pd);
        d.ps2_kbclk=mouse?d.ps2_kbclk_out:(dev.clock && d.ps2_kbclk_out);
        d.ps2_kbdat=mouse?d.ps2_kbdat_out:(dev.data && d.ps2_kbdat_out);
        d.ps2_mouseclk=mouse?(dev.clock && d.ps2_mouseclk_out):d.ps2_mouseclk_out;
        d.ps2_mousedat=mouse?(dev.data && d.ps2_mousedat_out):d.ps2_mousedat_out;
        d.clk=0; d.eval();
        if(point_matches()) {
            triggered=true; trigger_cycle=cycle;
            trigger_state=mouse?d.mouse_state:d.controller_state;
            output_was_pending=d.output_full;
            dev.flush_has_happened=true;
            if(reset_case) { d.rst_n=0; reset_left=4; }
            else { d.io_cs=1; d.io_address=4; d.io_write=1; d.io_writedata=0xaa; }
            d.eval();
        }
        const bool flush=!d.rst_n || d.self_test;
        const bool kr=d.fifo_read_request && !d.fifo_empty && !flush;
        const bool mr=d.mouse_rdreq && !d.mouse_fifo_empty && !flush;
        const uint8_t kv=d.fifo_q,mv=d.mouse_fifo_q;
        if(d.recv_final && !flush) key_raw.push_back(d.recv_raw);
        if(d.mouse_recv_final && !flush) mouse_raw.push_back(d.mouse_recv_raw);
        d.clk=1; d.eval();
        if(kr) { CHECK(d.io_readdata==kv); reads.push_back({false,kv}); }
        if(mr) { CHECK(d.io_readdata==mv); reads.push_back({true,mv}); }
        // Match the PRE-edge output that determined this physical cell.
        // A newly asserted flush inhibit becomes observable next normal tick.
        dev.after(hc);
        if(d.io_write && triggered && cycle==trigger_cycle) d.io_write=0;
        if(reset_left && --reset_left==0) d.rst_n=1;
        ++cycle;
    }
    void write(unsigned address,uint8_t value) {
        d.io_cs=1; d.io_address=address; d.io_read=0; d.io_write=1; d.io_writedata=value;
        step(); d.io_write=0; step(); step();
    }
    uint8_t read(unsigned address) {
        d.io_cs=1; d.io_address=address; d.io_write=0; d.io_read=1;
        step(); uint8_t value=d.io_readdata; d.io_read=0; step(); return value;
    }
    void run(const Point &p,bool reset) {
        target=&p; reset_case=reset;
        // Generic byte values, no named key, game-specific route or snapshot.
        dev.offer(mouse?0xa5:0x5a); dev.offer(mouse?0x39:0x76);
        for(unsigned n=0;n<400000;++n) {
            step();
            if(triggered && d.rst_n && d.output_full && !reset_left && cycle>trigger_cycle+8)
                (void)read(0);
            if(triggered && dev.done() && !d.output_full && d.fifo_empty &&
               d.mouse_fifo_empty && cycle>trigger_cycle+10000) {
                // Wait one full documented idle interval plus filter margin.
                for(uint64_t k=0;k<dev.idle_min+128;++k) step();
                if(!d.output_full) break;
            }
        }
        CHECK(triggered && dev.done());
    }
};
static unsigned red=0,positive=0;
static void run_case(bool mouse,bool reset,uint64_t hz,uint64_t half,const Point &p) {
    Harness h(mouse,hz,half); h.run(p,reset);
    std::vector<Received> expected;
    if(!reset) expected.push_back({false,0x55});
    if(!p.complete_boundary) expected.push_back({mouse,uint8_t(mouse?0xa5:0x1c)});
    expected.push_back({mouse,uint8_t(mouse?0x39:0x01)});
    const uint8_t status=h.read(4);
    const bool clean=h.reads==expected && !(status&0xc0);
    if(RESYNC_OLD_CONTROL) {
        CHECK(h.dev.aborted==0 && h.dev.longest_host_low==0);
        CHECK(h.dev.continued_after_flush>0 || p.complete_boundary);
        if(!clean && !p.complete_boundary) ++red;
        if(p.complete_boundary) CHECK(clean);
        // Post11 cases are NOT labelled defects merely because flush removes
        // the completed original byte; ordinary next sentinel remains authority.
        std::cout<<"PS2-RESYNC-OLD-OBSERVED";
    } else {
        CHECK(h.dev.longest_host_low>=8191 && h.dev.longest_host_low<=8200);
        CHECK(h.dev.aborted==(p.complete_boundary?0:1));
        CHECK(h.dev.completed==2);
        CHECK(clean); ++positive;
        std::cout<<"PS2-RESYNC-PROPOSED-OK";
    }
    std::cout<<" port="<<(mouse?"mouse":"keyboard")<<" flush="<<(reset?"reset":"AA")
             <<" hz="<<hz<<" point="<<p.name<<" trigger_rxstate="<<h.trigger_state
             <<" preflush_obf="<<h.output_was_pending<<" abort_policy_us=100"
             <<" host_low_cycles="<<h.dev.longest_host_low<<" actual_abort="<<h.dev.aborted
             <<" continued_cycles="<<h.dev.continued_after_flush<<" clean="<<clean
             <<" read_count="<<h.reads.size()<<" status="<<unsigned(status)<<" values=";
    for(auto r:h.reads) std::cout<<(r.mouse?'M':'K')<<unsigned(r.value)<<",";
    std::cout<<"\n";
}
int main(int argc,char **argv) {
    Verilated::commandArgs(argc,argv);
    try {
        for(bool m:{false,true}) for(bool reset:{false,true})
            for(auto timing:std::array<std::array<uint64_t,2>,2>{{{45000000,1875},{70000000,2917}}})
                for(const Point &p:points) run_case(m,reset,timing[0],timing[1],p);
        if(RESYNC_OLD_CONTROL) {
            CHECK(red>0);
            std::cout<<"PS2-RESYNC-OLD-RED-WITNESS-OK observed_mismatches="<<red
                     <<" NOT_CONTROLLER_CORRECTNESS\n";
        } else std::cout<<"PS2-RESYNC-CONDITIONAL-MICRO-OK cases="<<positive
             <<" assumption=100us_inhibit_abort_retry NO_GUEST_OR_FPGA_PROOF\n";
        return 0;
    } catch(const std::exception &e) {
        std::cerr<<"PS2-RESYNC-MICRO-FAIL "<<e.what()<<"\n"; return 1;
    }
}
