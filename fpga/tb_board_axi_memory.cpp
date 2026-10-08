// Test the proposed host AXI backend against the real posted bridge model.
#ifdef VEN_TEST_SERIAL_BRIDGE
#include "Vven_ddram_axi.h"
using Model=Vven_ddram_axi;
#else
#include "Vven_ddram_axi_posted.h"
using Model=Vven_ddram_axi_posted;
#endif
#include "verilated.h"
#include "../ao486-sim/ven/board_axi_memory.h"
#include <array>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <deque>
#include <random>
#include <vector>
#ifdef NDEBUG
#error "The host-backend gate requires active assertions"
#endif
struct Stream {
    std::vector<uint8_t> data; size_t at=0;
    void write(const void* p,size_t n) {
        const auto* b=static_cast<const uint8_t*>(p); data.insert(data.end(),b,b+n);
    }
    void read(void* p,size_t n) {
        if(at+n>data.size()) throw std::runtime_error("short snapshot");
        std::memcpy(p,data.data()+at,n); at+=n;
    }
};
static void merge(uint64_t& old,uint64_t value,uint8_t mask) {
    for(unsigned i=0;i<8;i++) if(mask&(1u<<i)) {
        const uint64_t m=uint64_t(255)<<(8*i); old=(old&~m)|(value&m);
    }
}
static void held_response_unit() {
    // Pin-only slave test: unlike the real bridge, this master deliberately
    // stalls B/R, including across serialization of an already-visible R.
    struct Pins {
        uint32_t m_axi_awid=0,m_axi_awaddr=16,m_axi_awlen=0,m_axi_awsize=3,m_axi_awburst=1;
        uint32_t m_axi_awvalid=1,m_axi_awready=0,m_axi_wvalid=0,m_axi_wready=0,m_axi_wlast=1,m_axi_wstrb=15;
        uint64_t m_axi_wdata=0x123456789abcdef0ULL;
        uint32_t m_axi_bvalid=0,m_axi_bready=0,m_axi_bresp=0;
        uint32_t m_axi_arid=0,m_axi_araddr=16,m_axi_arlen=1,m_axi_arsize=3,m_axi_arburst=1;
        uint32_t m_axi_arvalid=0,m_axi_arready=0,m_axi_rvalid=0,m_axi_rready=0,m_axi_rlast=0,m_axi_rresp=0;
        uint64_t m_axi_rdata=0;
    } p;
    ven_board::AxiMemory memory;
    std::array<uint64_t,8> ram{};ram[3]=0x1111222233334444ULL;
    auto read=[&](uint32_t a){return ram.at(a);};
    auto write=[&](uint32_t a,uint64_t d,uint8_t b){merge(ram.at(a),d,b);};
    memory.drive(p,0,read);memory.sample(p,0,write);p.m_axi_awvalid=0;
    p.m_axi_wvalid=1;memory.drive(p,5,read);memory.sample(p,5,write);p.m_axi_wvalid=0;
    for(unsigned c=6;c<=30;c++) {
        memory.drive(p,c,read);memory.sample(p,c,write);
        assert(ram[2]==0 && p.m_axi_bvalid==(c>=25));
    }
    p.m_axi_bready=1;memory.sample(p,30,write);assert(ram[2]==0x9abcdef0ULL);
    p.m_axi_arvalid=1;memory.drive(p,31,read);memory.sample(p,31,write);p.m_axi_arvalid=0;
    memory.drive(p,52,read);assert(p.m_axi_rvalid && !p.m_axi_rlast && p.m_axi_rdata==0x9abcdef0ULL);
    ram[2]=0xeeeeeeeeULL;
    Stream saved;memory.save(saved);ven_board::AxiMemory restored;restored.load(saved);memory=restored;
    memory.drive(p,53,read);assert(p.m_axi_rdata==0x9abcdef0ULL);
    p.m_axi_rready=1;memory.sample(p,53,write);
    memory.drive(p,54,read);assert(p.m_axi_rlast && p.m_axi_rdata==ram[3]);memory.sample(p,54,write);
    assert(memory.empty() && memory.b_count==1 && memory.r_count==2);
}
int main(int argc,char** argv) {
    held_response_unit();
    const unsigned seed=argc>1?unsigned(std::stoul(argv[1])):1;
    std::mt19937 random(seed);
    unsigned snapshots=0;
    for(unsigned delay:{0u,1u,20u,47u}) {
        Model d;
        ven_board::AxiMemory memory; memory.write_delay=delay;
        std::array<uint64_t,128> ram{},expected{};
        std::deque<uint64_t> reads;
        uint64_t cycle=0;
        d.clk=0;d.rst_n=0;d.DDRAM_RD=0;d.DDRAM_WE=0;
        d.DDRAM_BURSTCNT=1; d.m_axi_bvalid=0;d.m_axi_rvalid=0;
        d.eval(); d.clk=1; d.eval(); d.clk=0; d.rst_n=1; d.eval();
        auto tick=[&]() {
            assert(++cycle<1000000);
            d.clk=0;
            memory.drive(d,cycle,[&](uint32_t word){return ram.at(word);});
            d.eval();
            // Randomly backpressure the slave's ready channels; the host BFM
            // still samples the exact pins consumed by the RTL at this edge.
            if(random()%4==0) d.m_axi_awready=0;
            if(random()%3==0) d.m_axi_wready=0;
            if(random()%3==0) d.m_axi_arready=0;
            d.eval();
            bool accepted=!d.DDRAM_BUSY && (d.DDRAM_WE || d.DDRAM_RD);
            if(accepted && d.DDRAM_WE) merge(expected.at(d.DDRAM_ADDR),d.DDRAM_DIN,d.DDRAM_BE);
            if(accepted && d.DDRAM_RD)
                for(unsigned i=0;i<d.DDRAM_BURSTCNT;i++) reads.push_back(expected.at(d.DDRAM_ADDR+i));
            if(d.DDRAM_DOUT_READY) {assert(!reads.empty() && reads.front()==d.DDRAM_DOUT);reads.pop_front();}
            memory.sample(d,cycle,[&](uint32_t word,uint64_t data,uint8_t mask){merge(ram.at(word),data,mask);});
            d.clk=1; d.eval();
#ifndef VEN_TEST_SERIAL_BRIDGE
            assert(!d.fault);
#endif
            if(random()%31==0) {
                Stream saved;memory.save(saved);
                ven_board::AxiMemory restored;restored.write_delay=delay;restored.load(saved);
                Stream second;restored.save(second);assert(saved.data==second.data && saved.at==saved.data.size());
                memory=restored;++snapshots;
            }
            return accepted;
        };
        for(unsigned i=0;i<1024;i++) {
            d.DDRAM_WE=1;d.DDRAM_ADDR=random()%128;d.DDRAM_BURSTCNT=1;
            d.DDRAM_DIN=(uint64_t(random())<<32)|random();d.DDRAM_BE=random();
            do {} while(!tick());d.DDRAM_WE=0;
            if(i%8==7) {
                // Actual L2 raises a new RD only when DDRAM_BUSY is clear.
                // The legacy bridge edge-detects RD and cannot capture an
                // arbitrary early RD pulse while still servicing a write.
                while(d.DDRAM_BUSY) tick();
                d.DDRAM_RD=1;d.DDRAM_BURSTCNT=8;d.DDRAM_ADDR=8*(random()%16);
                do {} while(!tick());d.DDRAM_RD=0;
                while(!reads.empty() || d.DDRAM_BUSY) tick();
            }
        }
        while(!memory.empty() || !reads.empty() || d.DDRAM_BUSY) tick();tick();
        assert(ram==expected && memory.aw_count==1024 && memory.w_count==1024 && memory.b_count==1024);
        assert(memory.ar_count==256 && memory.r_count==2048);
        Stream good;memory.save(good);
        auto rejected=[&](Stream stream, unsigned wrong_delay) {
            ven_board::AxiMemory restored;restored.write_delay=wrong_delay;
            try {restored.load(stream);assert(false);} catch(const std::runtime_error&){}
        };
        rejected(good,delay+1);
        auto bad=good;bad.data[0]^=1;rejected(bad,delay);
        bad=good;bad.data.resize(11);rejected(bad,delay);
        d.final();
    }
    assert(snapshots>100);
    std::printf("BOARD-AXI-MEMORY-OK seed=%u writes=4096 reads=512 snapshots=%u\n",seed,snapshots);
}
