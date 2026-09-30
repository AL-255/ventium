// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#ifndef VENTIUM_RETIRE_PC_SNAPSHOT_H
#define VENTIUM_RETIRE_PC_SNAPSHOT_H

#include "retire_fault_ring.h"
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace ven_host {

// HOST-ONLY: an actual DPI callback latches a request; the caller saves only
// at its existing settled checkpoint point. No model access, eval or clocks.
// CS is the DPI POST-commit selector, PC the fetch OFFSET. A transfer may have
// changed CS; this pair must never be advertised as pre-execution linear PC.
struct RetirePcSnapshotOptions {
    bool enabled = false;
    uint16_t cs = 0;
    uint32_t pc = 0;
    uint64_t occurrence = 1;
    uint64_t after_retire = 0; // strict > filter; occurrences start after it
    unsigned seen = 0;
};

struct RetirePcSnapshotContext {
    bool restoring = false;
    uint64_t save_at = 0, save_every = 0, stop_retire = 0;
    bool save_stop = false, mouse = false, snapshot_v4 = false;
    const char *save_file = nullptr;
};

inline bool retire_pc_number(const char *text, uint64_t limit, uint64_t &out,
                             bool hex = false) {
    if (!text || !*text) return false;
    const char *digits = text;
    if (digits[0] == '0' && (digits[1] == 'x' || digits[1] == 'X')) {
        hex = true; digits += 2;
    }
    if (!*digits) return false;
    uint64_t value = 0;
    const unsigned radix = hex ? 16u : 10u;
    for (; *digits; ++digits) {
        unsigned d = 99;
        if (*digits >= '0' && *digits <= '9') d = unsigned(*digits - '0');
        else if (*digits >= 'a' && *digits <= 'f') d = unsigned(*digits - 'a') + 10u;
        else if (*digits >= 'A' && *digits <= 'F') d = unsigned(*digits - 'A') + 10u;
        if (d >= radix || value > limit / radix ||
            (value == limit / radix && d > limit % radix)) return false;
        value = value * radix + d;
    }
    out = value;
    return true;
}

// 1 consumed, 0 unrelated, -1 malformed; duplicate recognized options fail.
inline int parse_retire_pc_snapshot_option(int argc, char **argv, int &i,
                                           RetirePcSnapshotOptions &o,
                                           const char *&error) {
    const char *arg = argv[i];
    const bool target = !std::strcmp(arg, "--save-at-retired-pc");
    const bool occurrence = !std::strcmp(arg, "--save-pc-occurrence");
    const bool after = !std::strcmp(arg, "--save-pc-after-retire");
    if (!target && !occurrence && !after) return 0;
    const unsigned bit = target ? 1u : occurrence ? 2u : 4u;
    if (o.seen & bit) { error = "duplicate PC snapshot option"; return -1; }
    if (i + 1 >= argc) { error = "PC snapshot option requires a value"; return -1; }
    const char *text = argv[++i];
    uint64_t value = 0;
    if (target) {
        const std::string pair(text);
        const auto colon = pair.find(':');
        if (colon == std::string::npos || pair.find(':', colon + 1) != std::string::npos ||
            !retire_pc_number(pair.substr(0, colon).c_str(), UINT16_MAX, value, true)) {
            error = "PC snapshot target requires hexadecimal CS:offset"; return -1;
        }
        const uint16_t cs = uint16_t(value);
        if (!retire_pc_number(pair.substr(colon + 1).c_str(), UINT32_MAX, value, true)) {
            error = "PC snapshot target requires hexadecimal CS:offset"; return -1;
        }
        o.cs = cs; o.pc = uint32_t(value); o.enabled = true;
    } else {
        const uint64_t limit = occurrence ? 1000000u : UINT64_MAX;
        if (!retire_pc_number(text, limit, value) || (occurrence && !value)) {
            error = "invalid PC snapshot integer (occurrence 1..1000000)"; return -1;
        }
        if (occurrence) o.occurrence = value; else o.after_retire = value;
    }
    o.seen |= bit;
    return 1;
}

// No mutation: reject existing files (including hardlinks), symlink leaves
// AND ancestors, missing/non-directory parents, and parent-traversal paths.
inline const char *retire_pc_new_output(const char *path, bool owned = false) {
    if (!path || !*path) return "PC snapshot requires a nonempty save-file";
    const std::string name(path);
    if (name.back() == '/') return "snapshot path has no filename";
    std::string prefix = name.front() == '/' ? "/" : "";
    size_t pos = name.front() == '/' ? 1 : 0;
    while (pos < name.size()) {
        const auto slash = name.find('/', pos);
        const auto part = name.substr(pos, slash == std::string::npos ? slash : slash - pos);
        if (part.empty() || part == "..") return "unsafe snapshot path component";
        if (!prefix.empty() && prefix.back() != '/') prefix += '/';
        prefix += part;
        struct stat st{};
        const int rc = ::lstat(prefix.c_str(), &st);
        if (slash == std::string::npos) {
            if (!rc) return owned && S_ISREG(st.st_mode) && st.st_nlink == 1 ?
                nullptr : "snapshot output already exists or is unsafe";
            if (owned) return "snapshot reservation path disappeared";
            return errno == ENOENT ? nullptr : "snapshot output lstat failed";
        }
        if (rc || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode))
            return "snapshot parent missing, symlink, or not a directory";
        pos = slash + 1;
    }
    return "snapshot path has no filename";
}

inline const char *validate_retire_pc_snapshot_options(
    const RetirePcSnapshotOptions &o, const RetirePcSnapshotContext &c) {
    if (!o.enabled) return o.seen ? "PC snapshot filters require --save-at-retired-pc" : nullptr;
    if (o.occurrence < 1 || o.occurrence > 1000000u)
        return "invalid PC snapshot occurrence";
    if (c.restoring) return "PC snapshot observer requires a cold run";
    if (c.save_at || c.save_every || c.stop_retire)
        return "PC snapshot excludes cycle/periodic/retirement-stop triggers";
    if (c.mouse && !c.snapshot_v4) return "mouse PC snapshots require --snapshot-v4";
    return retire_pc_new_output(c.save_file);
}

class RetirePcSnapshot {
public:
    static constexpr size_t history_capacity = 256;
    RetirePcSnapshot() = default;
    RetirePcSnapshot(const RetirePcSnapshot &) = delete;
    RetirePcSnapshot &operator=(const RetirePcSnapshot &) = delete;
    ~RetirePcSnapshot() { if (fd_ >= 0) ::close(fd_); }

    bool open(const RetirePcSnapshotOptions &o, const RetirePcSnapshotContext &c,
              const char *&error) {
        if (fd_ >= 0 || active_) { error = "PC snapshot already opened"; return false; }
        if ((error = validate_retire_pc_snapshot_options(o, c))) return false;
        if (!o.enabled) return true;
        fd_ = ::open(c.save_file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd_ < 0) { error = "exclusive PC snapshot reservation failed"; return false; }
        if (::fstat(fd_, &identity_) || !S_ISREG(identity_.st_mode) ||
            identity_.st_nlink != 1 || identity_.st_size != 0) {
            error = "invalid PC snapshot reservation"; return false;
        }
        options_ = o; path_ = c.save_file;
        serialization_path_ = "/proc/self/fd/" + std::to_string(fd_);
        active_ = true;
        return true;
    }

    bool enabled() const { return active_ && !saved_ && !failure_; }
    bool pending() const { return enabled() && hit_; }
    bool saved() const { return saved_; }
    bool failed() const { return failure_ != nullptr; }
    const char *path() const { return path_.c_str(); }
    // VerilatedSave reopens with O_TRUNC. NEVER pass path() to that writer:
    // /proc/self/fd reopens the HELD owned inode even if the user leaf/parent
    // is replaced after prepare_save. complete_save still rejects tampering.
    const char *serialization_path() const {
        return prepared_ && pending() ? serialization_path_.c_str() : nullptr;
    }
    uint64_t matches() const { return matches_; }
    size_t history_count() const { return history_size_; }
    const FaultRetireSnapshot &trigger() const { return trigger_; }
    const FaultRetireSnapshot &history(size_t i) const {
        // The caller must use history_count(); no silently wrapped index.
        if (i >= history_size_) std::abort();
        return history_[(history_next_ + history_capacity - history_size_ + i) % history_capacity];
    }

    // Called ONCE PER ACTUAL DPI retirement, including both U and V. Pending
    // freezes the trigger/history, but validates later callback counters too.
    bool retire(const FaultRetireSnapshot &s) {
        if (!enabled()) return !failure_;
        if ((!have_last_ && s.retire != 1) ||
            (have_last_ && (s.retire != last_retire_ + 1 || s.cycle < last_cycle_)))
            return fail("noncontiguous/stale PC snapshot retirement");
        have_last_ = true; last_retire_ = s.retire; last_cycle_ = s.cycle;
        if (hit_) return true;
        if (s.retire > options_.after_retire && s.seg[0] == options_.cs && s.fetch_pc == options_.pc) {
            ++matches_;
            if (matches_ == options_.occurrence) { trigger_ = s; hit_ = true; return true; }
        }
        history_[history_next_] = s;
        history_next_ = (history_next_ + 1) % history_capacity;
        if (history_size_ < history_capacity) ++history_size_;
        return true;
    }

    bool prepare_save(uint64_t cycle, uint64_t retired, const char *&error) {
        if (!pending() || prepared_ || !have_last_ || retired != last_retire_ || cycle < last_cycle_) {
            error = "PC snapshot save point/counter mismatch"; return fail(error);
        }
        if ((error = owned_output(true))) return fail(error);
        save_cycle_ = cycle; save_retire_ = retired; prepared_ = true;
        return true;
    }

    bool complete_save(uint64_t cycle, uint64_t retired, const char *&error) {
        if (!pending() || !prepared_ || cycle != save_cycle_ || retired != save_retire_) {
            error = "PC snapshot completion point mismatch"; return fail(error);
        }
        if ((error = owned_output(false))) return fail(error);
        saved_ = true;
        return true;
    }

    // One bounded report, NOT .vtrace or proof of pre-store/cache coherence.
    bool report(FILE *out) {
        if (!saved_ || reported_ || !out) return false;
        reported_ = true;
        std::fprintf(out, "PC-SNAPSHOT v=1 passive=1 matched_post_commit_cs=%04x fetch_offset=%08x "
            "occurrence=%llu after_retire_exclusive=%llu trigger_cycle=%llu trigger_retire=%llu "
            "save_cycle=%llu save_retire=%llu cycle_overshoot=%llu retire_overshoot=%llu "
            "history_count=%zu history_capacity=256 post_instruction=1\n",
            unsigned(options_.cs), options_.pc, (unsigned long long)matches_,
            (unsigned long long)options_.after_retire, (unsigned long long)trigger_.cycle,
            (unsigned long long)trigger_.retire, (unsigned long long)save_cycle_,
            (unsigned long long)save_retire_, (unsigned long long)(save_cycle_ - trigger_.cycle),
            (unsigned long long)(save_retire_ - trigger_.retire), history_size_);
        for (size_t i = 0; i < history_size_; ++i) print_record(out, "PC-HISTORY", history(i));
        print_record(out, "PC-TRIGGER", trigger_);
        return !std::ferror(out);
    }

    const char *finish_error() const {
        if (failure_) return failure_;
        return active_ && !saved_ ? "PC snapshot target not reached or save not completed" : nullptr;
    }

private:
    bool fail(const char *message) { failure_ = message; return false; }
    const char *owned_output(bool empty) const {
        if (const char *error = retire_pc_new_output(path_.c_str(), true)) return error;
        struct stat path_stat{}, fd_stat{};
        if (::lstat(path_.c_str(), &path_stat) || ::fstat(fd_, &fd_stat))
            return "PC snapshot reservation disappeared";
        if (!S_ISREG(path_stat.st_mode) || !S_ISREG(fd_stat.st_mode) ||
            path_stat.st_dev != identity_.st_dev || path_stat.st_ino != identity_.st_ino ||
            fd_stat.st_dev != identity_.st_dev || fd_stat.st_ino != identity_.st_ino ||
            path_stat.st_nlink != 1 || fd_stat.st_nlink != 1 ||
            (empty ? path_stat.st_size != 0 : path_stat.st_size <= 0))
            return "PC snapshot reservation identity/link/extent changed";
        return nullptr;
    }
    static void print_record(FILE *out, const char *kind, const FaultRetireSnapshot &s) {
        std::fprintf(out, "%s cycle=%llu retire=%llu core_n=%llu post_cs=%04x fetch_offset=%08x "
            "flags=%08x ax=%08x cx=%08x dx=%08x bx=%08x sp=%08x bp=%08x si=%08x di=%08x "
            "ss=%04x ds=%04x es=%04x fs=%04x gs=%04x\n", kind,
            (unsigned long long)s.cycle, (unsigned long long)s.retire, (unsigned long long)s.core_n,
            unsigned(s.seg[0]), s.fetch_pc, s.eflags, s.gpr[0], s.gpr[1], s.gpr[2], s.gpr[3],
            s.gpr[4], s.gpr[5], s.gpr[6], s.gpr[7], unsigned(s.seg[1]), unsigned(s.seg[2]),
            unsigned(s.seg[3]), unsigned(s.seg[4]), unsigned(s.seg[5]));
    }
    RetirePcSnapshotOptions options_{};
    std::string path_, serialization_path_;
    int fd_ = -1;
    struct stat identity_{};
    bool active_ = false, hit_ = false, saved_ = false, prepared_ = false;
    bool reported_ = false, have_last_ = false;
    const char *failure_ = nullptr;
    uint64_t matches_ = 0, last_retire_ = 0, last_cycle_ = 0;
    uint64_t save_cycle_ = 0, save_retire_ = 0;
    std::array<FaultRetireSnapshot, history_capacity> history_{};
    size_t history_size_ = 0, history_next_ = 0;
    FaultRetireSnapshot trigger_{};
};

} // namespace ven_host
#endif
