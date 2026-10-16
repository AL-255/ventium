// Appended to the existing real-wire Harness; no hierarchical state writes.
static void ordinary_retained() {
    for (bool translated : {false,true}) for (uint64_t half : {32,64,1667,2917}) {
        Harness h(translated); h.start("1 key enter\n",half);
        h.finish_input(translated ? std::vector<uint8_t>{0x1c,0x9c} :
                                  std::vector<uint8_t>{0x5a,0xf0,0x5a});
    }
}

static void fill_during_frame(Harness &h) {
    h.start("1 key enter\n",1667); h.wait_start();
    for (unsigned n=0;n<10000 && h.d.controller_state!=10;++n) h.step();
    CHECK(h.d.controller_state==10 && !h.input->failed());
    for (unsigned n=0;n<64;++n) {
        h.write(0,0xf4);
        for (unsigned k=0;k<8;++k) h.step();
        CHECK(!h.d.input_full);
    }
    CHECK(h.d.fifo_full);
    for (unsigned n=0;n<100000 && !h.input->awaiting_commit();++n) h.step();
    CHECK(h.input->awaiting_commit() && !h.input->failed() && h.input->accepted_front()==0);
    CHECK(h.d.rx_pending && h.d.write_index==0);
}

static void held_retained() {
    for (bool translated : {false,true}) for (bool mode_change : {false,true}) {
        Harness h(translated); fill_during_frame(h);
        if (mode_change) { h.write(4,0x60); h.write(0,translated?0x01:0x41); }
        for (unsigned n=0;n<5000;++n) {
            h.step();
            CHECK(!h.input->failed() && h.input->awaiting_commit() && h.input->accepted_front()==0);
            CHECK(h.d.rx_pending && h.d.pending_value==(translated?0x1c:0x5a));
        }
        CHECK(h.read(0)==0xfa);
        CHECK(!h.input->failed() && !h.input->awaiting_commit() && h.input->accepted_front()==1);
        if (mode_change) { h.write(4,0x60); h.write(0,translated?0x41:0x01); }
        std::vector<uint8_t> expected(64,0xfa);
        if (translated) { expected.push_back(0x1c); expected.push_back(0x9c); }
        else { expected.push_back(0x5a); expected.push_back(0xf0); expected.push_back(0x5a); }
        h.finish_input(expected);
    }
}

static void collision_retained() {
    for (bool translated : {false,true}) {
        Harness h(translated); h.start("1 key enter\n",64);
        bool injected=false,witnessed=false;
        h.preedge_stimulus=[&](Harness &x) {
            if (x.d.recv_final && x.d.autoack) witnessed=true;
            if (!injected && x.d.controller_state==12 && !x.d.synced_clock &&
                x.d.synced_data && x.d.ps2_kbclk && x.d.ps2_kbdat &&
                x.input->accepted_front()==0 && x.d.recv_raw==0x5a) {
                x.d.io_cs=1; x.d.io_address=0; x.d.io_writedata=0xf4; x.d.io_write=1;
                injected=true;
            } else x.d.io_write=0;
        };
        h.finish_input(translated ? std::vector<uint8_t>{0x1c,0xfa,0x9c} :
                                  std::vector<uint8_t>{0x5a,0xfa,0xf0,0x5a});
        CHECK(injected && witnessed);
    }
}

static void flush_retained() {
    for (bool translated : {false,true}) for (bool selftest : {false,true}) {
        Harness h(translated); fill_during_frame(h);
        if (selftest) h.write(4,0xaa);
        else { h.d.rst_n=0; h.step(); }
        CHECK(h.input->failed() && h.input->accepted_front()==0 && !h.d.rx_pending);
    }
}

int main() {
    ordinary_retained(); held_retained(); collision_retained(); flush_retained();
    std::cout<<"UI-RETAINED-RTL-OK ordinary=8 retained=4 collisions=2 flush_refusals=4 full_pc=0\n";
}
