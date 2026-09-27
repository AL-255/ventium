#pragma once
// Host-only, pre-edge observer. No DUT references, writes, or eval() calls.
// The adapter supplies literal settled signals and profile-derived FSM IDs.
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

struct MemoryGeometryStates { unsigned load, exec, pipe, walk, ext_kind; const char* profile; };
struct MemoryGeometrySample {
    uint64_t cycle=0;
    bool reset=false, l1_enabled=false;
    unsigned state=0, walk_return=0;
    uint32_t eip=0, q_pc=0, pipe_pc=0;
    unsigned q_kind=0, q_src_width=0, q_dst_width=0;
    bool pipe_active=false, pipe_new_load=false, pipe_commit=false, fsm_enabled=false;
    bool chain_accept=false;
    bool req=false, we=false, beat_ack=false, final_ack=false;
    uint32_t physical=0, linear=0;
    unsigned strobes=0, extent=0;
    bool xp_cross=false, xp_pending=false, fx_active=false, fx_start=false;
    unsigned fx_phase=0;
    bool arvalid=false, arready=false, ar_narrow=false;
    uint64_t araddr=0;
    unsigned arid=0, arlen=0, arsize=0, arburst=0;
    bool rvalid=false, rready=false, rlast=false;
    unsigned rid=0, rresp=0;
    uint32_t rdata=0;
};

class MemoryGeometryProbe {
public:
    bool enabled=false;
private:
    FILE* log_=nullptr;
    MemoryGeometryStates states_{};
    bool configured_=false, finished_=false, sampled_=false, read_active_=false;
    uint32_t target_=0, consumer_=0;
    bool have_consumer_=false;
    uint64_t expected_=0, limit_=0, lines_=0, last_cycle_=0, final_reads_=0, fast_commits_=0;
    uint64_t ar_count_=0, r_count_=0, read_serial_=0;
    unsigned read_id_=0, read_left_=0;
    bool read_narrow_=false;

    static uint64_t number(const char* text) {
        if (!text || !*text || *text=='-') fail_static("missing/invalid numeric option");
        errno=0; char* end=nullptr;
        auto value=std::strtoull(text,&end,0);
        if (errno || *end) fail_static("invalid numeric option");
        return value;
    }
    [[noreturn]] static void fail_static(const char* why) {
        std::fprintf(stderr,"MEM-GEOMETRY-ERROR: %s\n",why); std::exit(2);
    }
    [[noreturn]] void fail(const char* why) {
        if(log_) { std::fprintf(log_,"{\"type\":\"error\",\"reason\":\"%s\"}\n",why); std::fflush(log_); }
        fail_static(why);
    }
    void room() {
        if(lines_>=limit_) fail("observer overflow; trace incomplete");
        ++lines_;
        if(std::ferror(log_)) fail("observer I/O failure");
    }
    void accept_r(const MemoryGeometrySample& s) {
        if(!read_active_) fail("R handshake without recorded AR");
        if(s.rid!=read_id_) fail("R ID does not match recorded AR");
        if(s.rlast!=(read_left_==1)) fail("R length/last mismatch");
        room();
        std::fprintf(log_,"{\"type\":\"axi_r\",\"cycle\":%llu,\"transaction\":%llu,\"id\":%u,\"last\":%u,\"resp\":%u,\"data\":%u,\"narrow\":%u}\n",
            (unsigned long long)s.cycle,(unsigned long long)read_serial_,s.rid,unsigned(s.rlast),s.rresp,s.rdata,unsigned(read_narrow_));
        ++r_count_;
        if(--read_left_==0) read_active_=false;
    }
public:
    MemoryGeometryProbe() {
        const char* path=std::getenv("VEN_MEM_GEOM_LOG");
        if(!path) return; // inert: no option parsing, files or DUT dependency
        enabled=true;
        const auto target=number(std::getenv("VEN_MEM_GEOM_PC"));
        if(target>UINT32_MAX) fail_static("target PC overflow");
        target_=uint32_t(target);
        if(const char* value=std::getenv("VEN_MEM_GEOM_CONSUMER")) {
            const auto pc=number(value);
            if(pc>UINT32_MAX) fail_static("consumer PC overflow");
            consumer_=uint32_t(pc); have_consumer_=true;
        }
        expected_=number(std::getenv("VEN_MEM_GEOM_EXPECT_READS"));
        if(!expected_) fail_static("expected read count must be positive");
        limit_=std::getenv("VEN_MEM_GEOM_MAX_RECORDS") ? number(std::getenv("VEN_MEM_GEOM_MAX_RECORDS")) : 500000;
        if(!limit_) fail_static("record limit must be positive");
        log_=std::fopen(path,"wx"); // receipt is never overwritten, including symlinks
        if(!log_) fail_static("cannot exclusively create observer log");
    }
    MemoryGeometryProbe(const MemoryGeometryProbe&)=delete;
    MemoryGeometryProbe& operator=(const MemoryGeometryProbe&)=delete;
    ~MemoryGeometryProbe() {
        if(enabled && !finished_) fail("finish was not called; trace incomplete");
    }
    void unsupported() { if(enabled) fail("unsupported build/adapter"); }
    void configure(MemoryGeometryStates states) {
        if(!enabled) return;
        if(configured_ || !states.profile || std::strlen(states.profile)!=64 ||
           std::strspn(states.profile,"0123456789abcdef")!=64)
            fail("invalid/duplicate profile configuration");
        const unsigned ids[]={states.load,states.exec,states.pipe,states.walk};
        for(unsigned i=0;i<4;i++) {
            if(ids[i]>=128) fail("invalid FSM profile");
            for(unsigned j=0;j<i;j++) if(ids[i]==ids[j]) fail("invalid FSM profile");
        }
        if(states.ext_kind>=32) fail("invalid kind profile");
        states_=states; configured_=true; room();
        std::fprintf(log_,"{\"type\":\"begin\",\"schema\":1,\"target_pc\":%u,\"consumer_pc\":%u,\"has_consumer\":%u,\"expected_reads\":%llu,\"profile_sha256\":\"%s\",\"load_state\":%u,\"exec_state\":%u,\"pipe_state\":%u,\"walk_state\":%u,\"ext_kind\":%u}\n",
            target_,consumer_,unsigned(have_consumer_),(unsigned long long)expected_,states.profile,
            states.load,states.exec,states.pipe,states.walk,states.ext_kind);
    }
    void pre_edge(const MemoryGeometrySample& s) {
        if(!enabled) return;
        if(!configured_) fail("missing profile/adapter configuration");
        if(finished_ || (sampled_ && s.cycle!=last_cycle_+1)) fail("duplicate/skipped sample clock");
        sampled_=true; last_cycle_=s.cycle;
        if(s.reset) {
            // Do not silently discard an outstanding transaction on reset.
            if(read_active_) fail("reset with outstanding AXI read");
            room(); std::fprintf(log_,"{\"type\":\"reset\",\"cycle\":%llu}\n",(unsigned long long)s.cycle);
            return;
        }
        if(!s.l1_enabled) fail("observer requires active L1/AXI path");
        // A next-read admission has a distinct packet owner on the old packet's
        // final-ACK edge. This first adapter intentionally does not reconstruct
        // that sideband; refuse the entire receipt rather than misattribute it.
        if(s.chain_accept) fail("memory-chain admission unsupported by observer");
        if(s.pipe_commit && s.state!=states_.pipe) fail("FSM profile disagrees with pipe commit");
        const bool walk=s.state==states_.walk;
        const unsigned producer=walk?s.walk_return:s.state;
        uint32_t owner_pc=0; const char* owner="none"; bool known=false;
        if(producer==states_.pipe && (walk || s.pipe_active || s.pipe_new_load || s.pipe_commit)) {
            owner_pc=s.pipe_active?s.pipe_pc:s.eip;
            owner=s.pipe_active?"pipe-held":"pipe-live"; known=true;
        } else if((producer==states_.load || producer==states_.exec) && s.q_kind==states_.ext_kind) {
            owner_pc=s.q_pc; owner="slow-ext"; known=true;
        }
        const bool target=known && owner_pc==target_;
        const bool consumer=known && have_consumer_ && owner_pc==consumer_;
        const bool final_read=target && !walk && s.fsm_enabled && s.final_ack &&
            ((s.state==states_.load && (!s.xp_cross || s.xp_pending)) ||
             (s.state==states_.pipe && s.pipe_commit && (s.pipe_active || s.pipe_new_load)));
        if(target || consumer) {
            room();
            std::fprintf(log_,"{\"type\":\"core\",\"cycle\":%llu,\"owner\":\"%s\",\"owner_pc\":%u,\"state\":%u,\"walk\":%u,\"walk_return\":%u,\"req\":%u,\"we\":%u,\"physical\":%u,\"linear\":%u,\"strobes\":%u,\"extent\":%u,\"beat_ack\":%u,\"accepted\":%u,\"final_ack\":%u,\"final_read\":%u,\"pipe_commit\":%u,\"fsm_enabled\":%u,\"pipe_active\":%u,\"xp_pending\":%u,\"xp_cross\":%u,\"fx_active\":%u,\"fx_start\":%u,\"fx_phase\":%u,\"q_source_bytes\":%u,\"q_destination_bytes\":%u}\n",
                (unsigned long long)s.cycle,owner,owner_pc,s.state,unsigned(walk),s.walk_return,unsigned(s.req),unsigned(s.we),s.physical,s.linear,s.strobes,s.extent,
                unsigned(s.beat_ack),unsigned(s.req&&s.beat_ack),unsigned(s.final_ack),unsigned(final_read),unsigned(s.pipe_commit),unsigned(s.fsm_enabled),unsigned(s.pipe_active),
                unsigned(s.xp_pending),unsigned(s.xp_cross),unsigned(s.fx_active),unsigned(s.fx_start),s.fx_phase,s.q_src_width,s.q_dst_width);
            if(target && !walk && s.req && s.we) fail("target EXT producer issued a write");
        }
        if(final_read) ++final_reads_;
        if(target && !walk && s.pipe_commit) ++fast_commits_;
        // Log literal AXI offers and handshakes independently. These are not
        // attributed to the current core PC: a previous fill can still drain.
        if(s.arvalid) {
            room();
            std::fprintf(log_,"{\"type\":\"axi_ar_offer\",\"cycle\":%llu,\"address\":%llu,\"id\":%u,\"len\":%u,\"size\":%u,\"burst\":%u,\"narrow\":%u,\"accepted\":%u}\n",
                (unsigned long long)s.cycle,(unsigned long long)s.araddr,s.arid,s.arlen,s.arsize,s.arburst,unsigned(s.ar_narrow),unsigned(s.arready));
        }
        const bool old_read=read_active_;
        if(s.rvalid && s.rready && old_read) accept_r(s);
        if(s.arvalid && s.arready) {
            if(read_active_) fail("overlapping AXI reads unsupported by observer");
            if(s.arsize>2 || s.arlen>255) fail("unsupported AXI geometry");
            read_active_=true; read_id_=s.arid; read_left_=s.arlen+1; read_narrow_=s.ar_narrow;
            read_serial_=++ar_count_;
            if(read_narrow_ && (s.arlen!=0 || s.arburst!=1 || (s.araddr & ((1ull<<s.arsize)-1))))
                fail("invalid narrow AXI geometry");
            room();
            std::fprintf(log_,"{\"type\":\"axi_ar\",\"cycle\":%llu,\"transaction\":%llu,\"address\":%llu,\"id\":%u,\"len\":%u,\"size\":%u,\"burst\":%u,\"narrow\":%u}\n",
                (unsigned long long)s.cycle,(unsigned long long)read_serial_,(unsigned long long)s.araddr,s.arid,s.arlen,s.arsize,s.arburst,unsigned(s.ar_narrow));
        }
        if(s.rvalid && s.rready && !old_read) accept_r(s);
    }
    void finish() {
        if(!enabled) return;
        if(!configured_ || !sampled_ || finished_) fail("missing/duplicate observer lifecycle");
        if(read_active_) fail("outstanding AXI response; trace incomplete");
        if(final_reads_!=expected_) fail("final read count mismatch; trace incomplete");
        room();
        std::fprintf(log_,"{\"type\":\"complete\",\"records\":%llu,\"last_cycle\":%llu,\"final_reads\":%llu,\"fast_commits\":%llu,\"axi_reads\":%llu,\"axi_beats\":%llu}\n",
            (unsigned long long)lines_,(unsigned long long)last_cycle_,(unsigned long long)final_reads_,(unsigned long long)fast_commits_,(unsigned long long)ar_count_,(unsigned long long)r_count_);
        if(std::fflush(log_) || std::ferror(log_)) fail("observer final I/O failure");
        if(std::fclose(log_)) { log_=nullptr; fail_static("observer close failure"); }
        log_=nullptr; finished_=true;
    }
};
