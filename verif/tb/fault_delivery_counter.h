// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include <cstdint>

// Observe the real delivery counter every clock. An unchanged fault PC is NOT
// an event signal: it invents a reset fault and misses repeated faults at one PC.
class FaultDeliveryCounter {
    uint8_t previous_;
    uint64_t total_ = 0;
public:
    explicit FaultDeliveryCounter(uint8_t initial) : previous_(initial) {}
    unsigned observe(uint8_t current) {
        const auto delta = static_cast<uint8_t>(current - previous_);
        previous_ = current;
        total_ += delta;
        return delta;
    }
    uint64_t total() const { return total_; }
};
