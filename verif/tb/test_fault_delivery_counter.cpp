// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "fault_delivery_counter.h"
#include <cassert>
#include <cstdio>
int main() {
    FaultDeliveryCounter counter(0);
    assert(counter.observe(0) == 0); // Reset is not a #DE at address zero.
    assert(counter.observe(1) == 1); // PC zero is allowed; it is not inspected.
    assert(counter.observe(2) == 1); // Repeated identical PC must still count.
    assert(counter.observe(2) == 0); // Holding the last vector is not a delivery.
    assert(counter.total() == 2);
    FaultDeliveryCounter wrap(254);
    assert(wrap.observe(255) == 1);
    assert(wrap.observe(0) == 1);
    assert(wrap.observe(2) == 2);
    assert(wrap.total() == 4);
    std::puts("FAULT_DELIVERY_COUNTER_OK reset/repetition/hold/wrap");
}
