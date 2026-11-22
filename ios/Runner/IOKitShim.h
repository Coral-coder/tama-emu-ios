// IOKit for the USB serial driver, loaded when the app runs: the iOS SDK has no IOKit module for
// Swift, but iPadOS (16 and later, M-series iPads) has the framework for apps that talk to their
// DriverKit driver. All functions return a kern_return_t (0: success) unless said otherwise.
#pragma once
#include <stdint.h>
#include <stddef.h>

/// 1 when IOKit could be loaded.
int tk_available(void);
/// Adapters the driver serves: up to max entries; returns how many. name: max * 64 bytes.
int tk_list(uint64_t *ids, int32_t *vids, int32_t *pids, char *names, int max);
/// Opens the driver's user client for the adapter with that registry ID.
int tk_open(uint64_t id, uint32_t *conn);
int tk_call(uint32_t conn, uint32_t selector, const uint64_t *in, uint32_t in_n, const void *in_s, size_t in_s_n,
            uint64_t *out, uint32_t *out_n, void *out_s, size_t *out_s_n);
void tk_close(uint32_t conn);
