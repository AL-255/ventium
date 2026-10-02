// Pure-host microtests. Source only; not compiled or executed during preparation.
#include "ui_input_host.h"
#include <algorithm>
#include <functional>
#include <iostream>
#include <sys/types.h>

#define CHECK(expr) do { if (!(expr)) throw std::runtime_error(#expr); } while (0)
using ven_ui::Input;
using ven_ui::ReceiveProof;
static constexpr ven_ui::Timing fast{32,128,1152};
static void feed(Input &i, const std::string &s) { i.feed(s.data(),s.size(),0); }
static uint64_t start_byte(Input &i, uint64_t &cycle) {
    for (unsigned n=0; n<2048; ++n) {
        i.drive(cycle++,false,true,true,true);
        if (i.inflight()) return cycle-1;
    }
    throw std::runtime_error("byte did not start within bound");
}
static ReceiveProof stored(uint8_t raw, uint8_t index=0) {
    ReceiveProof p;
    p.final=true; p.raw=raw; p.write_request=true;
    p.translated_value=raw; p.produced_value=raw; p.old_write_index=index;
    p.new_write_index=(index+1)&63; p.post_memory_at_old_write_index=raw;
    return p;
}
static void accept(Input &i, uint64_t launch, uint64_t &cycle, ReceiveProof p) {
    while (cycle<=launch+fast.half*22+2) i.drive(cycle++,false,true,true,false);
    i.accepted_edge(cycle-1,p);
}
static void chord_test() {
    std::vector<uint8_t> b;
    CHECK(ven_ui::chord_bytes("ctrl+esc",b));
    CHECK(b==std::vector<uint8_t>({0x14,0x76,0xf0,0x76,0xf0,0x14}));
    CHECK(ven_ui::chord_bytes("alt+f4",b));
    CHECK(b==std::vector<uint8_t>({0x11,0x0c,0xf0,0x0c,0xf0,0x11}));
    CHECK(ven_ui::chord_bytes("up",b));
    CHECK(b==std::vector<uint8_t>({0xe0,0x75,0xe0,0xf0,0x75}));
    CHECK(ven_ui::chord_bytes("ctrl+alt+shift+tab",b));
    CHECK(b==std::vector<uint8_t>({0x14,0x11,0x12,0x0d,0xf0,0x0d,
                                 0xf0,0x12,0xf0,0x11,0xf0,0x14}));
    for (const char *s : {"", "ctrl", "ctrl+ctrl+esc", "esc+ctrl", "ctrl+",
                         "Ctrl+esc", "type:winver", "_", "unknown", "ctrl++esc",
                         "alt+shift+ctrl+esc+tab"}) CHECK(!ven_ui::chord_bytes(s,b));
    for (char c='a'; c<='z'; ++c) CHECK(ven_ui::chord_bytes(std::string(1,c),b));
    for (char c='0'; c<='9'; ++c) CHECK(ven_ui::chord_bytes(std::string(1,c),b));
    CHECK(ven_ui::chord_bytes("shift+minus",b)); // Explicit shift, never '_' workaround.
}
static void framing_test() {
    Input i(fast,nullptr);
    feed(i,"1 key ct"); CHECK(i.pending()==0);
    feed(i,"rl+esc\n"); CHECK(i.pending()==1 && i.highest_id()==1);
    feed(i,"1 key enter\n"); CHECK(i.pending()==1);
    feed(i,"2 key bad\n"); CHECK(i.pending()==1 && i.highest_id()==2);
    feed(i,"2 key enter\n"); CHECK(i.pending()==1);
    feed(i,"3 capture\n"); CHECK(i.pending()==2);
    feed(i,"4 key tab"); i.writer_eof(0); CHECK(i.pending()==2);
    feed(i,"4 key tab\n"); CHECK(i.pending()==3);
    feed(i,"5 key enter\r\n"); CHECK(i.pending()==3);
    feed(i,std::string(ven_ui::kMaxLine+1,'x')+"\n"); CHECK(i.pending()==3);
    const char nul[]={'6',' ','k','e','y',' ','a','\0','\n'};
    i.feed(nul,sizeof nul,0); CHECK(i.pending()==3);
    feed(i,"18446744073709551616 key enter\n0 capture\n-1 capture\n");
    CHECK(i.pending()==3 && !i.failed());
    Input q(fast,nullptr);
    for (unsigned n=1;n<=ven_ui::kMaxCommands+2;++n) feed(q,std::to_string(n)+" key tab\n");
    CHECK(q.pending()==ven_ui::kMaxCommands && q.highest_id()==ven_ui::kMaxCommands+2);
    CHECK(!q.finish(0));
}
static void timing_and_bits_test() {
    const auto ordinary=ven_ui::Timing::ordinary(45000000);
    CHECK(ordinary.half==1875 && ordinary.idle==4500);
    CHECK(ven_ui::Timing::ordinary(70000000).half==2917);
    CHECK(ven_ui::Timing::ordinary(45000000,32).half==32);
    for (uint64_t half : {uint64_t(1),uint64_t(24),uint64_t(31),uint64_t(20001)}) {
        bool threw=false; try { (void)ven_ui::Timing::ordinary(45000000,half); }
        catch (const std::runtime_error &) { threw=true; } CHECK(threw);
    }
    Input i(fast,nullptr); feed(i,"1 key ctrl+esc\n"); uint64_t cycle=0;
    const uint64_t launch=start_byte(i,cycle); CHECK(i.owned_byte()==0x14);
    unsigned ones=0;
    for (unsigned bit=0;bit<11;++bit) {
        const auto high=i.drive(launch+bit*64,false,true,true,false);
        const auto low=i.drive(launch+bit*64+32,false,true,true,false);
        CHECK(high.clock && !low.clock && high.data==low.data);
        if (bit==0) CHECK(!high.data);
        else if (bit==10) CHECK(high.data);
        else if (high.data) ++ones;
        if (bit>=1 && bit<=8) CHECK(high.data==bool((0x14>>(bit-1))&1));
    }
    CHECK(ones%2==1);
    CHECK(i.drive(launch+704,false,true,true,false).clock);
    CHECK(i.inflight() && i.accepted_front()==0 && i.pending()==1);
}
static void ordered_capture_test() {
    Input i(fast,nullptr); feed(i,"1 key enter\n2 capture\n3 key tab\n");
    uint64_t cycle=0,id=0;
    CHECK(!i.capture_ready(id));
    for (uint8_t b : {uint8_t(0x5a),uint8_t(0xf0),uint8_t(0x5a)}) {
        const uint64_t launch=start_byte(i,cycle); CHECK(i.owned_byte()==b);
        accept(i,launch,cycle,stored(b,63)); CHECK(!i.failed());
    }
    CHECK(i.capture_ready(id) && id==2 && i.pending()==2);
    for (unsigned n=0;n<512;++n) i.drive(cycle++,false,true,true,true);
    CHECK(!i.inflight());
    i.capture_result(2,cycle,"raw_00000.ppm",true);
    CHECK(i.pending()==1 && !i.failed());
    const uint64_t tab_launch=start_byte(i,cycle);
    CHECK(tab_launch<cycle && i.owned_byte()==0x0d);
    CHECK(!i.finish(cycle)); // An accepted command with unfinished bytes is not success.
}
static void inhibition_and_ownership_test() {
    Input i(fast,nullptr); feed(i,"1 key enter\n");
    uint64_t cycle=0;
    for (unsigned n=0;n<2000;++n) {
        const auto l=i.drive(cycle++,false,false,true,true);
        CHECK(l.clock && l.data && !i.inflight());
    }
    CHECK(i.pending()==1 && i.accepted_front()==0 && !i.failed());
    const uint64_t launch=start_byte(i,cycle);
    i.drive(launch+50,false,false,true,false);
    CHECK(i.failed() && i.inflight() && i.pending()==1 && i.accepted_front()==0);
    CHECK(i.owned_byte()==0x5a && !i.finish(cycle));
    Input timeout(fast,nullptr); feed(timeout,"1 key a\n"); cycle=0;
    const uint64_t start=start_byte(timeout,cycle);
    timeout.drive(start+fast.accept_limit+1,false,true,true,true);
    CHECK(timeout.failed() && timeout.inflight() && timeout.accepted_front()==0);
    Input reset(fast,nullptr); feed(reset,"1 key a\n"); cycle=0; start_byte(reset,cycle);
    reset.drive(cycle,true,true,true,true);
    CHECK(reset.failed() && reset.pending()==1);
}
static void fifo_collision_proof_test() {
    const std::vector<std::function<void(ReceiveProof&)>> faults={
        [](auto&p){p.autoack=true;}, [](auto&p){p.reply=true;},
        [](auto&p){p.full=true;p.read_request=false;}, [](auto&p){p.clear=true;},
        [](auto&p){p.reset=true;}, [](auto&p){p.write_request=false;},
        [](auto&p){p.new_write_index=p.old_write_index;},
        [](auto&p){p.post_memory_at_old_write_index^=1;},
        [](auto&p){p.produced_value^=1;},
        [](auto&p){p.raw^=1;}
    };
    for (const auto &fault : faults) {
        Input i(fast,nullptr); feed(i,"1 key enter\n"); uint64_t cycle=0;
        const uint64_t launch=start_byte(i,cycle);
        auto p=stored(0x5a); fault(p); accept(i,launch,cycle,p);
        CHECK(i.failed() && i.accepted_front()==0 && i.inflight());
    }
    Input allowed(fast,nullptr); feed(allowed,"1 key enter\n"); uint64_t cycle=0;
    const uint64_t launch=start_byte(allowed,cycle);
    auto p=stored(0x5a,63); p.full=true; p.read_request=true;
    accept(allowed,launch,cycle,p); CHECK(!allowed.failed() && allowed.accepted_front()==1);
    // Translated F0 is a parser-state receipt, not a FIFO scan-byte receipt.
    Input prefix(fast,nullptr); feed(prefix,"1 key enter\n"); cycle=0;
    auto start=start_byte(prefix,cycle); accept(prefix,start,cycle,stored(0x5a));
    start=start_byte(prefix,cycle); p=stored(0xf0); p.translated=true;
    p.escape_before=true; p.escape_after=true; p.write_request=false; p.autoack=true;
    accept(prefix,start,cycle,p); CHECK(!prefix.failed() && prefix.accepted_front()==2);
    Input badprefix(fast,nullptr); feed(badprefix,"1 key enter\n"); cycle=0;
    start=start_byte(badprefix,cycle); accept(badprefix,start,cycle,stored(0x5a));
    start=start_byte(badprefix,cycle); p.escape_after=false;
    accept(badprefix,start,cycle,p); CHECK(badprefix.failed() && badprefix.accepted_front()==1);
}
static void fifo_security_test(const std::string &scratch) {
    std::string name=scratch+"/host-ui.XXXXXX";
    std::vector<char> buffer(name.begin(),name.end()); buffer.push_back(0);
    char *created=mkdtemp(buffer.data()); CHECK(created);
    const std::string dir=created, fifo=dir+"/input.fifo";
    CHECK(chmod(dir.c_str(),0700)==0);
    { Input i(fast,nullptr); i.open_fifo(fifo);
      bool twice=false; try { i.open_fifo(fifo); }
      catch (const std::runtime_error &) { twice=true; } CHECK(twice);
      const int writer=open(fifo.c_str(),O_WRONLY|O_NONBLOCK|O_CLOEXEC); CHECK(writer>=0);
      const char line[]="1 key ctrl+esc\n";
      CHECK(write(writer,line,sizeof line-1)==ssize_t(sizeof line-1)); close(writer);
      i.poll(0); CHECK(i.pending()==1);
      const int partial=open(fifo.c_str(),O_WRONLY|O_NONBLOCK|O_CLOEXEC); CHECK(partial>=0);
      const char fragment[]="2 key ent";
      CHECK(write(partial,fragment,sizeof fragment-1)==ssize_t(sizeof fragment-1)); close(partial);
      i.poll(1); CHECK(i.pending()==1 && i.highest_id()==1);
      const int complete=open(fifo.c_str(),O_WRONLY|O_NONBLOCK|O_CLOEXEC); CHECK(complete>=0);
      const char retry[]="2 key enter\n";
      CHECK(write(complete,retry,sizeof retry-1)==ssize_t(sizeof retry-1)); close(complete);
      i.poll(2); CHECK(i.pending()==2 && !i.failed()); }
    struct stat st{}; CHECK(lstat(fifo.c_str(),&st)==0 && S_ISFIFO(st.st_mode));
    CHECK(unlink(fifo.c_str())==0);
    const int file=open(fifo.c_str(),O_CREAT|O_EXCL|O_WRONLY,0600); CHECK(file>=0); close(file);
    bool rejected=false; try { Input i(fast,nullptr); i.open_fifo(fifo); }
    catch (const std::runtime_error &) { rejected=true; } CHECK(rejected);
    CHECK(unlink(fifo.c_str())==0);
    CHECK(symlink("nonexistent",fifo.c_str())==0);
    rejected=false; try { Input i(fast,nullptr); i.open_fifo(fifo); }
    catch (const std::runtime_error &) { rejected=true; } CHECK(rejected);
    CHECK(unlink(fifo.c_str())==0);
    // Active endpoint identity and permission guards, not merely startup checks.
    for (unsigned fault=0;fault<5;++fault) {
        { Input i(fast,nullptr); i.open_fifo(fifo);
          if (fault==0) { CHECK(unlink(fifo.c_str())==0); CHECK(mkfifo(fifo.c_str(),0600)==0); }
          else if (fault==1) CHECK(chmod(fifo.c_str(),0640)==0);
          else if (fault==2) { CHECK(unlink(fifo.c_str())==0); CHECK(symlink("nonexistent",fifo.c_str())==0); }
          else if (fault==3) CHECK(chmod(dir.c_str(),0750)==0);
          else CHECK(unlink(fifo.c_str())==0);
          i.poll(3); CHECK(i.failed()); }
        CHECK(chmod(dir.c_str(),0700)==0);
        if (fault!=4) CHECK(unlink(fifo.c_str())==0);
    }
    CHECK(chmod(dir.c_str(),0711)==0);
    rejected=false; try { Input i(fast,nullptr); i.open_fifo(fifo); }
    catch (const std::runtime_error &) { rejected=true; } CHECK(rejected);
    CHECK(chmod(dir.c_str(),0700)==0 && rmdir(dir.c_str())==0);
}
static void capture_failure_test() {
    for (const char *path : {static_cast<const char *>(nullptr),""}) {
        Input i(fast,nullptr); feed(i,"1 capture\n");
        i.capture_result(1,0,path,true);
        CHECK(i.failed() && i.pending()==1 && !i.finish(0));
    }
    Input unavailable(fast,nullptr); feed(unavailable,"1 capture\n");
    unavailable.capture_result(1,0,nullptr,false);
    CHECK(!unavailable.failed() && unavailable.finish(0));
    Input failed(fast,nullptr); feed(failed,"1 capture\n"); failed.capture_write_failed(0);
    CHECK(failed.failed() && failed.pending()==1 && !failed.finish(0));
    CHECK(!ven_ui::complete_raw_file(nullptr,true));
    FILE *full=fopen("/dev/full","wb"); CHECK(full);
    bool ok=fprintf(full,"P6\n1 1\n255\n")>=0;
    if (fputc(0,full)==EOF || fputc(0,full)==EOF || fputc(0,full)==EOF) ok=false;
    CHECK(!ven_ui::complete_raw_file(full,ok)); // Includes buffered fclose failure.
}
static void prefix_ownership_test() {
    // The DUT's own mux may coherently write a wrong MAKE after a timeout.
    // Receipt must use an independent accepted-F0 obligation, not trust that mux.
    auto through_prefix=[](Input &i,uint64_t &cycle) {
        feed(i,"1 key enter\n");
        auto start=start_byte(i,cycle); auto p=stored(0x5a);
        p.translated=true; p.translated_value=p.produced_value=p.post_memory_at_old_write_index=0x1c;
        accept(i,start,cycle,p); CHECK(!i.failed());
        start=start_byte(i,cycle); p=stored(0xf0); p.translated=true;
        p.escape_before=p.escape_after=true; p.write_request=false;
        accept(i,start,cycle,p);
        CHECK(!i.failed() && i.prefix_owned() && i.accepted_front()==2 && !i.inflight());
    };
    for (bool lost : {false,true}) {
        Input i(fast,nullptr); uint64_t cycle=0; through_prefix(i,cycle);
        const uint64_t start=start_byte(i,cycle); auto p=stored(0x5a);
        p.translated=true; p.escape_before=!lost;
        const uint8_t actual=lost?0x1c:0x9c;
        p.translated_value=p.produced_value=p.post_memory_at_old_write_index=actual;
        accept(i,start,cycle,p);
        if (lost) CHECK(i.failed() && i.prefix_owned() && i.accepted_front()==2 && i.pending()==1);
        else CHECK(!i.failed() && !i.prefix_owned() && i.finish(cycle));
    }
    for (unsigned fault=0;fault<4;++fault) {
        Input i(fast,nullptr); uint64_t cycle=0; through_prefix(i,cycle);
        i.prefix_context_before(cycle,fault!=0,fault!=1,fault==2,fault==3);
        CHECK(i.failed() && i.prefix_owned() && i.accepted_front()==2 && !i.inflight());
    }
    // A raw-mode F0 is also owned; a mode switch must not reinterpret its suffix.
    Input raw(fast,nullptr); feed(raw,"1 key enter\n"); uint64_t cycle=0;
    auto start=start_byte(raw,cycle); accept(raw,start,cycle,stored(0x5a));
    start=start_byte(raw,cycle); accept(raw,start,cycle,stored(0xf0));
    CHECK(raw.prefix_owned()); raw.prefix_context_before(cycle,true,false,false,false);
    CHECK(raw.failed() && raw.accepted_front()==2);
}
int main(int argc,char **argv) {
    if (argc!=2) { std::cerr<<"requires existing isolated scratch directory\n"; return 2; }
    try {
        chord_test(); framing_test(); timing_and_bits_test(); ordered_capture_test();
        inhibition_and_ownership_test(); fifo_collision_proof_test(); fifo_security_test(argv[1]);
        capture_failure_test();
        prefix_ownership_test();
        CHECK(ven_ui::forbidden_ui_option("--save-at-retired-pc"));
        CHECK(ven_ui::forbidden_ui_option("--snapshot-v4"));
        CHECK(ven_ui::forbidden_ui_option("--kb"));
        CHECK(!ven_ui::forbidden_ui_option("--fb-out"));
    } catch (const std::exception &e) {
        std::cerr<<"UI-HOST-MICRO-FAIL: "<<e.what()<<"\n"; return 1;
    }
    std::cout<<"UI-HOST-MICRO-OK\n"; return 0;
}
