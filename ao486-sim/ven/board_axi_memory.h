// Host-only AXI RAM slave for simulation of the REAL board transport RTL.
// No CPU/guest state injection. Writes become visible only on B completion;
// AW/W are independent, and R/B payloads remain stable under backpressure.
#pragma once
#include <cstdint>
#include <deque>
#include <stdexcept>

namespace ven_board {
class AxiMemory {
    struct Address { uint32_t word; uint64_t cycle; };
    struct Data { uint64_t value; uint8_t mask; uint64_t cycle; };
    struct Pending { uint32_t word; uint64_t value; uint8_t mask; uint64_t due; };
    std::deque<Address> aw;
    std::deque<Data> w;
    std::deque<Pending> pending;
    uint32_t read_word=0, read_left=0;
    uint64_t read_due=0, held_data=0;
    bool held_read=false;
    static void require(bool ok, const char *why) {
        if(!ok) throw std::runtime_error(why);
    }
public:
    // Board samples suggest ~19 B-wait and ~21 AR-to-first-R core clocks.
    // These are explicit model parameters, not claimed exact PS timing.
    uint32_t write_delay=20, read_delay=21;
    uint64_t aw_count=0, w_count=0, b_count=0, ar_count=0, r_count=0;
    bool empty() const { return aw.empty() && w.empty() && pending.empty() && !read_left && !held_read; }

    template<class Top, class Reader>
    void drive(Top& t, uint64_t cycle, Reader read) {
        // Limit host queues even if a broken master ignores the real bridge's
        // eight-slot bound. Never overwrite an unacknowledged request.
        t.m_axi_awready=aw.size()+pending.size()<16;
        t.m_axi_wready=w.size()+pending.size()<16;
        t.m_axi_bvalid=!pending.empty() && cycle>=pending.front().due;
        t.m_axi_bresp=0;
        t.m_axi_arready=!read_left && !held_read;
        if(read_left && !held_read && cycle>=read_due) {
            held_data=read(read_word); held_read=true;
        }
        t.m_axi_rvalid=held_read;
        t.m_axi_rdata=held_data;
        t.m_axi_rlast=read_left==1;
        t.m_axi_rresp=0;
    }

    // Call exactly once with settled PRE-RISING-EDGE pins. Calling after eval
    // at the rising edge would sample next-state valids and lose transactions.
    template<class Top, class Writer>
    void sample(const Top& t, uint64_t cycle, Writer write) {
        if(t.m_axi_bvalid && t.m_axi_bready) {
            require(!pending.empty(),"board AXI unowned B");
            const auto p=pending.front(); pending.pop_front();
            write(p.word,p.value,p.mask); ++b_count;
        }
        if(t.m_axi_awvalid && t.m_axi_awready) {
            require(t.m_axi_awid==0 && t.m_axi_awlen==0 && t.m_axi_awsize==3 &&
                    t.m_axi_awburst==1 && !(t.m_axi_awaddr&7),"board AXI invalid AW shape");
            aw.push_back({uint32_t(t.m_axi_awaddr/8),cycle}); ++aw_count;
        }
        if(t.m_axi_wvalid && t.m_axi_wready) {
            require(t.m_axi_wlast,"board AXI unsupported multi-beat write");
            w.push_back({uint64_t(t.m_axi_wdata),uint8_t(t.m_axi_wstrb),cycle}); ++w_count;
        }
        if(!aw.empty() && !w.empty()) {
            const auto a=aw.front(); const auto d=w.front(); aw.pop_front(); w.pop_front();
            pending.push_back({a.word,d.value,d.mask,(a.cycle>d.cycle?a.cycle:d.cycle)+write_delay});
        }
        if(t.m_axi_arvalid && t.m_axi_arready) {
            require(aw.empty() && w.empty() && pending.empty(),"board AXI read overtook pending write");
            require(t.m_axi_arid==0 && t.m_axi_arsize==3 && t.m_axi_arburst==1 &&
                    !(t.m_axi_araddr&7) && t.m_axi_arlen<8,"board AXI invalid AR shape");
            read_word=uint32_t(t.m_axi_araddr/8); read_left=uint32_t(t.m_axi_arlen)+1;
            read_due=cycle+read_delay; ++ar_count;
        }
        if(t.m_axi_rvalid && t.m_axi_rready) {
            require(held_read && read_left,"board AXI unowned R");
            --read_left; ++read_word; held_read=false; read_due=cycle+1; ++r_count;
        }
    }

    // Explicit fields, never struct padding or host pointer values. Keep this
    // payload behind a new format marker; old DDR-FIFO snapshots are incompatible.
    template<class Stream> void save(Stream& s) const {
        auto put=[&](const auto& value){ s.write(&value,sizeof(value)); };
        const uint64_t magic=0x4158494d454d3031ULL; put(magic);
        put(write_delay); put(read_delay);
        put(aw_count); put(w_count); put(b_count); put(ar_count); put(r_count);
        put(read_word); put(read_left); put(read_due); put(held_data);
        const uint8_t held=held_read; put(held);
        uint32_t n=uint32_t(aw.size()); put(n);
        for(const auto& x:aw){put(x.word);put(x.cycle);}
        n=uint32_t(w.size()); put(n);
        for(const auto& x:w){put(x.value);put(x.mask);put(x.cycle);}
        n=uint32_t(pending.size()); put(n);
        for(const auto& x:pending){put(x.word);put(x.value);put(x.mask);put(x.due);}
    }
    template<class Stream> void load(Stream& s) {
        AxiMemory next;
        auto get=[&](auto& value){ s.read(&value,sizeof(value)); };
        uint64_t magic=0; get(magic);
        require(magic==0x4158494d454d3031ULL,"board AXI snapshot format mismatch");
        get(next.write_delay); get(next.read_delay);
        require(next.write_delay==write_delay && next.read_delay==read_delay,"board AXI snapshot latency mismatch");
        get(next.aw_count); get(next.w_count); get(next.b_count); get(next.ar_count); get(next.r_count);
        get(next.read_word); get(next.read_left); get(next.read_due); get(next.held_data);
        uint8_t held; get(held); require(held<=1,"board AXI invalid held R"); next.held_read=held;
        uint32_t n=0;
        get(n); require(n<=16,"board AXI oversized AW snapshot");
        while(n--){Address x{};get(x.word);get(x.cycle);next.aw.push_back(x);}
        get(n); require(n<=16,"board AXI oversized W snapshot");
        while(n--){Data x{};get(x.value);get(x.mask);get(x.cycle);next.w.push_back(x);}
        get(n); require(n<=16,"board AXI oversized B snapshot");
        while(n--){Pending x{};get(x.word);get(x.value);get(x.mask);get(x.due);next.pending.push_back(x);}
        require(next.b_count<=next.aw_count && next.b_count<=next.w_count && next.read_left<=8 &&
                (!held || next.read_left) &&
                next.aw_count-next.b_count==next.aw.size()+next.pending.size() &&
                next.w_count-next.b_count==next.w.size()+next.pending.size(),"board AXI snapshot ownership mismatch");
        *this=next;
    }
};
} // namespace ven_board
