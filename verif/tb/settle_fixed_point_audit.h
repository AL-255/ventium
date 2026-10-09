// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Diagnostic only: ALWAYS execute eval(), then compare generated model state.
// This does not enable input-elision or authorize it for another profile.
#pragma once
#include "verilated_save.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <vector>

class SettleAuditStream final : public VerilatedSerialize {
public:
    std::vector<uint8_t> bytes;
    void clear() { bytes.clear(); m_cp = m_bufp; }
    void flush() override {
        if (bytes.size() + size_t(m_cp - m_bufp) > 8 * 1024 * 1024) {
            std::fprintf(stderr, "SETTLE-AUDIT: serialization exceeds 8 MiB bound\n");
            std::exit(2);
        }
        bytes.insert(bytes.end(), m_bufp, m_cp);
        m_cp = m_bufp;
    }
    template<class T> void capture(T& top) {
        clear();
        *this << top;
        flush();
    }
};

class SettleFixedPointAudit {
    SettleAuditStream before_, after_;
    uint64_t eligible_ = 0, checked_ = 0, bytes_ = 0;
public:
    // Caller supplies the COMPLETE generated input comparison and pending-event
    // check. Sampling bounds the diagnostic overhead, not its acceptance scope.
    template<class T, class F> void eval(T& top, bool eligible, F retired) {
        bool check = eligible && (++eligible_ <= 10000 || eligible_ % 257 == 0);
        if (!check) { top.eval(); return; }
        const auto count = retired();
        const auto time = top.contextp()->time();
        before_.capture(top);
        top.eval();
        after_.capture(top);
        if (before_.bytes != after_.bytes || retired() != count ||
            top.contextp()->time() != time) {
            const auto mismatch = std::mismatch(before_.bytes.begin(), before_.bytes.end(),
                                               after_.bytes.begin(), after_.bytes.end());
            std::fprintf(stderr,
                "SETTLE-AUDIT-FAIL eligible=%llu first-byte=%zu before-size=%zu after-size=%zu retired=%llu/%llu\n",
                (unsigned long long)eligible_, size_t(mismatch.first - before_.bytes.begin()),
                before_.bytes.size(), after_.bytes.size(),
                (unsigned long long)count, (unsigned long long)retired());
            std::exit(3);
        }
        ++checked_;
        bytes_ += before_.bytes.size();
    }
    ~SettleFixedPointAudit() {
        std::fprintf(stderr, "SETTLE-AUDIT eligible=%llu checked=%llu compared-bytes=%llu skipped=0\n",
            (unsigned long long)eligible_, (unsigned long long)checked_, (unsigned long long)bytes_);
    }
};
