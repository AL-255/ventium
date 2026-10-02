// Source-only isolated controller microTB. No complete PC, guest, FIFO seeding,
// force, deposit, hierarchical write, checkpoint or save-state machinery.
#include "Vps2_loss_probe.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#ifndef PS2_TEST_AUTOACK
#error "Explicit PS2_TEST_AUTOACK=0 or =1 required"
#endif
#ifndef PS2_TEST_LEGACY
#define PS2_TEST_LEGACY 0
#endif
#define CHECK(x) do { if(!(x)) throw std::runtime_error(std::string(__func__)+": "+#x); } while(0)
struct Edge {
    uint64_t cycle=0;
    bool final=false,full=false,read=false,write=false,ack=false,ack_commit=false;
    bool scan_commit=false,reply=false,rx_pending=false,flush=false,escape=false;
    uint8_t raw=0,data=0,old_index=0,new_index=0,memory=0;
};
class Harness {
public:
    Vps2_loss_probe d;
    uint64_t cycle=0;
    uint64_t release_at=0;
    bool kc=true,kd=true,mc=true,md=true;
    uint64_t timeout_count=0,key_write_count=0,mouse_write_count=0;
    uint64_t scan_count=0,ack_count=0,reply_count=0;
    bool saw_send=false,saw_mouse_send=false;
    std::vector<uint8_t> commits,keyboard_reads,mouse_reads,raw_receipts;
    std::vector<Edge> collisions;
    Edge last;
    std::function<void(Harness&)> preedge;
    Harness(bool translation=true) {
        d.clk=0; d.rst_n=0; d.io_address=0; d.io_read=0; d.io_write=0;
        d.io_cs=0; d.ctl_cs=0; d.io_writedata=0; d.inspect_index=0;
        d.ps2_kbclk=1; d.ps2_kbdat=1; d.ps2_mouseclk=1; d.ps2_mousedat=1;
        idle(32); d.rst_n=1; idle(64);
        write(4,0x60); write(0,translation?0x43:0x03); idle(32);
        CHECK(bool(d.translated)==translation);
        CHECK(d.fifo_empty && !d.fifo_full);
    }
    void step() {
        if(cycle>=5000000) throw std::runtime_error("per-case clock budget exhausted");
        d.ps2_kbclk=kc && d.ps2_kbclk_out;
        d.ps2_kbdat=kd && d.ps2_kbdat_out;
        d.ps2_mouseclk=mc && d.ps2_mouseclk_out;
        d.ps2_mousedat=md && d.ps2_mousedat_out;
        d.clk=0; d.eval();
        if(preedge) { preedge(*this); d.eval(); }
        d.inspect_index=d.write_index; d.eval();
        Edge p;
        p.cycle=cycle; p.final=d.recv_final; p.raw=d.recv_raw;
        p.full=d.fifo_full; p.read=d.fifo_read_request;
        p.write=d.write_request; p.data=d.produced_value;
        p.ack=d.ack_offer; p.ack_commit=d.ack_commit;
        p.scan_commit=d.scan_commit; p.reply=d.reply_done;
        p.rx_pending=d.rx_pending; p.escape=d.escape_state;
        p.flush=!d.rst_n || d.self_test; p.old_index=d.write_index;
        const bool accepted=p.write && (!p.full || p.read) && !p.flush;
        const bool consumed=p.read && !d.fifo_empty && !p.flush;
        const bool consumed_mouse=d.io_cs && d.io_read && d.mouse_full &&
                                  d.io_address==0 && !p.flush;
        const uint8_t consumed_value=d.fifo_q;
        if(d.timeout_event && !p.flush) ++timeout_count;
        if(d.write_keyb && !p.flush) ++key_write_count;
        if(d.write_mouse && !p.flush) ++mouse_write_count;
        if(d.controller_state>=1 && d.controller_state<=8) saw_send=true;
        if(d.mouse_state>=1 && d.mouse_state<=8) saw_mouse_send=true;
        if(!PS2_TEST_LEGACY && p.rx_pending && p.final && !p.scan_commit &&
           (!d.translated || p.raw!=0xf0))
            throw std::runtime_error("RX skid overrun: compliant next frame was not inhibited");
        d.clk=1; d.eval();
        p.new_index=d.write_index; p.memory=d.inspect_memory;
        if(!p.flush) {
            CHECK(p.new_index==uint8_t((p.old_index+(accepted?1:0))&63));
            if(accepted) { CHECK(p.memory==p.data); commits.push_back(p.data); }
            if(consumed) keyboard_reads.push_back(consumed_value);
            if(consumed_mouse) mouse_reads.push_back(d.io_readdata);
            if(p.final) raw_receipts.push_back(p.raw);
            if(p.scan_commit) ++scan_count;
            if(p.ack_commit) ++ack_count;
            if(p.reply) ++reply_count;
            if(p.final && p.ack) collisions.push_back(p);
            if(!PS2_TEST_LEGACY) {
                CHECK(!(p.scan_commit && p.ack_commit));
                CHECK(!(p.reply && (p.scan_commit || p.ack_commit)));
                CHECK(!p.write || accepted);
            }
        }
        last=p; ++cycle;
    }
    void idle(uint64_t n) { for(uint64_t k=0;k<n;++k) step(); }
    void write(unsigned a,uint8_t v,unsigned held=1,unsigned low=2) {
        d.io_cs=1; d.io_read=0; d.io_address=a; d.io_writedata=v; d.io_write=1;
        idle(held); d.io_write=0; idle(low);
    }
    uint8_t read(unsigned a=0) {
        d.io_cs=1; d.io_write=0; d.io_address=a; d.io_read=1;
        step(); uint8_t v=d.io_readdata; d.io_read=0; step(); return v;
    }
    void reply(uint8_t v,unsigned held=1) {
        write(4,0xd2); write(0,v,held); idle(8);
    }
    void fill(bool via_ack) {
        for(unsigned n=0;n<64;++n) {
            if(via_ack) { write(0,0xf4); idle(8); CHECK(!d.input_full); }
            else reply(uint8_t(0x40+n));
        }
        CHECK(d.fifo_full);
    }
    void wait_ready(uint64_t cap=400000) {
        for(uint64_t n=0;n<cap;++n) {
            if(d.controller_state==0 && d.ps2_kbclk_out && d.ps2_kbdat_out) {
                idle(64); if(d.controller_state==0 && d.ps2_kbclk_out) return;
            }
            step();
        }
        throw std::runtime_error("wire device inhibited beyond bounded readiness window");
    }
    void cell(bool bit,uint64_t half,bool mouse=false) {
        if(mouse) { md=bit; mc=true; idle(half); mc=false; idle(half); }
        else { kd=bit; kc=true; idle(half); kc=false; idle(half); }
    }
    void begin_frame(uint64_t half) {
        wait_ready(); cell(false,half);
        CHECK(d.controller_state==10);
    }
    void end_frame(uint8_t raw,uint64_t half,bool bad=false) {
        bool parity=true;
        for(unsigned n=0;n<8;++n) { bool bit=(raw>>n)&1; parity^=bit; cell(bit,half); }
        cell(bad?!parity:parity,half);
        release_at=cycle+2*half;
        cell(true,half);
        kd=true; kc=true; idle(128);
    }
    void byte(uint8_t raw,uint64_t half=64,bool bad=false) {
        begin_frame(half); end_frame(raw,half,bad);
    }
    std::vector<uint8_t> drain(uint64_t cap=400000) {
        std::vector<uint8_t> out;
        for(uint64_t n=0;n<cap;++n) {
            if(d.output_full) out.push_back(read());
            else step();
            if(d.fifo_empty && !d.rx_pending && !d.ack_offer && !d.reply_valid &&
               !d.output_full && !d.mouse_full) {
                idle(32); if(d.fifo_empty && !d.output_full) return out;
            }
        }
        throw std::runtime_error("drain exceeded cycle cap");
    }
    void reset() {
        kc=kd=mc=md=true; d.io_write=d.io_read=0; d.rst_n=0;
        idle(32); d.rst_n=1; idle(64);
    }
    void physical_command(bool mouse,uint8_t expected,uint64_t half=64) {
        // Ordinary PS/2 device clocking of host request-to-send, actual data
        // sampled on pins, odd parity, physical ACK bit, then a wire FA reply.
        auto state=[&](){return mouse?d.mouse_state:d.controller_state;};
        auto data=[&](){return bool(mouse?d.ps2_mousedat_out:d.ps2_kbdat_out);};
        auto clock=[&](){return bool(mouse?d.ps2_mouseclk_out:d.ps2_kbclk_out);};
        for(uint64_t n=0;n<30000 && state()!=5;++n) step();
        CHECK(state()==5 && clock() && !data());
        if(mouse) { md=true; mc=true; } else { kd=true; kc=true; }
        idle(half);
        std::array<bool,11> bits{};
        bits[0]=data();
        // Falling edges 0..9 ask host to produce eight data, parity, stop.
        for(unsigned n=0;n<10;++n) {
            if(mouse) mc=false; else kc=false;
            idle(half); bits[n+1]=data();
            if(mouse) mc=true; else kc=true;
            idle(half);
        }
        CHECK(!bits[0] && bits[10]);
        uint8_t actual=0; bool parity=false;
        for(unsigned n=0;n<8;++n) { actual|=uint8_t(bits[n+1])<<n; parity^=bits[n+1]; }
        CHECK(actual==expected && (parity^bits[9]));
        CHECK(state()==6);
        // Device acknowledgement of the host's stop bit is a low data bit.
        if(mouse) { md=false; mc=false; } else { kd=false; kc=false; }
        idle(half);
        if(mouse) { md=true; mc=true; } else { kd=true; kc=true; }
        idle(128); CHECK(state()==0);
        if(mouse) {
            bool p=true;
            cell(false,half,true);
            for(unsigned n=0;n<8;++n) { bool x=(0xfa>>n)&1; p^=x; cell(x,half,true); }
            cell(p,half,true); cell(true,half,true); md=mc=true; idle(128);
        } else byte(0xfa,half);
        idle(16); CHECK(!d.input_full);
    }
};

static void streams_and_parity() {
    const std::vector<uint8_t> raw={0x14,0x76,0xf0,0x76,0xf0,0x14,
        0x11,0x0c,0xf0,0x0c,0xf0,0x11,0xe0,0x75,0xe0,0xf0,0x75};
    const std::vector<uint8_t> expected={0x1d,0x01,0x81,0x9d,0x38,0x3e,
        0xbe,0xb8,0xe0,0x48,0xe0,0xc8};
    for(uint64_t half : {uint64_t(32),uint64_t(64),uint64_t(1875),uint64_t(2917)}) {
        Harness h;
        for(uint8_t r:raw) h.byte(r,half);
        CHECK(h.drain()==expected);
        CHECK(h.raw_receipts==raw);
        std::cout<<"PS2-STREAM half="<<half<<" ordinary_pins=1 OK\n";
    }
    Harness r(false); for(uint8_t x:{0x5a,0xf0,0x5a}) r.byte(x);
    CHECK(r.drain()==std::vector<uint8_t>({0x5a,0xf0,0x5a}));
    Harness bad; bad.byte(0x5a,64,true);
    CHECK(bad.d.fifo_empty && bad.raw_receipts.empty());
    CHECK(bad.read(4)&0x80); CHECK(!(bad.read(4)&0x80));
    bad.byte(0x5a); CHECK(bad.drain()==std::vector<uint8_t>({0x1c}));
    std::cout<<"PS2-PARITY rejected_bad_frame_then_recovers=1 OK\n";
}
static void collision(bool translate,uint8_t raw,bool prefix,int offset) {
    Harness h(translate);
    if(prefix) h.byte(0xf0);
    bool injected=false; uint64_t inject_cycle=0;
    h.preedge=[&](Harness &x) {
        bool boundary=x.d.controller_state==12 && !x.d.synced_clock &&
                      x.d.synced_data && x.d.ps2_kbclk && x.d.ps2_kbdat;
        if(offset<0 && !injected && x.release_at &&
           x.cycle==x.release_at-unsigned(-offset)) {
            x.d.io_cs=1; x.d.io_address=0; x.d.io_writedata=0xf4;
            x.d.io_write=1; injected=true; inject_cycle=x.cycle;
        } else if(boundary && !injected && offset>=0) {
            if(offset>0) { inject_cycle=x.cycle+unsigned(offset); injected=true; }
            else { x.d.io_cs=1; x.d.io_address=0; x.d.io_writedata=0xf4;
                   x.d.io_write=1; injected=true; inject_cycle=x.cycle; }
        } else if(injected && offset>0 && x.cycle==inject_cycle) {
            x.d.io_cs=1; x.d.io_address=0; x.d.io_writedata=0xf4; x.d.io_write=1;
        } else x.d.io_write=0;
    };
    h.byte(raw);
    h.preedge={}; h.d.io_write=0; h.idle(64); CHECK(injected);
    uint8_t translated=translate?uint8_t((prefix?0x80:0)|0x1c):raw;
    const bool consumes_prefix=translate && raw==0xf0;
    if(!offset) {
        CHECK(h.collisions.size()==1);
        CHECK(h.collisions[0].raw==raw);
        if(PS2_TEST_LEGACY) CHECK(h.collisions[0].data==0xfa);
        else if(!consumes_prefix) CHECK(h.collisions[0].data==translated);
    }
    if(consumes_prefix) {
        CHECK(h.d.escape_state); h.byte(0x5a);
        CHECK(h.drain()==std::vector<uint8_t>({0xfa,0x9c}));
    } else if(PS2_TEST_LEGACY && !offset) {
        CHECK(h.drain()==std::vector<uint8_t>({0xfa}));
        std::cout<<"PS2-LEGACY-RED lost_scan raw="<<unsigned(raw)<<" prefix="<<prefix<<"\n";
    } else if(offset<0) CHECK(h.drain()==std::vector<uint8_t>({0xfa,translated}));
    else CHECK(h.drain()==std::vector<uint8_t>({translated,0xfa}));
    if(!PS2_TEST_LEGACY) CHECK(!h.saw_send && !h.d.input_full);
}
static void full_ack_and_mouse_credit() {
    Harness h;
    // Mouse output is selected first, so its read must not grant keyboard space.
    h.write(4,0xd3); h.write(0,0xab); h.idle(8); CHECK(h.d.mouse_full);
    h.fill(true); h.write(0,0xf4); h.idle(16);
    if(PS2_TEST_LEGACY) {
        CHECK(h.d.fifo_full && !h.d.input_full);
        CHECK(h.read()==0xab);
        CHECK(h.drain()==std::vector<uint8_t>(64,0xfa));
        std::cout<<"PS2-LEGACY-RED lost_65th_ack_ibf_false_completion=1\n"; return;
    }
    CHECK(h.d.fifo_full && h.d.input_full && h.d.ack_offer);
    uint8_t wi=h.d.write_index; CHECK(h.read()==0xab);
    CHECK(h.d.write_index==wi && h.d.fifo_full && h.d.input_full && h.d.ack_offer);
    // Full+actual keyboard read commits the retained 65th ACK on that edge.
    CHECK(h.read()==0xfa); CHECK(h.last.new_index==uint8_t((wi+1)&63));
    CHECK(!h.d.input_full && h.d.fifo_full);
    auto rest=h.drain(); CHECK(rest==std::vector<uint8_t>(64,0xfa));
    CHECK(h.ack_count==65 && h.key_write_count==65);
    std::cout<<"PS2-FULL-ACK full_plus_read=1 mouse_read_no_credit=1 exactly65=1 OK\n";
}
static void initial_receive_command_race() {
    Harness h;
    bool injected=false;
    h.preedge=[&](Harness &x) {
        if(!injected && x.d.controller_state==0 && !x.kc) {
            x.d.io_cs=1; x.d.io_address=0; x.d.io_writedata=0xf4;
            x.d.io_write=1; injected=true;
        } else x.d.io_write=0;
    };
    h.byte(0x5a);
    h.preedge={}; h.d.io_write=0; h.idle(32);
    CHECK(injected && !h.saw_send && h.key_write_count==1 && h.ack_count==1);
    CHECK(h.drain()==std::vector<uint8_t>({0xfa,0x1c}));
    std::cout<<"PS2-INITIAL-RX-COMMAND-RACE no_fake_send_or_lost_frame=1 OK\n";
}
static void full_scan(bool prefix,bool flush_reset,bool flush_selftest) {
    Harness h;
    if(prefix) h.byte(0xf0);
    h.begin_frame(1875); h.fill(PS2_TEST_AUTOACK);
    h.end_frame(0x5a,1875);
    const uint8_t scan=prefix?0x9c:0x1c;
    if(PS2_TEST_LEGACY) {
        CHECK(h.d.fifo_full && !h.d.rx_pending);
        CHECK(h.drain()==std::vector<uint8_t>(64,0xfa));
        std::cout<<"PS2-LEGACY-RED full_scan_drop prefix="<<prefix<<"\n"; return;
    }
    CHECK(h.d.fifo_full && h.d.rx_pending && h.d.pending_data==scan);
    h.idle(64); CHECK(!h.d.ps2_kbclk_out);
    // Changing the translation mode after receipt must not reinterpret the
    // retained already-translated scan byte.
    h.write(4,0x60); h.write(0,0x03); h.idle(8);
    CHECK(!h.d.translated && h.d.pending_data==scan);
    if(PS2_TEST_AUTOACK) { h.write(0,0xf4); h.idle(16); CHECK(h.d.ack_offer && h.d.input_full); }
    if(flush_reset || flush_selftest) {
        if(flush_reset) h.reset();
        else { h.write(4,0xaa,20); h.idle(64); }
        CHECK(!h.d.rx_pending && !h.d.ack_offer && !h.d.input_full);
        if(flush_selftest) CHECK(h.drain()==std::vector<uint8_t>({0x55}));
        else CHECK(h.drain().empty());
        h.idle(256); CHECK(h.d.fifo_empty && !h.d.output_full);
        h.write(4,0x60); h.write(0,0x43); h.idle(8);
        h.byte(0x5a); CHECK(h.drain()==std::vector<uint8_t>({0x1c}));
        std::cout<<"PS2-FLUSH reset="<<flush_reset<<" selftest="<<flush_selftest<<" no_ghost=1 OK\n"; return;
    }
    // A pending controller reply cannot disappear when scan or ACK wins.
    h.write(4,0xc0); h.idle(8); CHECK(h.d.reply_valid);
    auto out=h.drain();
    std::vector<uint8_t> expect;
    for(unsigned n=0;n<64;++n) expect.push_back(PS2_TEST_AUTOACK?0xfa:uint8_t(0x40+n));
    expect.push_back(scan); if(PS2_TEST_AUTOACK) expect.push_back(0xfa); expect.push_back(0x80);
    CHECK(out==expect && !h.d.reply_valid);
    CHECK(h.scan_count==1 && h.reply_count==(PS2_TEST_AUTOACK?1:65));
    std::cout<<"PS2-FULL-SCAN prefix="<<prefix<<" retained_translated=1 scan_ack_reply_order=1 OK\n";
}
static void held_strobes() {
    Harness h;
    // Even a one-low-clock gap rearms: no unnecessary loss of successive
    // accepted transactions. The actual iobus pulses have >=2 low clocks.
    h.write(4,0xd2,1,1); h.write(0,0xb1,1,1);
    h.write(4,0xd2,1,1); h.write(0,0xb2,1,1); h.idle(8);
    CHECK(h.drain()==std::vector<uint8_t>({0xb1,0xb2}) && h.key_write_count==0);
    h.write(4,0x60,20); h.write(0,0x43,20); h.idle(32);
    CHECK(h.key_write_count==0 && !h.d.input_full && h.d.fifo_empty);
    h.write(4,0xd2,20); h.write(0,0xa5,20);
    CHECK(h.drain()==std::vector<uint8_t>({0xa5}) && h.key_write_count==0);
    h.write(4,0xd3,20); h.write(0,0x5a,20); h.idle(16);
    CHECK(h.read()==0x5a && h.key_write_count==0 && h.mouse_write_count==0);
    if(PS2_TEST_AUTOACK) {
        h.write(0,0xf4,50); h.idle(32);
        CHECK(h.drain()==std::vector<uint8_t>({0xfa}) && h.key_write_count==1);
        h.write(0,0xed,50); CHECK(h.drain()==std::vector<uint8_t>({0xfa}));
        CHECK(h.key_write_count==2 && h.ack_count==2 && !h.saw_send);
    } else {
        h.write(0,0xf4,50); CHECK(h.key_write_count==1 && h.d.input_full);
        h.physical_command(false,0xf4);
        CHECK(h.drain()==std::vector<uint8_t>({0xfa}) && h.key_write_count==1 && h.saw_send);
    }
    // Mouse parameter ownership must remain one ordinary physical command.
    h.write(4,0xd4,20); h.write(0,0xf4,20);
    CHECK(h.mouse_write_count==1);
    h.physical_command(true,0xf4);
    CHECK(h.read()==0xfa && h.mouse_write_count==1 && h.saw_mouse_send);
    std::cout<<"PS2-HELD-STROBES command_parameter_device_once=1 mouse_physical=1 OK\n";
}
static void prefix_led_gap() {
    Harness h;
    h.byte(0xf0); CHECK(h.d.escape_state);
    h.write(0,0xed); h.idle(64);
    if(PS2_TEST_AUTOACK) {
        CHECK(h.read()==0xfa); h.idle(1100000);
        if(PS2_TEST_LEGACY) {
            CHECK(h.timeout_count>0 && !h.d.escape_state);
            h.byte(0x5a); CHECK(h.drain()==std::vector<uint8_t>({0x1c}));
            std::cout<<"PS2-LEGACY-RED natural_LED_timeout_loses_prefix_wrong_make=1\n"; return;
        }
        CHECK(!h.saw_send && h.timeout_count==0 && h.d.escape_state);
        h.write(0,0x00); h.idle(32); CHECK(h.read()==0xfa);
    } else {
        CHECK(h.commits.empty() && h.d.input_full);
        h.physical_command(false,0xed); CHECK(h.read()==0xfa);
        // In raw physical-device reply profiles, ACK received while F0 owns
        // translation is itself an ordinary non-F0 byte. This test explicitly
        // re-establishes F0 after the command, rather than inventing a bypass.
        h.byte(0xf0);
        CHECK(h.d.escape_state && h.timeout_count==0 && h.saw_send);
    }
    h.byte(0x5a); CHECK(h.drain()==std::vector<uint8_t>({0x9c}));
    std::cout<<"PS2-PREFIX-LED-GAP no_fake_send="<<PS2_TEST_AUTOACK<<" OK\n";
}
static void disable_enable_and_irq() {
    Harness h; h.write(4,0xad); h.idle(20000);
    CHECK(!h.d.ps2_kbclk_out);
    h.write(4,0xae); h.wait_ready(); h.byte(0x5a); h.idle(16);
    CHECK(h.d.irq_keyb); CHECK(h.read()==0x1c); h.idle(16); CHECK(!h.d.irq_keyb);
    // Selftest is also tested while a receive frame is in progress.
    h.begin_frame(64); h.write(4,0xaa);
    h.kc=h.kd=true; h.idle(64);
    CHECK(h.drain()==std::vector<uint8_t>({0x55}));
    CHECK(h.raw_receipts==std::vector<uint8_t>({0x5a}));
    h.byte(0x5a); CHECK(h.drain()==std::vector<uint8_t>({0x1c}));
    std::cout<<"PS2-INHIBIT-IRQ-FLUSH ordinary_io=1 OK\n";
}
int main(int argc,char **argv) {
    Verilated::commandArgs(argc,argv);
    try {
        streams_and_parity();
        if(PS2_TEST_LEGACY) {
            if(PS2_TEST_AUTOACK) {
                collision(true,0x5a,false,0); collision(false,0x5a,false,0);
                collision(true,0x5a,true,0); collision(true,0xf0,false,0);
                full_ack_and_mouse_credit(); full_scan(false,false,false);
                full_scan(true,false,false); prefix_led_gap();
                std::cout<<"PS2-LEGACY-RED-CONTROLS-OK (expected defects, NOT correctness)\n";
            } else {
                Harness p(false); p.write(0,0xf4); p.physical_command(false,0xf4);
                CHECK(p.drain()==std::vector<uint8_t>({0xfa}) && p.saw_send);
                std::cout<<"PS2-LEGACY-PHYSICAL-CONTROL-OK\n";
            }
            return 0;
        }
        if(PS2_TEST_AUTOACK) {
            collision(true,0x5a,false,0); collision(false,0x5a,false,0);
            collision(true,0x5a,true,0); collision(true,0xf0,false,0);
            collision(true,0x5a,false,-4); collision(true,0x5a,false,4);
            full_ack_and_mouse_credit(); initial_receive_command_race();
        }
        full_scan(false,false,false); full_scan(true,false,false);
        full_scan(false,true,false); full_scan(true,false,true);
        held_strobes(); prefix_led_gap(); disable_enable_and_irq();
        std::cout<<"PS2-LOSS-FIX-MICRO-OK autoack="<<PS2_TEST_AUTOACK
                 <<" scope=isolated_controller_no_guest_no_FPGA\n"; return 0;
    } catch(const std::exception &e) {
        std::cerr<<"PS2-MICRO-FAIL "<<e.what()<<"\n"; return 1;
    }
}
