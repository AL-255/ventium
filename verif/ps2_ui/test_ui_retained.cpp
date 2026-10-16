// Synthetic host-protocol evidence only; not RTL or full-PC acceptance.
#include "pc_keyboard_retained.h"
#include <functional>
#include <iostream>

#define CHECK(x) do { if (!(x)) throw std::runtime_error(#x); } while (0)
using ven_ui::Input;
using ven_ui::ReceiveProof;
constexpr ven_ui::Timing timing{32,128,1152,4096};

#define K(name) system__DOT__ps2__DOT__##name
struct Root {
    bool K(translate)=false, K(keyb_translate_escape)=false, K(cmd_self_test)=false;
    bool K(keyb_recv_final)=false, K(wtk_q)=false, K(ps2_kb_reply_done)=false;
    bool K(kb_fifo_wrreq)=false, K(keyb_fifo_full)=false, K(keyb_fifo_empty)=true;
    bool K(__Vcellinp__keyb_fifo__rdreq)=false, K(kb_rx_pending)=false, K(kb_ack_pending)=false;
    unsigned K(keyb_timeout)=0;
    uint8_t K(keyb_recv_buffer)=0, K(trans)=0, K(keyb_reply)=0, K(kb_rx_pending_data)=0;
    uint8_t K(keyb_fifo__DOT__wr_index)=0, K(keyb_fifo_q)=0;
    std::array<uint8_t,64> K(keyb_fifo__DOT__mem){};
};

static void binding() {
    for (unsigned flags=0;flags<256;++flags) {
        Root r; Input input(timing,nullptr);
        r.K(kb_rx_pending)=flags&1; r.K(keyb_recv_final)=flags&2;
        r.K(kb_ack_pending)=flags&4; r.K(wtk_q)=flags&8;
        r.K(keyb_fifo_full)=flags&16; r.K(__Vcellinp__keyb_fifo__rdreq)=flags&32;
        r.K(cmd_self_test)=flags&64;
        r.K(kb_rx_pending_data)=0x9c; r.K(keyb_recv_buffer)=0x5a; r.K(keyb_reply)=0xee;
        const bool reset=flags&128, offer=flags&3;
        const uint8_t value=(flags&1)?0x9c:(flags&2)?0x5a:(flags&12)?0xfa:0xee;
        const auto edge=ven_ui::pc_keyboard_retained_before(input,0,r,reset);
        CHECK(edge.proof.produced_value==value);
        CHECK(edge.proof.scan_commit==(offer && !(flags&192) && (!(flags&16) || (flags&32))));
        CHECK(edge.proof.pending_before==bool(flags&1));
        // No own byte: post-edge observation alone must not invent delivery.
        r.K(keyb_recv_final)=false;
        if (!(flags&2)) ven_ui::pc_keyboard_retained_after(input,0,r,edge);
        CHECK(input.accepted_front()==0);
    }
}
#undef K

static uint64_t start(Input &input, uint64_t cycle) {
    for (unsigned n=0;n<8192;++n,++cycle) {
        input.drive(cycle,false,true,true,true);
        if (input.inflight()) return cycle;
    }
    throw std::runtime_error("no wire owner");
}

static void command(Input &input) {
    const std::string text="1 key enter\n2 capture\n";
    input.feed(text.data(),text.size(),0);
}

static ReceiveProof final_byte(uint8_t raw, bool translated, bool hold, uint8_t index=63) {
    ReceiveProof p;
    p.final=true; p.raw=raw; p.translated=translated; p.retained_contract=true;
    p.escape_before=translated && raw==0xf0;
    p.escape_after=p.escape_before;
    p.translated_value=translated ? 0x1c : raw;
    p.produced_value=p.translated_value;
    p.old_write_index=index; p.new_write_index=index;
    if (translated && raw==0xf0) return p;
    p.full=hold; p.pending_after=hold; p.pending_value_after=p.translated_value;
    if (!hold) {
        p.scan_commit=true; p.write_request=true; p.new_write_index=(index+1)&63;
        p.post_memory_at_old_write_index=p.translated_value;
    }
    return p;
}

static ReceiveProof held_edge(uint8_t value, bool commit) {
    ReceiveProof p;
    p.retained_contract=true; p.pending_before=true; p.pending_value_before=value;
    p.full=true; p.old_write_index=63; p.new_write_index=63;
    p.pending_after=!commit; p.pending_value_after=value;
    if (commit) {
        p.scan_commit=true; p.read_request=true; p.write_request=true;
        p.produced_value=value; p.new_write_index=0; p.post_memory_at_old_write_index=value;
    }
    return p;
}

static void ordinary_and_retained() {
    for (bool translated : {false,true}) for (bool hold : {false,true}) {
        Input input(timing,nullptr); command(input); uint64_t cycle=0;
        for (unsigned i=0;i<3;++i) {
            cycle=start(input,cycle)+timing.half*22;
            const uint8_t raw=i==1?0xf0:0x5a;
            auto p=final_byte(raw,translated,hold);
            if (translated && i==2) {
                p.escape_before=true; p.translated_value=0x9c; p.produced_value=0x9c;
                p.pending_value_after=0x9c; p.post_memory_at_old_write_index=0x9c;
            }
            // AUTOACK offer must not make a correctly selected scan look lost.
            p.autoack=true;
            input.accepted_edge(cycle,p);
            CHECK(!input.failed());
            if (hold && !(translated && raw==0xf0)) {
                CHECK(input.awaiting_commit() && input.accepted_front()==i);
                uint64_t id=0; CHECK(!input.capture_ready(id));
                for (unsigned n=0;n<20;++n) {
                    ++cycle;
                    // Ordinary inhibition and changed live translation do not
                    // invalidate an already translated, still-observed skid.
                    const auto lines=input.drive(cycle,false,false,true,false);
                    CHECK(lines.clock && lines.data);
                    input.prefix_context_before(cycle,!translated,false,false,true);
                    input.accepted_edge(cycle,held_edge(p.translated_value,false));
                    CHECK(!input.failed() && input.accepted_front()==i);
                }
                input.accepted_edge(++cycle,held_edge(p.translated_value,true));
            }
            CHECK(!input.failed() && !input.inflight()); ++cycle;
        }
        uint64_t id=0; CHECK(input.capture_ready(id) && id==2);
        input.capture_result(id,cycle,"/raw.ppm",true);
        CHECK(input.finish(cycle));
    }
}

static void mutations() {
    const std::vector<std::function<void(ReceiveProof&)>> capture_faults={
        [](auto &p){p.pending_after=false;}, [](auto &p){p.pending_value_after^=1;},
        [](auto &p){p.pending_before=true;}, [](auto &p){p.write_request=true;},
        [](auto &p){p.full=false;}, [](auto &p){p.read_request=true;},
        [](auto &p){p.new_write_index=0;}, [](auto &p){p.clear=true;},
        [](auto &p){p.reset=true;}, [](auto &p){p.raw^=1;}
    };
    for (const auto &fault:capture_faults) {
        Input input(timing,nullptr); command(input);
        const auto cycle=start(input,0)+timing.half*22;
        auto p=final_byte(0x5a,true,true); fault(p); input.accepted_edge(cycle,p);
        CHECK(input.failed() && input.accepted_front()==0);
    }
    const std::vector<std::function<void(ReceiveProof&)>> commit_faults={
        [](auto &p){p.pending_before=false;}, [](auto &p){p.pending_value_before^=1;},
        [](auto &p){p.pending_after=true;}, [](auto &p){p.write_request=false;},
        [](auto &p){p.read_request=false;}, [](auto &p){p.new_write_index=63;},
        [](auto &p){p.post_memory_at_old_write_index^=1;}, [](auto &p){p.produced_value^=1;},
        [](auto &p){p.clear=true;}, [](auto &p){p.reset=true;},
        [](auto &p){p.final=true;}, [](auto &p){p.retained_contract=false;}
    };
    for (const auto &fault:commit_faults) {
        Input input(timing,nullptr); command(input);
        const auto cycle=start(input,0)+timing.half*22;
        input.accepted_edge(cycle,final_byte(0x5a,true,true));
        auto p=held_edge(0x1c,true); fault(p); input.accepted_edge(cycle+1,p);
        CHECK(input.failed() && input.accepted_front()==0);
    }
    for (unsigned fault=0;fault<5;++fault) {
        Input input(timing,nullptr); command(input);
        const auto cycle=start(input,0)+timing.half*22;
        input.accepted_edge(cycle,final_byte(0x5a,true,true));
        auto p=held_edge(0x1c,false);
        if (fault==0) p.pending_after=false;
        if (fault==1) p.pending_value_after^=1;
        if (fault==2) p.write_request=true;
        if (fault==3) p.new_write_index=0;
        if (fault==4) p.scan_commit=true;
        input.accepted_edge(cycle+1,p);
        CHECK(input.failed() && input.accepted_front()==0);
    }
    Input input(timing,nullptr); command(input);
    const auto cycle=start(input,0)+timing.half*22;
    input.accepted_edge(cycle,final_byte(0x5a,true,true));
    input.drive(cycle+timing.commit_limit+1,false,true,true,true);
    CHECK(input.failed() && input.accepted_front()==0 && input.inflight());
}

int main() {
    binding(); ordinary_and_retained(); mutations();
    std::cout<<"UI-RETAINED-HOST-OK bindings=256 streams=4 negative_controls=28 rtl_execution=0\n";
}
