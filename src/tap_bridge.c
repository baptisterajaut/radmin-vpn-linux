/*
 * tap_bridge - Relay ethernet frames between a TAP device and two FIFOs.
 *
 * FIFOs (created by this process):
 *   /tmp/rvpn_b2d       — bridge-to-driver (TAP → Wine): bridge writes, driver reads
 *   /tmp/rvpn_d2b_high  — driver-to-bridge high priority (Wine → TAP): TCP/ICMP/unicast UDP
 *   /tmp/rvpn_d2b_low   — driver-to-bridge low priority (Wine → TAP): broadcasts/multicasts/rest
 *   /tmp/rvpn_d2b       — legacy single pipe — not created by new code
 *
 * Frame protocol on FIFOs: [uint16_t length][uint8_t frame[length]]
 * Length is native byte order (both sides are the same machine).
 *
 * The bridge opens (or attaches to) a TAP device, then runs two independent threads:
 *   - incoming_thread: reads [len][frame] from d2b FIFOs → writes raw frame to TAP
 *   - outgoing_thread: reads frames from TAP → writes [len][frame] to b2d FIFO
 *
 * Dual-threading eliminates head-of-line blocking: a stalled b2d write cannot
 * delay incoming frames arriving from the driver.
 *
 * Build: gcc -Wall -O2 -o tap_bridge tap_bridge.c -lpthread
 * Usage: sudo ./tap_bridge <vpn-ip> [netmask-bits]
 *   e.g.: sudo ./tap_bridge 26.145.88.170 8
 */

#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <time.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <net/if.h>
#include <linux/if_tun.h>
#include <sys/socket.h>
#include <arpa/inet.h>

/* ── Filter config (read from /tmp/rvpn_filters.json) ── */
#define FILTER_PATH    "/tmp/rvpn_filters.json"
#define MAX_FILTERS    256

typedef struct {
    int   block_ips_enabled;
    char  blocked_ips[MAX_FILTERS][48];
    int   blocked_ips_count;
    int   block_macs_enabled;
    char  blocked_macs[MAX_FILTERS][18];
    int   blocked_macs_count;
    int   block_broadcast_enabled;
    char  broadcast_block_ips[MAX_FILTERS][48];
    int   broadcast_block_ips_count;
} filter_cfg_t;

static filter_cfg_t filters;
static time_t       filters_mtime = 0;
static unsigned long drop_ip = 0, drop_mac = 0, drop_bcast = 0;

static pthread_rwlock_t g_filter_lock = PTHREAD_RWLOCK_INITIALIZER;

/* ── ARP snoop cache ── */
#define ARP_CACHE_SIZE 256
#define ARP_CACHE_TTL_SEC 600

typedef struct {
    time_t   last_seen;
    int      valid;
    uint8_t  ip[4];
    uint8_t  mac[6];
} arp_cache_entry_t;

static arp_cache_entry_t g_arp_cache[ARP_CACHE_SIZE];
static int               g_arp_cache_count = 0;
static unsigned long     g_arp_replies_sent = 0;
static unsigned long     g_arp_snooped = 0;
static uint8_t           g_local_ip[4] = {0};
static int               g_have_local_ip = 0;

static pthread_mutex_t g_arp_lock = PTHREAD_MUTEX_INITIALIZER;

#define TAP_DEV_NAME    "radminvpn0"
#define FIFO_B2D        "/tmp/rvpn_b2d"
#define FIFO_D2B_HIGH   "/tmp/rvpn_d2b_high"
#define FIFO_D2B_LOW    "/tmp/rvpn_d2b_low"
#define MTU             1500
#define FRAME_MAX       (MTU + 14 + 4)
/* The Wine driver (rvpnnetmp.c) bounds d2b frames by RX_FRAME_MAX (1600), which
 * exceeds FRAME_MAX. Size the relay buffer to that ceiling (+ margin) so an
 * oversized frame is read in full rather than desyncing the FIFO or killing the
 * relay loop. Keep in sync with rvpnnetmp.c RX_FRAME_MAX. */
#define RELAY_BUF_MAX   2048

/* Starvation guard: ensure low-priority frames are drained at least this often
 * (microseconds) even when the high-priority pipe is continuously busy. */
#define LOW_DRAIN_INTERVAL_US   50000

#define RETRY_RING_SIZE 8192
#define RETRY_RING_MASK (RETRY_RING_SIZE - 1)

struct retry_entry {
    uint16_t total_len;
    uint8_t  data[2 + RELAY_BUF_MAX];
};

static struct retry_entry g_retry_ring[RETRY_RING_SIZE];
static volatile uint32_t  g_retry_head = 0;
static volatile uint32_t  g_retry_tail = 0;

static volatile int running = 1;

/* Global file descriptors, set once in main() and read-only by the threads. */
static int g_tap_fd = -1;
static int g_b2d_fd = -1;
static int g_d2b_high_fd = -1;
static int g_d2b_low_fd = -1;

/* Per-thread counters (only one writer each). */
static unsigned long g_tap_to_drv = 0;      /* outgoing_thread only */
static unsigned long g_drv_to_tap_high = 0; /* incoming_thread only */
static unsigned long g_drv_to_tap_low = 0;  /* incoming_thread only */

/* Signal handler for graceful shutdown */
static void sig_handler(int sig)
{
    (void)sig;
    __atomic_store_n(&running, 0, __ATOMIC_SEQ_CST);
}

/* Forward declaration */
static int write_exact(int fd, const void *buf, size_t n);

/* Recalculate IP header checksum for a frame (eth + IP header) */
static void fix_ip_checksum(uint8_t *frame)
{
    uint8_t ihl = (frame[14] & 0x0F) * 4;
    frame[24] = 0; frame[25] = 0;
    uint32_t sum = 0;
    for (int i = 0; i < ihl; i += 2)
        sum += ((uint32_t)frame[14 + i] << 8) | frame[15 + i];
    while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
    uint16_t csum = ~((uint16_t)sum);
    frame[24] = (csum >> 8) & 0xFF;
    frame[25] = csum & 0xFF;
}

/* Write a frame to either FIFO ([len16][frame]) or TAP (raw frame) */
static int write_frame(int fd, const uint8_t *data, uint16_t len, int is_fifo)
{
    if (is_fifo) {
        if (write_exact(fd, &len, 2) < 0 ||
            write_exact(fd, data, len) < 0)
            return 0;
    } else {
        if (write_exact(fd, data, len) < 0)
            return 0;
    }
    return 1;
}

/* Minecraft LAN multicast replicator:
 * Check if an ethernet frame is IPv4 with destination 224.0.2.60.
 * If so, copy the frame and replicate it as broadcast to both
 * 26.255.255.255 and 255.255.255.255, with:
 *   - dest MAC  → ff:ff:ff:ff:ff:ff (broadcast)
 *   - dest IP   → 26.255.255.255 / 255.255.255.255
 *   - recalculate IP header checksum
 *   - zero UDP checksum (valid for IPv4 UDP — checksum is optional)
 * is_fifo=1: write [len16][frame] to FIFO; is_fifo=0: write raw frame to TAP fd.
 * Returns number of replicas written (0, 1, or 2). */
static int replicate_mcast_to_bcast(int write_fd, const uint8_t *frame, uint16_t frame_len, int is_fifo)
{
    if (frame_len < 42) return 0;  /* 14 eth + 20 IP + 8 UDP minimum */

    /* Must be IPv4 */
    if (frame[12] != 0x08 || frame[13] != 0x00) return 0;

    /* Check destination IP at offset 30 (14 eth + 16 IP offset for dst) */
    if (frame[30] != 224 || frame[31] != 0 || frame[32] != 2 || frame[33] != 60)
        return 0;

    /* Must be UDP (IP protocol field at offset 23) */
    if (frame[23] != 17) return 0;

    uint8_t ihl = (frame[14] & 0x0F) * 4;
    int udp_csum_off = 14 + ihl + 6;  /* UDP checksum offset in frame */

    int count = 0;
    uint8_t copy[FRAME_MAX];
    if ((uint16_t)sizeof(copy) < frame_len) return 0;

    /* --- Replica 1: 26.255.255.255 --- */
    memcpy(copy, frame, frame_len);
    memset(copy, 0xFF, 6);           /* broadcast MAC */
    copy[30] = 26; copy[31] = 255; copy[32] = 255; copy[33] = 255;
    fix_ip_checksum(copy);
    if (frame_len > (uint16_t)(udp_csum_off + 1)) { copy[udp_csum_off] = 0; copy[udp_csum_off + 1] = 0; }
    if (write_frame(write_fd, copy, frame_len, is_fifo)) {
        count++;
        fprintf(stderr, "tap_bridge: replicated 224.0.2.60 → 26.255.255.255 (%u bytes)\n", frame_len);
    }

    /* --- Replica 2: 255.255.255.255 --- */
    memcpy(copy, frame, frame_len);
    memset(copy, 0xFF, 6);           /* broadcast MAC */
    copy[30] = 255; copy[31] = 255; copy[32] = 255; copy[33] = 255;
    fix_ip_checksum(copy);
    if (frame_len > (uint16_t)(udp_csum_off + 1)) { copy[udp_csum_off] = 0; copy[udp_csum_off + 1] = 0; }
    if (write_frame(write_fd, copy, frame_len, is_fifo)) {
        count++;
        fprintf(stderr, "tap_bridge: replicated 224.0.2.60 → 255.255.255.255 (%u bytes)\n", frame_len);
    }

    return count;
}

/* Write exactly n bytes. If fd is non-blocking, returns -1 with EAGAIN
 * when the pipe cannot accept the whole buffer right now. */
static int write_exact(int fd, const void *buf, size_t n)
{
    size_t done = 0;
    while (done < n) {
        ssize_t w = write(fd, (const char *)buf + done, n - done);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (w == 0) return -1;
        done += w;
    }
    return 0;
}

/* Push a combined [len16][frame] into the retry ring. Returns 0 on success,
 * -1 if the ring is full. Called only from outgoing_thread. */
static int retry_ring_push(const uint8_t *combined, uint16_t total_len)
{
    uint32_t head = __atomic_load_n(&g_retry_head, __ATOMIC_RELAXED);
    uint32_t next = (head + 1) & RETRY_RING_MASK;
    if (next == __atomic_load_n(&g_retry_tail, __ATOMIC_RELAXED))
        return -1;  /* full */

    g_retry_ring[head].total_len = total_len;
    memcpy(g_retry_ring[head].data, combined, total_len);
    __atomic_store_n(&g_retry_head, next, __ATOMIC_RELEASE);
    return 0;
}

/* Try to send one retry-ring entry. Returns 1 if an entry was sent, 0 if empty,
 * -1 on unrecoverable b2d error. */
static int retry_ring_flush_one(void)
{
    uint32_t tail = __atomic_load_n(&g_retry_tail, __ATOMIC_ACQUIRE);
    if (tail == __atomic_load_n(&g_retry_head, __ATOMIC_RELAXED))
        return 0;

    struct retry_entry *e = &g_retry_ring[tail];
    if (write_exact(g_b2d_fd, e->data, e->total_len) < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return 0;
        return -1;
    }

    __atomic_store_n(&g_retry_tail, (tail + 1) & RETRY_RING_MASK, __ATOMIC_RELEASE);
    return 1;
}

/* Drain as much of the retry ring as possible. Returns -1 on unrecoverable
 * b2d error, 0 otherwise. */
static int retry_ring_flush(void)
{
    while (__atomic_load_n(&g_retry_head, __ATOMIC_RELAXED) !=
           __atomic_load_n(&g_retry_tail, __ATOMIC_RELAXED)) {
        int rc = retry_ring_flush_one();
        if (rc < 0) return -1;
        if (rc == 0) break;
    }
    return 0;
}

/* Open/attach to the TAP device
 * Creates or attaches to an existing TAP device for ethernet frame I/O.
 * IFF_NO_PI: no packet information header (we want raw ethernet frames) */
static int open_tap(const char *dev_name)
{
    struct ifreq ifr;
    int fd = open("/dev/net/tun", O_RDWR);
    if (fd < 0) { perror("open /dev/net/tun"); return -1; }

    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
    strncpy(ifr.ifr_name, dev_name, IFNAMSIZ - 1);

    if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
        perror("ioctl TUNSETIFF");
        close(fd);
        return -1;
    }
    fprintf(stderr, "tap_bridge: attached to '%s' (fd=%d)\n", ifr.ifr_name, fd);
    return fd;
}

/* Create named pipes for communication with Wine driver
 * FIFO_B2D:       bridge-to-driver (TAP → Wine): bridge writes, driver reads
 * FIFO_D2B_HIGH:  driver-to-bridge high priority (Wine → TAP)
 * FIFO_D2B_LOW:   driver-to-bridge low priority (Wine → TAP) */
static void create_fifos(void)
{
    unlink(FIFO_B2D);
    unlink(FIFO_D2B_HIGH);
    unlink(FIFO_D2B_LOW);
    mkfifo(FIFO_B2D, 0666);
    mkfifo(FIFO_D2B_HIGH, 0666);
    mkfifo(FIFO_D2B_LOW, 0666);
    fprintf(stderr, "tap_bridge: FIFOs created: %s, %s, %s\n",
            FIFO_B2D, FIFO_D2B_HIGH, FIFO_D2B_LOW);
}

/* Read exactly n bytes; returns 0 on success, -1 on error or EOF.
 * For non-blocking fds an empty pipe (EAGAIN/EWOULDBLOCK) is reported as
 * -1 so callers can return to select instead of spinning. */
static int read_exact(int fd, void *buf, size_t n)
{
    size_t done = 0;
    while (done < n) {
        ssize_t r = read(fd, (char *)buf + done, n - done);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (r == 0) return -1;
        done += r;
    }
    return 0;
}

/* ── Minimal JSON helpers (no library dependency) ── */

static const char *json_find_key(const char *json, const char *key)
{
    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *p = strstr(json, needle);
    if (!p) return NULL;
    p += strlen(needle);
    while (*p == ' ' || *p == '\t' || *p == ':' || *p == '\n' || *p == '\r') p++;
    return p;
}

static int json_bool(const char *json, const char *key, int defval)
{
    const char *p = json_find_key(json, key);
    if (!p) return defval;
    if (strncmp(p, "true", 4) == 0) return 1;
    if (strncmp(p, "false", 5) == 0) return 0;
    return defval;
}

static int json_str_array(const char *json, const char *key,
                          char *out, int max_out, int elem_size, int max_len)
{
    const char *p = json_find_key(json, key);
    if (!p || *p != '[') return 0;
    p++; /* skip '[' */
    int count = 0;
    while (count < max_out) {
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ',') p++;
        if (*p == ']' || *p == '\0') break;
        if (*p != '"') { p++; continue; }
        p++; /* skip opening quote */
        char *entry = out + (size_t)count * elem_size;
        int i = 0;
        while (*p && *p != '"' && i < max_len - 1) entry[i++] = *p++;
        entry[i] = '\0';
        if (*p == '"') p++;
        count++;
    }
    return count;
}

/* Load filter config from JSON file. Caller must hold g_filter_lock in write mode.
 * File I/O is performed outside the lock; only the final memcpy into the live
 * filter config happens under the write lock, keeping reader latency minimal. */
static void load_filters_internal(void)
{
    struct stat st;
    if (stat(FILTER_PATH, &st) != 0) return;
    if (st.st_mtime == filters_mtime) return;  /* unchanged */

    FILE *f = fopen(FILTER_PATH, "r");
    if (!f) return;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return; }
    long sz = ftell(f);
    if (sz <= 0 || sz > 65536) { fclose(f); return; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return; }
    char *buf = malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return; }
    size_t rd = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    if (rd != (size_t)sz) { free(buf); return; }
    buf[sz] = '\0';

    filter_cfg_t tmp;
    memset(&tmp, 0, sizeof(tmp));
    tmp.block_ips_enabled       = json_bool(buf, "block_ips_enabled", 0);
    tmp.block_macs_enabled      = json_bool(buf, "block_macs_enabled", 0);
    tmp.block_broadcast_enabled = json_bool(buf, "block_broadcast_enabled", 0);
    tmp.blocked_ips_count       = json_str_array(buf, "blocked_ips",
                                        (char *)tmp.blocked_ips, MAX_FILTERS, 48, 48);
    tmp.blocked_macs_count      = json_str_array(buf, "blocked_macs",
                                        (char *)tmp.blocked_macs, MAX_FILTERS, 18, 18);
    tmp.broadcast_block_ips_count = json_str_array(buf, "broadcast_block_ips",
                                        (char *)tmp.broadcast_block_ips, MAX_FILTERS, 48, 48);
    free(buf);

    filters_mtime = st.st_mtime;
    memcpy(&filters, &tmp, sizeof(filters));
    fprintf(stderr, "tap_bridge: filters loaded (ip=%d/%d mac=%d/%d bcast=%d/%d)\n",
            filters.block_ips_enabled, filters.blocked_ips_count,
            filters.block_macs_enabled, filters.blocked_macs_count,
            filters.block_broadcast_enabled, filters.broadcast_block_ips_count);
}

/* Parse "A.B.C.D" into 4 bytes. Returns 0 on success. */
static int parse_ip(const char *s, uint8_t out[4])
{
    unsigned a, b, c, d;
    if (sscanf(s, "%u.%u.%u.%u", &a, &b, &c, &d) != 4) return -1;
    if (a > 255 || b > 255 || c > 255 || d > 255) return -1;
    out[0] = (uint8_t)a; out[1] = (uint8_t)b;
    out[2] = (uint8_t)c; out[3] = (uint8_t)d;
    return 0;
}

/* Parse "aa:bb:cc:dd:ee:ff" into 6 bytes. Returns 0 on success. */
static int parse_mac(const char *s, uint8_t out[6])
{
    unsigned m[6];
    if (sscanf(s, "%x:%x:%x:%x:%x:%x",
              &m[0], &m[1], &m[2], &m[3], &m[4], &m[5]) != 6) return -1;
    for (int i = 0; i < 6; i++) { if (m[i] > 255) return -1; out[i] = (uint8_t)m[i]; }
    return 0;
}

/* Check if an IPv4 address matches any entry in a filter list. */
static int ip_in_list(const uint8_t ip[4], const char list[][48], int count)
{
    for (int i = 0; i < count; i++) {
        uint8_t fip[4];
        if (parse_ip(list[i], fip) == 0 &&
            ip[0] == fip[0] && ip[1] == fip[1] && ip[2] == fip[2] && ip[3] == fip[3])
            return 1;
    }
    return 0;
}

/* Check if a MAC address matches any entry in a filter list. */
static int mac_in_list(const uint8_t mac[6], const char list[][18], int count)
{
    for (int i = 0; i < count; i++) {
        uint8_t fmac[6];
        if (parse_mac(list[i], fmac) == 0 &&
            memcmp(mac, fmac, 6) == 0)
            return 1;
    }
    return 0;
}

/*
 * should_drop_frame — decide whether a frame should be dropped.
 * direction: 0 = TAP→driver (outgoing), 1 = driver→TAP (incoming)
 * Returns: 0 = pass, 1 = drop
 *
 * Caller must hold g_filter_lock (read or write mode). drop_* counters are
 * therefore protected by the same lock.
 */
static int should_drop_frame(const uint8_t *frame, uint16_t len, int direction)
{
    if (len < 14) return 0;  /* too short to be ethernet */

    /* ── Block MACs (both directions) ── */
    if (filters.block_macs_enabled && filters.blocked_macs_count > 0) {
        const uint8_t *src_mac = frame;
        const uint8_t *dst_mac = frame + 6;
        if (mac_in_list(src_mac, filters.blocked_macs, filters.blocked_macs_count) ||
            mac_in_list(dst_mac, filters.blocked_macs, filters.blocked_macs_count)) {
            drop_mac++;
            if (drop_mac <= 5 || (drop_mac % 100) == 0)
                fprintf(stderr, "tap_bridge: DROP mac #%lu (dir=%s)\n", drop_mac,
                        direction ? "drv→TAP" : "TAP→drv");
            return 1;
        }
    }

    /* Must be IPv4 for IP-based checks */
    if (len < 34 || frame[12] != 0x08 || frame[13] != 0x00) return 0;

    /* Validate IPv4 header: version==4 and IHL>=5 (min 20-byte header) */
    uint8_t ip_ver_ihl = frame[14];
    if ((ip_ver_ihl >> 4) != 4 || (ip_ver_ihl & 0x0F) < 5) return 0;

    /* Validate IP total length fits within the frame payload */
    uint16_t ip_total_len = ((uint16_t)frame[16] << 8) | frame[17];
    if (ip_total_len < 20 || ip_total_len > (len - 14)) return 0;

    const uint8_t *src_ip = frame + 26;
    const uint8_t *dst_ip = frame + 30;

    /* ── Block IPs (both directions) ── */
    if (filters.block_ips_enabled && filters.blocked_ips_count > 0) {
        if (ip_in_list(src_ip, filters.blocked_ips, filters.blocked_ips_count) ||
            ip_in_list(dst_ip, filters.blocked_ips, filters.blocked_ips_count)) {
            drop_ip++;
            if (drop_ip <= 5 || (drop_ip % 100) == 0)
                fprintf(stderr, "tap_bridge: DROP ip #%lu (dir=%s, src=%u.%u.%u.%u)\n",
                        drop_ip, direction ? "drv→TAP" : "TAP→drv",
                        src_ip[0], src_ip[1], src_ip[2], src_ip[3]);
            return 1;
        }
    }

    /* ── Block Broadcast (incoming only: driver→TAP) ── */
    if (direction == 1 &&
        filters.block_broadcast_enabled && filters.broadcast_block_ips_count > 0) {
        /* Must be UDP */
        if (frame[23] != 17) return 0;

        /* Check if src or dst IP is in broadcast block list */
        if (ip_in_list(src_ip, filters.broadcast_block_ips, filters.broadcast_block_ips_count) ||
            ip_in_list(dst_ip, filters.broadcast_block_ips, filters.broadcast_block_ips_count)) {
            /* Check UDP port 4445 (src or dst) */
            uint8_t ihl = (frame[14] & 0x0F) * 4;
            if (len < (uint16_t)(14 + ihl + 8)) return 0;  /* too short for UDP hdr */
            const uint8_t *udp_hdr = frame + 14 + ihl;
            uint16_t src_port = ((uint16_t)udp_hdr[0] << 8) | udp_hdr[1];
            uint16_t dst_port = ((uint16_t)udp_hdr[2] << 8) | udp_hdr[3];
            if (src_port == 4445 || dst_port == 4445) {
                drop_bcast++;
                if (drop_bcast <= 5 || (drop_bcast % 100) == 0)
                    fprintf(stderr, "tap_bridge: DROP bcast #%lu (ip=%u.%u.%u.%u port=%u/%u)\n",
                            drop_bcast, src_ip[0], src_ip[1], src_ip[2], src_ip[3],
                            src_port, dst_port);
                return 1;
            }
        }
    }

    return 0;
}

/* Detect local TAP IP so we don't cache our own MAC */
static void detect_local_ip(const char *ifname)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFADDR, &ifr) == 0) {
        struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
        memcpy(g_local_ip, &sin->sin_addr.s_addr, 4);
        g_have_local_ip = 1;
        fprintf(stderr, "tap_bridge: local IP %u.%u.%u.%u\n",
                g_local_ip[0], g_local_ip[1], g_local_ip[2], g_local_ip[3]);
    }
    close(fd);
}

/* Inject a gratuitous ARP reply into the TAP device so the Linux kernel
 * learns the IP-MAC mapping immediately, without needing to send its own
 * ARP request through the tunnel (which takes ~1-2s and drops the first ping).
 * Caller must hold g_arp_lock. */
static void inject_gratuitous_arp(const uint8_t ip[4], const uint8_t mac[6])
{
    if (g_tap_fd < 0) return;

    uint8_t garp[60];
    memset(garp, 0, sizeof(garp));

    /* Ethernet header: broadcast destination */
    memset(garp, 0xFF, 6);           /* dst = broadcast */
    memcpy(garp + 6, mac, 6);        /* src = announced MAC */
    garp[12] = 0x08; garp[13] = 0x06; /* ARP */

    /* ARP payload */
    garp[14] = 0x00; garp[15] = 0x01; /* HTYPE = Ethernet */
    garp[16] = 0x08; garp[17] = 0x00; /* PTYPE = IPv4 */
    garp[18] = 6;                      /* HLEN */
    garp[19] = 4;                      /* PLEN */
    garp[20] = 0x00; garp[21] = 0x02; /* opcode = reply */
    memcpy(garp + 22, mac, 6);        /* sender MAC */
    memcpy(garp + 28, ip, 4);         /* sender IP */
    memcpy(garp + 32, mac, 6);        /* target MAC */
    memcpy(garp + 38, ip, 4);         /* target IP */

    if (write(g_tap_fd, garp, 60) == 60) {
        g_arp_replies_sent++;
        fprintf(stderr, "tap_bridge: gratuitous ARP for %u.%u.%u.%u -> "
                "%02x:%02x:%02x:%02x:%02x:%02x\n",
                ip[0], ip[1], ip[2], ip[3],
                mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    }
}

/* Caller must hold g_arp_lock. */
static void arp_cache_update(const uint8_t ip[4], const uint8_t mac[6])
{
    if (g_have_local_ip && memcmp(ip, g_local_ip, 4) == 0) return;

    time_t now = time(NULL);

    /* Update existing entry */
    for (int i = 0; i < g_arp_cache_count; i++) {
        if (g_arp_cache[i].valid && memcmp(g_arp_cache[i].ip, ip, 4) == 0) {
            memcpy(g_arp_cache[i].mac, mac, 6);
            g_arp_cache[i].last_seen = now;
            return;
        }
    }

    /* Reuse expired slot */
    for (int i = 0; i < g_arp_cache_count; i++) {
        if (!g_arp_cache[i].valid ||
            (now - g_arp_cache[i].last_seen) > ARP_CACHE_TTL_SEC) {
            memcpy(g_arp_cache[i].ip, ip, 4);
            memcpy(g_arp_cache[i].mac, mac, 6);
            g_arp_cache[i].last_seen = now;
            g_arp_cache[i].valid = 1;
            g_arp_snooped++;
            inject_gratuitous_arp(ip, mac);
            return;
        }
    }

    /* Append if room */
    if (g_arp_cache_count < ARP_CACHE_SIZE) {
        int i = g_arp_cache_count++;
        memcpy(g_arp_cache[i].ip, ip, 4);
        memcpy(g_arp_cache[i].mac, mac, 6);
        g_arp_cache[i].last_seen = now;
        g_arp_cache[i].valid = 1;
        g_arp_snooped++;
        inject_gratuitous_arp(ip, mac);
        return;
    }

    /* Overwrite oldest */
    int oldest = 0;
    for (int i = 1; i < ARP_CACHE_SIZE; i++) {
        if (g_arp_cache[i].last_seen < g_arp_cache[oldest].last_seen)
            oldest = i;
    }
    memcpy(g_arp_cache[oldest].ip, ip, 4);
    memcpy(g_arp_cache[oldest].mac, mac, 6);
    g_arp_cache[oldest].last_seen = now;
    g_arp_cache[oldest].valid = 1;
    g_arp_snooped++;
    inject_gratuitous_arp(ip, mac);
}

/* Caller must hold g_arp_lock. */
static int arp_cache_lookup(const uint8_t ip[4], uint8_t out_mac[6])
{
    time_t now = time(NULL);
    for (int i = 0; i < g_arp_cache_count; i++) {
        if (g_arp_cache[i].valid && memcmp(g_arp_cache[i].ip, ip, 4) == 0) {
            if ((now - g_arp_cache[i].last_seen) <= ARP_CACHE_TTL_SEC) {
                memcpy(out_mac, g_arp_cache[i].mac, 6);
                return 1;
            }
            g_arp_cache[i].valid = 0;
        }
    }
    return 0;
}

/* If frame is an ARP request whose target IP is in cache, inject reply on tap_fd.
 * Caller must hold g_arp_lock. */
static int try_arp_reply(int tap_fd, const uint8_t *frame, uint16_t len)
{
    if (len < 42) return 0;
    if (frame[12] != 0x08 || frame[13] != 0x06) return 0;  /* not ARP */
    if (frame[20] != 0x00 || frame[21] != 0x01) return 0;  /* not request */

    const uint8_t *target_ip = frame + 38;
    uint8_t cached_mac[6];
    if (!arp_cache_lookup(target_ip, cached_mac)) return 0;

    uint8_t reply[60];
    memset(reply, 0, sizeof(reply));

    /* Ethernet header */
    memcpy(reply, frame + 6, 6);        /* dest = requester MAC */
    memcpy(reply + 6, cached_mac, 6);   /* src = cached target MAC */
    reply[12] = 0x08; reply[13] = 0x06; /* ARP ethertype */

    /* ARP payload */
    reply[14] = 0x00; reply[15] = 0x01; /* HTYPE = Ethernet */
    reply[16] = 0x08; reply[17] = 0x00; /* PTYPE = IPv4 */
    reply[18] = 6;                      /* HLEN */
    reply[19] = 4;                      /* PLEN */
    reply[20] = 0x00; reply[21] = 0x02; /* opcode = reply */
    memcpy(reply + 22, cached_mac, 6);  /* sender MAC */
    memcpy(reply + 28, target_ip, 4);   /* sender IP */
    memcpy(reply + 32, frame + 6, 6);   /* target MAC = requester */
    memcpy(reply + 38, frame + 28, 4);  /* target IP = requester IP */

    if (write(tap_fd, reply, 60) == 60) {
        g_arp_replies_sent++;
        if (g_arp_replies_sent <= 5 || (g_arp_replies_sent % 50) == 0)
            fprintf(stderr, "tap_bridge: ARP reply #%lu for %u.%u.%u.%u\n",
                    g_arp_replies_sent,
                    target_ip[0], target_ip[1], target_ip[2], target_ip[3]);
        return 1;
    }
    return 0;
}

/* Process one driver-to-bridge frame: snoop ARP/IP, filter, write to TAP,
 * replicate multicast. On success returns 0 and writes the frame length into
 * *out_len. Returns -1 on fatal read error/EOF; returns 0 with *out_len=0 when
 * the non-blocking pipe is momentarily empty (EAGAIN). */
static int process_incoming_frame(int fd, uint8_t *buf, uint16_t *out_len)
{
    *out_len = 0;

    uint16_t len;
    if (read_exact(fd, &len, 2) < 0) {
        /* EAGAIN/EWOULDBLOCK means the pipe was drained; EOF/error is fatal. */
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return 0;
        return -1;
    }
    if (len > RELAY_BUF_MAX) {
        fprintf(stderr, "tap_bridge: corrupt frame len %u > %d\n", len, RELAY_BUF_MAX);
        return -1;
    }
    if (read_exact(fd, buf, len) < 0)
        return -1;

    *out_len = len;

    /* ARP snooping under arp_lock. */
    pthread_mutex_lock(&g_arp_lock);
    if (len >= 34 && buf[12] == 0x08 && buf[13] == 0x00)
        arp_cache_update(buf + 26, buf + 6);
    if (len >= 42 && buf[12] == 0x08 && buf[13] == 0x06)
        arp_cache_update(buf + 28, buf + 22);
    pthread_mutex_unlock(&g_arp_lock);

    /* Filter check under read lock. */
    pthread_rwlock_rdlock(&g_filter_lock);
    int drop = should_drop_frame(buf, len, 1);
    pthread_rwlock_unlock(&g_filter_lock);
    if (drop)
        return 0;

    if (write(g_tap_fd, buf, len) != (ssize_t)len) {
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return 0;
        perror("tap_bridge: write to TAP");
        __atomic_store_n(&running, 0, __ATOMIC_SEQ_CST);
        return -1;
    }

    replicate_mcast_to_bcast(g_tap_fd, buf, len, 0);
    return 0;
}

/* Incoming thread: driver → TAP (high + low priority FIFOs).
 * Never blocks on the outgoing b2d FIFO, so a slow/stalled Wine driver cannot
 * delay frames entering the Linux TAP. */
static void *incoming_thread(void *arg)
{
    (void)arg;
    uint8_t buf[RELAY_BUF_MAX];
    int maxfd = (g_d2b_high_fd > g_d2b_low_fd) ? g_d2b_high_fd : g_d2b_low_fd;

    struct timespec last_low_attempt = {0};
    int have_last_low_attempt = 0;

    int fatal = 0;
    while (__atomic_load_n(&running, __ATOMIC_RELAXED) && !fatal) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(g_d2b_high_fd, &rfds);
        FD_SET(g_d2b_low_fd, &rfds);

        struct timeval tv = { .tv_sec = 0, .tv_usec = 200000 };  /* 200ms */
        int ret = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (ret < 0) {
            if (errno == EINTR) continue;
            perror("tap_bridge: incoming select");
            break;
        }

        /* HIGH pipe: drain completely before touching low. */
        if (FD_ISSET(g_d2b_high_fd, &rfds)) {
            while (__atomic_load_n(&running, __ATOMIC_RELAXED)) {
                uint16_t len = 0;
                int rc = process_incoming_frame(g_d2b_high_fd, buf, &len);
                if (rc < 0) { fatal = 1; break; }
                if (len == 0)
                    break;  /* drained */
                g_drv_to_tap_high++;
                if (g_drv_to_tap_high <= 5 || (g_drv_to_tap_high % 100) == 0)
                    fprintf(stderr, "tap_bridge: drv→TAP(high) #%lu (%u bytes)\n",
                            g_drv_to_tap_high, len);
            }
        }
        if (fatal) break;

        /* LOW pipe: one frame, with a starvation guard. */
        int low_ready = FD_ISSET(g_d2b_low_fd, &rfds);
        int force_low = 0;
        if (!low_ready && have_last_low_attempt) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            long long us = (now.tv_sec - last_low_attempt.tv_sec) * 1000000LL
                         + (now.tv_nsec - last_low_attempt.tv_nsec) / 1000LL;
            if (us >= LOW_DRAIN_INTERVAL_US)
                force_low = 1;
        }

        if (low_ready || force_low) {
            clock_gettime(CLOCK_MONOTONIC, &last_low_attempt);
            have_last_low_attempt = 1;
            uint16_t len = 0;
            if (process_incoming_frame(g_d2b_low_fd, buf, &len) < 0) {
                fatal = 1;
                break;
            }
            if (len > 0) {
                g_drv_to_tap_low++;
                if (g_drv_to_tap_low <= 5 || (g_drv_to_tap_low % 100) == 0)
                    fprintf(stderr, "tap_bridge: drv→TAP(low) #%lu (%u bytes)\n",
                            g_drv_to_tap_low, len);
            }
        }
    }

    __atomic_store_n(&running, 0, __ATOMIC_SEQ_CST);
    return NULL;
}

static void *outgoing_thread(void *arg)
{
    (void)arg;
    uint8_t buf[RELAY_BUF_MAX];

    pthread_rwlock_wrlock(&g_filter_lock);
    load_filters_internal();
    pthread_rwlock_unlock(&g_filter_lock);

    while (__atomic_load_n(&running, __ATOMIC_RELAXED)) {
        if (retry_ring_flush() < 0) {
            fprintf(stderr, "tap_bridge: b2d write failed (retry flush)\n");
            __atomic_store_n(&running, 0, __ATOMIC_SEQ_CST);
            break;
        }

        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(g_tap_fd, &rfds);

        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
        int ret = select(g_tap_fd + 1, &rfds, NULL, NULL, &tv);
        if (ret < 0) {
            if (errno == EINTR) continue;
            perror("tap_bridge: outgoing select");
            __atomic_store_n(&running, 0, __ATOMIC_SEQ_CST);
            break;
        }
        if (ret == 0) {
            pthread_rwlock_wrlock(&g_filter_lock);
            load_filters_internal();
            pthread_rwlock_unlock(&g_filter_lock);
            continue;
        }

        if (!FD_ISSET(g_tap_fd, &rfds))
            continue;

        ssize_t n = read(g_tap_fd, buf, sizeof(buf));
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            if (n < 0) perror("tap_bridge: read TAP");
            continue;
        }

        uint16_t len = (uint16_t)n;

        pthread_mutex_lock(&g_arp_lock);
        if (len >= 42 && buf[12] == 0x08 && buf[13] == 0x06)
            arp_cache_update(buf + 28, buf + 22);
        try_arp_reply(g_tap_fd, buf, len);
        pthread_mutex_unlock(&g_arp_lock);

        pthread_rwlock_rdlock(&g_filter_lock);
        int drop = should_drop_frame(buf, len, 0);
        pthread_rwlock_unlock(&g_filter_lock);
        if (drop)
            continue;

        uint8_t combined[2 + RELAY_BUF_MAX];
        combined[0] = (uint8_t)(len & 0xFF);
        combined[1] = (uint8_t)((len >> 8) & 0xFF);
        memcpy(combined + 2, buf, len);
        uint16_t total_len = 2 + len;

        if (write_exact(g_b2d_fd, combined, total_len) < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                if (retry_ring_push(combined, total_len) < 0) {
                    fprintf(stderr, "tap_bridge: retry ring full, dropped outgoing frame (%u bytes)\n", len);
                }
            } else {
                fprintf(stderr, "tap_bridge: b2d write failed\n");
                __atomic_store_n(&running, 0, __ATOMIC_SEQ_CST);
                break;
            }
        } else {
            g_tap_to_drv++;
            if (g_tap_to_drv <= 5 || (g_tap_to_drv % 100) == 0)
                fprintf(stderr, "tap_bridge: TAP→drv #%lu (%d bytes)\n", g_tap_to_drv, (int)n);
        }

        replicate_mcast_to_bcast(g_b2d_fd, buf, len, 1);
    }

    __atomic_store_n(&running, 0, __ATOMIC_SEQ_CST);
    return NULL;
}

int main(int argc, char *argv[])
{
    (void)argc; (void)argv;

    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);
    signal(SIGPIPE, SIG_IGN);

    /* Attach to existing TAP (created by run.sh with ip tuntap add) */
    int tap_fd = open_tap(TAP_DEV_NAME);
    if (tap_fd < 0) return 1;
    g_tap_fd = tap_fd;

    detect_local_ip(TAP_DEV_NAME);

    /* Create FIFOs */
    create_fifos();

    fprintf(stderr, "tap_bridge: opening FIFOs (will block until driver connects)...\n");

    /* Open the d2b read ends first (non-blocking) so the driver can open the
     * matching write ends without blocking when it starts up. */
    int d2b_high_fd = open(FIFO_D2B_HIGH, O_RDONLY | O_NONBLOCK);
    if (d2b_high_fd < 0) { perror("open d2b_high"); close(tap_fd); return 1; }
    if (fcntl(d2b_high_fd, F_SETPIPE_SZ, 256 * 1024) < 0)
        perror("tap_bridge: fcntl high pipe size");

    int d2b_low_fd = open(FIFO_D2B_LOW, O_RDONLY | O_NONBLOCK);
    if (d2b_low_fd < 0) { perror("open d2b_low"); close(tap_fd); close(d2b_high_fd); return 1; }
    if (fcntl(d2b_low_fd, F_SETPIPE_SZ, 1024 * 1024) < 0)
        perror("tap_bridge: fcntl low pipe size");

    int b2d_fd = open(FIFO_B2D, O_WRONLY);
    if (b2d_fd < 0) { perror("open b2d"); close(tap_fd); close(d2b_high_fd); close(d2b_low_fd); return 1; }
    int flags = fcntl(b2d_fd, F_GETFL, 0);
    if (flags >= 0) fcntl(b2d_fd, F_SETFL, flags | O_NONBLOCK);

    g_d2b_high_fd = d2b_high_fd;
    g_d2b_low_fd = d2b_low_fd;
    g_b2d_fd = b2d_fd;

    fprintf(stderr, "tap_bridge: FIFOs connected! Relaying frames (dual-thread).\n");

    pthread_t in_thr, out_thr;
    if (pthread_create(&out_thr, NULL, outgoing_thread, NULL) != 0) {
        perror("pthread_create outgoing");
        close(d2b_low_fd);
        close(d2b_high_fd);
        close(b2d_fd);
        close(tap_fd);
        return 1;
    }
    if (pthread_create(&in_thr, NULL, incoming_thread, NULL) != 0) {
        perror("pthread_create incoming");
        __atomic_store_n(&running, 0, __ATOMIC_SEQ_CST);
        pthread_join(out_thr, NULL);
        close(d2b_low_fd);
        close(d2b_high_fd);
        close(b2d_fd);
        close(tap_fd);
        return 1;
    }

    /* Wait for either thread to exit (error or shutdown). */
    pthread_join(in_thr, NULL);
    pthread_join(out_thr, NULL);

    fprintf(stderr, "tap_bridge: shutting down (TAP→drv=%lu, drv→TAP high=%lu low=%lu, drops: ip=%lu mac=%lu bcast=%lu, arp: snooped=%lu replies=%lu)\n",
            g_tap_to_drv, g_drv_to_tap_high, g_drv_to_tap_low, drop_ip, drop_mac, drop_bcast,
            g_arp_snooped, g_arp_replies_sent);

    close(d2b_low_fd);
    close(d2b_high_fd);
    close(b2d_fd);
    close(tap_fd);
    unlink(FIFO_B2D);
    unlink(FIFO_D2B_HIGH);
    unlink(FIFO_D2B_LOW);
    return 0;
}
