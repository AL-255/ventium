#include "Vven_ddram_axi_posted.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <random>
#include <vector>
#ifdef NDEBUG
#error "The bridge scoreboard requires active assertions"
#endif

struct Write { unsigned addr, aw_cycle=0, w_cycle=0; uint64_t data; uint8_t mask; };
struct Sim {
    Vven_ddram_axi_posted d;
    std::mt19937 random;
    unsigned cycle=0, aw=0, w=0, b=0, ar=0, responses=0;
    unsigned read_addr=0, read_left=0, read_at=0, write_delay;
    unsigned held_aw=0; uint64_t held_w=0; unsigned held_mask=0;
    bool aw_stalled=false, w_stalled=false;
    bool hold_aw=false, hold_w=false, hold_b=false;
    int bad_b=-1; bool bad_r=false;
    std::vector<Write> writes;
    std::array<uint64_t,128> memory{}, expected{};
    std::deque<uint64_t> reads;
    explicit Sim(unsigned seed, unsigned latency) : random(seed), write_delay(latency) {
        d.clk=0; d.rst_n=0; d.DDRAM_WE=0; d.DDRAM_RD=0;
        d.DDRAM_BURSTCNT=1; d.DDRAM_BE=0xff;
        d.m_axi_bvalid=0; d.m_axi_rvalid=0; d.m_axi_rlast=0;
        d.m_axi_awready=0; d.m_axi_wready=0; d.m_axi_arready=0;
        d.eval(); d.clk=1; d.eval(); d.clk=0; d.rst_n=1; d.eval();
    }
    static void merge(uint64_t &dst, uint64_t data, unsigned mask) {
        for (unsigned j=0;j<8;j++) if (mask & (1u<<j)) {
            uint64_t m=uint64_t(255)<<(8*j); dst=(dst&~m)|(data&m);
        }
    }
    bool tick() {
        ++cycle; assert(cycle<2000000);
        d.clk=0;
        d.m_axi_awready=!hold_aw && random()%4;
        d.m_axi_wready=!hold_w && random()%3;
        d.m_axi_arready=random()%3;
        d.m_axi_bvalid=!hold_b && b<aw && b<w &&
            cycle>=std::max(writes[b].aw_cycle,writes[b].w_cycle)+write_delay;
        d.m_axi_bresp=int(b)==bad_b ? 2 : 0;
        d.m_axi_rvalid=read_left && cycle>=read_at && random()%3;
        d.m_axi_rresp=bad_r ? 2 : 0;
        d.m_axi_rlast=read_left==1;
        d.m_axi_rdata=memory[read_addr%128];
        d.eval();
        if (aw_stalled) assert(d.m_axi_awvalid && d.m_axi_awaddr==held_aw);
        if (w_stalled) assert(d.m_axi_wvalid && d.m_axi_wdata==held_w && d.m_axi_wstrb==held_mask);
        aw_stalled=d.m_axi_awvalid && !d.m_axi_awready; held_aw=d.m_axi_awaddr;
        w_stalled=d.m_axi_wvalid && !d.m_axi_wready; held_w=d.m_axi_wdata; held_mask=d.m_axi_wstrb;
        bool accepted=!d.DDRAM_BUSY && (d.DDRAM_WE || d.DDRAM_RD);
        if (accepted && d.DDRAM_WE) {
            assert(!d.DDRAM_RD && d.DDRAM_BURSTCNT<=1);
            writes.push_back({unsigned(d.DDRAM_ADDR),0,0,d.DDRAM_DIN,uint8_t(d.DDRAM_BE)});
            merge(expected[d.DDRAM_ADDR%128],d.DDRAM_DIN,d.DDRAM_BE);
        }
        if (accepted && d.DDRAM_RD) {
            unsigned count=d.DDRAM_BURSTCNT ? d.DDRAM_BURSTCNT : 1;
            for(unsigned j=0;j<count;j++) reads.push_back(expected[(d.DDRAM_ADDR+j)%128]);
        }
        if(d.DDRAM_DOUT_READY) {
            assert(!reads.empty() && d.DDRAM_DOUT==reads.front());
            reads.pop_front(); ++responses;
        }
        if(d.m_axi_awvalid && d.m_axi_awready) {
            assert(aw<writes.size() && d.m_axi_awaddr==writes[aw].addr*8);
            assert(d.m_axi_awlen==0 && d.m_axi_awsize==3 && d.m_axi_awburst==1 && d.m_axi_awid==0);
            writes[aw++].aw_cycle=cycle;
        }
        if(d.m_axi_wvalid && d.m_axi_wready) {
            assert(w<writes.size() && d.m_axi_wdata==writes[w].data && d.m_axi_wstrb==writes[w].mask && d.m_axi_wlast);
            writes[w++].w_cycle=cycle;
        }
        if(d.m_axi_bvalid && d.m_axi_bready) {
            assert(b<aw && b<w);
            if(int(b)!=bad_b) merge(memory[writes[b].addr%128],writes[b].data,writes[b].mask);
            ++b;
        }
        if(d.m_axi_arvalid && d.m_axi_arready) {
            assert(b==writes.size() && !read_left);
            assert(d.m_axi_arsize==3 && d.m_axi_arburst==1 && d.m_axi_arid==0);
            read_addr=d.m_axi_araddr/8; read_left=d.m_axi_arlen+1; read_at=cycle+7; ++ar;
        }
        if(d.m_axi_rvalid && d.m_axi_rready) { assert(read_left); --read_left; ++read_addr; }
        d.clk=1; d.eval();
        return accepted;
    }
    void send_write(unsigned address,uint64_t data,unsigned mask) {
        d.DDRAM_RD=0; d.DDRAM_WE=1; d.DDRAM_ADDR=address; d.DDRAM_DIN=data; d.DDRAM_BE=mask;
        do {} while(!tick());
        d.DDRAM_WE=0;
    }
    void drain() { d.DDRAM_WE=0; d.DDRAM_RD=0; while(b<writes.size() || !reads.empty() || d.DDRAM_BUSY) tick(); tick(); }
    void reset_all() {
        d.rst_n=0; d.DDRAM_WE=0; d.DDRAM_RD=0; d.clk=0; d.eval(); d.clk=1; d.eval();
        d.clk=0; d.eval();
        assert(!d.m_axi_awvalid && !d.m_axi_wvalid && !d.m_axi_arvalid && !d.DDRAM_DOUT_READY && !d.fault);
    }
};

int main(int argc,char **argv) {
    Verilated::threadContextp()->threads(1);
    Verilated::commandArgs(argc,argv);
    unsigned seed=argc>1 ? std::stoul(argv[1]) : 1;
    for(unsigned latency : {0u,1u,7u,20u,47u}) {
        Sim s(seed,latency);
        for(unsigned group=0;group<32;group++) {
            for(unsigned j=0;j<16;j++)
                s.send_write(s.random()%64,(uint64_t(s.random())<<32)|s.random(),s.random()%256);
            s.d.DDRAM_WE=0; s.d.DDRAM_RD=1;
            s.d.DDRAM_ADDR=s.random()%56; s.d.DDRAM_BURSTCNT=1+s.random()%8;
            do {} while(!s.tick()); // read may be accepted before previous B
            s.d.DDRAM_RD=0;
            s.drain(); s.d.DDRAM_BURSTCNT=1;
        }
        assert(s.b==512 && s.aw==512 && s.w==512 && s.ar==64 && s.expected==s.memory && !s.d.fault);
        s.reset_all();
    }
    // Backpressure each channel independently, retain all queue data, then
    // drain. Also reset a full queue with one channel not yet accepted.
    for(unsigned channel=0;channel<3;channel++) {
        Sim s(seed,20); s.hold_aw=channel==0; s.hold_w=channel==1; s.hold_b=channel==2;
        for(unsigned j=0;j<4;j++) s.send_write(j,0x1234+j,0xff);
        for(unsigned j=0;j<30;j++) { s.tick(); assert(s.d.DDRAM_BUSY); }
        s.hold_aw=s.hold_w=s.hold_b=false; s.drain(); assert(s.b==4 && s.expected==s.memory);
        s.hold_aw=true; for(unsigned j=0;j<4;j++) s.send_write(j,j,1);
        s.reset_all();
    }
    for(int error_at : {0,2}) {
        Sim s(seed,20); s.bad_b=error_at;
        for(unsigned j=0;j<4;j++) s.send_write(j,j,0xff);
        while(s.b<4) s.tick();
        assert(s.d.fault && s.d.DDRAM_BUSY && s.aw==4 && s.w==4);
        s.d.DDRAM_RD=1;
        for(unsigned j=0;j<30;j++) s.tick();
        assert(s.ar==0 && s.writes.size()==4); s.reset_all();
    }
    { Sim s(seed,20); s.bad_r=true; s.d.DDRAM_RD=1; do {} while(!s.tick());
      s.d.DDRAM_RD=0; for(unsigned j=0;j<100;j++) s.tick();
      assert(s.d.fault && s.d.DDRAM_BUSY && s.responses==0 && s.ar==1); s.reset_all(); }
    std::printf("DDRAM-POSTED-FUZZ-OK seed=%u partial-alias-writes=2560 reads=160 errors/reset/skew=OK\n",seed);
}
