// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once

#include <cstdint>
#include <stdexcept>

// One observation is the *newly registered* retire event(s) after a core edge.
// Repeated string elements each generate a legacy callback, but only the final
// element completes an x86 instruction. A zero-count REP completes one
// instruction without completing an element. Unknown control transfers remain
// explicit instead of being guessed from a repeated PC.
struct RepAccounting {
    uint64_t legacy = 0;
    // REP-normalized retirement callbacks, not yet a canonical completed-x86
    // count: asynchronous FP owners can be reported before result completion.
    uint64_t rep_normalized_known = 0;
    uint64_t rep_callbacks = 0;
    uint64_t rep_elements = 0;
    uint64_t rep_completed = 0;
    uint64_t rep_zero_count = 0;
    uint64_t unresolved = 0;

    void observe(unsigned retired, bool repeat, bool zero_count,
                 uint32_t post_eip, uint32_t q_pc, uint32_t next_eip) {
        if (retired > 2) throw std::invalid_argument("invalid retire width");
        legacy += retired;
        if (!retired) return;
        if (!repeat) {
            rep_normalized_known += retired;
            return;
        }
        if (retired != 1 || q_pc == next_eip)
            throw std::invalid_argument("ambiguous REP retirement");
        ++rep_callbacks;
        if (zero_count) ++rep_zero_count;
        else ++rep_elements;
        if (post_eip == next_eip) {
            ++rep_completed;
            ++rep_normalized_known;
        } else if (post_eip != q_pc) {
            ++unresolved;
        }
    }
};
