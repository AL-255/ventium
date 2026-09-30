// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#ifndef VENTIUM_SIM_STOP_REQUEST_H
#define VENTIUM_SIM_STOP_REQUEST_H

#include <cerrno>
#include <sys/stat.h>

namespace ven_host {

enum class SimStopStatus { absent, requested, error };
struct SimStopResult {
    SimStopStatus status;
    int error;
};

// Host supervision only: a stop request says nothing about guest correctness.
// stat deliberately follows symlinks, but the resolved object must be regular.
// A missing path is normal; every other failure stops the run unsuccessfully.
inline SimStopResult poll_sim_stop_request(const char *path) {
    if (!path) return {SimStopStatus::absent, 0};
    if (!*path) return {SimStopStatus::error, EINVAL};
    struct stat info;
    if (::stat(path, &info) != 0) {
        const int error = errno;
        return error == ENOENT ? SimStopResult{SimStopStatus::absent, 0}
                              : SimStopResult{SimStopStatus::error, error};
    }
    if (!S_ISREG(info.st_mode)) return {SimStopStatus::error, EINVAL};
    return {SimStopStatus::requested, 0};
}

} // namespace ven_host
#endif
