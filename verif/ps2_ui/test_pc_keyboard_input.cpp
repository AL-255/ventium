// Host-binding unit tests. Synthetic observations below are not RTL execution.
#include "pc_keyboard_input.h"
#include <iostream>

#define CHECK(x) do { if (!(x)) throw std::runtime_error(#x); } while (0)
#define K(name) system__DOT__ps2__DOT__##name
struct Root {
    bool K(translate)=false, K(keyb_translate_escape)=false, K(cmd_self_test)=false;
    bool K(keyb_recv_final)=false, K(wtk_q)=false, K(ps2_kb_reply_done)=false;
    bool K(kb_fifo_wrreq)=false, K(keyb_fifo_full)=false, K(keyb_fifo_empty)=true;
    bool K(__Vcellinp__keyb_fifo__rdreq)=false;
    unsigned K(keyb_timeout)=0;
    uint8_t K(keyb_state)=0, K(keyb_recv_buffer)=0, K(trans)=0, K(keyb_reply)=0;
    uint8_t K(keyb_fifo__DOT__wr_index)=0, K(keyb_fifo_q)=0;
    std::array<uint8_t,64> K(keyb_fifo__DOT__mem){};
};
struct Top {
    Root root;
    Root *rootp = &root;
    bool reset=false, ps2_kbclk_out=true, ps2_kbdat_out=true;
    bool ps2_kbclk_in=true, ps2_kbdat_in=true;
};
constexpr ven_ui::Timing timing{32,128,1152};

static uint64_t start(ven_ui::Input &input, Top &top, uint64_t &cycle) {
    for (unsigned n=0;n<4096;++n) {
        ven_ui::pc_keyboard_drive(input,cycle++,top);
        if (input.inflight()) return cycle-1;
    }
    throw std::runtime_error("no owned byte");
}

static void mapping() {
    // Compare the binding against independently selected mux cases, including
    // translation, AUTOACK priority, reply priority and full/read overlap.
    for (unsigned flags=0;flags<128;++flags) for (unsigned raw=0;raw<256;++raw) {
        Root r;
        r.K(translate)=flags&1; r.K(keyb_translate_escape)=flags&2;
        r.K(wtk_q)=flags&4; r.K(ps2_kb_reply_done)=flags&8;
        r.K(keyb_fifo_full)=flags&16; r.K(__Vcellinp__keyb_fifo__rdreq)=flags&32;
        r.K(keyb_fifo_empty)=flags&64;
        r.K(keyb_reply)=0xee; r.K(keyb_recv_buffer)=raw; r.K(trans)=raw ^ 0x55;
        r.K(keyb_fifo_q)=0x6a; r.K(keyb_fifo__DOT__wr_index)=63;
        ven_ui::Input input(timing,nullptr);
        const auto e=ven_ui::pc_keyboard_before(input,0,r,false);
        const uint8_t translation=(flags&1) ? ((raw^0x55) | ((flags&2)?0x80:0)) : raw;
        const uint8_t selected=(flags&4)?0xfa:(flags&8)?0xee:translation;
        CHECK(e.proof.produced_value==selected);
        CHECK(e.proof.translated_value==translation);
        CHECK(e.proof.old_write_index==63);
        CHECK(e.proof.full==bool(flags&16));
        CHECK(e.consumed==(bool(flags&32) && !(flags&64)));
        CHECK(e.consumed_value==0x6a);
    }
}

static void ordinary(bool translated) {
    Top top; auto &r=top.root;
    r.K(translate)=translated;
    r.K(keyb_fifo__DOT__wr_index)=63;
    ven_ui::Input input(timing,nullptr);
    const std::string command="1 key enter\n";
    input.feed(command.data(),command.size(),0);
    uint64_t cycle=0;
    for (unsigned n=0;n<3;++n) {
        const uint8_t raw=n==1?0xf0:0x5a;
        const uint64_t launched=start(input,top,cycle);
        CHECK(input.owned_byte()==raw);
        cycle=launched+timing.half*22;
        r.K(keyb_recv_final)=true; r.K(keyb_recv_buffer)=raw; r.K(trans)=0x1c;
        // Production translator sets F0 escape before recv_final.
        r.K(keyb_translate_escape)=translated && n!=0;
        r.K(kb_fifo_wrreq)=!translated || n!=1;
        auto edge=ven_ui::pc_keyboard_before(input,cycle,r,false);
        if (r.K(kb_fifo_wrreq)) {
            r.K(keyb_fifo__DOT__mem)[r.K(keyb_fifo__DOT__wr_index)]=edge.proof.produced_value;
            r.K(keyb_fifo__DOT__wr_index)=(r.K(keyb_fifo__DOT__wr_index)+1)&63;
        }
        r.K(keyb_translate_escape)=translated && n==1;
        ven_ui::pc_keyboard_after(input,cycle,r,edge);
        CHECK(!input.failed());
        r.K(keyb_recv_final)=false; ++cycle;
    }
    CHECK(input.pending()==0 && !input.inflight() && input.finish(cycle));
    CHECK(r.K(keyb_fifo__DOT__mem)[63]==(translated?0x1c:0x5a));
    CHECK(r.K(keyb_fifo__DOT__mem)[translated?0:1]==(translated?0x9c:0x5a));
}

static void mutations() {
    for (unsigned mutation=0;mutation<8;++mutation) {
        Top top; auto &r=top.root;
        ven_ui::Input input(timing,nullptr);
        const std::string command="1 key enter\n";
        input.feed(command.data(),command.size(),0);
        uint64_t cycle=0;
        cycle=start(input,top,cycle)+timing.half*22;
        r.K(keyb_recv_final)=true; r.K(keyb_recv_buffer)=0x5a;
        r.K(kb_fifo_wrreq)=mutation!=0;
        r.K(keyb_fifo_full)=mutation==1;
        r.K(wtk_q)=mutation==2; r.K(ps2_kb_reply_done)=mutation==3;
        r.K(cmd_self_test)=mutation==4;
        auto edge=ven_ui::pc_keyboard_before(input,cycle,r,mutation==5);
        r.K(keyb_fifo__DOT__wr_index)=mutation==6?0:1;
        r.K(keyb_fifo__DOT__mem)[0]=mutation==7?0x00:0x5a;
        ven_ui::pc_keyboard_after(input,cycle,r,edge);
        CHECK(input.failed() && input.accepted_front()==0 && input.pending()==1);
    }
}

static void no_input_and_timeout() {
    Top top;
    ven_ui::Input input(timing,nullptr);
    for (uint64_t cycle=0;cycle<10000;++cycle) {
        top.ps2_kbclk_out=cycle%7!=0; top.ps2_kbdat_out=cycle%11!=0;
        ven_ui::pc_keyboard_drive(input,cycle,top);
        CHECK(top.ps2_kbclk_in==top.ps2_kbclk_out);
        CHECK(top.ps2_kbdat_in==top.ps2_kbdat_out);
        auto edge=ven_ui::pc_keyboard_before(input,cycle,top.root,false);
        ven_ui::pc_keyboard_after(input,cycle,top.root,edge);
    }
    CHECK(input.finish(10000));
    // A pre-existing owned raw F0 is not silently replayed after timeout.
    ven_ui::Input prefix(timing,nullptr); Top clean;
    const std::string command="1 key enter\n";
    prefix.feed(command.data(),command.size(),0); uint64_t cycle=0;
    for (uint8_t raw : {uint8_t(0x5a),uint8_t(0xf0)}) {
        cycle=start(prefix,clean,cycle)+timing.half*22;
        auto &r=clean.root; r.K(keyb_recv_final)=true; r.K(keyb_recv_buffer)=raw;
        r.K(kb_fifo_wrreq)=true;
        auto edge=ven_ui::pc_keyboard_before(prefix,cycle,r,false);
        r.K(keyb_fifo__DOT__mem)[r.K(keyb_fifo__DOT__wr_index)++]=raw;
        ven_ui::pc_keyboard_after(prefix,cycle,r,edge); ++cycle;
        r.K(keyb_recv_final)=false;
    }
    CHECK(prefix.prefix_owned() && !prefix.failed());
    clean.root.K(keyb_timeout)=1;
    (void)ven_ui::pc_keyboard_before(prefix,cycle,clean.root,false);
    CHECK(prefix.failed());
}

int main() {
    mapping(); ordinary(false); ordinary(true); mutations(); no_input_and_timeout();
    std::cout << "PC-KEYBOARD-BINDING-HOST-OK mux_cases=32768 negative_controls=9 rtl_execution=0\n";
}
#undef K
