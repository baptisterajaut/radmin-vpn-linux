# Dual-Thread TAP Bridge — Implementation Notes

This document records the changes made to `src/tap_bridge.c` in this session to implement the dual-thread design from `dual-thread-design.md` and push outgoing latency as low as possible.

## Goal

- Eliminate head-of-line blocking in the TAP bridge.
- Separate incoming (driver → TAP) and outgoing (TAP → driver) traffic into independent threads.
- Keep latency on the outgoing path as low as possible.
- Handle the case where the TAP device disappears during runtime without spinning on errors.

## What changed

### 1. Dual-thread architecture

The original single `main()` loop was replaced by two POSIX threads:

- `incoming_thread()` — waits on `d2b_high` and `d2b_low`, reads frames from the driver, and writes raw frames to the TAP device.
- `outgoing_thread()` — waits on the TAP fd, reads frames from the kernel, and writes `[len16][frame]` to the `b2d` FIFO.

Both threads share read-only fd globals set in `main()`:

```c
static int g_tap_fd;
static int g_b2d_fd;
static int g_d2b_high_fd;
static int g_d2b_low_fd;
```

The split guarantees that a slow or blocked `b2d` write cannot delay frames arriving from the driver.

### 2. Shared-state protection

| State | Protection |
|---|---|
| `g_arp_cache[]`, `g_arp_cache_count`, ARP counters, gratuitous ARP/reply | `pthread_mutex_t g_arp_lock` |
| `filters`, `filters_mtime`, `drop_*` counters | `pthread_rwlock_t g_filter_lock` |
| `running` | `__atomic_*` builtins |
| Per-thread counters (`g_tap_to_drv`, `g_drv_to_tap_high/low`) | None — single writer each |

Filter reload (once per second in `outgoing_thread`) takes a **write lock**. Frame filtering takes a **read lock**, so the two threads do not contend.

### 3. Non-blocking `b2d` with retry ring

To avoid blocking the outgoing thread when the Wine driver is slow:

1. `b2d` is opened blocking so `open()` waits for the driver to connect.
2. After the connection succeeds, `fcntl(F_SETFL, O_NONBLOCK)` is applied.
3. `write_exact()` was modified so a partial/non-blocking write returns `-1` with `EAGAIN` instead of spinning.
4. A single-producer/single-consumer retry ring was added:

```c
#define RETRY_RING_SIZE 8192
#define RETRY_RING_MASK (RETRY_RING_SIZE - 1)

struct retry_entry {
    uint16_t total_len;
    uint8_t  data[2 + RELAY_BUF_MAX];
};
```

- On `EAGAIN`, the combined `[len16][frame]` is copied into the ring.
- Before each new `read(TAP)`, `outgoing_thread()` flushes as much of the ring as the pipe will accept.
- If the ring fills up, the oldest frame is overwritten by dropping the new one (logged).

This keeps the read→process→write loop unblocked even when the driver cannot keep up.

### 4. Starvation guard for low-priority pipe

`incoming_thread()` drains the high-priority pipe completely before touching the low-priority pipe, but a timer guarantees at least one low-priority frame every `LOW_DRAIN_INTERVAL_US` (50 ms) so broadcasts/multicast do not starve.

### 5. TAP fd failures are now fatal

Previously, if the TAP device was removed while the bridge was running, `write(TAP)` returned `EBADFD`/`EIO` and the threads logged the error forever. Now:

- A permanent TAP write error in `incoming_thread` sets `running = 0` and exits.
- A permanent TAP error in `outgoing_thread` also stops the loop.
- This prevents log spam and CPU spin; the process shuts down cleanly and `run.sh` cleanup runs.

### 6. Filter loading

- `load_filters()` was split into `load_filters_internal()` which must be called with `g_filter_lock` held.
- Parsing is done into a temporary `filter_cfg_t`, then a single `memcpy` copies it into the live config.
- File I/O happens outside the lock; only the final swap is under the write lock, keeping reader latency minimal.

### 7. Build and runtime verification

- Builds cleanly with `gcc -Wall -O2 -lpthread`.
- Also builds with strict flags `-Wall -Wextra -Wshadow -Wstrict-prototypes -Wmissing-prototypes -Werror` with zero warnings.
- Smoke test passed: TAP created, bridge started, driver end of `b2d` opened, frame injected through `d2b_high`, frame observed on TAP, SIGINT shutdown clean.

## Important operational note

Because `b2d` is now opened **blocking** and then switched to non-blocking, do not start the bridge without the Wine driver also starting. `run.sh` handles this ordering. If `run.sh` is launched manually after stale FIFOs exist, remove them first:

```bash
sudo rm -f /tmp/rvpn_b2d /tmp/rvpn_d2b_high /tmp/rvpn_d2b_low
```

## Files changed

- `src/tap_bridge.c` — complete rewrite of the relay loop into dual threads, added locks, retry ring, and non-blocking `b2d`.

## Future work (not implemented)

- The retry ring currently drops the newest frame when full. For this workload (peaks around 2k pps) the ring almost never fills; the pipe drains faster than the TAP produces frames. Changing drop policy would only matter if the driver stalled for seconds.
- A lock-free SPSC queue is unnecessary here. The volatile-head/tail ring is single-producer/single-consumer and the critical path is already a memcpy + atomic store; the mutex/rwlock contention is on ARP/filter, not on the ring.
