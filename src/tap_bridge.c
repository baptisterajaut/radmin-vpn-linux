/*
 * tap_bridge - Relay ethernet frames between a TAP device and two FIFOs.
 *
 * FIFOs (created by this process):
 *   /tmp/rvpn_b2d  — bridge-to-driver (TAP → Wine): bridge writes, driver reads
 *   /tmp/rvpn_d2b  — driver-to-bridge (Wine → TAP): driver writes, bridge reads
 *
 * Frame protocol on FIFOs: [uint16_t length][uint8_t frame[length]]
 * Length is native byte order (both sides are the same machine).
 *
 * The bridge opens (or attaches to) a TAP device, then:
 *   - Reads frames from TAP → writes [len][frame] to b2d FIFO
 *   - Reads [len][frame] from d2b FIFO → writes frame to TAP
 *
 * Build: gcc -Wall -O2 -o tap_bridge tap_bridge.c -lpthread
 * Usage: sudo ./tap_bridge <vpn-ip> [netmask-bits]
 *   e.g.: sudo ./tap_bridge 26.145.88.170 8
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <net/if.h>
#include <linux/if_tun.h>

#define TAP_DEV_NAME    "radminvpn0"
#define FIFO_B2D        "/tmp/rvpn_b2d"
#define FIFO_D2B        "/tmp/rvpn_d2b"
#define MTU             1500
#define FRAME_MAX       (MTU + 14 + 4)

static volatile int running = 1;

static void sig_handler(int sig) { (void)sig; running = 0; }

/* Read exactly n bytes (blocking) */
static int read_exact(int fd, void *buf, size_t n)
{
    size_t done = 0;
    while (done < n) {
        ssize_t r = read(fd, (char *)buf + done, n - done);
        if (r <= 0) return -1;
        done += r;
    }
    return 0;
}

/* Write exactly n bytes (blocking) */
static int write_exact(int fd, const void *buf, size_t n)
{
    size_t done = 0;
    while (done < n) {
        ssize_t w = write(fd, (const char *)buf + done, n - done);
        if (w <= 0) return -1;
        done += w;
    }
    return 0;
}

/* Open/attach to the TAP device */
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

static void create_fifos(void)
{
    unlink(FIFO_B2D);
    unlink(FIFO_D2B);
    mkfifo(FIFO_B2D, 0666);
    mkfifo(FIFO_D2B, 0666);
    fprintf(stderr, "tap_bridge: FIFOs created: %s, %s\n", FIFO_B2D, FIFO_D2B);
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

    /* Create FIFOs */
    create_fifos();

    fprintf(stderr, "tap_bridge: opening FIFOs (will block until driver connects)...\n");

    /* Open FIFOs — these block until the other side opens too.
       Open b2d (write end) first in O_RDWR to avoid blocking,
       then d2b (read end) in O_RDONLY. */
    int b2d_fd = open(FIFO_B2D, O_WRONLY);
    if (b2d_fd < 0) { perror("open b2d"); close(tap_fd); return 1; }

    int d2b_fd = open(FIFO_D2B, O_RDONLY);
    if (d2b_fd < 0) { perror("open d2b"); close(tap_fd); close(b2d_fd); return 1; }

    fprintf(stderr, "tap_bridge: FIFOs connected! Relaying frames.\n");

    /* Relay loop */
    uint8_t buf[FRAME_MAX];
    fd_set rfds;
    int maxfd = (tap_fd > d2b_fd) ? tap_fd : d2b_fd;

    unsigned long tap_to_drv = 0, drv_to_tap = 0;

    while (running) {
        FD_ZERO(&rfds);
        FD_SET(tap_fd, &rfds);
        FD_SET(d2b_fd, &rfds);

        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
        int ret = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (ret < 0) {
            if (errno == EINTR) continue;
            perror("select");
            break;
        }
        if (ret == 0) continue;

        /* TAP → driver (b2d FIFO): read frame from TAP, write [len16][frame] */
        if (FD_ISSET(tap_fd, &rfds)) {
            ssize_t n = read(tap_fd, buf, sizeof(buf));
            if (n > 0) {
                uint16_t len = (uint16_t)n;
                if (write_exact(b2d_fd, &len, 2) < 0 ||
                    write_exact(b2d_fd, buf, len) < 0) {
                    fprintf(stderr, "tap_bridge: b2d write failed\n");
                    break;
                }
                tap_to_drv++;
                if (tap_to_drv <= 5 || (tap_to_drv % 100) == 0)
                    fprintf(stderr, "tap_bridge: TAP→drv #%lu (%d bytes)\n", tap_to_drv, (int)n);
            }
        }

        /* Driver → TAP (d2b FIFO): read [len16][frame], write frame to TAP */
        if (FD_ISSET(d2b_fd, &rfds)) {
            uint16_t len;
            if (read_exact(d2b_fd, &len, 2) < 0) {
                fprintf(stderr, "tap_bridge: d2b read len failed (driver disconnected?)\n");
                break;
            }
            if (len > FRAME_MAX) {
                fprintf(stderr, "tap_bridge: bad frame len %u\n", len);
                break;
            }
            if (read_exact(d2b_fd, buf, len) < 0) {
                fprintf(stderr, "tap_bridge: d2b read frame failed\n");
                break;
            }
            if (write(tap_fd, buf, len) != (ssize_t)len) {
                perror("tap_bridge: write to TAP");
            }
            drv_to_tap++;
            if (drv_to_tap <= 5 || (drv_to_tap % 100) == 0)
                fprintf(stderr, "tap_bridge: drv→TAP #%lu (%u bytes)\n", drv_to_tap, len);
        }
    }

    fprintf(stderr, "tap_bridge: shutting down (TAP→drv=%lu, drv→TAP=%lu)\n", tap_to_drv, drv_to_tap);
    close(d2b_fd);
    close(b2d_fd);
    close(tap_fd);
    unlink(FIFO_B2D);
    unlink(FIFO_D2B);
    return 0;
}
