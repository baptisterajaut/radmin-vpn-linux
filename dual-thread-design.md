# Dual-Thread Bridge — Eliminate Head-of-Line Blocking

## Problem

The main loop processes outgoing (TAP → b2d) **before** incoming (d2b → TAP):

```
while (running):
  1. if FD_ISSET(tap_fd):      → write_exact(b2d, ...)  ← CAN BLOCK
  2. if FD_ISSET(d2b_high_fd): → write(tap_fd, ...)
  3. if FD_ISSET(d2b_low_fd):  → write(tap_fd, ...)
```

When `write_exact(b2d_fd, ...)` blocks (pipe full because Wine driver is busy), every
subsequent step stalls. Incoming frames pile up in d2b pipes. The game sees lag.

## Solution — Two Threads

```
┌──────────────────────────────────────────────────┐
│                    tap_bridge                     │
│                                                   │
│  ┌──────────────────┐      ┌──────────────────┐  │
│  │  incoming_thread  │      │  outgoing_thread  │  │
│  │                   │      │                   │  │
│  │ select(           │      │ select(tap_fd)    │  │
│  │   d2b_high_fd,    │      │ read(tap_fd)      │  │
│  │   d2b_low_fd)     │      │ write(b2d_fd)     │  │
│  │                   │      │                   │  │
│  │ read pipe → TAP   │      │ TAP → write pipe  │  │
│  └────────┬─────────┘      └────────┬──────────┘  │
│           │                         │              │
│           │      ┌──────────┐       │              │
│           │      │ arp_lock │       │              │
│           │      │ (mutex)  │       │              │
│           │      └────┬─────┘       │              │
│           │     ┌─────┴──────┐      │              │
│           │     │ g_arp_cache│      │              │
│           │     │ filters    │      │              │
│           │     │ running    │      │              │
│           │     └────────────┘      │              │
│           ▼                         ▼              │
│         TAP fd (full-duplex)                     │
│           │                         │              │
│      read(tap) ← kernel        write(tap)         │
│      write(tap) → kernel      read(tap) ← kernel  │
└──────────────────────────────────────────────────┘
```

### Thread 1 — `incoming_thread`
- `select()` on `d2b_high_fd` + `d2b_low_fd` only
- Reads frames from pipes, writes raw to TAP
- ARP snooping under `arp_lock`
- **Never blocks on outgoing**

### Thread 2 — `outgoing_thread`
- `select()` on `tap_fd` only (plus periodic filter reload)
- Reads frames from TAP, writes combined to b2d
- ARP snooping + proxy ARP under `arp_lock`
- Filter loading (once per second on select timeout)
- Minecraft multicast replication
- **Blocked on b2d write? Thread 1 keeps running**

---

## Shared State — Protection Matrix

| Symbol | Accessed by | Type | Protection | Why |
|--------|-------------|------|------------|-----|
| `g_arp_cache[]` | both | array of struct | `pthread_mutex_t arp_lock` | 6-byte MAC writes not atomic on x86 |
| `g_arp_cache_count` | both | int (write) | `arp_lock` | paired with array |
| `g_local_ip[4]` | both | uint8[4] (read-only after init) | none | set once in `main()`, never modified |
| `g_have_local_ip` | both | int (read-only after init) | none | set once in `main()` |
| `g_arp_replies_sent` | outgoing | unsigned long | `arp_lock` (under `try_arp_reply`) | counter |
| `g_arp_snooped` | both | unsigned long | `arp_lock` (under `arp_cache_update`) | counter |
| `filters` | both | struct (read/locked-write) | `pthread_rwlock_t filter_lock` | see below |
| `filters_mtime` | outgoing | time_t | `filter_lock` | paired with reload |
| `running` | both | volatile int | atomics / signal | set by handler, read by both |
| `tap_to_drv` | outgoing | unsigned long | none | only one writer |
| `drv_to_tap_high` | incoming | unsigned long | none | only one writer |
| `drv_to_tap_low` | incoming | unsigned long | none | only one writer |
| `drop_ip/mac/bcast` | both | unsigned long | `filter_lock` or atomic | updated inside `should_drop_frame` |
| `g_icmp_rx/g_icmp_tx` | driver-side | LONG (Interlocked) | InterlockedIncrement | driver uses Win32 atomics |

### ARP Cache (`arp_lock`)

A single `pthread_mutex_t` protects every ARP cache operation:

```c
static pthread_mutex_t g_arp_lock = PTHREAD_MUTEX_INITIALIZER;

// Thread-safe wrappers:
static void arp_cache_update_safe(const uint8_t ip[4], const uint8_t mac[6]) {
    pthread_mutex_lock(&g_arp_lock);
    arp_cache_update(ip, mac);    // the existing logic
    pthread_mutex_unlock(&g_arp_lock);
}
```

**Every entry point that reads or writes the cache** must hold the lock:
- `incoming_thread`: ARP snooping (IP & ARP frame parsing)
- `outgoing_thread`: ARP snooping (IP & ARP frame parsing)
- `outgoing_thread`: `try_arp_reply()` — reads cache, **injects gratuitous ARP to TAP** while holding lock
- Both: `inject_gratuitous_arp()` — writes to TAP (safe under lock, fast)
- Both: `arp_cache_lookup()` — reads cache entries

**Lock ordering**: `arp_lock` is always acquired alone, never nested inside another lock.
No lock ordering concerns.

**Critical section duration**: 1-3 µs (table lookup or entry fill). TAP write inside the
critical section (from `inject_gratuitous_arp`) is the only potential stall — but it's a
60-byte frame write, typically < 1 µs. Total worst-case hold time: ~5 µs.

### Filter Config (`filter_lock`)

`pthread_rwlock_t` because filters are **read-mostly**:

```c
static pthread_rwlock_t g_filter_lock = PTHREAD_RWLOCK_INITIALIZER;

// Incoming/outgoing frame check:
pthread_rwlock_rdlock(&g_filter_lock);
int drop = should_drop_frame(buf, len, direction);
pthread_rwlock_unlock(&g_filter_lock);

// Outgoing thread, periodic reload:
pthread_rwlock_wrlock(&g_filter_lock);
load_filters();  // the existing logic
pthread_rwlock_unlock(&g_filter_lock);
```

**Why rwlock instead of mutex?** Filter check is called on EVERY frame (~100+ times/sec).
Write lock only on reload (~1/sec). Read lock is shared — no contention between threads.

**Alternative**: atomically swap a pointer to an immutable filter snapshot. More complex,
not worth it for filter config that changes by user request only.

### Shared Drop Counters

`drop_ip`, `drop_mac`, `drop_bcast` are `static unsigned long` incremented by both threads
inside `should_drop_frame()`:

```c
// Both threads call this — counter increment is NOT atomic on x86-64
drop_mac++;
```

**Fix options:**
1. Move counters inside `filter_lock` (already held during `should_drop_frame`)
2. Use `__sync_fetch_and_add()` / `atomic_fetch_add()` (C11 atomics)

Option 1 is simplest (the counters are already inside the filter-check path).

### `running` Flag

```c
static volatile int running = 1;

void sig_handler(int sig) {
    (void)sig;
    __atomic_store_n(&running, 0, __ATOMIC_SEQ_CST);
}

// In each thread:
while (__atomic_load_n(&running, __ATOMIC_RELAXED)) {
    ...
}
```

On x86, plain `volatile int` reads/writes are already atomic for alignment. But
`volatile` does not guarantee memory ordering across threads. Using `__atomic` built-ins
adds the barrier. In practice, since SIGINT is delivered to one thread and the flag is
read in another, the `__atomic` fence matters.

---

## Shutdown Sequence

```
SIGINT/SIGTERM
    → sig_handler() sets running = 0
    → incoming_thread: select() wakes up (1s timeout max), checks running=0, exits
    → outgoing_thread: select() wakes up, or write() gets EINTR, checks running=0, exits
    → main() pthread_join() both threads
    → main() closes fds, unlinks FIFOs, returns
```

**Edge case**: outgoing thread blocked on `write(b2d_fd)` to a full pipe.
- SIGINT arrives, handler sets `running=0`
- Pipe is still full, write() blocks waiting for driver to read
- `write()` does NOT return EINTR (Linux: writes to pipes/FIFOs are interrupted by
  signals only if the signal handler was installed without SA_RESTART, BUT even then
  the interrupted write returns EINTR and `write_exact` retries)
- **Fix**: The bridge must wait for the driver to close its end of the FIFO (part of
  normal shutdown when Wine exits). The closing of the read end causes `write()` to
  return EPIPE or SIGPIPE. The bridge `write_exact` returns -1, thread exits.

**Practical timeout**: `run.sh` kills Wine first, then tap_bridge. By the time bridge
gets SIGTERM, Wine has already closed the FIFO → write gets EPIPE → thread exits.

---

## Thread Safety — Remaining Global State

| Symbol | Access Pattern | Safe? |
|--------|---------------|-------|
| `g_tap_fd` | set once in main(), read-only after | ✅ |
| `g_arp_cache[]` | both threads, under lock | ✅ |
| `g_arp_cache_count` | both threads, under lock | ✅ |
| `g_local_ip[]` | set once in main() | ✅ |
| `g_have_local_ip` | set once in main() | ✅ |
| `filters` | read under rwlock, write under wrlock | ✅ |
| `filters_mtime` | only outgoing thread writes, both read | ✅ (or move under rwlock) |
| `running` | volatile + atomic store/load | ✅ |
| `buf[RELAY_BUF_MAX]` | stack-local per thread | ✅ (each thread has own) |
| `tap_to_drv` | only outgoing thread | ✅ |
| `drv_to_tap_high/low` | only incoming thread | ✅ |
| `g_tap_fd write()` | both threads write to TAP | ✅ (kernel serializes per syscall) |
| `g_tap_fd read()` | only outgoing thread | ✅ |

---

## TAP fd — Concurrent Access

The TAP fd is **full-duplex**:
- `read()` pops frames FROM the kernel's send queue (packets leaving Linux)
- `write()` pushes frames INTO the kernel's receive queue (packets entering Linux)

These are separate queues inside the kernel. Multiple concurrent `write()` calls are safe
— each becomes a separate ethernet frame. `read()` and `write()` on the same fd from
different threads is standard Unix practice.

**No lock needed for TAP read/write.**

---

## Migration: single-thread → dual-thread

### Startup

```c
int main() {
    // ... existing setup (TAP, FIFOs, signal handler) ...

    pthread_t in_thr, out_thr;
    pthread_create(&out_thr, NULL, outgoing_thread, NULL);
    pthread_create(&in_thr,  NULL, incoming_thread,  NULL);

    // Wait for either thread to exit (error or shutdown)
    pthread_join(in_thr,  NULL);
    pthread_join(out_thr, NULL);

    // ... existing cleanup (close fds, unlink FIFOs) ...
}
```

### Incoming Thread

```c
static void *incoming_thread(void *arg) {
    (void)arg;
    uint8_t buf[RELAY_BUF_MAX];
    fd_set rfds;
    int maxfd = (d2b_high_fd > d2b_low_fd) ? d2b_high_fd : d2b_low_fd;

    while (__atomic_load_n(&running, __ATOMIC_RELAXED)) {
        FD_ZERO(&rfds);
        FD_SET(d2b_high_fd, &rfds);
        FD_SET(d2b_low_fd, &rfds);

        struct timeval tv = { .tv_sec = 0, .tv_usec = 200000 };  // 200ms
        int ret = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (ret < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (ret == 0) continue;  // timeout, check running

        // HIGH pipe — drain completely
        if (FD_ISSET(d2b_high_fd, &rfds)) {
            // ... same logic as current, but arp_update under lock ...
        }

        // LOW pipe — 1 frame with starvation guard
        if (FD_ISSET(d2b_low_fd, &rfds) || force_low) {
            // ... same logic, arp_update under lock ...
        }
    }
    return NULL;
}
```

### Outgoing Thread

```c
static void *outgoing_thread(void *arg) {
    (void)arg;
    uint8_t buf[RELAY_BUF_MAX];
    unsigned long tap_to_drv = 0;

    load_filters();  // initial load

    while (__atomic_load_n(&running, __ATOMIC_RELAXED)) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(tap_fd, &rfds);

        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
        int ret = select(tap_fd + 1, &rfds, NULL, NULL, &tv);
        if (ret < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (ret == 0) {
            pthread_rwlock_wrlock(&g_filter_lock);
            load_filters();
            pthread_rwlock_unlock(&g_filter_lock);
            continue;
        }

        if (FD_ISSET(tap_fd, &rfds)) {
            ssize_t n = read(tap_fd, buf, sizeof(buf));
            if (n <= 0) continue;

            uint16_t len = (uint16_t)n;

            // ARP snoop + proxy (under lock)
            pthread_mutex_lock(&g_arp_lock);
            if (len >= 42 && buf[12] == 0x08 && buf[13] == 0x06)
                arp_cache_update(buf + 28, buf + 22);
            try_arp_reply(tap_fd, buf, len);
            pthread_mutex_unlock(&g_arp_lock);

            // Filter check (read lock)
            pthread_rwlock_rdlock(&g_filter_lock);
            int drop = should_drop_frame(buf, len, 0);
            pthread_rwlock_unlock(&g_filter_lock);
            if (drop) continue;

            // Combined write to b2d
            uint8_t combined[2 + RELAY_BUF_MAX];
            combined[0] = (uint8_t)(len & 0xFF);
            combined[1] = (uint8_t)((len >> 8) & 0xFF);
            memcpy(combined + 2, buf, len);
            if (write_exact(b2d_fd, combined, 2 + len) < 0) {
                fprintf(stderr, "tap_bridge: b2d write failed\n");
                break;
            }
            tap_to_drv++;
            replicate_mcast_to_bcast(b2d_fd, buf, len, 1);
        }
    }
    return NULL;
}
```

---

## No-Lock Zones (Intentionally)

| Code | Why no lock |
|------|-------------|
| `write(tap_fd)` in incoming thread | TAP is full-duplex, kernel serializes |
| `read(tap_fd)` in outgoing thread | Only thread that reads TAP |
| Counter `tap_to_drv` | Only thread that writes it |
| Counters `drv_to_tap_high/low` | Only incoming thread writes them |
| `should_drop_frame()` counters | Under `filter_lock` (rwlock held) |
| `g_local_ip[4]` | Set once before threads start |
| `g_have_local_ip` | Set once before threads start |

---

## Future: Truly Non-Blocking Outgoing

If blocking `write(b2d_fd)` is still undesirable (e.g., Wine driver is slow and outgoing
TCP starts backing up), add a **retry buffer**:

```c
#define RETRY_BUF_SIZE 1024
#define FRAME_MAX 1518

struct retry_entry {
    uint8_t data[2 + FRAME_MAX];  // combined [len][frame]
    uint16_t total_len;
};

static struct retry_entry g_retry_ring[RETRY_BUF_SIZE];
static volatile int g_retry_head, g_retry_tail;
static pthread_mutex_t g_retry_lock = PTHREAD_MUTEX_INITIALIZER;
```

Then open b2d as `O_WRONLY | O_NONBLOCK`. On EAGAIN, push frame to retry ring.
On every select() iteration, flush retry ring before reading TAP. If ring fills up
(oldest frame gets dropped), TCP handles retransmission.

This makes **everything non-blocking** at the cost of complexity and potential drops.
Not recommended for the initial dual-thread implementation.
