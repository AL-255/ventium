// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "settle_fixed_point_audit.h"
#include <cassert>
#include <string>

struct AuditTestContext {
    uint64_t now = 0;
    uint64_t time() const { return now; }
};
struct AuditTestModel {
    AuditTestContext context;
    std::vector<uint8_t> state = std::vector<uint8_t>(1024 * 1024, 17);
    unsigned calls = 0, retired = 0;
    std::string mutation;
    auto contextp() { return &context; }
    void eval() {
        ++calls;
        if (mutation == "state") state.back() ^= 1;
        if (mutation == "retire") ++retired;
        if (mutation == "time") ++context.now;
    }
};
VerilatedSerialize& operator<<(VerilatedSerialize& out, AuditTestModel& model) {
    return out.write(model.state.data(), model.state.size());
}
int main(int argc, char** argv) {
    AuditTestModel model;
    if (argc > 1) model.mutation = argv[1];
    SettleFixedPointAudit audit;
    if (model.mutation == "oversize") model.state.resize(9 * 1024 * 1024);
    auto retired = [&]() { return model.retired; };
    audit.eval(model, false, retired);
    assert(model.calls == 1); // Noncandidate still executes.
    audit.eval(model, true, retired);
    assert(model.calls == 2); // Observed candidate also executes.
    return 0;
}
