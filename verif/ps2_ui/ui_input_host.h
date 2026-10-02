// Isolated diagnostic host input only. No RTL, CPU-state, or snapshot writes.
// SOURCE REVIEW ONLY: compile/execute only after the owning agent approves.
#ifndef VENTIUM_UI_INPUT_HOST_H
#define VENTIUM_UI_INPUT_HOST_H

#include <array>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <stdexcept>
#include <string>
#include <vector>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace ven_ui {

constexpr size_t kMaxLine = 192;
constexpr size_t kMaxCommands = 16;
constexpr uint64_t kFastControllerTimeout = 0x00fffff;
constexpr uint64_t kMinHalfPeriod = 32;

struct Key { const char *name; uint8_t code; bool extended; bool modifier; };
inline const Key *find_key(const std::string &name) {
    static constexpr Key keys[] = {
        {"ctrl",0x14,false,true}, {"alt",0x11,false,true},
        {"shift",0x12,false,true},
        {"enter",0x5a,false,false}, {"esc",0x76,false,false},
        {"escape",0x76,false,false}, {"space",0x29,false,false},
        {"tab",0x0d,false,false}, {"backspace",0x66,false,false},
        {"up",0x75,true,false}, {"down",0x72,true,false},
        {"left",0x6b,true,false}, {"right",0x74,true,false},
        {"home",0x6c,true,false}, {"end",0x69,true,false},
        {"pageup",0x7d,true,false}, {"pagedown",0x7a,true,false},
        {"insert",0x70,true,false}, {"delete",0x71,true,false},
        {"f1",0x05,false,false}, {"f2",0x06,false,false},
        {"f3",0x04,false,false}, {"f4",0x0c,false,false},
        {"f5",0x03,false,false}, {"f6",0x0b,false,false},
        {"f7",0x83,false,false}, {"f8",0x0a,false,false},
        {"f9",0x01,false,false}, {"f10",0x09,false,false},
        {"f11",0x78,false,false}, {"f12",0x07,false,false},
        {"a",0x1c,false,false}, {"b",0x32,false,false},
        {"c",0x21,false,false}, {"d",0x23,false,false},
        {"e",0x24,false,false}, {"f",0x2b,false,false},
        {"g",0x34,false,false}, {"h",0x33,false,false},
        {"i",0x43,false,false}, {"j",0x3b,false,false},
        {"k",0x42,false,false}, {"l",0x4b,false,false},
        {"m",0x3a,false,false}, {"n",0x31,false,false},
        {"o",0x44,false,false}, {"p",0x4d,false,false},
        {"q",0x15,false,false}, {"r",0x2d,false,false},
        {"s",0x1b,false,false}, {"t",0x2c,false,false},
        {"u",0x3c,false,false}, {"v",0x2a,false,false},
        {"w",0x1d,false,false}, {"x",0x22,false,false},
        {"y",0x35,false,false}, {"z",0x1a,false,false},
        {"1",0x16,false,false}, {"2",0x1e,false,false},
        {"3",0x26,false,false}, {"4",0x25,false,false},
        {"5",0x2e,false,false}, {"6",0x36,false,false},
        {"7",0x3d,false,false}, {"8",0x3e,false,false},
        {"9",0x46,false,false}, {"0",0x45,false,false},
        {"minus",0x4e,false,false}, {"equal",0x55,false,false},
        {"grave",0x0e,false,false}, {"comma",0x41,false,false},
        {"period",0x49,false,false}, {"slash",0x4a,false,false},
        {"semicolon",0x4c,false,false}, {"quote",0x52,false,false},
        {"leftbracket",0x54,false,false}, {"rightbracket",0x5b,false,false},
        {"backslash",0x5d,false,false}
    };
    for (const Key &k : keys) if (name == k.name) return &k;
    return nullptr;
}

inline void append_make(std::vector<uint8_t> &out, const Key &k) {
    if (k.extended) out.push_back(0xe0);
    out.push_back(k.code);
}
inline void append_break(std::vector<uint8_t> &out, const Key &k) {
    if (k.extended) out.push_back(0xe0);
    out.push_back(0xf0); out.push_back(k.code);
}
inline bool chord_bytes(const std::string &text, std::vector<uint8_t> &out) {
    out.clear();
    std::vector<const Key *> keys;
    size_t begin = 0;
    while (true) {
        const size_t end = text.find('+', begin);
        const std::string token = text.substr(begin, end - begin);
        const Key *k = find_key(token);
        if (!k || keys.size() == 4) return false;
        for (const Key *prior : keys) if (prior->code == k->code &&
                                         prior->extended == k->extended) return false;
        keys.push_back(k);
        if (end == std::string::npos) break;
        if (!k->modifier) return false;
        begin = end + 1;
    }
    if (keys.empty() || keys.back()->modifier) return false;
    for (const Key *k : keys) append_make(out, *k);
    for (auto it = keys.rbegin(); it != keys.rend(); ++it) append_break(out, **it);
    return true;
}

inline bool decimal_id(const std::string &text, uint64_t &out) {
    if (text.empty() || text.size() > 20) return false;
    uint64_t v = 0;
    for (const unsigned char c : text) {
        if (c < '0' || c > '9' || v > (UINT64_MAX - (c - '0')) / 10) return false;
        v = v * 10 + (c - '0');
    }
    if (!v) return false;
    out = v; return true;
}

enum class Op { Key, Capture };
struct Command { uint64_t id; Op op; std::vector<uint8_t> bytes; size_t accepted = 0; };

// One-clock-step wire state. The sender never removes an owned raw byte
// simply because its waveform ended: only production recv_final commits it.
// Unexpected interruption fails closed, not automatic replay. A timeout can
// clear the controller's accepted F0 prefix, making a blind retry unsafe.
struct Timing {
    uint64_t half = 0, idle = 0, accept_limit = 0;
    static Timing ordinary(uint32_t hz, uint64_t requested_half = 0) {
        Timing t;
        t.half = requested_half ? requested_half : (uint64_t(hz) + 23999) / 24000;
        if (t.half < kMinHalfPeriod) t.half = kMinHalfPeriod;
        if (requested_half && requested_half < kMinHalfPeriod)
            throw std::runtime_error("half_period_below_filter_margin");
        if (t.half > 20000) throw std::runtime_error("frame_exceeds_controller_timeout_margin");
        t.idle = (uint64_t(hz) + 9999) / 10000; // >=100 us at configured clock.
        if (t.idle < 128) t.idle = 128;
        t.accept_limit = t.half * 22 + t.idle + 256;
        if (t.accept_limit >= kFastControllerTimeout)
            throw std::runtime_error("frame_exceeds_controller_timeout");
        return t;
    }
};

struct Lines { bool clock = true, data = true; };
// Actual controller producer/consumer proof sampled around one RTL edge.
// post_memory_at_old_write_index is a read-only observation of simple_fifo.
// No guessed "wire done" or recv_final alone is sufficient for enqueue.
struct ReceiveProof {
    bool final = false, reset = false, clear = false, translated = false;
    bool autoack = false, reply = false, write_request = false;
    bool full = false, read_request = false, escape_before = false, escape_after = false;
    uint8_t raw = 0, translated_value = 0, produced_value = 0, old_write_index = 0;
    uint8_t new_write_index = 0, post_memory_at_old_write_index = 0;
};
class Input {
    FILE *log_;
    int fd_ = -1;
    int dir_fd_ = -1;
    std::string parent_path_, basename_;
    struct stat fifo_identity_{}, directory_identity_{};
    std::string line_;
    bool discard_ = false;
    std::deque<Command> queue_;
    uint64_t highest_id_ = 0;
    Timing timing_;
    enum class Wire { Idle, Sending, AwaitAcceptance } wire_ = Wire::Idle;
    uint64_t wire_start_ = 0, idle_since_ = 0;
    bool idle_seen_ = false, failed_ = false;
    std::array<bool,11> bits_{};
    uint8_t owned_byte_ = 0;
    bool prefix_owned_ = false, prefix_translated_ = false;
    uint64_t read_context_ = 0, read_until_ = 0;
    unsigned read_count_ = 0;
    void reject(uint64_t id, const char *why, uint64_t cycle) {
        if (log_) fprintf(log_, "[UI-REJECT] id=%llu cycle=%llu reason=%s\n",
                          (unsigned long long)id, (unsigned long long)cycle, why);
    }
    void fail(const char *why, uint64_t cycle) {
        if (!failed_ && log_) fprintf(log_,
            "[UI-ERROR] cycle=%llu reason=%s pending=%zu owned=%u raw=%02x ui_success=not_asserted\n",
            (unsigned long long)cycle, why, queue_.size(), unsigned(inflight()), owned_byte_);
        failed_ = true;
    }
    void admit(const std::string &line, uint64_t cycle) {
        const size_t space = line.find(' ');
        uint64_t id = 0;
        if (space == std::string::npos || !decimal_id(line.substr(0, space), id)) {
            reject(0, "invalid_id_or_frame", cycle); return;
        }
        if (id <= highest_id_) { reject(id, "nonmonotonic_id", cycle); return; }
        // Every well-framed ID is consumed, even a rejection. Retrying requires
        // a new ID; no accepted/rejected command can accidentally be replayed.
        highest_id_ = id;
        const std::string operation = line.substr(space + 1);
        Command cmd{id, Op::Capture, {}, 0};
        if (operation == "capture") cmd.op = Op::Capture;
        else if (operation.compare(0, 4, "key ") == 0) {
            cmd.op = Op::Key;
            if (!chord_bytes(operation.substr(4), cmd.bytes)) {
                reject(id, "invalid_named_key_or_chord", cycle); return;
            }
        } else { reject(id, "unknown_operation", cycle); return; }
        if (queue_.size() == kMaxCommands) { reject(id, "queue_full", cycle); return; }
        queue_.push_back(cmd);
        if (log_) fprintf(log_, "[UI-QUEUED] id=%llu cycle=%llu op=%s bytes=%zu queued=%zu\n",
                          (unsigned long long)id, (unsigned long long)cycle,
                          cmd.op == Op::Key ? "key" : "capture", cmd.bytes.size(), queue_.size());
    }
    bool endpoint_unchanged(uint64_t cycle) {
        struct stat fd{}, entry{}, dir{}, path{};
        const bool good = !fstat(fd_,&fd) && !fstat(dir_fd_,&dir) &&
            !lstat(parent_path_.c_str(),&path) &&
            !fstatat(dir_fd_,basename_.c_str(),&entry,AT_SYMLINK_NOFOLLOW) &&
            S_ISFIFO(fd.st_mode) && S_ISFIFO(entry.st_mode) &&
            S_ISDIR(dir.st_mode) && S_ISDIR(path.st_mode) &&
            fd.st_uid==geteuid() && entry.st_uid==geteuid() &&
            dir.st_uid==geteuid() && path.st_uid==geteuid() &&
            (fd.st_mode&0777)==0600 && (entry.st_mode&0777)==0600 &&
            (dir.st_mode&0777)==0700 && (path.st_mode&0777)==0700 &&
            fd.st_dev==fifo_identity_.st_dev && fd.st_ino==fifo_identity_.st_ino &&
            entry.st_dev==fifo_identity_.st_dev && entry.st_ino==fifo_identity_.st_ino &&
            dir.st_dev==directory_identity_.st_dev && dir.st_ino==directory_identity_.st_ino &&
            path.st_dev==directory_identity_.st_dev && path.st_ino==directory_identity_.st_ino;
        if (!good) fail("endpoint_identity_or_permissions_changed",cycle);
        return good;
    }
public:
    explicit Input(Timing timing, FILE *log = stderr) : log_(log), timing_(timing) {}
    Input(const Input &) = delete;
    Input &operator=(const Input &) = delete;
    ~Input() { if (fd_ >= 0) close(fd_); if (dir_fd_ >= 0) close(dir_fd_); }
    bool failed() const { return failed_; }
    bool inflight() const { return wire_ != Wire::Idle; }
    bool prefix_owned() const { return prefix_owned_; }
    size_t pending() const { return queue_.size(); }
    size_t accepted_front() const { return queue_.empty() ? 0 : queue_.front().accepted; }
    uint64_t highest_id() const { return highest_id_; }
    uint8_t owned_byte() const { return owned_byte_; }
    const Timing &timing() const { return timing_; }

    // The final directory and FIFO must be owned by this effective UID, with
    // no other-user access. No unlink/replacement of an existing endpoint.
    // The caller chooses a fresh isolated directory; no default ~/ endpoint.
    void open_fifo(const std::string &path) {
        if (fd_>=0 || dir_fd_>=0) throw std::runtime_error("fifo_already_open");
        if (path.empty() || path[0] != '/' || path.size() > 4095)
            throw std::runtime_error("fifo_requires_absolute_path");
        const size_t slash = path.find_last_of('/');
        const std::string parent = path.substr(0, slash), name = path.substr(slash + 1);
        if (parent.empty() || name.empty() || name == "." || name == "..")
            throw std::runtime_error("invalid_fifo_path");
        const int dir = open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (dir < 0) throw std::runtime_error("fifo_parent_open_failed");
        struct stat ds{}, before{}, actual{};
        auto close_error = [&](const char *why) { close(dir); throw std::runtime_error(why); };
        if (fstat(dir, &ds) || ds.st_uid != geteuid() || (ds.st_mode & 0777) != 0700)
            close_error("fifo_parent_requires_owner_0700");
        if (mkfifoat(dir, name.c_str(), 0600) && errno != EEXIST)
            close_error("fifo_create_failed");
        if (fstatat(dir, name.c_str(), &before, AT_SYMLINK_NOFOLLOW) ||
            !S_ISFIFO(before.st_mode) || before.st_uid != geteuid() ||
            (before.st_mode & 0777) != 0600)
            close_error("fifo_requires_owner_fifo_0600");
        const int next = openat(dir, name.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
        if (next < 0) close_error("fifo_open_failed");
        if (fstat(next, &actual) || !S_ISFIFO(actual.st_mode) ||
            actual.st_dev != before.st_dev || actual.st_ino != before.st_ino ||
            actual.st_uid != geteuid() || (actual.st_mode & 0777) != 0600) {
            close(next); close_error("fifo_identity_changed");
        }
        dir_fd_=dir; fd_=next; parent_path_=parent; basename_=name;
        fifo_identity_=actual; directory_identity_=ds;
        if (log_) fprintf(log_,
            "[UI-READY] pid=%ld uid=%ld dev=%llu ino=%llu half=%llu idle=%llu framing=lf_ascii max_line=%zu max_commands=%zu identity=diagnostic_only\n",
            (long)getpid(), (long)geteuid(), (unsigned long long)actual.st_dev,
            (unsigned long long)actual.st_ino, (unsigned long long)timing_.half,
            (unsigned long long)timing_.idle, kMaxLine, kMaxCommands);
    }
    // Public feed supports pure-host tests. Runtime reads are bounded below.
    void feed(const char *bytes, size_t count, uint64_t cycle) {
        for (size_t i = 0; i < count && !failed_; ++i) {
            const unsigned char c = bytes[i];
            if (c == '\n') {
                if (discard_) reject(0, "invalid_or_overlong_frame", cycle);
                else admit(line_, cycle);
                line_.clear(); discard_ = false;
            } else if (c < 32 || c > 126 || line_.size() == kMaxLine) {
                line_.clear(); discard_ = true;
            } else if (!discard_) line_.push_back(char(c));
        }
    }
    void writer_eof(uint64_t cycle) {
        if (!line_.empty() || discard_) reject(0, "unterminated_frame_at_eof", cycle);
        line_.clear(); discard_ = false;
    }
    void poll(uint64_t cycle) {
        if (fd_ < 0 || failed_) return;
        if (!endpoint_unchanged(cycle)) return;
        char bytes[512];
        // At most 4096 bytes/syscall work per poll; never waits for a writer.
        for (unsigned calls = 0; calls < 8; ++calls) {
            const ssize_t n = read(fd_, bytes, sizeof bytes);
            if (n > 0) { feed(bytes, size_t(n), cycle); continue; }
            if (!n) { writer_eof(cycle); return; }
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            if (errno == EINTR) continue;
            fail("fifo_read_failed", cycle); return;
        }
    }
    Lines drive(uint64_t cycle, bool reset, bool host_clock, bool host_data,
                bool controller_idle) {
        Lines out;
        if (failed_) return out;
        if (reset) {
            if (inflight() || (!queue_.empty() && queue_.front().accepted))
                fail("reset_interrupted_command", cycle);
            idle_seen_ = false; return out;
        }
        if (inflight()) {
            if (!host_clock || !host_data) {
                fail("host_interrupted_owned_frame", cycle); return out;
            }
            if (cycle - wire_start_ > timing_.accept_limit) {
                fail("controller_accept_timeout_no_replay", cycle); return out;
            }
            const uint64_t elapsed = cycle - wire_start_;
            if (elapsed < timing_.half * 22) {
                const unsigned bit = unsigned(elapsed / (timing_.half * 2));
                out.data = bits_[bit];
                out.clock = elapsed % (timing_.half * 2) < timing_.half;
            } else wire_ = Wire::AwaitAcceptance;
            return out;
        }
        if (!host_clock || !host_data || !controller_idle) {
            idle_seen_ = false; return out;
        }
        if (!idle_seen_) { idle_since_ = cycle; idle_seen_ = true; }
        if (queue_.empty() || queue_.front().op != Op::Key ||
            cycle - idle_since_ < timing_.idle) return out;
        Command &cmd = queue_.front();
        owned_byte_ = cmd.bytes[cmd.accepted];
        bits_[0] = false;
        bool parity = true;
        for (unsigned k = 0; k < 8; ++k) {
            bits_[1+k] = bool((owned_byte_ >> k) & 1u); parity ^= bits_[1+k];
        }
        bits_[9] = parity; bits_[10] = true;
        wire_start_ = cycle; wire_ = Wire::Sending; idle_seen_ = false;
        read_context_ = cmd.id; read_until_ = cycle + timing_.accept_limit + timing_.idle;
        out.data = false; return out;
    }
    // Call only AFTER the real rising edge. Preedge witnesses bind to actual
    // producer arbitration; postedge index/memory prove the actual FIFO write.
    // VEN_KBD_AUTOACK has priority over a coincident scan byte. Never declare
    // that collided raw byte accepted and never replay it speculatively.
    void prefix_context_before(uint64_t cycle, bool translated, bool escape,
                               bool reset_or_clear, bool timeout_reset) {
        if (!prefix_owned_ || failed_) return;
        if (reset_or_clear) fail("owned_prefix_reset_or_selftest",cycle);
        else if (timeout_reset) fail("owned_prefix_controller_timeout",cycle);
        else if (translated!=prefix_translated_) fail("owned_prefix_translation_mode_changed",cycle);
        else if (prefix_translated_ && !escape) fail("owned_prefix_lost_between_bytes",cycle);
    }
    void controller_reset_edge(uint64_t cycle, bool reset_or_clear) {
        if (reset_or_clear && (prefix_owned_ || inflight() ||
            (!queue_.empty() && queue_.front().accepted)))
            fail("controller_reset_or_clear_interrupted_command", cycle);
    }
    void accepted_edge(uint64_t cycle, const ReceiveProof &p) {
        if (!p.final || failed_) return;
        if (!inflight() || queue_.empty() || queue_.front().op != Op::Key ||
            p.raw != owned_byte_ || cycle - wire_start_ < timing_.half * 20) {
            fail("unexpected_controller_receive", cycle); return;
        }
        if (p.reset || p.clear) { fail("controller_reset_or_clear_at_receive", cycle); return; }
        if (prefix_owned_ && (p.translated!=prefix_translated_ ||
            (prefix_translated_ && !p.escape_before))) {
            fail("owned_prefix_missing_or_mode_changed_at_suffix",cycle); return;
        }
        if (p.translated && p.raw!=0xf0 && p.escape_before!=prefix_owned_) {
            fail("unexpected_translation_prefix_at_suffix",cycle); return;
        }
        const bool prefix_only = p.translated && p.raw == 0xf0;
        if (prefix_only) {
            if (!p.escape_before || !p.escape_after) { fail("translation_prefix_not_retained", cycle); return; }
        } else {
            if (p.autoack || p.reply) { fail("controller_producer_overwrote_scan_byte", cycle); return; }
            if (!p.write_request || (p.full && !p.read_request) ||
                p.produced_value != p.translated_value ||
                p.new_write_index != ((p.old_write_index + 1) & 63) ||
                p.post_memory_at_old_write_index != p.translated_value) {
                fail("controller_fifo_dropped_or_changed_scan_byte", cycle); return;
            }
        }
        // Independent raw-stream obligation: never infer this from DUT trans.
        // Clear only after the suffix's full enqueue proof has validated.
        if (p.raw==0xf0) { prefix_owned_=true; prefix_translated_=p.translated; }
        else prefix_owned_=false;
        Command &cmd = queue_.front();
        ++cmd.accepted;
        if (log_) fprintf(log_, "[UI-WIRE-BYTE] id=%llu cycle=%llu index=%zu total=%zu raw=%02x\n",
                          (unsigned long long)cmd.id, (unsigned long long)cycle,
                          cmd.accepted, cmd.bytes.size(), unsigned(p.raw));
        wire_ = Wire::Idle; idle_seen_ = false;
        if (cmd.accepted == cmd.bytes.size()) {
            if (log_) fprintf(log_,
                "[UI-WIRE-COMPLETE] id=%llu cycle=%llu bytes=%zu ui_success=not_asserted\n",
                (unsigned long long)cmd.id, (unsigned long long)cycle, cmd.bytes.size());
            queue_.pop_front(); read_count_ = 0;
        }
    }
    void guest_read_edge(uint64_t cycle, bool read, uint8_t value) {
        if (!read || !read_context_ || cycle > read_until_ || read_count_ >= 128) return;
        ++read_count_;
        if (log_) fprintf(log_,
            "[UI-GUEST-READ] cycle=%llu id_context=%llu value=%02x correlation=unproven ui_success=not_asserted\n",
            (unsigned long long)cycle, (unsigned long long)read_context_, unsigned(value));
    }
    bool capture_ready(uint64_t &id) const {
        if (failed_ || prefix_owned_ || inflight() || queue_.empty() || queue_.front().op != Op::Capture) return false;
        id = queue_.front().id; return true;
    }
    void capture_result(uint64_t id, uint64_t cycle, const char *path, bool graphics) {
        uint64_t expected = 0;
        if (!capture_ready(expected) || expected != id) { fail("capture_order_violation", cycle); return; }
        if (graphics && (!path || !*path)) { fail("capture_published_path_missing",cycle); return; }
        if (log_) fprintf(log_,
            "[%s] id=%llu cycle=%llu path=%s pixels=raw ui_success=not_asserted\n",
            graphics ? "UI-CAPTURE-PUBLISHED" : "UI-CAPTURE-UNAVAILABLE",
            (unsigned long long)id, (unsigned long long)cycle, graphics ? path : "none");
        queue_.pop_front();
    }
    void capture_write_failed(uint64_t cycle) { fail("capture_write_failed_no_publication",cycle); }
    bool finish(uint64_t cycle) {
        if (!line_.empty() || discard_) writer_eof(cycle);
        if (log_) fprintf(log_, "[UI-END] cycle=%llu pending=%zu owned=%u failed=%u\n",
                          (unsigned long long)cycle, queue_.size(), unsigned(inflight()), unsigned(failed_));
        return !failed_ && !prefix_owned_ && queue_.empty() && !inflight();
    }
};

// Exact finalization used by the unmodified raw-pixel conversion path. A
// buffered /dev/full failure often surfaces only in fclose; never publish it.
inline bool complete_raw_file(FILE *f,bool write_ok) {
    if (!f) return false;
    if (ferror(f)) write_ok=false;
    if (fclose(f)!=0) write_ok=false;
    return write_ok;
}

inline bool forbidden_ui_option(const char *option) {
    // Reject even nominally harmless snapshot selectors: this variant has no
    // native save/restore format for the external endpoint and ownership state.
    return !std::strncmp(option,"--kb",4) || !std::strncmp(option,"--save",6) ||
           !std::strncmp(option,"--restore",9) || !std::strncmp(option,"--snapshot",10);
}

} // namespace ven_ui
#endif
