/* time_shim.c — deterministic guest clock for the ao486 Win95 boot sim.
 *
 * LD_PRELOAD this so the host `time()` returns a fixed timestamp (FAKE_TIME, or
 * 2000-01-01 00:00:00 UTC by default) instead of the real wall-clock. Win95's
 * first-boot flow is date-sensitive (DST notice, file timestamps), so pinning the
 * clock makes the boot deterministic and reproducible run-to-run.
 *
 * Build:  cc -shared -fPIC -o tmp/time_shim.so ao486-sim/tools/time_shim.c
 * Use:    env TZ=UTC FAKE_TIME=946684800 LD_PRELOAD=../tmp/time_shim.so ./obj_dir/ao486sim ...
 */
#define _GNU_SOURCE
#include <time.h>
#include <stdlib.h>
time_t time(time_t *t){ const char*e=getenv("FAKE_TIME"); time_t v=e?(time_t)atoll(e):946684800L; if(t)*t=v; return v; }
